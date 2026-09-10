#!/bin/bash
# ============================================================
# test-agent-secrets.sh — a passphrase must not reach the audit log
#
# `wifi.join` is the first agent verb that handles a SECRET, and the
# rule it has to keep is RFC 0005's: configuration is declared,
# secrets are not. The SSID is configuration and belongs in
# /var/log/novi-agent.jsonl; the passphrase belongs nowhere but the
# pipe it arrives on.
#
# THE REFUSAL PATH IS THE ONE THAT IS EASY TO GET WRONG, and it is
# most of what this file tests. cmd_do captures `args="$*"` before it
# dispatches, so a caller who makes the obvious mistake --
# `wifi.join <ssid> <passphrase>`, putting the secret in argv where
# every other verb puts its arguments -- would have that passphrase
# written to a 0600 file permanently, BY THE REFUSAL that was supposed
# to protect them. A boundary that leaks the thing it is guarding
# while reporting that it refused is worse than no boundary.
#
# Runs the real script under the SHIPPED BusyBox ash where one is
# built, for the reason CLAUDE.md records about packages/pkg: testing
# the shell answers a different question than testing the image.
# ============================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

AGENT=packages/novi-agent
BUSYBOX=/build/rootfs/bin/busybox
SECRET='hunter2-correct-horse'

if [ -x "${BUSYBOX}" ]; then
    SH=("${BUSYBOX}" ash)
    echo ">>> agent secrets, under the shipped busybox ash"
else
    SH=(sh)
    echo ">>> agent secrets, under host sh (no shipped busybox found)" >&2
fi

checks=0
fail=0
note() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }
ok()   { checks=$((checks + 1)); [ "$1" = 0 ] || note "$2"; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

AUDIT="${TMP}/audit.jsonl"
STATECONF="${TMP}/system.conf"

# agent.enabled on and every verb allowed, so nothing is refused for
# policy reasons and the refusals we see are the ones under test.
cat > "${STATECONF}" <<CONF
agent.enabled = on
agent.allow = state.set, state.apply, state.rollback, pkg.sync, pkg.install, wifi.join
CONF

# A novi-wifi stand-in that records what it was handed. The real one
# needs a supplicant; what is under test is what novi-agent passes and
# what it writes down, not whether a radio associated.
cat > "${TMP}/novi-wifi" <<'WIFI'
#!/bin/sh
# args land in argv.log, stdin lands in stdin.log
printf '%s\n' "$*" >> "$(dirname "$0")/argv.log"
cat >> "$(dirname "$0")/stdin.log"
exit 0
WIFI
chmod +x "${TMP}/novi-wifi"

run_agent() {
    # Every path novi-agent touches is redirected, so this never reads
    # or writes the machine running the test:
    #   NOVI_AGENT_AUDIT  the log, into the temp dir
    #   NOVI_STATE        the repo's novi-state, not one on PATH
    #   NOVI_STATE_FILE   a system.conf written above
    #   NOVI_JSON_LIB     the repo's escaper -- /usr/lib/novi/json.sh
    #                     exists on the TARGET and not on a build host,
    #                     and novi-agent refuses to run without it
    #                     because every one of its outputs is JSON
    #   NOVI_WIFI         a stand-in that records what it was handed
    NOVI_AGENT_AUDIT="${AUDIT}" \
    NOVI_STATE="packages/novi-state" \
    NOVI_STATE_FILE="${STATECONF}" \
    NOVI_JSON_LIB="packages/lib-json.sh" \
    NOVI_WIFI="${TMP}/novi-wifi" \
    "${SH[@]}" "${AGENT}" "$@"
}

# ── 1. the mistake: passphrase as a second argument ──────────────────
printf '' | run_agent do wifi.join "MyNet" "${SECRET}" >/dev/null 2>&1
ok $([ -f "${AUDIT}" ] && echo 0 || echo 1) "the refusal should have been audited"
if [ -f "${AUDIT}" ]; then
    if grep -q -- "${SECRET}" "${AUDIT}"; then
        note "THE PASSPHRASE REACHED THE AUDIT LOG on the refusal path"
    fi
    checks=$((checks + 1))
    grep -q "withheld" "${AUDIT}" ||
        note "the refusal should say the arguments were withheld"
    checks=$((checks + 1))
fi

# ── 2. the correct call: passphrase on stdin ─────────────────────────
: > "${AUDIT}"
printf '%s\n' "${SECRET}" | run_agent do wifi.join "MyNet" >/dev/null 2>&1

grep -q -- "${SECRET}" "${AUDIT}" &&
    note "THE PASSPHRASE REACHED THE AUDIT LOG on the success path"
checks=$((checks + 1))

grep -q '"args": "MyNet"' "${AUDIT}" ||
    note "the SSID should be audited (it is configuration, not a secret)"
checks=$((checks + 1))

# The secret must have gone down the PIPE and not into argv.
if [ -f "${TMP}/argv.log" ]; then
    grep -q -- "${SECRET}" "${TMP}/argv.log" &&
        note "THE PASSPHRASE REACHED novi-wifi's ARGV (/proc/pid/cmdline is world-readable)"
    checks=$((checks + 1))
    grep -q -- "--stdin" "${TMP}/argv.log" ||
        note "novi-wifi should have been called with --stdin"
    checks=$((checks + 1))
fi
if [ -f "${TMP}/stdin.log" ]; then
    grep -q -- "${SECRET}" "${TMP}/stdin.log" ||
        note "the passphrase should have reached novi-wifi on stdin"
    checks=$((checks + 1))
fi

# ── 3. a hostile SSID is refused without echoing it back ─────────────
: > "${AUDIT}"
printf '%s\n' "${SECRET}" | run_agent do wifi.join "-oProxyCommand=evil" >/dev/null 2>&1
grep -q "invalid ssid" "${AUDIT}" ||
    note "an SSID starting with - should be refused"
checks=$((checks + 1))

if [ "${fail}" -ne 0 ]; then
    echo "agent secrets: ${fail} check(s) FAILED of ${checks}" >&2
    exit 1
fi
echo "agent secrets: ${checks} checks passed, no passphrase in the log"
