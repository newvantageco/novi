#!/bin/bash
# Remove busybox applet symlinks this kernel cannot support.
#
# `kernel/dead-applets` is a table of <applet> <CONFIG_SYMBOL>; this
# script reads the GENERATED kernel config -- never the curated one,
# which is a subset -- and removes an applet's symlink only when its
# symbol is absent there. An applet whose symbol IS set is left alone,
# so enabling a kernel feature restores the command with no edit to
# the table.
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

removed=0 kept=0
while read -r applet symbol _rest; do
    case "${applet}" in ''|'#'*) continue ;; esac
    if grep -qE "^${symbol}=(y|m)$" "${GEN}"; then
        kept=$((kept + 1))
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

echo "    dead applets: removed ${removed}, left ${kept} whose symbol is set"
