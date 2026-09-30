#!/bin/bash
# ============================================================
# test-state-time.sh — the time domain (RFC 0042)
#
# What is checked here is the part a running machine never shows you.
# `time.timezone` becomes a PATH -- /etc/localtime is symlinked at
# /usr/share/zoneinfo/<value> -- so the interesting inputs are the
# ones nobody types on purpose: a traversal, an absolute path, a
# name with a space, a zone that is not installed. Each of those has
# a quiet failure mode, and the quietest is the traversal: musl reads
# whatever it is pointed at, fails to parse it as TZif, and falls
# back to UTC without a word. A machine that ends up in UTC is
# exactly what an unconfigured machine looks like.
#
# THE ROOT IS DOCTORED INTO /tmp, and the sed is ASSERTED rather than
# assumed -- test-state-packages.sh's pattern, for its reason: a
# substitution that matched nothing would leave the converger writing
# the BUILD CONTAINER's own /etc/localtime, and the test would pass
# while reconfiguring the machine running it.
#
# The zone tree is a fixture, not the host's. This runs on a CI
# runner that may have no tzdata at all, and a check that quietly
# stops checking where the data is missing is the failure this
# repository keeps writing tests to avoid.
# ============================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

STATE=packages/novi-state
HOOK=packages/novi-ntp-hook
NTPRUN=init/services/ntp/run
CONF=rootfs/etc/novi/system.conf
BUSYBOX=/build/rootfs/bin/busybox

if [ -x "${BUSYBOX}" ]; then
    SH=("${BUSYBOX}" ash)
    echo ">>> the time domain, under the shipped busybox ash"
else
    SH=(sh)
    echo ">>> the time domain, under host sh (no shipped busybox found)" >&2
fi

checks=0
fail=0
note() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }
did() { checks=$((checks + 1)); }
is() {  # is <label> <got> <want>
    did
    [ "$2" = "$3" ] || note "$1: got '$2' want '$3'"
}

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# ── a zone tree that is ours ─────────────────────────────────────────
#
# Real TZif content is not needed by anything under test here: the
# validator asks whether a FILE EXISTS, which is the only question it
# can answer offline, and the observer reads a symlink's text. What
# musl does with the bytes is checked in build/42-tzdata.sh, against
# the real compiler, where a wrong answer is a wrong answer.
ZI="${TMP}/zoneinfo"
mkdir -p "${ZI}/Europe" "${ZI}/America" "${ZI}/Etc"
: > "${ZI}/UTC"
: > "${ZI}/Europe/London"
: > "${ZI}/America/New_York"
: > "${ZI}/Etc/GMT+5"
LT="${TMP}/localtime"

# ── a doctored novi-state, with both paths pointed into TMP ──────────
DOC="${TMP}/novi-state"
sed -e "s#/usr/share/zoneinfo#${ZI}#g" \
    -e "s#/etc/localtime#${LT}#g" \
    "${STATE}" > "${DOC}"

# THE SUBSTITUTIONS ARE ASSERTED. Without this the next two hundred
# lines would be testing the container's own clock configuration.
did
if grep -q '/etc/localtime' "${DOC}" || grep -q '/usr/share/zoneinfo' "${DOC}"; then
    note "the doctoring sed left a real system path in the copy -- refusing to run"
    echo "  ${checks} check(s), ${fail} failure(s)"
    exit 1
fi
did
grep -q "${ZI}" "${DOC}" || note "the doctoring sed matched nothing at all"

# novi-state runs its dispatcher at the bottom, so the copy is read
# only as far as the functions.
DRIVER="${TMP}/drive"
cat > "${DRIVER}" <<'DRIVE'
#!/bin/sh
state="$1"; shift
sed '/^observe_key() {/,$d' "$state" > "$state.funcs"
# shellcheck disable=SC1090
. "$state.funcs"
case "$1" in
    valid)    valid_timezone "$2" && echo yes || echo no ;;
    observe)  observe_timezone; echo ;;
    converge) converge_timezone "$2" 2>&1 && echo "OK" ;;
    # STATE_FILE is bound at SOURCE time (novi-state line 33), so
    # NOVI_STATE_FILE has to be set before the `.` above, not in front
    # of the call. Setting it on the function did nothing and every
    # server case read the empty document -- a test bug that looked
    # exactly like a broken observer.
    servers)  observe_ntp_servers; echo ;;
