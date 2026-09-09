#!/bin/bash
# ============================================================
# 37-novi-glinfo.sh — the GL stack, from a client's side
#
# RFC 0025 put Mesa in the image and verified the COMPOSITOR's gles2
# renderer end to end. It verified nothing at all about a client, and
# a client takes a different path: EGL's Wayland platform, and buffer
# sharing back to the compositor. That path is why Mesa is here --
# a compositor could have gone on using pixman forever -- and until
# this program existed nothing had exercised it.
#
# It is also the tool RFC 0025's one tunable needs. `display.renderer
# = gles2` on a machine with a real GPU is a guess until something
# says which driver answered, and "softpipe" and "iris" look identical
# from the outside.
#
# Desktop package, not base: it links Mesa, and Mesa is a package
# (RFC 0007 keeps the base console-only). The stage number puts it
# after the other clients and well before packaging at 40+, so
# pkgsplit sees the binary in the rootfs and moves it out.
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/00-versions.sh"
harden_flags

# -rpath-link, and this is the FOURTH time in this repository (nftables,
# git/curl, the meson cross file, now here). The static linker consults
# -L only for a library named directly with -l; it will not use it to
# resolve a shared library's own DT_NEEDED entries. libEGL.so names
# libgallium, libgbm, libglapi, libexpat, libdrm and libwayland-server,
# and without this the link fails on "undefined reference to
# XML_ErrorString" and "wl_resource_post_error" -- symbols belonging to
# libraries that are sitting in the rootfs, from a libEGL that exports
# none of them. The error names the wrong thing entirely.
#
# build/lib-meson-cross.sh sets exactly this globally for meson builds.
# The client Makefiles link with $(CC) directly and get no such thing,
# which is why each one rediscovers it.
export LDFLAGS="${LDFLAGS:-} -Wl,-rpath-link,${ROOTFS}/usr/lib"

require_desktop_headers

XDG_SHELL_XML="${ROOTFS}/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml"
[ -f "${XDG_SHELL_XML}" ] || {
    echo "ERROR: ${XDG_SHELL_XML} not found -- run build/06-wayland.sh first." >&2
    exit 1
}

# Named separately from the header check above because the failure
# reads completely differently: no egl.pc means Mesa was never built
# (06-wayland.sh section 13), not that the desktop headers were split
# out. Two causes, two messages.
[ -f "${ROOTFS}/usr/lib/pkgconfig/egl.pc" ] || {
    echo "ERROR: egl.pc not found in ${ROOTFS} -- Mesa has not been built." >&2
    echo "       Run build/06-wayland.sh (section 13 builds it)." >&2
    exit 1
}

echo ">>> Building novi-glinfo (desktop) ..."
cd "${REPO_ROOT}/novi-glinfo"
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
echo "installed:"
ls -la "${ROOTFS}/usr/bin/novi-glinfo"
