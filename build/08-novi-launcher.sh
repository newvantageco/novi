#!/bin/bash
# ============================================================
# 08-novi-launcher.sh — Build novi-launcher, the Alt+Space overlay
#
# Cross-compiles novi-launcher/main.c against the wlroots stack
# build/06-wayland.sh already built, using the same cross-compiler
# and pkg-config wrapper -- run 06-wayland.sh (and 07-novi-shell.sh,
# for the compositor that spawns this) first.
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/00-versions.sh"
require_desktop_headers
harden_flags

XDG_SHELL_XML="${ROOTFS}/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml"
[ -f "${XDG_SHELL_XML}" ] || {
    echo "ERROR: ${XDG_SHELL_XML} not found -- run build/06-wayland.sh first." >&2
    exit 1
}
command -v wayland-scanner >/dev/null 2>&1 || {
    echo "ERROR: wayland-scanner not found on the build host (package: libwayland-bin)" >&2
    exit 1
}

cd "${REPO_ROOT}/novi-launcher"
make clean
make \
    CC="${TARGET_TRIPLE}-gcc" \
    PKG_CONFIG="${TARGET_TRIPLE}-pkg-config" \
    WAYLAND_SCANNER=wayland-scanner \
    XDG_SHELL_XML="${XDG_SHELL_XML}"
# Repeats every var from the build invocation above -- see
# 07-novi-shell.sh's identical comment: `install` depends on the
# `novi-launcher` target, so make re-checks xdg-shell-protocol.c/.h's
# own $(XDG_SHELL_XML) prerequisite here too, and without repeating it
# this falls back to the Makefile's host-path default, which doesn't
# exist on a from-scratch host.
make \
    CC="${TARGET_TRIPLE}-gcc" \
    PKG_CONFIG="${TARGET_TRIPLE}-pkg-config" \
    WAYLAND_SCANNER=wayland-scanner \
    XDG_SHELL_XML="${XDG_SHELL_XML}" \
    DESTDIR="${ROOTFS}" PREFIX=/usr install
make clean

echo ""
echo "novi-launcher installed:"
ls -la "${ROOTFS}/usr/bin/novi-launcher"
