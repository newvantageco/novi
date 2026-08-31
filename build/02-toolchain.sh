#!/bin/bash
# ============================================================
# 02-toolchain.sh — Build cross-compiler (binutils + gcc + musl)
#
# Phase 1: binutils (cross)
# Phase 2: gcc stage 1 (no libc yet)
# Phase 3: linux headers → musl headers
# Phase 4: musl libc
# Phase 5: gcc stage 2 (full, musl-linked)
# ============================================================
set -euo pipefail
source "$(dirname "$0")/00-versions.sh"

NPROC=$(nproc)
mkdir -p "${TOOLS}" "${SYSROOT}/usr"

cd "${SOURCES}"

# ── Phase 1: binutils (cross) ─────────────────────────────
echo "==> [1/5] binutils-${BINUTILS_VERSION} (cross)"
tar -xf binutils-${BINUTILS_VERSION}.tar.xz
mkdir -p build-binutils && cd build-binutils

../binutils-${BINUTILS_VERSION}/configure \
    --prefix="${TOOLS}" \
    --target="${TARGET_TRIPLE}" \
    --with-sysroot="${SYSROOT}" \
    --disable-nls \
    --disable-multilib \
    --disable-werror

make -j${NPROC}
make install
cd "${SOURCES}"
rm -rf build-binutils

# ── Phase 2: gcc stage 1 ─────────────────────────────────
echo "==> [2/5] gcc-${GCC_VERSION} stage 1 (cross, no libc)"
tar -xf gcc-${GCC_VERSION}.tar.xz
cd gcc-${GCC_VERSION}
# Pull gcc prerequisites (mpfr, gmp, mpc)
contrib/download_prerequisites
cd "${SOURCES}"

mkdir -p build-gcc-stage1 && cd build-gcc-stage1

../gcc-${GCC_VERSION}/configure \
    --prefix="${TOOLS}" \
    --target="${TARGET_TRIPLE}" \
    --with-sysroot="${SYSROOT}" \
    --disable-nls \
    --disable-multilib \
    --disable-shared \
    --disable-threads \
    --disable-libgomp \
    --disable-libssp \
    --disable-libmudflap \
    --disable-libquadmath \
    --disable-libatomic \
    --enable-languages=c \
    --without-headers

make -j${NPROC} all-gcc all-target-libgcc
make install-gcc install-target-libgcc
cd "${SOURCES}"
rm -rf build-gcc-stage1

# ── Phase 3: Linux kernel headers ────────────────────────
echo "==> [3/5] Linux ${LINUX_VERSION} headers"
tar -xf linux-${LINUX_VERSION}.tar.xz
cd linux-${LINUX_VERSION}
make ARCH=x86_64 INSTALL_HDR_PATH="${SYSROOT}/usr" headers_install
cd "${SOURCES}"

# ── Phase 4: musl libc ───────────────────────────────────
echo "==> [4/5] musl-${MUSL_VERSION}"
tar -xf musl-${MUSL_VERSION}.tar.gz
mkdir -p build-musl && cd build-musl

CROSS_COMPILE="${TARGET_TRIPLE}-" \
CC="${TOOLS}/bin/${TARGET_TRIPLE}-gcc" \
../musl-${MUSL_VERSION}/configure \
    --prefix="${SYSROOT}/usr" \
    --target="${TARGET_TRIPLE}" \
    --disable-static \
    --enable-optimize=speed

make -j${NPROC}
make install
cd "${SOURCES}"
rm -rf build-musl

# Create dynamic linker symlink
ln -sfn "${SYSROOT}/usr/lib/ld-musl-x86_64.so.1" "${SYSROOT}/lib/ld-musl-x86_64.so.1" 2>/dev/null || true
mkdir -p "${SYSROOT}/lib"
ln -sfn ../usr/lib/ld-musl-x86_64.so.1 "${SYSROOT}/lib/ld-musl-x86_64.so.1" 2>/dev/null || true

# ── Phase 5: gcc stage 2 (full, musl-linked) ─────────────
echo "==> [5/5] gcc-${GCC_VERSION} stage 2 (full cross-compiler)"
mkdir -p build-gcc-stage2 && cd build-gcc-stage2

../gcc-${GCC_VERSION}/configure \
    --prefix="${TOOLS}" \
    --target="${TARGET_TRIPLE}" \
    --with-sysroot="${SYSROOT}" \
    --disable-nls \
    --disable-multilib \
    --enable-languages=c,c++ \
    --enable-shared \
    --enable-threads=posix \
    --enable-tls

make -j${NPROC}
make install
cd "${SOURCES}"
rm -rf build-gcc-stage2

echo ""
echo "Toolchain complete: ${TOOLS}/bin/${TARGET_TRIPLE}-gcc"
${TOOLS}/bin/${TARGET_TRIPLE}-gcc --version
