#!/bin/bash
# ============================================================
# test-agent-idle.sh — `novi-agent describe` composes the idle picture
#
# RFC 0036 roadmap 3. novi-shell publishes /run/novi/idle; the panel
# draws a glyph from it, `novi-power idle` prints it for a person, and
# this puts it in the document an automated actor reads. Three
# properties are worth asserting rather than eyeballing:
#
#   1. ABSENT IS NOT ZERO. A machine with no compositor has no idle
#      clock, and `{"seconds": 0, "awake": false}` would tell an agent
#      that somebody had just touched it. The honest zeros are the
#      indistinguishable ones, which is exactly why this needs a test.
#
#   2. A TIMEOUT THAT IS OFF IS NULL, never the 0 the file spells it
#      with. `"suspend_after": 0` reads as "suspends immediately" --
#      the opposite of the truth, and the one wrong answer that
#      matters.
#
#   3. THE OUTPUT IS STILL JSON when the inputs are hostile. The
#      inhibitor name comes from a client's own app_id; novi-shell has
#      already reduced it to one whitespace-free token, and this side
#      must not be the half that assumes more than that.
#
# Run against the shipped busybox ash where there is one: the target's
# shell is not this host's.
# ============================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

BUSYBOX=/build/rootfs/bin/busybox
if [ -x "${BUSYBOX}" ]; then
    SH=("${BUSYBOX}" ash)
    echo ">>> novi-agent describe (idle), under the shipped busybox ash"
else
    SH=(sh)
    echo ">>> novi-agent describe (idle), under host sh (no shipped busybox found)" >&2
fi

