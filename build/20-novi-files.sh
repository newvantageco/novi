#!/bin/bash
# ============================================================
# 20-novi-files.sh — Build novi-files, the file manager
#
# Cross-compiles novi-files/main.c against the wlroots stack
# build/06-wayland.sh already built. Same shape as
# build/14-novi-settings.sh -- see that script's comments.
#
# Numbered 20 because that number came free when 20-repo.sh moved to
# 30: a GUI client has to build BEFORE 31-desktop-split.sh deletes the
# headers and libraries it compiles against, and be packaged by
# 30-repo.sh. That is the whole reason those two stages moved to the
# end -- see 30-repo.sh's header.
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

cd "${REPO_ROOT}/novi-files"
make clean
make \
    CC="${TARGET_TRIPLE}-gcc" \
    PKG_CONFIG="${TARGET_TRIPLE}-pkg-config" \
    WAYLAND_SCANNER=wayland-scanner \
    XDG_SHELL_XML="${XDG_SHELL_XML}"
# Repeats every var from the build invocation above -- see
# 07-novi-shell.sh's identical comment: `install` depends on the
# `novi-files` target, so make re-checks xdg-shell-protocol.c's own
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
echo "novi-files installed:"
ls -la "${ROOTFS}/usr/bin/novi-files"

# ── Register as a launchable GUI app ─────────────────────────────────
#
# packages/pkg-format.md's "GUI Application Registration" convention --
# same pattern build/09-foot.sh's own step 8 already uses. Not
# pkg-installed (baked into the base rootfs directly), same reason
# foot isn't either.
echo "==> Registering novi-files as a launchable GUI app"
APPS_DIR="${ROOTFS}/usr/share/novi/apps"
mkdir -p "${APPS_DIR}"
cat > "${APPS_DIR}/novi-files.app" <<'EOF'
name=Files
exec=/usr/bin/novi-files
icon=folder
description=Browse files and folders
EOF
echo "   done: ${APPS_DIR}/novi-files.app"
