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

# ── 5. THE HANDLER HOLDS NO POLICY, wifi.join included ───────────────
#
# wifi.join is unreachable over the socket, and the refusal lives in
# novi-agent (see test-agent-secrets.sh) rather than here. It was here
# first, and the log never saw it: a boundary that records only what it
# let through says nothing about what was tried (RFC 0016). So what
# this file asserts is the opposite of what it used to -- the verb goes
# THROUGH, carrying the marker that lets the one policy reader refuse
# it and write that down.
request 1000 "wifi.join MyNet" >/dev/null
did; [ "$(sed -n 1p "${TMP}/argv.log" 2>/dev/null)" = "wifi.join" ] ||
    note "the handler must pass wifi.join on; refusing it here loses the audit line"
did; grep -q "VIA=socket" "${TMP}/argv.log" ||
    note "novi-agent cannot refuse a socket-only verb without knowing it came from the socket"

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

# ── 8. the CLIENT half: `novi-agent send` ────────────────────────────
#
# Driving this socket by hand is `s6-ipcclient <path> s6-ioconnect`
# with the request on stdin, which works and which nobody would guess.
# The audience for the non-root path is exactly the reader least
# likely to know skarnet's tool names, so `send` is the same verb with
# the same spelling as `do`.
#
# What is testable here is everything BEFORE the connection: the
# checks that stop a request which would mean something different at
# the other end. The round trip needs a running daemon and belongs on
# a booted machine.
send() {
    NOVI_AGENT_SOCK="$1" NOVI_JSON_LIB="packages/lib-json.sh" \
        "${SH[@]}" packages/novi-agent send "${@:2}" 2>&1
}

out="$(send /nonexistent/sock)"
did; case "${out}" in *"usage: novi-agent send"*) ;; *) note "send with no verb should print its usage" ;; esac

# AN ARGUMENT CONTAINING WHITESPACE CANNOT SURVIVE THE TRIP. The
# protocol is one line split on whitespace, so `pkg.install "a b"`
# would arrive as two arguments and the verb would act on something it
# was never given. Refused here, where the caller still knows what was
# meant.
out="$(send /nonexistent/sock state.set hostname "two words")"
did; case "${out}" in *"may not contain whitespace"*) ;; *) note "an argument with a space must be refused, not silently split" ;; esac

# And the missing socket is named, with the key that creates it --
# "connection refused" would send somebody looking at the wrong layer.
out="$(send /nonexistent/sock pkg.sync)"
did; case "${out}" in *"services.novi-agentd"*) ;; *) note "a missing socket should name the key that creates it" ;; esac

if [ "${fail}" -ne 0 ]; then
    echo "agent socket: ${fail} check(s) FAILED of ${checks}" >&2
    exit 1
fi
echo "agent socket: ${checks} checks passed"
