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

# The shortcut sheet, as an ordinary entry in the app list.
#
# It is ALSO on Super+/ (novi-shell's NOVI_ACT_SHORTCUTS), and this is
# not a duplicate of that: a list of keyboard shortcuts reachable only
# by a keyboard shortcut is a bootstrapping paradox -- useful to
# everyone except somebody who does not yet know any of them, who is
# exactly the person it is for. Apps is a button on the panel, so this
# is reachable with a mouse and nothing else.
echo "==> Registering the keyboard-shortcut sheet as a launchable app"
# The colour palettes (RFC 0030). Installed here rather than in a stage
# of their own because there is no free stage number below 40 and these
# are four text files -- but they are their OWN package (novi-themes in
# pkgsplit's DATA_FILES), because "which package do I uninstall to stop
# having these" should have an answer that matches what they are.
THEMES_SRC="${REPO_ROOT}/rootfs/usr/share/novi/themes"
THEMES_DIR="${ROOTFS}/usr/share/novi/themes"
mkdir -p "${THEMES_DIR}"
install -m 644 "${THEMES_SRC}"/*.theme "${THEMES_DIR}/"
echo "themes: $(ls -1 "${THEMES_DIR}" | tr '\n' ' ')"

APPS_DIR="${ROOTFS}/usr/share/novi/apps"
mkdir -p "${APPS_DIR}"
cat > "${APPS_DIR}/shortcuts.app" <<'EOF'
name=Keyboard Shortcuts
exec=/usr/bin/novi-launcher --keys
icon=keyboard
description=Every keyboard shortcut this desktop has
EOF
echo "   done: ${APPS_DIR}/shortcuts.app"

echo ""
echo "novi-launcher installed:"
ls -la "${ROOTFS}/usr/bin/novi-launcher"
