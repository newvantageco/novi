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

echo ""
echo "All sources downloaded to ${SOURCES}"
