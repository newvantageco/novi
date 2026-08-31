#!/bin/bash
# ============================================================
# 02-toolchain.sh — Build cross-compiler (binutils + gcc + musl)
#
# Phase 1: binutils (cross)
# Phase 2: gcc stage 1a (compiler only, no libc, no libgcc)
# Phase 3: Linux headers -> sysroot
# Phase 4: musl headers only (libgcc needs real <stdio.h> etc.)
# Phase 5: gcc stage 1b (libgcc, now that target headers exist)
# Phase 6: musl libc (full build, linked with gcc stage 1)
# Phase 7: gcc stage 2 (full, musl-linked)
# ============================================================
set -euo pipefail
source "$(dirname "$0")/00-versions.sh"

NPROC=$(nproc)
mkdir -p "${TOOLS}" "${SYSROOT}/usr/include"

cd "${SOURCES}"

# ── Phase 1: binutils (cross) ─────────────────────────────
echo "==> [1/7] binutils-${BINUTILS_VERSION} (cross)"
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

# ── Phase 2: gcc stage 1a (compiler only, --without-headers) ─
# Only the compiler itself is built here. libgcc is deferred to
# Phase 5: it needs a real target <stdio.h> (via gcc/tsystem.h),
# which doesn't exist until musl's headers are installed (Phase 4).
echo "==> [2/7] gcc-${GCC_VERSION} stage 1a (compiler only, no libc)"
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

make -j${NPROC} all-gcc
make install-gcc
cd "${SOURCES}"

# ── Phase 3: Linux kernel headers ────────────────────────
echo "==> [3/7] Linux ${LINUX_VERSION} headers"
tar -xf linux-${LINUX_VERSION}.tar.xz
cd linux-${LINUX_VERSION}
make ARCH=x86_64 INSTALL_HDR_PATH="${SYSROOT}/usr" headers_install
cd "${SOURCES}"

# ── Phase 4: musl headers only ───────────────────────────
# Installs musl's headers into the sysroot without building or
# linking musl itself -- that happens in Phase 6, after gcc stage 1
# has a working libgcc to link musl against.
echo "==> [4/7] musl-${MUSL_VERSION} headers"
tar -xf musl-${MUSL_VERSION}.tar.gz
mkdir -p build-musl-headers && cd build-musl-headers

CROSS_COMPILE="${TARGET_TRIPLE}-" \
CC="${TOOLS}/bin/${TARGET_TRIPLE}-gcc" \
../musl-${MUSL_VERSION}/configure \
    --prefix="${SYSROOT}/usr" \
    --target="${TARGET_TRIPLE}"

make install-headers
cd "${SOURCES}"
rm -rf build-musl-headers

# ── Phase 5: gcc stage 1b (libgcc) ───────────────────────
echo "==> [5/7] gcc-${GCC_VERSION} stage 1b (libgcc)"
cd build-gcc-stage1
make -j${NPROC} all-target-libgcc
make install-target-libgcc
cd "${SOURCES}"
rm -rf build-gcc-stage1

# ── Phase 6: musl libc (full build) ──────────────────────
# Build both libc.so and libc.a: the shared lib is needed for gcc
# stage 2 and any dynamically-linked package later, but the static
# archive is required too -- 03-base.sh links BusyBox fully static
# (README's stated stack: "Userland | BusyBox (static)"), and a
# static link needs -lc to resolve to libc.a, not just libc.so.
echo "==> [6/7] musl-${MUSL_VERSION} (full build)"
mkdir -p build-musl && cd build-musl

CROSS_COMPILE="${TARGET_TRIPLE}-" \
CC="${TOOLS}/bin/${TARGET_TRIPLE}-gcc" \
../musl-${MUSL_VERSION}/configure \
    --prefix="${SYSROOT}/usr" \
    --target="${TARGET_TRIPLE}" \
    --enable-optimize=speed

make -j${NPROC}
make install
cd "${SOURCES}"
rm -rf build-musl musl-${MUSL_VERSION}

# Dynamic linker symlink (relative, so it resolves once copied into
# any rootfs rooted elsewhere, not just here in the build sysroot).
mkdir -p "${SYSROOT}/lib"
ln -sfn ../usr/lib/ld-musl-x86_64.so.1 "${SYSROOT}/lib/ld-musl-x86_64.so.1"

# ── Phase 7: gcc stage 2 (full, musl-linked) ─────────────
echo "==> [7/7] gcc-${GCC_VERSION} stage 2 (full cross-compiler)"
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
rm -rf build-gcc-stage2 gcc-${GCC_VERSION}

echo ""
echo "Toolchain complete: ${TOOLS}/bin/${TARGET_TRIPLE}-gcc"
${TOOLS}/bin/${TARGET_TRIPLE}-gcc --version