checks=0
fail=0
note() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }
did() { checks=$((checks + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# One hardcoded path, which is right for the tool and unreachable for a
# test. Redirected with a sed rather than by adding an environment
# override to production code purely so a test can reach it -- the same
# call test-power-idle.sh makes over the same file.
sed "s|local file=/run/novi/idle|local file=${TMP}/idle|" packages/novi-agent \
    > "${TMP}/novi-agent"

# describe() also runs novi-state and pkg. Neither is what is under
# test here, and a machine-shaped answer from them is not needed: the
# tool's own fallbacks turn a missing one into `{}`.
cat > "${TMP}/false-tool" <<'T'
#!/bin/sh
exit 1
T
chmod +x "${TMP}/false-tool"

describe() {
    NOVI_JSON_LIB="packages/lib-json.sh" \
    NOVI_STATE="${TMP}/false-tool" \
    NOVI_PKG="${TMP}/false-tool" \
    NOVI_STATE_FILE="${TMP}/system.conf" \
    "${SH[@]}" "${TMP}/novi-agent" describe 2>/dev/null
}

: > "${TMP}/system.conf"

# The idle object, extracted from the whole document by a real JSON
# parser -- not by grep. A test that greps for a substring passes on a
# document that is not JSON at all, which is the failure this most
# needs to catch.
idle_field() {
    python3 -c 'import json,sys
d = json.load(sys.stdin)
v = d.get("idle", {})
for k in sys.argv[1].split("."):
    v = v[k] if isinstance(v, dict) else v
print(json.dumps(v))' "$1"
}

# ── 1. no compositor at all ──────────────────────────────────────────
rm -f "${TMP}/idle"
out="$(describe)"
did; printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' ||
    note "describe must be valid JSON with no idle file"
did; [ "$(printf '%s' "$out" | idle_field present)" = "false" ] ||
    note 'a machine with no compositor must report {"present": false}'
did; printf '%s' "$out" | python3 -c 'import json,sys
d = json.load(sys.stdin)["idle"]
sys.exit(0 if "seconds" not in d and "awake" not in d else 1)' ||
    note "absent must not be reported as a reading of zero"

# ── 2. an ordinary idle desktop ──────────────────────────────────────
cat > "${TMP}/idle" <<'F'
blanked 0
locked 0
idle 35
blank 600
suspend 0
awake 0
inhibit 0
F
out="$(describe)"
did; [ "$(printf '%s' "$out" | idle_field present)" = "true" ] ||
    note "a published idle file must report present"
did; [ "$(printf '%s' "$out" | idle_field seconds)" = "35" ] ||
    note "seconds must come through as a number"
did; [ "$(printf '%s' "$out" | idle_field blank_after)" = "600" ] ||
    note "a live blank timeout must come through as its seconds"
did; [ "$(printf '%s' "$out" | idle_field suspend_after)" = "null" ] ||
    note "suspend = 0 means OFF and must be null, never 0"
did; [ "$(printf '%s' "$out" | idle_field awake)" = "false" ] ||
    note "awake 0 must be false"
did; [ "$(printf '%s' "$out" | idle_field inhibitors)" = "[]" ] ||
    note "no inhibitors must be an empty array"

# ── 3. both askers asking, and both timeouts live ────────────────────
cat > "${TMP}/idle" <<'F'
blanked 1
locked 1
idle 4210
blank 600
suspend 1800
awake 1
inhibit 2
inhibitor org.example.Player
inhibitor novi-panel
F
out="$(describe)"
did; [ "$(printf '%s' "$out" | idle_field awake)" = "true" ] ||
    note "awake 1 must be true"
did; [ "$(printf '%s' "$out" | idle_field blanked)" = "true" ] ||
    note "blanked 1 must be true"
did; [ "$(printf '%s' "$out" | idle_field locked)" = "true" ] ||
    note "locked 1 must be true"
did; [ "$(printf '%s' "$out" | idle_field suspend_after)" = "1800" ] ||
    note "a live suspend timeout must come through as its seconds"
did; [ "$(printf '%s' "$out" | idle_field inhibitors)" = \
    '["org.example.Player", "novi-panel"]' ] ||
    note "every inhibitor named in the file must reach the array"
# The two claims stay separate: a person's Super+A is not an entry in
# the inhibitor list and never becomes one.
did; printf '%s' "$out" | python3 -c 'import json,sys
d = json.load(sys.stdin)["idle"]
sys.exit(0 if len(d["inhibitors"]) == 2 and d["awake"] is True else 1)' ||
    note "awake and the inhibitor list are two claims and must stay two"

# ── 4. keys this script has never heard of ───────────────────────────
# An installed base is never one version, and a novi-shell newer than
# this script will write lines it does not know. Ignoring them is easy
# to write and easy to lose to a `case` that grows an `*)` branch.
cat > "${TMP}/idle" <<'F'
blanked 0
schema 7
idle 12
dim_after 90
awake 1
F
out="$(describe)"
did; printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' ||
    note "an unknown key must not break the document"
did; [ "$(printf '%s' "$out" | idle_field seconds)" = "12" ] ||
    note "an unknown key must not stop the known ones being read"
did; [ "$(printf '%s' "$out" | idle_field blank_after)" = "null" ] ||
    note "a key the file never carried must read as off, not as garbage"

# ── 4b. a timeout that is not a number at all ────────────────────────
# json_num() answers 0 for a value it cannot parse, and 0 is the one
# number this field must never carry. A garbage timeout is an absent
# timeout, not an immediate one.
cat > "${TMP}/idle" <<'F'
idle 3
blank later
suspend -30
awake 0
F
out="$(describe)"
did; printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' ||
    note "a garbage timeout must not break the document"
did; [ "$(printf '%s' "$out" | idle_field blank_after)" = "null" ] ||
    note "a timeout that is not a number must be null, never 0"
did; [ "$(printf '%s' "$out" | idle_field suspend_after)" = "null" ] ||
    note "a negative timeout must be null, never 0"

# ── 5. a name that arrives with something in it ──────────────────────
# novi-shell replaces control characters and spaces with underscores
# before it writes them, so what reaches here is one token. A quote and
# a backslash are NOT in that set -- they pass through, and json.sh is
# what has to survive them. This is the assertion that would have
# caught a describe_idle that built its strings by hand.
cat > "${TMP}/idle" <<'F'
idle 0
awake 0
inhibit 1
inhibitor say"hello\world
F
out="$(describe)"
did; printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' ||
    note "a quote in an app_id must not break the document"
did; [ "$(printf '%s' "$out" | idle_field inhibitors)" = \
    '["say\"hello\\world"]' ] ||
    note "a quote and a backslash must arrive escaped, not mangled"

if [ "${fail}" -ne 0 ]; then
    echo "novi-agent idle: ${fail} check(s) FAILED of ${checks}" >&2
    exit 1
fi
echo "novi-agent idle: ${checks} checks passed"
