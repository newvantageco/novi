#!/bin/bash
# ============================================================
# test-lib-json.sh — the shell JSON escaper, checked against a real
# JSON parser, under the SHELL THAT WILL ACTUALLY RUN IT
#
# Run by scripts/lint.sh. Two things make it worth having:
#
# 1. IT USES THE SHIPPED BUSYBOX, not the host's bash. CLAUDE.md
#    records the exact cost of not doing that: `packages/pkg`'s process
#    substitution was "verified working against the real busybox
#    binary" on a host that has /dev/fd, and failed on the image that
#    does not. If ${ROOTFS}/bin/busybox is not built yet this falls
#    back to bash and SAYS SO, because a green tick from the wrong
#    shell is worse than a skip.
#
# 2. THE ORACLE IS PYTHON'S json MODULE, not a string comparison
#    against what the escaper happened to produce. "Did this survive a
#    round trip through a real parser" is the question; "does it look
#    right" is not.
#
# The injection case is the reason any of this exists: every JSON
# document this system emits is assembled by a shell script out of
# strings the shell did not choose.
# ============================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

LIB="packages/lib-json.sh"
BB="/build/rootfs/bin/busybox"
if [ -x "${BB}" ]; then
    SHELL_UNDER_TEST="${BB} ash"
    WHICH="the shipped busybox ash"
else
    SHELL_UNDER_TEST="bash"
    WHICH="bash (WARNING: ${BB} not built, so this did NOT test the target shell)"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

cat > "${WORK}/emit.sh" <<SCRIPT
. $(pwd)/${LIB}
printf '{'
printf '"plain": %s,'      "\$(json_str 'hello world')"
printf '"quote": %s,'      "\$(json_str 'she said "hi"')"
printf '"backslash": %s,'  "\$(json_str 'C:\\path\\to')"
printf '"both": %s,'       "\$(json_str 'a"b\\c"d')"
printf '"newline": %s,'    "\$(json_str "line1
line2")"
printf '"tab": %s,'        "\$(json_str "\$(printf 'a\\tb')")"
printf '"ctrl": %s,'       "\$(json_str "\$(printf 'a\\001b\\002c')")"
printf '"del": %s,'        "\$(json_str "\$(printf 'a\\177b')")"
printf '"utf8": %s,'       "\$(json_str 'café — naïve 日本語')"
printf '"empty": %s,'      "\$(json_str '')"
printf '"spaces": %s,'     "\$(json_str '  padded  ')"
printf '"injection": %s,'  "\$(json_str '", "evil": "yes')"
printf '"bs_then_q": %s,' "\$(json_str '\\"')"
printf '"long": %s,'       "\$(NOVI_JSON_MAX=16 json_str 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaXX')"
printf '"num_ok": %s,'     "\$(json_num 42)"
printf '"num_neg": %s,'    "\$(json_num -7)"
printf '"num_junk": %s,'   "\$(json_num 'N/A')"
printf '"num_empty": %s,'  "\$(json_num '')"
printf '"num_partial": %s,' "\$(json_num '12abc')"
printf '"bool_on": %s,'    "\$(json_bool on)"
printf '"bool_up": %s,'    "\$(json_bool up)"
printf '"bool_off": %s,'   "\$(json_bool off)"
printf '"bool_junk": %s'   "\$(json_bool maybe)"
printf '}\n'
SCRIPT

echo ">>> lib-json under ${WHICH}"
if ! ${SHELL_UNDER_TEST} "${WORK}/emit.sh" > "${WORK}/out.json" 2>"${WORK}/err"; then
    echo "!! the emitter itself failed:" >&2
    cat "${WORK}/err" >&2
    exit 1
fi

python3 - "${WORK}/out.json" <<'PY'
import json, sys

path = sys.argv[1]
raw = open(path, "rb").read()
try:
    d = json.loads(raw.decode("utf-8"))
except Exception as e:
    print("!! the emitter did not produce valid JSON:", e)
    print("   " + raw.decode("utf-8", "replace")[:400])
    sys.exit(1)

want = {
    "plain": "hello world",
    "quote": 'she said "hi"',
    "backslash": r"C:\path\to",
    "both": r'a"b\c"d',
    # A newline cannot appear raw in a JSON string and nothing here
    # wants one, so it becomes a space -- and NOT a trailing one. The
    # first version of the escaper put a trailing space on every string
    # it produced, because `cut` appends a newline to input that had
    # none and the newline->space step ran after it. Valid JSON,
    # silently wrong, and only a round-trip check finds it.
    "newline": "line1 line2",
    "tab": "a b",
    "ctrl": "abc",
    "del": "ab",
    "utf8": "café — naïve 日本語",
    "empty": "",
    "spaces": "  padded  ",
    # The whole reason this file exists.
    "injection": '", "evil": "yes',
    # A backslash FOLLOWED BY a quote -- two characters, and the
    # case that catches escaping them in the wrong order: escape the
    # quote first and its new backslash gets escaped again, so the
    # quote ends the string.
    "bs_then_q": '\\"',
    "long": "aaaaaaaaaaaaaaaa",
    "num_ok": 42,
    "num_neg": -7,
    "num_junk": 0,
    "num_empty": 0,
    "num_partial": 0,
    "bool_on": True,
    "bool_up": True,
    "bool_off": False,
    "bool_junk": False,
}

bad = []
for k, v in want.items():
    if k not in d:
        bad.append(f"{k}: missing from the document")
    elif d[k] != v:
        bad.append(f"{k}: got {d[k]!r}, want {v!r}")
extra = set(d) - set(want)
if extra:
    bad.append(f"unexpected keys: {sorted(extra)}")

if bad:
    print(f"!! {len(bad)} check(s) failed")
    for b in bad:
        print("   ! " + b)
    sys.exit(1)
print(f"lib-json: {len(want)} checks passed, document parsed by json.loads")
PY
