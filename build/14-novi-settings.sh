#!/bin/bash
# ============================================================
# 14-novi-settings.sh — Build novi-settings, the first-party Settings app
#
# Cross-compiles novi-settings/main.c against the wlroots stack
# build/06-wayland.sh already built. Same shape as
# build/08-novi-launcher.sh -- see that script's comments.
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/00-versions.sh"
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

cd "${REPO_ROOT}/novi-settings"
make clean
make \
    CC="${TARGET_TRIPLE}-gcc" \
    PKG_CONFIG="${TARGET_TRIPLE}-pkg-config" \
    WAYLAND_SCANNER=wayland-scanner \
    XDG_SHELL_XML="${XDG_SHELL_XML}"
# Repeats every var from the build invocation above -- see
# 07-novi-shell.sh's identical comment: `install` depends on the
# `novi-settings` target, so make re-checks xdg-shell-protocol.c's own
# $(XDG_SHELL_XML) prerequisite here too, and without repeating it this
# falls back to the Makefile's host-path default, which doesn't exist
# on a from-scratch host.
make \
    CC="${TARGET_TRIPLE}-gcc" \
    PKG_CONFIG="${TARGET_TRIPLE}-pkg-config" \
    WAYLAND_SCANNER=wayland-scanner \
    XDG_SHELL_XML="${XDG_SHELL_XML}" \
    DESTDIR="${ROOTFS}" PREFIX=/usr install
make clean

echo ""
echo "novi-settings installed:"
ls -la "${ROOTFS}/usr/bin/novi-settings"

# ── Register as a launchable GUI app ─────────────────────────────────
#
# packages/pkg-format.md's "GUI Application Registration" convention --
# same pattern build/09-foot.sh's own step 8 already uses. Not
# pkg-installed (baked into the base rootfs directly), same reason
# foot isn't either.
echo "==> Registering novi-settings as a launchable GUI app"
APPS_DIR="${ROOTFS}/usr/share/novi/apps"
mkdir -p "${APPS_DIR}"
cat > "${APPS_DIR}/novi-settings.app" <<'EOF'
name=Settings
exec=/usr/bin/novi-settings
icon=settings
description=Account settings (change password)
EOF
echo "   done: ${APPS_DIR}/novi-settings.app"
