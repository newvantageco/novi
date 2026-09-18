#!/bin/bash
# ============================================================
# test-state-document.sh — the shipped document, and the key reference
#
# RFC 0002 roadmap item 3, the half of it that CI can actually do.
#
# The item asked for "`novi-state diff` in CI, and a `--json`
# projection for tooling". THE `--json` PROJECTION ALREADY EXISTED
# when that was written down -- `show --json`, `diff --json` and
# `health --json` were built for RFC 0029's agent interface, which
# composes its document out of them. Fourth roadmap item in this
# repository found to be wrong about what is already built, after
# RFC 0002's own `packages.*`, RFC 0030's "a re-render is not one
# function call", and RFC 0033's wired-network GUI. Check the code.
#
# What `diff` in CI cannot be is the real thing: it observes a RUNNING
# machine -- s6-rc's service list, /run/novi, /proc -- and a CI runner
# has none of that. What it CAN be is this: the observer run over the
# SHIPPED /etc/novi/system.conf, asserting that every key in the
# document is one this novi-state knows.
#
# That is worth having because the failure is silent. An unrecognised
# key observes as `unmanaged` on purpose (forward compatibility, a
# hand-written note), so a TYPO in the shipped document -- or a key
# whose domain was renamed -- ships as a line that looks declarative,
# reads as converged to anyone skimming, and converges nothing. It is
# the same class as the `power.governor = schedutil` line that was
# accidentally uncommented and cost five boots.
#
# Three lists have to agree, and the discipline is the one
# common/keys.h already follows: the DOCUMENT, the DISPATCHER, and the
# HELP TEXT that is the only place a person learns what a key is
# called.
# ============================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

STATE=packages/novi-state
CONF=rootfs/etc/novi/system.conf
JSONLIB="$(pwd)/packages/lib-json.sh"
BUSYBOX=/build/rootfs/bin/busybox

if [ -x "${BUSYBOX}" ]; then
    SH=("${BUSYBOX}" ash)
    echo ">>> the shipped system.conf, under the shipped busybox ash"
else
    SH=(bash)
    echo ">>> the shipped system.conf, under bash (no shipped busybox found)" >&2
fi

checks=0
fail=0
note() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }
did() { checks=$((checks + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# ── the observer, driven off-machine ─────────────────────────────────
#
# novi-state runs its dispatcher at the bottom of the file, so it is
# read up to the Commands marker and no further: enough for the
# observers, not enough to do anything. Same driver shape as
# test-network-static.sh.
cat > "${TMP}/observe" <<'DRIVER'
#!/bin/sh
STATE="$1"; CONF="$2"
NOVI_STATE_FILE="$CONF"; export NOVI_STATE_FILE
sed '/^# Commands$/,$d' "$STATE" > "$CONF.funcs.$$"
# shellcheck source=/dev/null
. "$CONF.funcs.$$"
rm -f "$CONF.funcs.$$"
service_cache_load 2>/dev/null || true
for k in $(state_keys); do
    printf '%s = %s\n' "$k" "$(observe_key "$k" 2>/dev/null)"
done
DRIVER
chmod +x "${TMP}/observe"

cp "${CONF}" "${TMP}/system.conf"
observed="$("${SH[@]}" "${TMP}/observe" "$(pwd)/${STATE}" "${TMP}/system.conf" 2>/dev/null)"

did
[ -n "${observed}" ] || note "the observer produced nothing for ${CONF}"

# ── 1. no key in the shipped document is unmanaged ────────────────────
#
# `unknown` is fine and expected here: services observe through
# `s6-rc`, and `storage.automount` through `novi-mount`, neither of
# which exists on a build host. `unmanaged` is the one answer that
# means novi-state does not recognise the key at all.
unmanaged="$(printf '%s\n' "${observed}" | awk '$3 == "unmanaged" { print $1 }')"
did
if [ -n "${unmanaged}" ]; then
    note "${CONF} declares key(s) this novi-state does not know:"
    printf '       %s\n' ${unmanaged} >&2
fi

declared="$(printf '%s\n' "${observed}" | awk '{ print $1 }' | sort -u)"
did
[ "$(printf '%s\n' "${declared}" | wc -l)" -ge 20 ] ||
    note "only $(printf '%s\n' "${declared}" | wc -l) key(s) observed -- the driver is probably not reading the document"

# ── 2. the help text is a reference, so it has to be complete ────────
#
# `novi-state --help` (the "Keys:" block) is the only place a person
# learns what a key is CALLED. A key that is declared in the shipped
# document and missing from that block is a key nobody can look up;
# the reverse is a reference that promises something the dispatcher
# does not have.
help_keys="$(sed -n '/^Keys:/,/^$/p' "${STATE}" |
    sed -n 's/^  \([a-z][a-z0-9._<>-]*\) .*/\1/p' | sort -u)"
did
[ -n "${help_keys}" ] || note "no key reference found in ${STATE} (the 'Keys:' block moved?)"

# A key name in the reference may carry a <placeholder> for the part
# the person chooses (users.<name>.shell, packages.<name>). Compare on
# the shape rather than the literal.
shape() {
    case "$1" in
        users.*.shell)  printf 'users.<name>.shell' ;;
        users.*.groups) printf 'users.<name>.groups' ;;
        packages.*)     printf 'packages.<name>' ;;
        services.*)     printf 'services.<name>' ;;
        *)              printf '%s' "$1" ;;
    esac
}

