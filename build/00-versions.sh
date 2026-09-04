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
