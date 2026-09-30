#!/bin/bash
# ============================================================
# test-services.sh — the shipped /etc/services, and musl's parser
#
# RFC 0028 roadmap 3. This file is base content (03-base.sh installs
# it) and nothing in this repository parses it: musl does, inside
# getservbyname(3) and getservbyport(3), and the only thing that calls
# those is `novi-recon ports`. So there is no code here whose tests
# would cover the file -- which is exactly why it needs its own.
#
# EVERY FAILURE MODE HERE IS SILENT. musl does not report a malformed
# line, a duplicate, an over-long name or a split line; it skips or
# misreads and hands back a number, which is indistinguishable from
# "this port has no name" -- the answer the tool prints for the
# hundreds of ports that genuinely have none. A typo in this file
# therefore looks exactly like the feature working.
#
# The two limits checked here were read out of musl 1.2.5's
# src/network/lookup_serv.c and src/network/getnameinfo.c rather than
# assumed from the format:
#
#   * both readers use `fgets(line, 128, f)`, so a line of 128 bytes
#     or more is SPLIT and its tail parsed as a record of its own;
#   * reverse_services() has `if (p-line > 32) continue`, where
#     p-line is the name's length plus its terminator -- so a name of
#     32 bytes or more resolves by name and NOT by port. Half-working,
#     in the direction nobody would test.
#
# The last check is not about this file's format at all: it is RFC
# 0022's rule, that the firewall names ports as NUMBERS. Shipping a
# name table makes `tcp dport ssh` suddenly work, which is the moment
# somebody writes it -- and a rule whose meaning depends on a name
# table means something different on a machine whose table differs.
# The check exists because the file did not exist when that rule was
# written, so nothing enforced it.
# ============================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

SERVICES=rootfs/etc/services
FIREWALL=rootfs/etc/novi/firewall.nft

checks=0
fail=0
note() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }
did() { checks=$((checks + 1)); }

echo ">>> /etc/services"

[ -f "${SERVICES}" ] || { echo "FAIL: ${SERVICES} is missing" >&2; exit 1; }

# 03-base.sh must actually install it. A correct file nobody ships is
# the same amount of naming as no file at all, and this repo has
# shipped that exact shape before (novi-glinfo, packaged and indexed
# and absent from the machine).
did
grep -q 'rootfs/etc/services' build/03-base.sh \
    || note "build/03-base.sh does not install ${SERVICES}"

# ── the format, line by line ─────────────────────────────────────────
declare -A seen_port=()      # "<port>/<proto>" -> name
declare -A seen_name=()      # "<name>/<proto>" -> port
prev_key=0
entries=0

lineno=0
while IFS= read -r line || [ -n "${line}" ]; do
    lineno=$((lineno + 1))

    # musl reads 127 bytes plus a terminator. Measured on the raw line
    # including the newline fgets consumes, because that is what fills
    # the buffer.
    did
    if [ "$(( ${#line} + 1 ))" -ge 128 ]; then
        note "line ${lineno} is $(( ${#line} + 1 )) bytes -- musl splits at 128"
    fi

    case "${line}" in ''|'#'*) continue ;; esac

    # shellcheck disable=SC2206
    f=(${line})
    name="${f[0]}"
    hostport="${f[1]:-}"

    did
    case "${hostport}" in
        *[0-9]/tcp|*[0-9]/udp) ;;
        *) note "line ${lineno}: '${hostport}' is not <port>/tcp or <port>/udp" ; continue ;;
    esac
    port="${hostport%/*}"
    proto="${hostport#*/}"

    did
    case "${port}" in
        ''|*[!0-9]*) note "line ${lineno}: port '${port}' is not a number" ; continue ;;
    esac
    did
    if [ "${port}" -lt 1 ] || [ "${port}" -gt 65535 ]; then
        note "line ${lineno}: port ${port} is outside 1..65535"
    fi

    # reverse_services() skips a name of 32 bytes or more. Silently,
    # and only in the port -> name direction.
    did
    if [ "${#name}" -ge 32 ]; then
        note "line ${lineno}: name '${name}' is ${#name} bytes -- musl will not resolve port ${port} to it"
    fi

    # The forward lookup matches a name anywhere on the line at
    # whitespace boundaries, so a name carrying '#' would be cut by the
    # comment strip and one carrying '/' reads as a port field.
    did
    case "${name}" in
        [A-Za-z]*) ;;
        *) note "line ${lineno}: name '${name}' does not start with a letter" ;;
    esac
    did
    case "${name}" in
        *'#'*|*'/'*) note "line ${lineno}: name '${name}' contains '#' or '/'" ;;
    esac

    # A duplicate port is not an error to musl: reverse_services takes
    # the first match and stops, so the second entry is unreachable by
    # port while still answering by name -- two spellings of one port
    # that disagree about which one gets printed.
    did
    if [ -n "${seen_port[${port}/${proto}]:-}" ]; then
        note "line ${lineno}: ${port}/${proto} already named '${seen_port[${port}/${proto}]}'"
    fi
    seen_port[${port}/${proto}]="${name}"

    did
    if [ -n "${seen_name[${name}/${proto}]:-}" ]; then
        note "line ${lineno}: name '${name}/${proto}' already used for port ${seen_name[${name}/${proto}]}"
    fi
    seen_name[${name}/${proto}]="${port}"

    # Sorted by port, then protocol. Nothing depends on it; a reviewer
    # does, and a duplicate that is not adjacent is a duplicate nobody
    # sees in a diff.
    did
    key="$(( port * 2 ))"
    [ "${proto}" = "udp" ] && key="$(( key + 1 ))"
    if [ "${key}" -lt "${prev_key}" ]; then
        note "line ${lineno}: ${port}/${proto} is out of order"
    fi
    prev_key="${key}"

    entries=$((entries + 1))
done < "${SERVICES}"

did
if [ "${entries}" -lt 40 ]; then
    note "only ${entries} entries parsed -- the file or this parser is wrong"
fi

# The ports this system's own services listen on have to be nameable,
# because those are the ones a person scanning their own machine sees
# first. ssh is the only one Novi ships a service for (RFC 0022).
did
[ "${seen_port[22/tcp]:-}" = "ssh" ] || note "22/tcp is not named 'ssh'"
did
[ "${seen_port[80/tcp]:-}" = "http" ] || note "80/tcp is not named 'http'"
did
[ "${seen_port[443/tcp]:-}" = "https" ] || note "443/tcp is not named 'https'"

# ── RFC 0022: a port name is not a policy ────────────────────────────
#
# The shipped ruleset must name ports as numbers. `nft` resolves a name
# through /etc/services on the machine the rule is applied to, so a
# ruleset that says `ssh` is a ruleset whose meaning is whatever that
# machine's table says -- and until today there was no table at all,
# which is why this could not have been written wrong before.
if [ -f "${FIREWALL}" ]; then
    did
    # Strip comments first: the file explains itself in prose, and the
    # word "ssh" appears there legitimately.
    bad="$(sed 's/#.*//' "${FIREWALL}" \
           | grep -nE '\b(dport|sport)\b[[:space:]]+\{?[[:space:]]*[A-Za-z]' || true)"
    if [ -n "${bad}" ]; then
        note "firewall.nft names a port by NAME, not by number (RFC 0022):"
        printf '%s\n' "${bad}" >&2
    fi
fi

echo ">>> ${checks} check(s), ${entries} entries, ${fail} failure(s)"
[ "${fail}" -eq 0 ] || exit 1
exit 0
