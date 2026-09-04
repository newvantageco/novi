#!/bin/bash
# ============================================================
# 17-novi-install.sh — Install novi-install, the disk installer
#
# RFC 0003. Nothing to cross-compile: packages/novi-install is a POSIX
# shell script that runs under BusyBox ash on the target, like
# packages/pkg and packages/novi-state.
#
# What it needs from the rest of the build, and why each is load-bearing:
#
#   * BusyBox applets fdisk, mke2fs, partprobe, tar, dd, blkid. All are
#     in this repo's BusyBox config today; the installer checks again at
#     runtime, but a missing applet is much cheaper to find here.
#   * The GRUB artifacts scripts/mkiso.sh stages into /novi-boot on the
#     ISO. Those are made on the BUILD HOST (grub-mkimage), not here --
#     the installed system has no GRUB tooling at all, which is the
#     whole reason the work is split across build time and install time.
#   * The disk-root boot path in scripts/mkinitramfs.sh's /init, which
#     is what actually makes `root=LABEL=NOVI_ROOT` boot into a real
#     writable filesystem instead of a squashfs+tmpfs overlay.
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/00-versions.sh"

BUSYBOX="${ROOTFS}/bin/busybox"
[ -f "${BUSYBOX}" ] || {
    echo "ERROR: ${BUSYBOX} not found -- run build/03-base.sh first." >&2
    exit 1
}

echo ">>> Checking the BusyBox applets novi-install depends on ..."
APPLET_LIST="$("${BUSYBOX}" --list 2>/dev/null || true)"
MISSING=()
for applet in fdisk mke2fs partprobe tar dd blkid mount umount sync tac; do
    grep -qx "${applet}" <<<"${APPLET_LIST}" || MISSING+=("${applet}")
done
if (( ${#MISSING[@]} > 0 )); then
    echo "ERROR: BusyBox is missing applets novi-install needs: ${MISSING[*]}" >&2
    echo "  Enable them in the BusyBox config and re-run build/03-base.sh." >&2
    exit 1
fi
echo "    all present"

install -D -m 755 "${REPO_ROOT}/packages/novi-install" "${ROOTFS}/usr/bin/novi-install"

echo ""
echo "novi-install installed:"
ls -la "${ROOTFS}/usr/bin/novi-install"
