#!/bin/bash
# ============================================================
# 22-novi-view.sh — Build novi-view, the image viewer
#
# Cross-compiles novi-view/main.c against the wlroots stack
# build/06-wayland.sh already built. Same shape as
# build/14-novi-settings.sh -- see that script's comments.
#
# Numbered 22 so it runs after 21-imagelibs.sh, which builds the
# libpng it links, and before 50-repo.sh packages it and
# 51-desktop-split.sh removes the headers. Same constraint as every
# other GUI client -- see 50-repo.sh's header for why those two stages
# live at the end.
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

# ── The sandbox wrapper ──────────────────────────────────────────────
#
# RFC 0039 roadmap 4, and the caller that item said it did not have.
# novi-view decodes a PNG off somebody else's USB stick through libpng
# and zlib -- the same class of surface RFC 0031 roadmap 4 pointed a
# corpus at for the browser -- and unlike the browser it has NO
# BUSINESS ON THE NETWORK AT ALL. So this is where `--no-net` earns
# its keep rather than being wiring for a hypothetical.
#
# Same shape as netsurf and novi-recon: the binary moves to
# /usr/libexec and the wrapper takes the name on PATH, because a bound
# somebody bypasses by typing the other name is not a bound.
#
# THE BIND LIST IS BUILT AT RUNTIME, which no other wrapper here has
# had to do. The one file this program reads is chosen when it is
# started, so the list cannot be fixed in the script -- and the path is
# resolved with `readlink -f` for two reasons: the cwd inside the
# sandbox is `/`, so a relative path would resolve against the wrong
# directory; and a SYMLINK would otherwise be bound at its target and
# opened at its link name, which does not exist inside. The resolved
# path is what novi-view is given.
install -d "${ROOTFS}/usr/libexec"
mv "${ROOTFS}/usr/bin/novi-view" "${ROOTFS}/usr/libexec/novi-view"
cat > "${ROOTFS}/usr/bin/novi-view" <<'WRAP'
#!/bin/sh
# novi-view inside a mount, process and NETWORK namespace (RFC 0039).
# An image decoder has no use for a socket. NOVI_VIEW_SANDBOX=off for
# somebody debugging the difference between a bad image and a missing
# bind.
REAL=/usr/libexec/novi-view
# NOVI_SANDBOX_DESCRIBE=1 prints the command this would have run and
# stops. Every exit goes through run(), so the answer is the argv that
# would really be exec'd -- runtime branches taken, optional binds
# resolved -- rather than a second description that can drift from it.
# `novi-agent describe` READS this file instead (RFC 0029 decision 1:
# describing must not run anything); this is the exact answer, for a
# person.
run() {
    if [ -n "${NOVI_SANDBOX_DESCRIBE:-}" ]; then
        printf '%s\n' "$*"
        exit 0
    fi
    exec "$@"
}

SANDBOX="${NOVI_VIEW_SANDBOX:-on}"
case "${SANDBOX}" in
    off|none|0) run "${REAL}" "$@" ;;
    on|1) ;;
    *)
        echo "novi-view: NOVI_VIEW_SANDBOX must be 'on' or 'off'" >&2
        exit 2 ;;
esac
command -v novi-sandbox >/dev/null 2>&1 || run "${REAL}" "$@"

RUNTIME="${XDG_RUNTIME_DIR:-/run/user/0}"
if [ "$#" -ge 1 ] && IMG="$(readlink -f -- "$1" 2>/dev/null)" &&
        [ -n "${IMG}" ]; then
    shift
    set -- --ro "${IMG}" -- "${REAL}" "${IMG}" "$@"
else
    # No argument, or a path that resolves to nothing: hand it over
    # unchanged and let novi-view print its own usage or its own error.
    set -- -- "${REAL}" "$@"
fi
# THE TWO OPTIONAL ONES ARE TESTED, not just listed. novi-sandbox
# skips an absent path by design and says so, which is right for a
# caller naming what a program MIGHT need -- but /etc/novi/themes is a
# user override directory most machines never create, and
# /run/novi/theme only exists once a theme has been applied, so naming
# them unconditionally printed two warnings on every single launch. A
# warning that fires when nothing is wrong is a warning nobody reads,
# and it was the first thing this viewer said on a booted machine.
for opt in /etc/novi/themes /run/novi/theme; do
    [ -e "${opt}" ] && set -- --ro "${opt}" "$@"
done
# A BIND DOES NOT FOLLOW A SYMLINK OUT OF WHAT IT BOUND, and
# /usr/share/X11/xkb is an absolute link to /usr/share/xkeyboard-config-2
# -- so binding /usr/share/X11 puts a DANGLING link inside, because an
# absolute link resolves against the sandbox's root where the target is
# not. xkbcommon then cannot add a single default include path,
# `xkb_context_new` returns NULL, and the client dies on the first
# keymap. Both ends, and the target is resolved rather than written:
# the "2" in that directory name is a version.
if [ -e /usr/share/X11/xkb ]; then
    set -- --ro /usr/share/X11 "$@"
    XKB="$(readlink -f /usr/share/X11/xkb 2>/dev/null)"
    case "${XKB}" in
        /usr/share/X11/*|"") ;;      # inside what is already bound
        *) [ -d "${XKB}" ] && set -- --ro "${XKB}" "$@" ;;
    esac
fi
set -- novi-sandbox --no-net \
    --ro /usr/lib --ro /lib --ro /usr/libexec \
    --ro /usr/share/fonts --ro /usr/share/fontconfig \
    --ro /usr/share/novi/themes --ro /etc/fonts \
    --ro /var/cache/fontconfig \
    --rw "${RUNTIME}" \
    "$@"
run "$@"
WRAP
chmod 755 "${ROOTFS}/usr/bin/novi-view"

echo ""
echo "novi-view installed:"
ls -la "${ROOTFS}/usr/libexec/novi-view" "${ROOTFS}/usr/bin/novi-view"

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
icon=image
description=View a PNG, BMP or PPM image
EOF
echo "   done: ${APPS_DIR}/novi-view.app"
