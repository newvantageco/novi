#!/bin/bash
# ============================================================
# 07-novi-shell.sh — Build novi-shell, the compositor (RFC 0001)
#
# Cross-compiles novi-shell/main.c against the wlroots stack
# build/06-wayland.sh already built, using the same cross-compiler
# and pkg-config wrapper -- run 06-wayland.sh first.
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

cd "${REPO_ROOT}/novi-shell"
make clean
make \
    CC="${TARGET_TRIPLE}-gcc" \
    PKG_CONFIG="${TARGET_TRIPLE}-pkg-config" \
    WAYLAND_SCANNER=wayland-scanner \
    XDG_SHELL_XML="${XDG_SHELL_XML}"
# Repeats every var from the build invocation above, not just
# DESTDIR/PREFIX: `install` depends on the `novi-shell` target, so make
# re-checks that target's own prerequisites (xdg-shell-protocol.c/.h
# depend on $(XDG_SHELL_XML)) here too -- without CC/PKG_CONFIG/
# WAYLAND_SCANNER/XDG_SHELL_XML repeated, make silently falls back to
# the Makefile's plain-host defaults for this second invocation only,
# and XDG_SHELL_XML's default (a host path wayland-protocols would
# need installed at, which CONTRIBUTING.md's prerequisites don't
# require) doesn't exist on a from-scratch host -- confirmed by hitting
# "No rule to make target '/usr/share/wayland-protocols/.../xdg-shell.xml'"
# for real, not guessed.
make \
    CC="${TARGET_TRIPLE}-gcc" \
    PKG_CONFIG="${TARGET_TRIPLE}-pkg-config" \
    WAYLAND_SCANNER=wayland-scanner \
    XDG_SHELL_XML="${XDG_SHELL_XML}" \
    DESTDIR="${ROOTFS}" PREFIX=/usr install
make clean

echo ""
echo "novi-shell installed:"
ls -la "${ROOTFS}/usr/bin/novi-shell"
