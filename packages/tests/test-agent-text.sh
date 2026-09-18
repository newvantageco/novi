#!/bin/bash
# ============================================================
# test-agent-text.sh — `describe --text` is a VIEW, not a second answer
#
# RFC 0029 roadmap 3. JSON is what this interface is for and stays the
# default; the table is for the other audience `describe` has always
# had -- a person reading a machine over a serial console, for whom
# one 3 KB line is not a way to read anything.
#
# THE RISK IS DRIFT, and it is worth being precise about which kind.
# The dangerous kind -- two paths that independently gather and
# disagree about what the machine IS -- cannot happen here, because
# each describe_* function reads its sources once and branches on $FMT
# at the printf. What remains is a DISPLAY omission: a field added to
# the JSON branch and forgotten in the text one, which is invisible in
# a diff and looks like nothing at all when you run it.
#
# So the central check is mechanical and needs no list of its own:
# every STRING value in the JSON document must appear somewhere in the
# table.
#
#   * Strings and not numbers, because reformatting a number is the
#     work this mode exists to do -- 1998848 kB is not a thing to read
#     and 1.9 GiB is -- so demanding the raw digits appear would
#     forbid the feature. A string is never reformatted.
#   * Not the `state`, `drift` and `health` subtrees, because those are
#     novi-state's document rendered by novi-state: the table prints
#     its `diff` and its `health`, not its whole state file, and
#     asserting otherwise would be asserting that `describe --text`
#     reimplements `novi-state show`.
#
# The fixture supplies its own `pkg` and `novi-state`, so the packages
# list and the verb list are non-empty and the check has something to
# bite on. Everything else is read off this host, which is the point:
# a real /proc/cpuinfo model name has spaces in it.
# ============================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

BUSYBOX=/build/rootfs/bin/busybox
if [ -x "${BUSYBOX}" ]; then
    SH=("${BUSYBOX}" ash)
    echo ">>> novi-agent describe --text, under the shipped busybox ash"
else
    SH=(sh)
    echo ">>> novi-agent describe --text, under host sh (no shipped busybox found)" >&2
fi

command -v python3 >/dev/null 2>&1 || { echo ">>> no python3 -- skipping" >&2; exit 0; }

checks=0
fail=0
note() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }
did() { checks=$((checks + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

sed "s|local file=/run/novi/idle|local file=${TMP}/idle|" packages/novi-agent \
    > "${TMP}/novi-agent"

# A novi-state that answers the three calls `describe` makes of it and
# nothing else. Real enough that both branches have something to show,
# fake enough that this test does not need a machine.
cat > "${TMP}/novi-state" <<'T'
#!/bin/sh
case "$1 ${2:-}" in
    "get agent.allow")  printf 'state.set pkg.sync\n' ;;
    "show --json")      printf '{"state_file": "/etc/novi/system.conf", "declared": {"hostname": "fixture"}}\n' ;;
    "diff --json")      printf '{"drift": [], "converged": true, "unhealthy": []}\n' ;;
    "health --json")    printf '{"services": [], "healthy": true}\n' ;;
    "diff ")            printf 'system matches declared state\n' ;;
    "health ")          printf 'syslog UP -\n' ;;
    *)                  exit 1 ;;
esac
T
chmod +x "${TMP}/novi-state"

cat > "${TMP}/pkg" <<'T'
#!/bin/sh
[ "$1" = list ] || exit 1
printf 'novi-recon                     0.1.0\n'
printf 'python                         3.11.16\n'
T
chmod +x "${TMP}/pkg"

# agent.enabled is read through novi-state's own state file reader, not
# through the stub above, so the policy comes from a real document.
cat > "${TMP}/system.conf" <<'T'
agent.enabled = on
agent.allow = state.set pkg.sync
T

agent() {
    NOVI_JSON_LIB="packages/lib-json.sh" \
    NOVI_STATE="${TMP}/novi-state" \
    NOVI_PKG="${TMP}/pkg" \
    NOVI_STATE_FILE="${TMP}/system.conf" \
    NOVI_AGENT_AUDIT="${TMP}/audit.jsonl" \
    NOVI_AGENT_SOCK="${TMP}/no-such-sock" \
    "${SH[@]}" "${TMP}/novi-agent" "$@" 2>/dev/null
}

# A compositor's worth of idle state, so the section has strings in it.
cat > "${TMP}/idle" <<'T'
idle 312
blanked 0
locked 0
blank 600
suspend 0
awake 1
inhibitor org.novi.netsurf
T

JSON="$(agent describe)"
TEXT="$(agent describe --text)"

# ── 1. the JSON form is untouched ────────────────────────────────────
did
printf '%s' "${JSON}" | python3 -c 'import json,sys; json.load(sys.stdin)' \
    || note "describe still has to emit valid JSON"

