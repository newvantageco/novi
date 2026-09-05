#!/bin/bash
# ============================================================
# Novi Linux — Package versions & OS identity
# Change here, changes everywhere.
# ============================================================

# OS identity
OS_NAME="Novi"
OS_TAGLINE="Linux, reimagined."
OS_VERSION="0.1.0"
OS_CODENAME="Axiom"
OS_ID="novi"

LINUX_VERSION="6.10.3"
MUSL_VERSION="1.2.5"
BINUTILS_VERSION="2.43"
GCC_VERSION="14.2.0"
MAKE_VERSION="4.4.1"          # GNU make, for the native (self-hosting) toolchain
PKGCONF_VERSION="2.3.0"       # pkg-config implementation in C (no perl, no glib)
ZLIB_VERSION="1.3.1"          # deflate; libpng needs it, and so will everything else
LIBPNG_VERSION="1.6.43"       # PNG decode, for novi-view
BUSYBOX_VERSION="1.36.1"

# s6 ecosystem (skarnet.org)
SKALIBS_VERSION="2.14.1.1"
EXECLINE_VERSION="2.9.4.0"
S6_VERSION="2.12.0.2"
S6_RC_VERSION="0.5.4.2"
S6_LINUX_INIT_VERSION="1.1.2.0"

# Wayland/wlroots stack (novi-shell foundation) -- meson-built, see
# build/06-wayland.sh. libxkbcommon, libudev-zero come from GitHub;
# seatd comes from sourcehut; everything else from gitlab.freedesktop.org.
LIBFFI_VERSION="3.4.8"
EXPAT_VERSION="2.6.2"
WAYLAND_VERSION="1.23.0"
WAYLAND_PROTOCOLS_VERSION="1.37"
LIBXKBCOMMON_VERSION="1.8.1"
PIXMAN_VERSION="0.43.4"
LIBUDEV_ZERO_VERSION="1.0.5"
LIBEVDEV_VERSION="1.13.3"
MTDEV_VERSION="1.1.7"
LIBINPUT_VERSION="1.26.2"
LIBDRM_VERSION="2.4.122"
SEATD_VERSION="0.9.3"
LIBDISPLAY_INFO_VERSION="0.2.0"
WLROOTS_VERSION="0.18.0"
XKEYBOARD_CONFIG_VERSION="2.48"

# foot (default terminal, RFC 0001 decision 6) and its dependency
# chain -- see build/09-foot.sh. freetype/fontconfig/fcft/tllist/
# JetBrains Mono are all NEW here, nothing else in this repo needed
# real font rendering before now.
#
# fcft is pinned to the 2.x line, NOT latest (3.3.3 at time of
# writing) -- confirmed by reading foot-1.9.2's own meson.build:
# `dependency('fcft', version: ['>=2.4.0', '<3.0.0'])`. Pinning
# "latest fcft" here would have been the same class of mistake as an
# unpinned skarnet version skew earlier in this repo's history.
FREETYPE_VERSION="2-14-3"
FONTCONFIG_VERSION="2.18.3"
TLLIST_VERSION="1.1.0"
FCFT_VERSION="2.5.1"
FOOT_VERSION="1.9.2"
JETBRAINS_MONO_VERSION="2.304"

# e2fsprogs: real mke2fs and e2fsck. BusyBox's mke2fs writes ext2 with
# no journal, which on real hardware turns an unclean shutdown into a
# full fsck and a risk to data rather than a journal replay. RFC 0008.
E2FSPROGS_VERSION="1.47.1"

# WiFi (RFC 0009). wpa_supplicant is built with its INTERNAL crypto, so
# it pulls in no OpenSSL -- the base image deliberately has none, and
# novi-verify exists precisely so that stays true. hostapd comes from
# the same source tree and is built only to test against; it is not
# installed into the image.
LIBNL_VERSION="3.11.0"
WPA_SUPPLICANT_VERSION="2.11"
IW_VERSION="6.9"

# linux-firmware (RFC 0011). Not the whole tree -- build/26-firmware.sh
# extracts a curated subset. Without it the WiFi radio in most laptops
# never comes up and an AMD GPU does not initialise at all, so this is
# the difference between "boots on your machine" and "boots in QEMU".
LINUX_FIRMWARE_VERSION="20260810"

# The wireless regulatory database. NOT part of linux-firmware -- it is
# its own project, and this kernel has
# CONFIG_CFG80211_REQUIRE_SIGNED_REGDB=y, so without regulatory.db and
# its .p7s signature the wireless stack falls back to the most
# restrictive world-roaming rules. That looks like bad reception, not
# like a missing file.
WIRELESS_REGDB_VERSION="2026.09.03"

