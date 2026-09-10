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

# Hash-pinned fetch. Every other source here is trusted because of
# where it comes from (kernel.org, gnu.org, musl.libc.org over TLS);
# that is the normal bargain and it is fine for a compiler. It is not
# fine for the one file that becomes the trust root of package
# verification -- if TweetNaCl arrives modified, `pkg` verifies
# signatures with an implementation an attacker chose. Pin it.
fetch_pinned() {
    local url="$1" want="$2"
    local file
    file="$(basename "${url}")"
    if [ ! -f "${file}" ]; then
        echo "[fetch] ${file}"
        curl -fL --retry 3 -o "${file}.part" "${url}"
        mv "${file}.part" "${file}"
    else
        echo "[skip]  ${file} already exists"
    fi
    local got
    got="$(sha256sum "${file}" | cut -d' ' -f1)"
    if [ "${got}" != "${want}" ]; then
        echo "ERROR: ${file} sha256 mismatch" >&2
        echo "  expected ${want}" >&2
        echo "  got      ${got}" >&2
        exit 1
    fi
    echo "[ok]    ${file} sha256 verified"
}

# Kernel
fetch "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${LINUX_VERSION}.tar.xz"

# Toolchain
fetch "https://ftp.gnu.org/gnu/binutils/binutils-${BINUTILS_VERSION}.tar.xz"

# GNU make, for the native toolchain (RFC 0015). BusyBox has no make
# applet, so without this a Novi machine can run a compiler and still
# not build anything that ships a Makefile -- which is all of it.
fetch "https://ftp.gnu.org/gnu/make/make-${MAKE_VERSION}.tar.gz"

# pkgconf, for the native toolchain. Without a pkg-config on the target
# every `./configure` fails to locate a single library, which makes the
# difference between a compiler and a build environment. pkgconf rather
# than freedesktop pkg-config: it is plain C with no dependencies,
# where the original needs glib.
fetch "https://distfiles.ariadne.space/pkgconf/pkgconf-${PKGCONF_VERSION}.tar.xz"

# zlib and libpng, for novi-view. PNG is the only image
# format anyone actually hands you, and decoding it needs both. zlib is
# also the first general-purpose compression library in this image --
# freetype was built with -Dzlib=internal precisely because there was
# none.
fetch "https://zlib.net/fossils/zlib-${ZLIB_VERSION}.tar.gz"
fetch "https://download.sourceforge.net/libpng/libpng-${LIBPNG_VERSION}.tar.xz"
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
fetch "https://archive.mesa3d.org/mesa-${MESA_VERSION}.tar.xz"
fetch "https://gitlab.freedesktop.org/emersion/libdisplay-info/-/archive/${LIBDISPLAY_INFO_VERSION}/libdisplay-info-${LIBDISPLAY_INFO_VERSION}.tar.gz"
fetch "https://gitlab.freedesktop.org/wlroots/wlroots/-/archive/${WLROOTS_VERSION}/wlroots-${WLROOTS_VERSION}.tar.gz"
# xkeyboard-config: the runtime keyboard layout database (rules/symbols/
# keycodes/compat/types data files). libxkbcommon builds fine without
# it, but at runtime xkb_keymap_new_from_names() needs this data to
# compile ANY keymap -- confirmed live: novi-shell got all the way
# through DRM+renderer+allocator+libinput init and then hard-failed
# ("xkbcommon: ERROR: failed to add default include path
# /usr/share/X11/xkb") the moment libinput handed it a real input
# device to build a keymap for. GitLab archive naming doubles the
# project name for a "xkeyboard-config-N.NN" ref, same pattern as
# pixman/libdrm above.
fetch "https://gitlab.freedesktop.org/xkeyboard-config/xkeyboard-config/-/archive/xkeyboard-config-${XKEYBOARD_CONFIG_VERSION}/xkeyboard-config-xkeyboard-config-${XKEYBOARD_CONFIG_VERSION}.tar.gz"
fetch_git "libxkbcommon" "${LIBXKBCOMMON_VERSION}" \
    "https://github.com/xkbcommon/libxkbcommon" "xkbcommon-${LIBXKBCOMMON_VERSION}"
fetch_git "libudev-zero" "${LIBUDEV_ZERO_VERSION}" \
    "https://github.com/illiliti/libudev-zero" "${LIBUDEV_ZERO_VERSION}"
