#!/bin/bash
# ============================================================
# 22-novi-view.sh — Build novi-view, the image viewer
#
# Cross-compiles novi-view/main.c against the wlroots stack
# build/06-wayland.sh already built. Same shape as
# build/14-novi-settings.sh -- see that script's comments.
#
# Numbered 22 so it runs after 21-imagelibs.sh, which builds the
# libpng it links, and before 30-repo.sh packages it and
# 31-desktop-split.sh removes the headers. Same constraint as every
# other GUI client -- see 30-repo.sh's header for why those two stages
# live at the end.
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/00-versions.sh"

XDG_SHELL_XML="${ROOTFS}/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml"
[ -f "${XDG_SHELL_XML}" ] || {
    echo "ERROR: ${XDG_SHELL_XML} not found -- run build/06-wayland.sh first." >&2
    exit 1
}
command -v wayland-scanner >/dev/null 2>&1 || {
    echo "ERROR: wayland-scanner not found on the build host (package: libwayland-bin)" >&2
    exit 1
}

cd "${REPO_ROOT}/novi-view"
make clean
make \
    CC="${TARGET_TRIPLE}-gcc" \
    PKG_CONFIG="${TARGET_TRIPLE}-pkg-config" \
    WAYLAND_SCANNER=wayland-scanner \
    XDG_SHELL_XML="${XDG_SHELL_XML}"
# Repeats every var from the build invocation above -- see
# 07-novi-shell.sh's identical comment: `install` depends on the
# `novi-view` target, so make re-checks xdg-shell-protocol.c's own
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
echo "novi-view installed:"
ls -la "${ROOTFS}/usr/bin/novi-view"

# ── Register as a launchable GUI app ─────────────────────────────────
#
# packages/pkg-format.md's "GUI Application Registration" convention --
# same pattern build/09-foot.sh's own step 8 already uses. Not
# pkg-installed (baked into the base rootfs directly), same reason
# foot isn't either.
echo "==> Registering novi-view as a launchable GUI app"
APPS_DIR="${ROOTFS}/usr/share/novi/apps"
mkdir -p "${APPS_DIR}"
cat > "${APPS_DIR}/novi-view.app" <<'EOF'
name=Image Viewer
exec=/usr/bin/novi-view
icon=globe
description=View a PNG, BMP or PPM image
EOF
echo "   done: ${APPS_DIR}/novi-view.app"
