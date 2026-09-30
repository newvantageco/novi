#!/bin/bash
# ============================================================
# check-hardening.sh — every first-party program must keep the
# compile-time hardening build/00-versions.sh's harden_flags() gives it.
#
#   bash scripts/check-hardening.sh [rootfs]
#
# This is a regression check, not an audit. It looks only at the
# programs this project writes, because those are the ones whose build
# we control and the ones harden_flags() is wired into.
#
# It exists because the flags were absent for the whole life of the
# project and nothing said so -- and because when they were first added
# they still did not take: every Makefile here linked with
# `$(CC) $(CFLAGS) -o $@ ...` and never mentioned $(LDFLAGS), so -pie
# and -z now were dropped on the floor while -fstack-protector-strong
# went through. The binaries looked hardened if you only checked for a
# stack canary. Check what you claim, on the artifact, not on the flags
# you think you passed.
# ============================================================
# No pipefail here, deliberately: `readelf | grep -q` makes grep exit on
# the first match, readelf takes SIGPIPE, and pipefail would turn that
# into a failure of the check rather than a pass. It did -- three
# binaries were reported as having no stack protector while `readelf -s`
# by hand showed the symbol twice. Each file's headers are read once
# into a variable below instead.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../build/00-versions.sh"
ROOT="${1:-${ROOTFS}}"
READELF="${TARGET_TRIPLE}-readelf"
command -v "${READELF}" >/dev/null 2>&1 || READELF=readelf

# The dynamically-linked programs this repo builds. BusyBox and
# novi-verify are deliberately absent: both are static, static PIE is a
# different flag with different failure modes in PID 1's path, and
# widening this is its own change with its own boot test.
PROGRAMS=(
    usr/bin/novi-shell usr/bin/novi-panel usr/bin/novi-launcher
    usr/bin/novi-settings usr/bin/novi-lockscreen usr/bin/novi-screenshot
    usr/bin/novi-edit usr/bin/novi-files
    # novi-view's ELF lives in /usr/libexec since RFC 0039 roadmap 4 put
    # a sandbox wrapper on its name. The path had to move with it: what
    # sits at usr/bin/novi-view now is a shell script, and readelf says
    # nothing about a shell script -- so this checker reported it as
    # `not-PIE no-RELRO no-BIND_NOW no-stack-protector`, four
    # fabricated findings about a file that cannot have any of them.
    usr/libexec/novi-view
)

fail=0
stale=0
checked=0
for rel in "${PROGRAMS[@]}"; do
    f="${ROOT}/${rel}"
    if [[ ! -f "${f}" ]]; then
        # The desktop split moves these into packages; not finding one
        # is not a failure, it is a rootfs that has already been split.
        continue
    fi
    # A LISTED PATH THAT IS NOT AN ELF IS A STALE LIST, NOT AN
    # UNHARDENED BINARY, and the difference matters because readelf
    # answers nothing for both and the four checks below then all
    # "fail". Skipping it quietly would hide a binary genuinely
    # replaced by something else, so it is its own error naming its own
    # fix. (`printf '\177ELF'` -- `file` is not on every build host.)
    if [[ "$(head -c 4 "${f}" | od -An -c | tr -d ' ')" != "177ELF" ]]; then
        echo "${rel}: not an ELF file" >&2
        echo "  If this became a wrapper script, point PROGRAMS at the" >&2
        echo "  real binary instead of deleting the entry." >&2
        fail=1
        stale=1
        continue
    fi
    checked=$(( checked + 1 ))
    problems=""
    hdr="$("${READELF}" -h "${f}" 2>/dev/null)"
    seg="$("${READELF}" -l "${f}" 2>/dev/null)"
    dyn="$("${READELF}" -d "${f}" 2>/dev/null)"
    sym="$("${READELF}" -s "${f}" 2>/dev/null)"

    [[ "$(awk '/Type:/{print $2}' <<<"${hdr}")" == "DYN" ]] || problems+=" not-PIE"
    grep -q GNU_RELRO         <<<"${seg}" || problems+=" no-RELRO"
    grep -q BIND_NOW          <<<"${dyn}" || problems+=" no-BIND_NOW"
    grep -q __stack_chk_fail  <<<"${sym}" || problems+=" no-stack-protector"
    grep -q 'GNU_STACK.*RWE'  <<<"${seg}" && problems+=" exec-stack"
    if [[ -n "${problems}" ]]; then
        echo "  ${rel}:${problems}" >&2
        fail=1
    fi
done

if (( checked == 0 )); then
    echo "check-hardening: no first-party programs in ${ROOT} (already split?)"
    exit 0
fi
if (( fail )); then
    echo "" >&2
    if (( stale )); then
        # A trailer that names the wrong cause is the bug this file
        # keeps finding in other people's checks.
        echo "ERROR: PROGRAMS names a path that is not a binary." >&2
    else
        echo "ERROR: the above lost their hardening. harden_flags() in" >&2
        echo "build/00-versions.sh sets it; a Makefile that links without" >&2
        echo "\$(LDFLAGS) silently drops every linker flag in it." >&2
    fi
    exit 1
fi
echo "check-hardening: ${checked} program(s) OK (PIE, RELRO, BIND_NOW, stack protector, no exec stack)"
