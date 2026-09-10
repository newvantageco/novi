#!/bin/bash
# ============================================================
# test-agent-socket.sh — novi-agent-serve parses a stranger's line
#
# RFC 0032. This is the first place in the agent interface where text
# from a possibly-UNPRIVILEGED caller is read by a process running as
# ROOT, so the parser is the part worth testing and the shell is the
# part worth being afraid of.
#
# The one that would actually bite: `set -- $line` is how a request
# becomes arguments, and unquoted expansion in a shell expands GLOBS
# as well as splitting words. Without `set -f` a request of
# `state.set hostname *` arrives as the contents of the working
# directory. Nothing about that looks wrong in a diff.
#
# Runs against a novi-agent stand-in: what is under test is what the
# handler PASSES ON and what it refuses, not what novi-agent then does
# with it -- that has its own tests.
# ============================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

# Absolute: the glob check below cd's into a directory with known
# contents, and a relative path to the handler would simply not exist
# from there -- which looks exactly like the handler failing to run.
SERVE="$(pwd)/packages/novi-agent-serve"
BUSYBOX=/build/rootfs/bin/busybox

if [ -x "${BUSYBOX}" ]; then
    SH=("${BUSYBOX}" ash)
    echo ">>> agent socket, under the shipped busybox ash"
else
    SH=(sh)
    echo ">>> agent socket, under host sh (no shipped busybox found)" >&2
fi

checks=0
fail=0
note() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }
did() { checks=$((checks + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# Records argv, one argument per line, so a test can tell "one
# argument containing a space" from "two arguments".
cat > "${TMP}/agent" <<'AGENT'
#!/bin/sh
shift            # drop the literal "do"
for a in "$@"; do printf '%s\n' "$a"; done > "$(dirname "$0")/argv.log"
printf 'PEER=%s VIA=%s\n' "${NOVI_AGENT_PEER_UID:-}" "${NOVI_AGENT_VIA:-}" \
    >> "$(dirname "$0")/argv.log"
AGENT
chmod +x "${TMP}/agent"

# request <uid> <line...>  -> prints the handler's stdout
request() {
    local uid="$1"; shift
    rm -f "${TMP}/argv.log"
    printf '%s\n' "$*" | PROTO=IPC IPCREMOTEEUID="${uid}" \
        NOVI_AGENT="${TMP}/agent" "${SH[@]}" "${SERVE}" 2>/dev/null
}

# ── 1. a plain request is passed through verbatim ────────────────────
request 1000 "state.set hostname box" >/dev/null
did; [ "$(sed -n 1p "${TMP}/argv.log" 2>/dev/null)" = "state.set" ] || note "verb should be passed through"
did; [ "$(sed -n 3p "${TMP}/argv.log" 2>/dev/null)" = "box" ] || note "arguments should be passed through"

# ── 2. THE GLOB. Without `set -f` this becomes a directory listing ───
cd "${TMP}"   # somewhere with known contents
: > aaa.tmp; : > bbb.tmp
request 1000 "state.set hostname *" >/dev/null
did; [ "$(sed -n 3p "${TMP}/argv.log" 2>/dev/null)" = "*" ] ||
    note "an asterisk must reach novi-agent as an asterisk, not a file list"
did; [ "$(grep -c . "${TMP}/argv.log" 2>/dev/null)" -eq 4 ] ||
    note "a globbed request should produce exactly 3 arguments plus the PEER line"
cd - >/dev/null

# ── 3. the peer uid the KERNEL reported reaches novi-agent ───────────
request 1234 "pkg.sync" >/dev/null
did; grep -q "PEER=1234 VIA=socket" "${TMP}/argv.log" ||
    note "the peer uid and call path must reach novi-agent for the audit"

# ── 4. no credentials, no service ────────────────────────────────────
out="$(printf 'pkg.sync\n' | PROTO=IPC NOVI_AGENT="${TMP}/agent" \
       "${SH[@]}" "${SERVE}" 2>/dev/null)"
did; case "${out}" in *"no peer credentials"*) ;; *) note "a request with no IPCREMOTEEUID must be refused" ;; esac
out="$(printf 'pkg.sync\n' | PROTO=IPC IPCREMOTEEUID=notanumber \
       NOVI_AGENT="${TMP}/agent" "${SH[@]}" "${SERVE}" 2>/dev/null)"
did; case "${out}" in *"no peer credentials"*) ;; *) note "a non-numeric uid must be refused" ;; esac

# ── 5. wifi.join is not reachable here, and says why ─────────────────
out="$(request 1000 "wifi.join MyNet")"
did; case "${out}" in *"not available over the socket"*) ;; *) note "wifi.join must be refused over the socket" ;; esac
did; [ ! -f "${TMP}/argv.log" ] || [ ! -s "${TMP}/argv.log" ] ||
    note "a refused wifi.join must not reach novi-agent at all"

# ── 6. bounds on a stranger's text ───────────────────────────────────
long="$(head -c 600 < /dev/zero | tr '\0' 'a')"
out="$(request 1000 "state.set hostname ${long}")"
did; case "${out}" in *"too long"*) ;; *) note "an over-long request must be refused" ;; esac

out="$(printf 'state.set hostname a\tb\001c\n' | PROTO=IPC IPCREMOTEEUID=1000 \
       NOVI_AGENT="${TMP}/agent" "${SH[@]}" "${SERVE}" 2>/dev/null)"
did; case "${out}" in *"control characters"*) ;; *) note "control characters must be refused" ;; esac

# ── 7. run by hand at a shell, it explains itself ────────────────────
out="$(printf 'pkg.sync\n' | NOVI_AGENT="${TMP}/agent" "${SH[@]}" "${SERVE}" 2>&1)"
did; case "${out}" in *"per-connection handler"*) ;; *) note "without PROTO=IPC it should explain what it is" ;; esac

if [ "${fail}" -ne 0 ]; then
    echo "agent socket: ${fail} check(s) FAILED of ${checks}" >&2
    exit 1
fi
echo "agent socket: ${checks} checks passed"