esac
DRIVE
drive() { "${SH[@]}" "${DRIVER}" "${DOC}" "$@" 2>&1; }
drive_conf() { NOVI_STATE_FILE="$1" "${SH[@]}" "${DRIVER}" "${DOC}" servers 2>&1; }

echo "== a zone name is a path, so it is validated like one"
for good in UTC Europe/London America/New_York Etc/GMT+5; do
    is "valid: ${good}" "$(drive valid "${good}")" yes
done
# The traversal is the case this validator exists for. Without it
# /etc/localtime points at the password file, musl reads it as a
# corrupt TZif, and the machine silently reads UTC.
for bad in \
    '../../../etc/shadow' \
    '/etc/shadow' \
    'Europe/../../../etc/shadow' \
    '' \
    'Europe/Lon don' \
    'Europe/London;reboot' \
    'Europe/London$(id)' \
    'Atlantis/Nowhere' \
    '/UTC' \
    '//UTC'
do
    is "refused: '${bad}'" "$(drive valid "${bad}")" no
done
# WHY '/UTC' IS IN THAT LIST, and why it was added after the fact.
# Provoking each clause of the validator separately showed that NONE
# of them changed an answer on its own, which reads exactly like four
# dead guards. Two things were actually true and only measurement
# separated them:
#
#   - `*..*` and the dot-exclusion in the character class are
#     OVERLAPPING, deliberately. Drop either and the other still
#     refuses a traversal; drop BOTH and '../../../etc/shadow' is
#     accepted. Defence in depth that works, not dead code -- and
#     reading the code rather than mutating it would have left the
#     wrong conclusion in place.
#
#   - the `/*` clause had no case at all here. '/etc/shadow' is
#     refused by the existence check whatever the guard does, so it
#     proved nothing; '/UTC' resolves to a file that DOES exist
#     (a leading slash just collapses) and was accepted with the
#     guard removed. The one input that could tell the difference
#     was the one the first draft of this test did not have.

echo "== the observer reads the LINK, and distinguishes four machines"
rm -f "${LT}"
is "absent -> UTC (what musl actually does)" "$(drive observe)" UTC

ln -sfn "../usr/share/zoneinfo/Europe/London" "${LT}"
is "relative link (what stage 42 writes)" "$(drive observe)" Europe/London

ln -sfn "${ZI}/America/New_York" "${LT}"
is "absolute link (what a person writes by hand)" "$(drive observe)" America/New_York

# A COPY is a real configuration and nothing in the file says which
# zone it came from. Guessing would be worse than saying so.
rm -f "${LT}"; cp "${ZI}/UTC" "${LT}"
is "a regular file -> unknown, not a guess" "$(drive observe)" unknown

# A DANGLING link is not the same as UTC, and `readlink -f` would
# have made them identical. This is why the observer reads the link
# text rather than resolving it.
rm -f "${LT}"; ln -sfn "../usr/share/zoneinfo/Atlantis/Nowhere" "${LT}"
is "dangling link names the zone that is missing" "$(drive observe)" Atlantis/Nowhere

rm -f "${LT}"; ln -sfn /dev/null "${LT}"
is "a link outside the database -> unknown" "$(drive observe)" unknown

echo "== the converger writes a RELATIVE link, and refuses the rest"
rm -f "${LT}"
did; out="$(drive converge Europe/London)"
[ "${out}" = "OK" ] || note "converge Europe/London: ${out}"
did
[ -L "${LT}" ] || note "converge did not make a symlink"
# Relative on purpose: an absolute link resolves against the RUNNING
# system rather than an A/B slot being written (RFC 0041).
# Derived from the doctored directory exactly as converge_timezone
# derives it. Writing "../usr/share/zoneinfo/..." here would have been
# a second spelling of the very thing this check is about.
WANTLINK="../${ZI#/}/Europe/London"
is "link is relative" "$(readlink "${LT}")" "${WANTLINK}"
is "and the observer reads it back" "$(drive observe)" Europe/London

did; out="$(drive converge ../../etc/shadow)"
case "${out}" in *"not a zone"*) ;; *) note "converge traversal: ${out}" ;; esac
did
# THE REFUSAL MUST NOT HAVE MOVED THE LINK. A converger that validates
# after writing is a converger that breaks the machine and then
# complains.
is "a refused converge leaves the link alone" \
   "$(readlink "${LT}")" "${WANTLINK}"

