#!/bin/bash
# ============================================================
# test-agent-sandbox.sh — `novi-agent describe` and the sandbox section
#
# RFC 0039 roadmap 5. Three wrappers decide whether a program runs
# confined, so the answer lived in shell scripts inside packages and
# nothing on the machine could be asked. `describe_sandbox` reads them.
#
# THE FIXTURE IS THE SHIPPED WRAPPERS, EXTRACTED FROM THE BUILD STAGES
# THAT WRITE THEM. A test with its own copy of a wrapper tests the
# copy -- and this is precisely a test about whether a reader and a
# wrapper agree, so a second copy would be the one thing it must not
# have. The wrappers live in `<<'WRAP' ... WRAP` heredocs; the same
# sed-it-out-and-use-it move `45-novi-sandbox.sh` makes on the syscall
# profile.
#
# Run by scripts/lint.sh. Under the shipped busybox ash where one is
# built, because that is what runs on the target.
# ============================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO="$(pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

BUSYBOX="${REPO}/build/rootfs/bin/busybox"
if [ -x "${BUSYBOX}" ]; then
    SH=("${BUSYBOX}" sh)
    echo ">>> the sandbox section, under the shipped busybox ash"
else
    SH=(sh)
    echo ">>> the sandbox section, under host sh (no shipped busybox found)" >&2
fi

checks=0; fail=0
ok() {
    checks=$(( checks + 1 ))
    if [ "$2" != "$3" ]; then
        fail=$(( fail + 1 ))
        printf 'FAIL: %s\n  want: %s\n  got : %s\n' "$1" "$3" "$2" >&2
    fi
}
has() {
    checks=$(( checks + 1 ))
    case "$2" in
        *"$3"*) ;;
        *) fail=$(( fail + 1 ))
           printf 'FAIL: %s\n  missing: %s\n  in: %s\n' "$1" "$3" "$2" >&2 ;;
    esac
}

# ---- the fixture: every wrapper this repository ships ---------------
mkdir -p "${TMP}/bin"
extract() {   # <build stage> <name on PATH>
    sed -n "/<<'WRAP'\$/,/^WRAP\$/p" "${REPO}/$1" | sed '1d;$d' > "${TMP}/bin/$2"
    chmod 755 "${TMP}/bin/$2"
    [ -s "${TMP}/bin/$2" ] || { echo "FAIL: no wrapper in $1" >&2; exit 1; }
}
extract build/35-devtools.sh  netsurf-fb
extract build/44-novi-recon.sh novi-recon
extract build/22-novi-view.sh  novi-view
# A program that is NOT sandboxed, so the reader has something to leave
# out: a list that names everything is not a finding.
printf '#!/bin/sh\necho hello\n' > "${TMP}/bin/plain-tool"
chmod 755 "${TMP}/bin/plain-tool"
# AND ONE THAT ONLY MENTIONS IT. The first version of this test had
# `plain-tool` alone and the "must not be listed" check COULD NOT FAIL:
# a script with no novi-sandbox anywhere is rejected twice over, by the
# grep and again by the invocation match, so breaking either left the
# answer right. This one passes the grep and must still be excluded,
# which is the layer where a wrong answer is a wrong answer -- the same
# correction RFC 0028's five malformed-input checks needed.
{
    printf '#!/bin/sh\n'
    printf '# Someone should put this behind novi-sandbox one day.\n'
    printf 'exec /usr/libexec/almost-tool "$@"\n'
} > "${TMP}/bin/almost-tool"
chmod 755 "${TMP}/bin/almost-tool"

sed "s|local bindir=/usr/bin|local bindir=${TMP}/bin|" "${REPO}/packages/novi-agent" \
    > "${TMP}/novi-agent"
chmod 755 "${TMP}/novi-agent"

