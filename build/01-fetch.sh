#!/bin/bash
# ============================================================
# 01-fetch.sh — Download all sources
# Run this first. Idempotent (skips existing files).
# ============================================================
set -euo pipefail
source "$(dirname "$0")/00-versions.sh"

mkdir -p "${SOURCES}"
cd "${SOURCES}"

fetch() {
    local url="$1"
    local file="$(basename $url)"
    if [ ! -f "${file}" ]; then
        echo "[fetch] ${file}"
        curl -fL --retry 3 -o "${file}" "${url}"
    else
        echo "[skip]  ${file} already exists"
    fi
}

# A few small deps (libxkbcommon, libudev-zero, seatd) aren't hosted
# anywhere with a plain-HTTPS release-tarball endpoint this environment
# can reach directly (GitHub's codeload archive endpoints and
# sourcehut's git.sr.ht/.../archive/... both came back blocked/erroring
# when checked directly), but a shallow `git clone` of the same tag
# works fine through this session's git access. Repackage that clone as
# a tarball with the same "<name>-<version>/" layout `fetch()`'s
# targets already have, so every downstream build script can keep
# treating all sources identically (plain `tar -xf`) instead of two
# parallel fetch mechanisms.
fetch_git() {
    local name="$1" version="$2" url="$3" tag="$4"
    local file="${name}-${version}.tar.gz"
    if [ -f "${file}" ]; then
        echo "[skip]  ${file} already exists"
        return
    fi
    echo "[fetch] ${file} (git: ${url} @ ${tag})"
    local tmp
    tmp="$(mktemp -d)"
    git clone --quiet --depth 1 --branch "${tag}" "${url}" "${tmp}/src"
    git -C "${tmp}/src" archive --format=tar.gz \
        --prefix="${name}-${version}/" \
        --output="${SOURCES}/${file}" HEAD
    rm -rf "${tmp}"
}

# Kernel
fetch "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${LINUX_VERSION}.tar.xz"

# Toolchain
fetch "https://ftp.gnu.org/gnu/binutils/binutils-${BINUTILS_VERSION}.tar.xz"
fetch "https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VERSION}/gcc-${GCC_VERSION}.tar.xz"
fetch "https://musl.libc.org/releases/musl-${MUSL_VERSION}.tar.gz"

# Base userland
fetch "https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2"

# s6 ecosystem (skarnet.org)
fetch "https://skarnet.org/software/skalibs/skalibs-${SKALIBS_VERSION}.tar.gz"
fetch "https://skarnet.org/software/execline/execline-${EXECLINE_VERSION}.tar.gz"
fetch "https://skarnet.org/software/s6/s6-${S6_VERSION}.tar.gz"
fetch "https://skarnet.org/software/s6-rc/s6-rc-${S6_RC_VERSION}.tar.gz"
fetch "https://skarnet.org/software/s6-linux-init/s6-linux-init-${S6_LINUX_INIT_VERSION}.tar.gz"

# Wayland/wlroots stack (novi-shell foundation)
# libffi: wayland's libwayland-server links against it (confirmed via
# an actual meson configure run: "Dependency libffi not found"), and
# it isn't part of musl/gcc/binutils. GitHub's release-ASSET downloads
# (this one) are served from separate blob-storage infrastructure and
# aren't affected by the codeload/archive source-download restriction
# that blocks plain "download this tag as a tarball" links elsewhere
# in this file -- and unlike Debian's raw .orig source tarball (tried
# first), a GitHub release asset ships a pre-generated ./configure,
# no autoreconf/libtool bootstrap required.
fetch "https://github.com/libffi/libffi/releases/download/v${LIBFFI_VERSION}/libffi-${LIBFFI_VERSION}.tar.gz"
# expat: wayland's scanner/core links against it for XML protocol
# parsing (confirmed the same way as libffi above: "Dependency expat
# not found"). Same GitHub-release-asset path as libffi, for the
# same reason.
fetch "https://github.com/libexpat/libexpat/releases/download/R_${EXPAT_VERSION//./_}/expat-${EXPAT_VERSION}.tar.gz"
fetch "https://gitlab.freedesktop.org/wayland/wayland/-/archive/${WAYLAND_VERSION}/wayland-${WAYLAND_VERSION}.tar.gz"
fetch "https://gitlab.freedesktop.org/wayland/wayland-protocols/-/archive/${WAYLAND_PROTOCOLS_VERSION}/wayland-protocols-${WAYLAND_PROTOCOLS_VERSION}.tar.gz"
fetch "https://gitlab.freedesktop.org/pixman/pixman/-/archive/pixman-${PIXMAN_VERSION}/pixman-pixman-${PIXMAN_VERSION}.tar.gz"
fetch "https://gitlab.freedesktop.org/libevdev/libevdev/-/archive/libevdev-${LIBEVDEV_VERSION}/libevdev-libevdev-${LIBEVDEV_VERSION}.tar.gz"
# mtdev specifically (not the other gitlab.freedesktop.org projects
# fetched here -- confirmed by re-running the plain fetch() request
# repeatedly and inspecting the actual response) gets bounced by
# freedesktop.org's Anubis anti-bot challenge on its archive endpoint,
# which needs a JS proof-of-work solve no plain HTTP client can pass --
# curl -fL doesn't treat this as a failure since the challenge page
# itself returns 200, so it silently downloads an HTML page named
# mtdev-1.1.7.tar.gz instead of a tarball. Debian's source mirror
# carries the identical pristine upstream tarball (mtdev_X.orig.tar.gz)
# with no such wall. Fetched under our own "<name>-<version>.tar.gz"
# name directly (not via fetch()) so the idempotency check on re-runs
# looks at the name we actually keep, not Debian's .orig naming.
if [ ! -f "mtdev-${MTDEV_VERSION}.tar.gz" ]; then
    echo "[fetch] mtdev-${MTDEV_VERSION}.tar.gz (via Debian mirror)"
    curl -fL --retry 3 -o "mtdev-${MTDEV_VERSION}.tar.gz" \
        "http://deb.debian.org/debian/pool/main/m/mtdev/mtdev_${MTDEV_VERSION}.orig.tar.gz"
else
    echo "[skip]  mtdev-${MTDEV_VERSION}.tar.gz already exists"
fi
fetch "https://gitlab.freedesktop.org/libinput/libinput/-/archive/${LIBINPUT_VERSION}/libinput-${LIBINPUT_VERSION}.tar.gz"
fetch "https://gitlab.freedesktop.org/mesa/drm/-/archive/libdrm-${LIBDRM_VERSION}/drm-libdrm-${LIBDRM_VERSION}.tar.gz"
fetch "https://gitlab.freedesktop.org/wlroots/wlroots/-/archive/${WLROOTS_VERSION}/wlroots-${WLROOTS_VERSION}.tar.gz"
fetch_git "libxkbcommon" "${LIBXKBCOMMON_VERSION}" \
    "https://github.com/xkbcommon/libxkbcommon" "xkbcommon-${LIBXKBCOMMON_VERSION}"
fetch_git "libudev-zero" "${LIBUDEV_ZERO_VERSION}" \
    "https://github.com/illiliti/libudev-zero" "${LIBUDEV_ZERO_VERSION}"
fetch_git "seatd" "${SEATD_VERSION}" \
    "https://git.sr.ht/~kennylevinsen/seatd" "${SEATD_VERSION}"

echo ""
echo "All sources downloaded to ${SOURCES}"