fetch_git "seatd" "${SEATD_VERSION}" \
    "https://git.sr.ht/~kennylevinsen/seatd" "${SEATD_VERSION}"

# ── foot (default terminal, RFC 0001 decision 6) and its font-rendering
# dependency chain -- see build/09-foot.sh. Both gitlab.freedesktop.org
# archive endpoints work with a plain fetch here (no Anubis wall, unlike
# mtdev's).
fetch "https://gitlab.freedesktop.org/freetype/freetype/-/archive/VER-${FREETYPE_VERSION}/freetype-VER-${FREETYPE_VERSION}.tar.gz"
fetch "https://gitlab.freedesktop.org/fontconfig/fontconfig/-/archive/${FONTCONFIG_VERSION}/fontconfig-${FONTCONFIG_VERSION}.tar.gz"

# tllist/fcft/foot are hosted on codeberg.org (Forgejo, not GitLab) --
# its archive tarballs extract to a bare "<project>/" directory with NO
# version suffix at all (confirmed by hand: "tllist/", not
# "tllist-1.1.0/"), unlike every GitHub/GitLab archive fetched above.
# Fetched to an explicit "<name>-<version>.tar.gz" filename so the
# generic build_meson() naming convention still applies to the
# downloaded file even though the version has to be passed as a `-d`
# directory override at build time.
for pkg_ver in "tllist:${TLLIST_VERSION}" "fcft:${FCFT_VERSION}" "foot:${FOOT_VERSION}"; do
    pkg="${pkg_ver%%:*}"
    ver="${pkg_ver##*:}"
    fname="${pkg}-${ver}.tar.gz"
    if [ ! -f "${fname}" ]; then
        echo "[fetch] ${fname}"
        curl -fL --retry 3 -o "${fname}" "https://codeberg.org/dnkl/${pkg}/archive/${ver}.tar.gz"
    else
        echo "[skip]  ${fname} already exists"
    fi
done

# JetBrains Mono: the default terminal font. OFL-1.1 (fully
# redistributable). Fetched as a GitHub *release asset* (a prebuilt
# .zip of .ttf files), not a source-archive endpoint -- this repo's
# session environment blocks GitHub source-archive downloads but not
# release-asset downloads (different backing infra), and building a
# font from its real source (a FontForge/UFO project) would pull in
# FontForge itself, wildly out of proportion to "install a terminal
# font."
INTER_ZIP="inter-${INTER_VERSION}.zip"
if [ ! -f "${INTER_ZIP}" ]; then
    echo "[fetch] ${INTER_ZIP}"
    curl -fL --retry 3 -o "${INTER_ZIP}" \
        "https://github.com/rsms/inter/releases/download/v${INTER_VERSION}/Inter-${INTER_VERSION}.zip"
else
    echo "[skip]  ${INTER_ZIP} already exists"
fi

# Source Serif 4 (RFC 0031's serif). Same release-asset reasoning as
# the two above -- and one extra fetch, because Adobe's release asset
# contains font files and nothing else. An OFL font redistributed
# without its licence is a licence violation with a friendly face, so
# the text comes down beside it.
SOURCE_SERIF_ZIP="source-serif-${SOURCE_SERIF_VERSION}.zip"
if [ ! -f "${SOURCE_SERIF_ZIP}" ]; then
    echo "[fetch] ${SOURCE_SERIF_ZIP}"
    curl -fL --retry 3 -o "${SOURCE_SERIF_ZIP}" \
        "https://github.com/adobe-fonts/source-serif/releases/download/${SOURCE_SERIF_VERSION}R/source-serif-${SOURCE_SERIF_VERSION}.zip"
else
    echo "[skip]  ${SOURCE_SERIF_ZIP} already exists"
fi

SOURCE_SERIF_LICENSE="source-serif-${SOURCE_SERIF_VERSION}-OFL.txt"
if [ ! -f "${SOURCE_SERIF_LICENSE}" ]; then
    echo "[fetch] ${SOURCE_SERIF_LICENSE}"
    curl -fL --retry 3 -o "${SOURCE_SERIF_LICENSE}" \
        "https://raw.githubusercontent.com/adobe-fonts/source-serif/${SOURCE_SERIF_VERSION}R/LICENSE.md"
else
    echo "[skip]  ${SOURCE_SERIF_LICENSE} already exists"
fi

