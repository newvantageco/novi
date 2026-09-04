#!/bin/bash
# ============================================================
# 22-live-desktop.sh — Install the live-boot desktop helper
#
# RFC 0007. The base image is console-only, so a live boot that wants a
# desktop installs one from the repository on the medium. This is the
# ~40-line script that does it; init/skel/rc.init calls it when
# `novi.live.desktop` is on the kernel command line, which the ISO's
# "Live Desktop" menu entry passes.
#
# Nothing to cross-compile: a POSIX shell script, like pkg,
# novi-state and novi-install.
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/00-versions.sh"

install -D -m 755 "${REPO_ROOT}/rootfs/usr/bin/novi-live-desktop" \
    "${ROOTFS}/usr/bin/novi-live-desktop"

echo ""
echo "live-desktop helper installed:"
ls -la "${ROOTFS}/usr/bin/novi-live-desktop"
