#!/bin/bash
# Remove busybox applet symlinks this kernel cannot support.
#
# `kernel/dead-applets` is a table of <applet> <CONFIG_SYMBOL>; this
# script reads the GENERATED kernel config -- never the curated one,
# which is a subset -- and CONVERGES each row against it: an applet
# whose symbol is absent loses its symlink, and one whose symbol is
# set gets the symlink back if a previous run took it.
#
# THE RESTORE HALF IS NOT SYMMETRY FOR ITS OWN SAKE. Without it the
# claim "turning a symbol on brings the command back" is only true of
# a FULL build, because it is `03-base.sh` that creates the symlinks
# and `--from 05` never reaches it -- so somebody enabling
# CONFIG_RTC_CLASS and rebuilding the kernel would get a working RTC
# and no `hwclock`, which is the shape of bug this whole table exists
# to stop. Watched: that is exactly what the RTC change did here.
#
# Where the link goes is ASKED, not computed from a rule somebody
# wrote down: `busybox --list-full` prints each applet at the path
# busybox's own installer would put it (`sbin/hwclock`,
# `usr/sbin/rtcwake`, `usr/bin/ipcs`), so the two cannot disagree. The
# link is relative in the same shape busybox writes -- `bin/ls ->
# busybox`, everything deeper `-> ../[../]bin/busybox`.
#
# Two callers, one implementation: `05-kernel.sh` runs it the moment
# the generated config exists, and `16-s6-rc-db.sh` runs it again as
# part of the repair it already does after somebody re-runs
# `03-base.sh` -- busybox's `make install` recreates every symlink,
# which is the same hazard that stage already fixes for /sbin/init.
#
# Exits 0 and does nothing when the generated config is not there
# (a tree where the kernel has not been built yet): removing commands
# on a guess about the kernel is the mistake this whole table exists
# to stop.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ROOTFS="${1:-${ROOTFS:-}}"
GEN="${2:-}"
TABLE="${REPO_ROOT}/kernel/dead-applets"

[ -n "${ROOTFS}" ] || { echo "usage: prune-dead-applets.sh <rootfs> [generated-.config]" >&2; exit 2; }
[ -f "${TABLE}" ]  || { echo "no ${TABLE}" >&2; exit 2; }

if [ -z "${GEN}" ]; then
    # The config the kernel build installed into the image is the same
    # file the build generated, and it is the one copy that travels
    # with the rootfs -- so a caller with no build tree still gets the
    # right answer.
    GEN="$(ls -1 "${ROOTFS}/boot/config-"* 2>/dev/null | head -1 || true)"
fi
if [ -z "${GEN}" ] || [ ! -f "${GEN}" ]; then
    echo "    no generated kernel config yet; leaving every applet in place"
    exit 0
fi

# Where busybox itself would install each applet. Absent on a tree with
# no busybox yet, in which case nothing can be restored and the pruning
# half still works.
LISTFULL=""
if [ -x "${ROOTFS}/bin/busybox" ]; then
    LISTFULL="$("${ROOTFS}/bin/busybox" --list-full 2>/dev/null || true)"
fi

# The relative target busybox writes: `bin/ls -> busybox`, and one
# `../` per directory level above that for anything deeper.
bb_target() {
    local dir="${1%/*}" up="" n
    [ "${dir}" = "bin" ] && { printf 'busybox'; return; }
    n="$(printf '%s' "${dir}" | tr -cd '/' | wc -c)"
    n=$((n + 1))
    while [ "${n}" -gt 0 ]; do up="${up}../"; n=$((n - 1)); done
    printf '%sbin/busybox' "${up}"
}

removed=0 kept=0 restored=0
while read -r applet symbol _rest; do
    case "${applet}" in ''|'#'*) continue ;; esac
    if grep -qE "^${symbol}=(y|m)$" "${GEN}"; then
        kept=$((kept + 1))
        # The symbol is set, so this applet belongs on the machine.
        # Put it back if an earlier run, under a kernel that did not
        # have the feature, took it away.
        [ -n "${LISTFULL}" ] || continue
        rel="$(printf '%s\n' "${LISTFULL}" | grep -x -- "[a-z/]*/${applet}" | head -1 || true)"
        [ -n "${rel}" ] || continue
        p="${ROOTFS}/${rel}"
        if [ ! -L "${p}" ] && [ ! -e "${p}" ]; then
            mkdir -p "$(dirname "${p}")"
            ln -sf "$(bb_target "${rel}")" "${p}"
            echo "    restored /${rel} (${symbol} is set)"
            restored=$((restored + 1))
        fi
        continue
    fi
    for d in bin sbin usr/bin usr/sbin; do
        p="${ROOTFS}/${d}/${applet}"
        if [ -L "${p}" ] || [ -f "${p}" ]; then
            rm -f "${p}"
            echo "    removed /${d}/${applet} (${symbol} is not set)"
            removed=$((removed + 1))
        fi
    done
done < "${TABLE}"

echo "    dead applets: removed ${removed}, restored ${restored}, left ${kept} whose symbol is set"
