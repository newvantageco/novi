#!/bin/bash
# ============================================================
# 36-novi-notifyd.sh — desktop notifications (RFC 0024)
#
# TWO PROGRAMS, and they land in different halves of the system:
#
#   novi-notify    the sender. BASE image. Links libc and nothing
#                  else. The things with something to say --
#                  novi-mount when a stick arrives, novi-eject when
#                  one is safe to pull -- are base tools that run on
#                  machines with no desktop at all.
#   novi-notifyd   the daemon that draws them. DESKTOP package, a
#                  layer-shell client like novi-panel, spawned by
#                  novi-shell.
#
# Both are built here rather than in two stages because they are one
# feature with one wire format between them, and a format defined in
# two files that are built apart is a format that drifts.
#
# The stage number puts it after the desktop clients (06..14) and
# well before packaging (40+): novi-notifyd is a desktop binary and
# pkgsplit has to see it in the rootfs to move it out.
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/00-versions.sh"
harden_flags

# ── novi-notify (base) ────────────────────────────────────────────
#
# No require_desktop_headers: this one has no Wayland in it, so it
# builds in a split tree where every desktop header has been moved
# into the novi-headers package. That is not an accident of the
# dependency list, it is the point of the split between the two.
echo ">>> Building novi-notify (base image) ..."
cd "${REPO_ROOT}/novi-notify"
make clean
make CC="${TARGET_TRIPLE}-gcc"
make CC="${TARGET_TRIPLE}-gcc" DESTDIR="${ROOTFS}" PREFIX=/usr install
make clean
"${TARGET_TRIPLE}-strip" "${ROOTFS}/usr/bin/novi-notify"

# ── novi-notifyd (desktop) ────────────────────────────────────────
require_desktop_headers
XDG_SHELL_XML="${ROOTFS}/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml"
[ -f "${XDG_SHELL_XML}" ] || {
    echo "ERROR: ${XDG_SHELL_XML} not found -- run build/06-wayland.sh first." >&2
    exit 1
}
command -v wayland-scanner >/dev/null 2>&1 || {
    echo "ERROR: wayland-scanner not found on the build host (package: libwayland-bin)" >&2
    exit 1
}

echo ">>> Building novi-notifyd (desktop) ..."
cd "${REPO_ROOT}/novi-notifyd"
make clean
make \
    CC="${TARGET_TRIPLE}-gcc" \
    PKG_CONFIG="${TARGET_TRIPLE}-pkg-config" \
    WAYLAND_SCANNER=wayland-scanner \
    XDG_SHELL_XML="${XDG_SHELL_XML}"
make \
    CC="${TARGET_TRIPLE}-gcc" \
    PKG_CONFIG="${TARGET_TRIPLE}-pkg-config" \
    WAYLAND_SCANNER=wayland-scanner \
    XDG_SHELL_XML="${XDG_SHELL_XML}" \
    DESTDIR="${ROOTFS}" PREFIX=/usr install
make clean

echo ""
echo "notifications installed:"
ls -la "${ROOTFS}/usr/bin/novi-notify" "${ROOTFS}/usr/bin/novi-notifyd"