# A STUB novi-sandbox, because the wrappers check for one. Without it
# every wrapper correctly decides there is no sandbox on this machine
# and hands the program straight over -- which is right, and would have
# made this test assert that three sandboxed programs are not
# sandboxed. Found by running it: the hook printed
# `nice -n 5 s6-softlimit -a ... /usr/libexec/netsurf-fb`.
printf '#!/bin/sh\nexit 0\n' > "${TMP}/bin/novi-sandbox"
chmod 755 "${TMP}/bin/novi-sandbox"

# The real dispatcher, not a sourced function: `describe` composes
# novi-state and pkg, and both are overridable so a build host that has
# neither still exercises the whole path. Their absence is a thing
# describe already handles (`|| true`, `{}`), so this is the shipped
# behaviour rather than a special case for the test.
run_describe() {   # <--json|--text>
    NOVI_STATE=/bin/false NOVI_PKG=/bin/false \
        NOVI_JSON_LIB="${REPO}/packages/lib-json.sh" \
        "${SH[@]}" "${TMP}/novi-agent" describe "$1" 2>/dev/null
}

json="$(run_describe --json)"
text="$(run_describe --text)"

# ---- what the reader must say ---------------------------------------
has "netsurf-fb is listed"        "$json" '"program": "netsurf-fb"'
has "novi-recon is listed"        "$json" '"program": "novi-recon"'
has "novi-view is listed"         "$json" '"program": "novi-view"'
for absent in plain-tool almost-tool; do
    checks=$(( checks + 1 ))
    case "$json" in
        *"$absent"*) fail=$(( fail + 1 ))
            printf 'FAIL: %s does not invoke novi-sandbox and was listed\n' \
                "$absent" >&2 ;;
    esac
done

# The browser keeps the denylist and needs the network; novi-recon has
# the allowlist; novi-view has neither the network nor a profile. Those
# three facts are the whole point of the section, and each is a
# decision in RFC 0039 that would be silently reversed if the wrapper
# changed and this said nothing.
has "netsurf: denylist"  "$json" '"program": "netsurf-fb", "runs": "/usr/libexec/netsurf-fb", "filter": "denylist", "network": "on"'
has "recon: the profile" "$json" '"program": "novi-recon", "runs": "/usr/libexec/novi-recon", "filter": "recon", "network": "on"'
has "view: no network"   "$json" '"program": "novi-view", "runs": "/usr/libexec/novi-view", "filter": "denylist", "network": "off"'

# RFC 0029's rule for --text: every STRING in the JSON appears in the
# table. Asserted here for this section rather than relying on
# test-agent-text.sh, which cannot see a build host's /usr/bin.
for v in netsurf-fb novi-recon novi-view /usr/libexec/netsurf-fb \
         /usr/libexec/novi-recon /usr/libexec/novi-view denylist recon off on; do
    has "--text shows ${v}" "$text" "$v"
done

# ---- and the wrapper's own answer, which must agree ------------------
#
# describe READS; NOVI_SANDBOX_DESCRIBE makes the wrapper PRINT the argv
# it would exec. They are two mechanisms for two audiences and they are
# allowed to differ in detail -- but not about whether there is a
# sandbox, which filter, or whether the network is there.
for w in netsurf-fb novi-recon novi-view; do
    line="$(NOVI_SANDBOX_DESCRIBE=1 PATH="${TMP}/bin:${PATH}" \
        "${SH[@]}" "${TMP}/bin/${w}" 2>/dev/null)"
    has "${w}: the hook prints an argv" "$line" "novi-sandbox"
    want_net=$(case "$w" in novi-view) echo off ;; *) echo on ;; esac)
    got_net=$(case "$line" in *--no-net*) echo off ;; *) echo on ;; esac)
    ok "${w}: the hook and the reader agree about the network" "$got_net" "$want_net"
    want_p=$(case "$w" in novi-recon) echo yes ;; *) echo no ;; esac)
    got_p=$(case "$line" in *--profile*) echo yes ;; *) echo no ;; esac)
    ok "${w}: the hook and the reader agree about the profile" "$got_p" "$want_p"
done

echo ">>> the sandbox section: ${checks} check(s), ${fail} failure(s)"
[ "${fail}" -eq 0 ]