JBMONO_ZIP="jetbrains-mono-${JETBRAINS_MONO_VERSION}.zip"
if [ ! -f "${JBMONO_ZIP}" ]; then
    echo "[fetch] ${JBMONO_ZIP}"
    curl -fL --retry 3 -o "${JBMONO_ZIP}" \
        "https://github.com/JetBrains/JetBrainsMono/releases/download/v${JETBRAINS_MONO_VERSION}/JetBrainsMono-${JETBRAINS_MONO_VERSION}.zip"
else
    echo "[skip]  ${JBMONO_ZIP} already exists"
fi

# ALSA: the library, and the handful of tools that make a sound card
# usable (amixer, alsactl, aplay, speaker-test).
fetch "https://www.alsa-project.org/files/pub/lib/alsa-lib-${ALSA_VERSION}.tar.bz2"
fetch "https://www.alsa-project.org/files/pub/utils/alsa-utils-${ALSA_VERSION}.tar.bz2"

# The wireless regulatory database and Intel SOF audio firmware.
# Neither is part of linux-firmware; both are separately versioned
# projects, and both are the difference between hardware that works and
# hardware that half-works in a way that looks like something else.
fetch "https://www.kernel.org/pub/software/network/wireless-regdb/wireless-regdb-${WIRELESS_REGDB_VERSION}.tar.xz"

SOF_TARBALL="sof-bin-${SOF_BIN_VERSION}.tar.gz"
if [ ! -f "${SOF_TARBALL}" ]; then
    echo "[fetch] ${SOF_TARBALL}"
    curl -fL --retry 3 -o "${SOF_TARBALL}" \
        "https://github.com/thesofproject/sof-bin/releases/download/v${SOF_BIN_VERSION}/${SOF_TARBALL}"
else
    echo "[skip]  ${SOF_TARBALL} already exists"
fi

# linux-firmware. Big (several hundred MB) and fetched whole because
# kernel.org serves one tarball; build/26-firmware.sh extracts only the
# curated subset that ends up in the image.
fetch "https://cdn.kernel.org/pub/linux/kernel/firmware/linux-firmware-${LINUX_FIRMWARE_VERSION}.tar.xz"

# nftables and its two libraries (RFC 0016). netfilter.org publishes
# these as plain tarballs, which is the easiest fetch in this file.
# nftables is configured --with-mini-gmp --without-cli, so none of gmp,
# readline or jansson is needed alongside them.
fetch "https://netfilter.org/projects/libmnl/files/libmnl-${LIBMNL_VERSION}.tar.bz2"
fetch "https://netfilter.org/projects/libnftnl/files/libnftnl-${LIBNFTNL_VERSION}.tar.xz"
fetch "https://netfilter.org/projects/nftables/files/nftables-${NFTABLES_VERSION}.tar.xz"

# WPA3 (RFC 0021). Fetched by git rather than as a tarball because
# GitHub's /archive/refs/tags/ endpoint is not reachable from this
# build environment (403) and wolfSSL publishes no release asset under
# a predictable name -- fetch_git exists for exactly this.
fetch_git "wolfssl" "${WOLFSSL_VERSION}" \
    "https://github.com/wolfSSL/wolfssl" "v${WOLFSSL_VERSION}-stable"

# HTTPS (RFC 0020): mbedTLS, curl, and the certificate authorities the
# whole thing rests on.
fetch "https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-${MBEDTLS_VERSION}/mbedtls-${MBEDTLS_VERSION}.tar.bz2"
fetch "https://curl.se/download/curl-${CURL_VERSION}.tar.xz"

# The CA bundle is HASH-PINNED, and it is only the second thing in this
# project that is. The first is TweetNaCl, because it verifies package
# signatures; this is the same argument. A CA bundle is a list of
# parties whose word is accepted about who a server is -- if it arrives
# modified, every HTTPS connection this system makes is validated
# against a set somebody else chose. Fetching a *dated* file rather
# than the rolling cacert.pem is what makes pinning possible at all.
fetch_pinned "https://curl.se/ca/cacert-${CACERT_DATE}.pem" "${CACERT_SHA256}"

# Developer tooling (RFC 0019): git, and the ssh client it needs to
# reach anything. OpenSSH is built --without-openssl, which is the
# whole reason it is allowed in this image at all.
fetch "https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-${OPENSSH_VERSION}.tar.gz"
fetch "https://cdn.kernel.org/pub/software/scm/git/git-${GIT_VERSION}.tar.xz"