for k in ${declared}; do
    want="$(shape "${k}")"
    did
    printf '%s\n' "${help_keys}" | grep -qx -- "${want}" ||
        note "${k} is declared in ${CONF} and not in novi-state's key reference"
done

# ── 3. and every key the reference names is one the dispatcher knows ──
#
# Driven by writing a document that declares each one and asking the
# observer about it: a name in the reference that falls through to
# `unmanaged` is a reference entry for a key that does nothing.
{
    for k in ${help_keys}; do
        case "${k}" in
            *'<name>'*) printf '%s = x\n' "$(printf '%s' "${k}" | sed 's/<name>/testname/')" ;;
            *) printf '%s = x\n' "${k}" ;;
        esac
    done
} > "${TMP}/reference.conf"

ref_observed="$("${SH[@]}" "${TMP}/observe" "$(pwd)/${STATE}" "${TMP}/reference.conf" 2>/dev/null)"
ref_unmanaged="$(printf '%s\n' "${ref_observed}" | awk '$3 == "unmanaged" { print $1 }')"
did
if [ -n "${ref_unmanaged}" ]; then
    note "novi-state's key reference names key(s) its dispatcher does not handle:"
    printf '       %s\n' ${ref_unmanaged} >&2
fi

# ── 4. the --json projection, over the shipped document ──────────────
#
# RFC 0029's `novi-agent describe` composes its document out of these,
# so a --json mode that emits something unparseable breaks the agent
# interface rather than just this command. python3 is already required
# by scripts/lint.sh.
if command -v python3 >/dev/null 2>&1; then
    for mode in show diff; do
        out="$(NOVI_STATE_FILE="${TMP}/system.conf" NOVI_JSON_LIB="${JSONLIB}" \
               "${SH[@]}" "${STATE}" "${mode}" --json 2>/dev/null)"
        did
        printf '%s' "${out}" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null ||
            note "novi-state ${mode} --json did not emit parseable JSON"
    done

    # `health --json` needs s6-svstat, which a build host does not
    # have. What is asserted is that it fails CLEANLY -- nothing on
    # stdout -- because novi-agent reads it as
    # `$(... 2>/dev/null || true)` and substitutes `{}` for an empty
    # answer. A half-document on stdout there would be spliced into
    # describe's JSON and break it.
    if ! command -v s6-svstat >/dev/null 2>&1; then
        out="$(NOVI_STATE_FILE="${TMP}/system.conf" NOVI_JSON_LIB="${JSONLIB}" \
               "${SH[@]}" "${STATE}" health --json 2>/dev/null)"
        did
        [ -z "${out}" ] ||
            note "health --json wrote to stdout while failing: ${out}"
        did
        grep -q "health='{}'" "${STATE%novi-state}novi-agent" ||
            note "novi-agent no longer substitutes {} for an empty health answer"
    fi
else
    did; note "python3 is missing, so the --json projection was not checked"
fi

if [ "${fail}" -eq 0 ]; then
    echo ">>> the shipped document: ${checks} check(s), 0 failure(s)"
    exit 0
fi
echo ">>> the shipped document: ${checks} check(s), ${fail} failure(s)" >&2
exit 1