# Intel SOF audio firmware, also NOT in linux-firmware (it moved to its
# own project). Intel laptops from roughly 2019 on drive their audio
# through SOF rather than legacy HDA; without this they have no sound
# at all.
SOF_BIN_VERSION="2025.01"

# ALSA (RFC 0011). The kernel has had 57 sound options compiled in
# since the beginning and nothing in userspace has ever touched one of
# them.
ALSA_VERSION="1.2.12"

# TweetNaCl is versioned by release date, not a semver tag. This is the
# only "version" its authors publish; the sha256 pins in 01-fetch.sh
# are what actually fix the code.
TWEETNACL_VERSION="20140427"

# Build target
TARGET_ARCH="x86_64"
TARGET_TRIPLE="${TARGET_ARCH}-linux-musl"

# Directories
export BUILD_DIR="/build"
export SOURCES="${BUILD_DIR}/sources"
export TOOLS="${BUILD_DIR}/tools"
export SYSROOT="${BUILD_DIR}/sysroot"
export ROOTFS="${BUILD_DIR}/rootfs"

export PATH="${TOOLS}/bin:${PATH}"

# ── harden_flags ──────────────────────────────────────────────────────
#
# Compile-time hardening for the code this project writes. Call it in a
# stage before building; it exports CFLAGS/LDFLAGS, and every Makefile
# here uses `CFLAGS +=`, so the stage's own flags are appended to these
# rather than replacing them.
#
# This exists because the kernel config is hardened -- STACKPROTECTOR_
# STRONG, RANDOMIZE_BASE, STRICT_KERNEL_RWX, FORTIFY_SOURCE,
# INIT_ON_ALLOC_DEFAULT_ON are all set in kernel/config-x86_64 -- and
# the userland it was protecting had none of it. Every binary in the
# image was type=EXEC with no __stack_chk_fail symbol and no BIND_NOW:
# no ASLR, no stack guard, no fortified string functions, and a GOT
# that stayed writable for the life of the process.
#
# The project's stated security model (PLATFORM-ROADMAP §9) is "small
# TCB by construction", which is an argument about how MANY binaries
# can be attacked, not about how hard any one of them is to attack.
# Alpine is the same libc and the same smallness argument and ships PIE
# + SSP + fortify by default; there was no reason not to.
#
# What each one is for:
#   -O2                    fortify is a no-op without optimisation, and
#                          these clients were being built at -O0
#   -fstack-protector-strong   a canary on any frame with an array or a
#                          local whose address is taken
#   -D_FORTIFY_SOURCE=2    musl's checked str*/mem*/sprintf variants
#   -fPIE -pie             the binary can be loaded anywhere, so kernel
#                          ASLR actually applies to it
#   -Wl,-z,relro,-z,now    resolve every symbol at load, then make the
#                          GOT read-only
#   -Wl,-z,noexecstack     no executable stack (musl needs none)
#
# Deliberately NOT applied to the static binaries (BusyBox, novi-verify)
# or to anything under kernel/: static PIE is a different flag with
# different failure modes in PID 1's path, and the kernel has its own
# hardening already set in its own config. Widening this is its own
# change, with its own boot test.
harden_flags() {
    export CFLAGS="-O2 -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fPIE ${CFLAGS:-}"
    export LDFLAGS="-pie -Wl,-z,relro,-z,now -Wl,-z,noexecstack ${LDFLAGS:-}"
}

# ── require_desktop_headers ───────────────────────────────────────────
#
# Every stage that cross-compiles a Wayland client needs the headers and
# .pc files that 06-wayland.sh put in the rootfs. 31-desktop-split.sh
# takes them out again (RFC 0015 made them a package), so in a tree
# where a full build has already run, rebuilding one client stops with
# four "No such file or directory" lines from four different headers and
# no indication of why or what to do.
#
# That is not a hypothetical. Chaining a rebuild into 30-repo.sh without
# checking it succeeded packaged a rootfs with no desktop in it, and
# 31-desktop-split.sh then deleted from the base exactly what that empty
# manifest described -- leaving no desktop in the image AND none in the
# repository. Recovering meant re-running the stages, which is the
# documented mechanism and took fifteen minutes. One clear line at the
# top of the stage is cheaper than that.
require_desktop_headers() {
    if [ -f "${ROOTFS}/usr/include/wayland-client.h" ]; then
        return 0
    fi
    echo "ERROR: the desktop headers are not in ${ROOTFS}." >&2
    echo "" >&2
    echo "  31-desktop-split.sh has removed them (they ship as the" >&2
    echo "  novi-headers package). Put them back before building a" >&2
    echo "  client against them:" >&2
    echo "" >&2
    echo "      bash scripts/restore-build-inputs.sh" >&2
    echo "" >&2
    echo "  Then re-run this stage, and re-run 30-repo.sh and" >&2
    echo "  31-desktop-split.sh before making an image." >&2
    exit 1
}