# NetSurf (RFC 0032), the "all" tarball: the browser plus the thirteen
# libraries it is built from, which are separate git repositories
# upstream and are not separately released.
fetch "https://download.netsurf-browser.org/netsurf/releases/source-full/netsurf-all-${NETSURF_VERSION}.tar.gz"

# OpenSSL (RFC 0027). A package: it is what CPython's ssl module is
# written against, and there is no other implementation it accepts.
fetch "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"

# CPython (RFC 0026). A package, like every other developer tool here.
fetch "https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tar.xz"

# Full-disk encryption (RFC 0018). popt and json-c are cryptsetup's
# hard dependencies; util-linux and LVM2 are enormous trees fetched for
# exactly one library each (libuuid, libdevmapper) -- see
# build/34-cryptsetup.sh for why neither can be avoided.
fetch "http://ftp.rpm.org/popt/releases/popt-1.x/popt-${POPT_VERSION}.tar.gz"
fetch "https://s3.amazonaws.com/json-c_releases/releases/json-c-${JSON_C_VERSION}.tar.gz"
fetch "https://www.kernel.org/pub/linux/utils/util-linux/v${UTIL_LINUX_VERSION%.*}/util-linux-${UTIL_LINUX_VERSION}.tar.xz"
fetch "https://sourceware.org/ftp/lvm2/LVM2.${LVM2_VERSION}.tgz"
fetch "https://cdn.kernel.org/pub/linux/utils/cryptsetup/v${CRYPTSETUP_VERSION%.*}/cryptsetup-${CRYPTSETUP_VERSION}.tar.xz"

# WiFi: libnl (wpa_supplicant's nl80211 driver needs it), wpa_supplicant
# and hostapd (same upstream tree; hostapd is test-only -- see
# build/25-wifi.sh), and iw for diagnostics.
#
# libnl publishes tarballs as GitHub *release assets*, which this
# environment can reach; its source-archive endpoints it cannot. Same
# split this file already documents for JetBrains Mono.
LIBNL_TARBALL="libnl-${LIBNL_VERSION}.tar.gz"
if [ ! -f "${LIBNL_TARBALL}" ]; then
    echo "[fetch] ${LIBNL_TARBALL}"
    curl -fL --retry 3 -o "${LIBNL_TARBALL}" \
        "https://github.com/thom311/libnl/releases/download/libnl$(echo "${LIBNL_VERSION}" | tr . _)/${LIBNL_TARBALL}"
else
    echo "[skip]  ${LIBNL_TARBALL} already exists"
fi

fetch "https://w1.fi/releases/wpa_supplicant-${WPA_SUPPLICANT_VERSION}.tar.gz"
fetch "https://w1.fi/releases/hostapd-${WPA_SUPPLICANT_VERSION}.tar.gz"
fetch "https://www.kernel.org/pub/software/network/iw/iw-${IW_VERSION}.tar.xz"

# e2fsprogs — real mke2fs (journalled ext4) and e2fsck. From tytso's own
# kernel.org directory, the upstream home of the project.
fetch "https://www.kernel.org/pub/linux/kernel/people/tytso/e2fsprogs/v${E2FSPROGS_VERSION}/e2fsprogs-${E2FSPROGS_VERSION}.tar.xz"

# TweetNaCl — the Ed25519 implementation novi-verify is built on, and
# therefore the trust root for every package this system installs.
# Public domain, by the NaCl authors (Bernstein, Janssen, Lange,
# Schwabe, Van Assche). Two files, no build system, no configuration.
# Fetched from the authors' own site and hash-pinned above.
mkdir -p "${SOURCES}/tweetnacl-${TWEETNACL_VERSION}"
(
    cd "${SOURCES}/tweetnacl-${TWEETNACL_VERSION}"
    fetch_pinned "https://tweetnacl.cr.yp.to/${TWEETNACL_VERSION}/tweetnacl.c" \
        "02e65bc3013ff2168983365e55906bc783c4c7e0a60d8100f17bb303a17175c4"
    fetch_pinned "https://tweetnacl.cr.yp.to/${TWEETNACL_VERSION}/tweetnacl.h" \
        "43f29ad721d9927b747b0100ab4160c119e7bb180c7c98a66e4bf79d31244287"
)

echo ""
echo "All sources downloaded to ${SOURCES}"