# Two runs of the same command are a second apart, so uptime_seconds
# and mem_available_kb legitimately differ. Compare the KEY STRUCTURE,
# which is the thing a flag must not change.
shape() {
    python3 -c '
import json, sys
def keys(v, p=""):
    if isinstance(v, dict):
        for k in v: yield from keys(v[k], p + "." + k)
    elif isinstance(v, list):
        for x in v: yield from keys(x, p + "[]")
    else:
        yield p + ":" + type(v).__name__
print("\n".join(sorted(keys(json.load(sys.stdin)))))'
}
did
[ "$(printf '%s' "$(agent describe --json)" | shape)" \
  = "$(printf '%s' "${JSON}" | shape)" ] \
    || note "--json and no flag must produce the same document"

# An unknown flag is REFUSED, not ignored. `describe --txt` quietly
# producing JSON is a script that looks like it works.
did
if agent describe --txt >/dev/null 2>&1; then
    note "describe --txt was accepted; an unknown option must be refused"
fi

# ── 2. every string in the document appears in the table ─────────────
mapfile -t STRINGS < <(printf '%s' "${JSON}" | python3 -c '
import json, sys
doc = json.load(sys.stdin)
# novi-state renders its own document; see the header.
for k in ("state", "drift", "health", "schema"):
    doc.pop(k, None)
out = []
def walk(v):
    if isinstance(v, dict):
        for x in v.values(): walk(x)
    elif isinstance(v, list):
        for x in v: walk(x)
    elif isinstance(v, str) and v.strip():
        out.append(v)
walk(doc)
# A duplicate teaches nothing and makes the count lie.
for s in dict.fromkeys(out): print(s)
')

did
[ "${#STRINGS[@]}" -ge 8 ] \
    || note "only ${#STRINGS[@]} strings extracted -- the fixture or the extractor is wrong"

for s in "${STRINGS[@]}"; do
    did
    case "${TEXT}" in
        *"${s}"*) ;;
        *) note "the table does not show '${s}', which the JSON reports" ;;
    esac
done

# ── 3. the decisions the table makes on its own ──────────────────────
#
# These are the places where the text is deliberately NOT a
# transliteration, so nothing above can check them.

# A timeout that is off prints the document's own word. `0` reads as
# "immediately", which is the opposite of the truth -- the same wrong
# answer the JSON branch avoids by emitting null.
#
# Matched as a WHOLE ROW, because a `*"sleep after"*"off"*` glob can
# be satisfied by the word "off" anywhere further down the table --
# and it was, by the agent section's "agent.enabled is off". A probe
# that cannot fail is the mistake this repository keeps finding in its
# own tests rather than in its code, so these read one line out of the
# output and compare it.
row() { printf '%s\n' "${1}" | sed -n "s/^  ${2} *//p"; }

did
[ "$(row "${TEXT}" 'sleep after')" = "off" ] \
    || note "a suspend timeout of 0 must print 'off', not '$(row "${TEXT}" 'sleep after')'"
did
[ "$(row "${TEXT}" 'blank after')" = "10m 0s" ] \
    || note "blank after 600 seconds should read as '10m 0s', not '$(row "${TEXT}" 'blank after')'"

# An absent socket is a sentence naming the fix, not `null` and not a
# blank. "novi-agentd is not running" and "it is, and here is where"
# are different problems.
did
case "${TEXT}" in
    *"services.novi-agentd"*) ;;
    *) note "an absent agent socket must say how to get one" ;;
esac

# A machine with no compositor at all: absent is its own answer in the
# table too, not a row of zeros.
rm -f "${TMP}/idle"
NOIDLE="$(agent describe --text)"
did
case "${NOIDLE}" in
    *"no idle clock"*) ;;
    *) note "with no /run/novi/idle the table must say there is no clock" ;;
esac
did
case "${NOIDLE}" in
    *"stay awake"*) note "with no compositor the table must not report an idle reading" ;;
esac

# An empty value is a dash, never a blank column: present-and-empty and
# absent look identical otherwise, and they are different facts.
did
case "${NOIDLE}" in
    *"wifi          -"*) ;;
    *) note "an empty value must render as '-'" ;;
esac

# ── 4. novi-state's own renderers, not a second copy ─────────────────
did
case "${TEXT}" in
    *"system matches declared state"*) ;;
    *) note "the table must show novi-state's own diff output" ;;
esac
did
case "${TEXT}" in
    *"syslog UP"*) ;;
    *) note "the table must show novi-state's own health output" ;;
esac

echo ">>> novi-agent describe --text: ${checks} check(s), ${fail} failure(s)"
[ "${fail}" -eq 0 ] || exit 1
exit 0
