#!/bin/bash
# ============================================================
# 12-novi-screenshot.sh — Build novi-screenshot, PrintScreen capture
#
# Cross-compiles novi-screenshot/main.c against the wlroots stack
# build/06-wayland.sh already built. Same shape as
# build/08-novi-launcher.sh, minus the XDG_SHELL_XML dance -- this
# client never creates a wl_surface, so it doesn't need xdg-shell's
# xdg_popup_interface link workaround (see novi-launcher/Makefile's
# comment on that).
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/00-versions.sh"
require_desktop_headers
harden_flags

command -v wayland-scanner >/dev/null 2>&1 || {
    echo "ERROR: wayland-scanner not found on the build host (package: libwayland-bin)" >&2
    exit 1
}

cd "${REPO_ROOT}/novi-screenshot"
make clean
make \
    CC="${TARGET_TRIPLE}-gcc" \
    PKG_CONFIG="${TARGET_TRIPLE}-pkg-config" \
    WAYLAND_SCANNER=wayland-scanner
make \
    CC="${TARGET_TRIPLE}-gcc" \
    PKG_CONFIG="${TARGET_TRIPLE}-pkg-config" \
    WAYLAND_SCANNER=wayland-scanner \
    DESTDIR="${ROOTFS}" PREFIX=/usr install
make clean

echo ""
echo "novi-screenshot installed:"
ls -la "${ROOTFS}/usr/bin/novi-screenshot"
