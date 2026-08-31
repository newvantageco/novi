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