did; out="$(drive converge Atlantis/Nowhere)"
case "${out}" in *"not a zone"*) ;; *) note "converge absent zone: ${out}" ;; esac

echo "== time.ntp.servers: canonical, and a host name is a host name"
mkconf() { printf 'time.ntp.servers = %s\n' "$1" > "${TMP}/conf"; echo "${TMP}/conf"; }
is "none"        "$(drive_conf "$(mkconf none)")"        none
is "off (verbatim, not folded into none)" "$(drive_conf "$(mkconf off)")" off
is "one server"  "$(drive_conf "$(mkconf pool.ntp.org)")" pool.ntp.org
# The DECLARED string comes back verbatim when the list is fine --
# the document's own formatting is not this tool's to correct, the
# call network.firewall.allow already made about ports.
is "order and spacing preserved when valid" \
   "$(drive_conf "$(mkconf 'b.example, a.example')")" "b.example, a.example"
is "a space in a name is refused" \
   "$(drive_conf "$(mkconf 'a.example b.example')")" unsupported
is "a metacharacter is refused" \
   "$(drive_conf "$(mkconf 'a.example;reboot')")" unsupported

echo "== the three lists agree (document, dispatcher, help text)"
for key in time.timezone time.ntp.servers; do
    did; grep -q "^#\{0,1\}[[:space:]]*${key}[[:space:]]*=" "${CONF}" ||
        note "${key} is not named in the shipped ${CONF}"
    did; grep -q "^[[:space:]]*${key})" "${STATE}" ||
        note "${key} is not in novi-state's observe dispatcher"
    did; grep -q "^  ${key} " "${STATE}" ||
        note "${key} is missing from novi-state --help's Keys: block"
done
# AND THE KEY THAT MUST NOT EXIST. Turning the client on is
# `services.ntp`; a `time.ntp` key would be a second spelling of one
# decision, which is what RFC 0029 decision 10 refused for
# `firewall.allow`. "We agreed not to" is not a mechanism.
did
if grep -qE '^[[:space:]]*time\.ntp\)' "${STATE}"; then
    note "a bare time.ntp key appeared -- services.ntp already says this"
fi

echo "== the ntp service refuses rather than inventing a server"
did; grep -q 'exit 1' "${NTPRUN}" ||
    note "the ntp run script has no refusal path at all"
did
# A POOL NOBODY NAMED IS THE FAILURE THIS CHECKS FOR. A default like
# pool.ntp.org reads as helpful and means the machine contacts a
# third party the operator never chose.
if grep -qE '\-p[[:space:]]+[a-z0-9.]*(pool|ntp\.org|time\.[a-z]+\.com)' "${NTPRUN}"; then
    note "the ntp run script carries a built-in server"
fi
did; grep -q 'set -f' "${NTPRUN}" ||
    note "the ntp run script splits a list without set -f -- a name could glob"
did; grep -q 'notification-fd' <(ls init/services/ntp) &&
    note "the ntp service declares a readiness it cannot signal (RFC 0014)"

echo "== the RTC hook writes UTC, and only when the clock is trusted"
did; grep -q 'hwclock -u -w' "${HOOK}" ||
    note "the hook does not pass -u: hwclock would write LOCAL time to the RTC"
did
# `unsync` means ntpd has lost its peers and no longer believes its
# own clock. Persisting it would save exactly the reading that should
# not outlive this boot.
if grep -qE '^[[:space:]]*step\|.*unsync|unsync.*\)' "${HOOK}"; then
    note "the hook writes the RTC on 'unsync'"
fi
hookrun() { "${SH[@]}" "${HOOK}" "$@" >"${TMP}/out" 2>&1; echo "$?"; }
is "no argument is a no-op"  "$(hookrun)"         0
is "unsync is a no-op"       "$(hookrun unsync)"  0
is "stratum is a no-op"      "$(hookrun stratum)" 0
# No RTC is a fact about the machine, not a failure of the hook --
# and ntpd must not be made to look broken by it.
is "step with no /dev/rtc0 still exits 0" "$(hookrun step)" 0

echo ">>> time domain: ${checks} check(s), ${fail} failure(s)"
[ "${fail}" -eq 0 ]
