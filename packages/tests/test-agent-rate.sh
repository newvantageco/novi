#!/bin/bash
# ============================================================
# test-agent-rate.sh — agent.rate bounds an accident, and says so
#
# The limit exists to make a RUNAWAY VISIBLE, not to stop an attacker:
# anything that can run `novi-agent do` can run `pkg` directly. So what
# is worth asserting is the behaviour an operator reads off the log.
#
# The subtle one is that only ALLOWED calls count. Counting refusals
# too would make the limit self-sustaining -- each refusal is itself a
# log line, so once tripped it would stay tripped for a full minute
# even if the caller stopped entirely. That is a lockout wearing a
# rate limit's clothes, and it is the kind of thing that reads fine in
# a diff.
# ============================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

AGENT=packages/novi-agent
BUSYBOX=/build/rootfs/bin/busybox

if [ -x "${BUSYBOX}" ]; then
    SH=("${BUSYBOX}" ash)
    echo ">>> agent rate, under the shipped busybox ash"
else
    SH=(sh)
    echo ">>> agent rate, under host sh (no shipped busybox found)" >&2
fi

checks=0
fail=0
note() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }
did() { checks=$((checks + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
AUDIT="${TMP}/audit.jsonl"
STATECONF="${TMP}/system.conf"

# pkg.sync is the cheapest verb to repeat; stand in for it so the test
# does not need a repository.
cat > "${TMP}/pkg" <<'PKG'
#!/bin/sh
exit 0
PKG
chmod +x "${TMP}/pkg"

write_conf() {
    cat > "${STATECONF}" <<CONF
agent.enabled = on
agent.allow = pkg.sync
agent.rate = $1
CONF
}

run_agent() {
    NOVI_AGENT_AUDIT="${AUDIT}" \
    NOVI_STATE="packages/novi-state" \
    NOVI_STATE_FILE="${STATECONF}" \
    NOVI_JSON_LIB="packages/lib-json.sh" \
    NOVI_PKG="${TMP}/pkg" \
    "${SH[@]}" "${AGENT}" "$@"
}

# `grep -c` PRINTS the count and EXITS 1 when the count is zero, so
# `grep -c ... || echo 0` prints "0\n0" and every arithmetic test on
# it fails with "integer expression expected". `|| true` swallows the
# status without adding a second line.
count_in_audit() {
    [ -f "${AUDIT}" ] || { echo 0; return; }
    grep -c "$1" "${AUDIT}" 2>/dev/null || true
}
allowed_count() { count_in_audit '"decision": "allowed"'; }
refused_count() { count_in_audit 'rate limit'; }

# ── 1. no limit by default ───────────────────────────────────────────
write_conf 0
: > "${AUDIT}"
for _ in 1 2 3 4 5 6; do run_agent do pkg.sync >/dev/null 2>&1; done
did; [ "$(allowed_count)" -eq 6 ] || note "agent.rate = 0 must not limit anything (got $(allowed_count)/6)"
did; [ "$(refused_count)" -eq 0 ] || note "agent.rate = 0 must produce no rate refusals"

# ── 2. the limit bites, and is audited ───────────────────────────────
write_conf 3
: > "${AUDIT}"
for _ in 1 2 3 4 5 6; do run_agent do pkg.sync >/dev/null 2>&1; done
did; [ "$(allowed_count)" -eq 3 ] || note "agent.rate = 3 should allow exactly 3 (got $(allowed_count))"
did; [ "$(refused_count)" -eq 3 ] || note "the other 3 should be refused AND audited (got $(refused_count))"
did; grep -q '"reason": "rate limit' "${AUDIT}" ||
    note "the refusal must name the rate limit, so a runaway is legible"

# ── 3. THE SELF-SUSTAINING TRAP: refusals must not count ─────────────
#
# This needs a window where ALLOWED is under the limit while
# allowed+refused is over it -- otherwise both behaviours give the same
# answer and the check cannot fail. The first version of it raised the
# limit and expected one more call through, which passes whether or not
# refusals count. Confirmed the hard way: the bug was introduced on
# purpose and the suite stayed green.
#
# So: limit 5, three allowed calls, then four refusals that are NOT
# rate refusals (state.set is not in agent.allow). Allowed is 3, under
# the limit; every line together is 7, over it. A fourth pkg.sync must
# still go through.
write_conf 5
: > "${AUDIT}"
for _ in 1 2 3; do run_agent do pkg.sync >/dev/null 2>&1; done
for _ in 1 2 3 4; do run_agent do state.set hostname box >/dev/null 2>&1; done
did; [ "$(allowed_count)" -eq 3 ] || note "setup: expected 3 allowed, got $(allowed_count)"
did; [ "$(count_in_audit '"decision": "refused"')" -eq 4 ] ||
    note "setup: expected 4 non-rate refusals"
run_agent do pkg.sync >/dev/null 2>&1
did; [ "$(allowed_count)" -eq 4 ] ||
    note "refusals must not count toward the limit (that is a lockout, not a rate limit)"
did; [ "$(refused_count)" -eq 0 ] ||
    note "no rate refusal should have been issued -- only 3 allowed calls were in the window"

# ── 4. an unusable value does not silently disable the limit ─────────
# novi-state's observer reports `agent.rate = twenty` as drift; what
# matters here is that novi-agent does not crash on it.
write_conf twenty
: > "${AUDIT}"
run_agent do pkg.sync >/dev/null 2>&1
did; [ "$(allowed_count)" -eq 1 ] || note "an unusable agent.rate must not break the verb"
did; [ "$(refused_count)" -eq 0 ] || note "an unusable agent.rate must not refuse everything"

# ── 5. the observer is the place a typo surfaces ─────────────────────
got="$(NOVI_STATE_FILE="${STATECONF}" NOVI_JSON_LIB="packages/lib-json.sh" \
       "${SH[@]}" packages/novi-state get agent.rate 2>/dev/null)"
did; [ "${got}" = "twenty" ] || note "novi-state get should return the raw declared value"

if [ "${fail}" -ne 0 ]; then
    echo "agent rate: ${fail} check(s) FAILED of ${checks}" >&2
    exit 1
fi
echo "agent rate: ${checks} checks passed"
