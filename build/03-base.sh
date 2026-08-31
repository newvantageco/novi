#!/bin/bash
# ============================================================
# 03-base.sh — Build base userland (BusyBox) into rootfs
# ============================================================
set -euo pipefail
source "$(dirname "$0")/00-versions.sh"

NPROC=$(nproc)
CC="${TOOLS}/bin/${TARGET_TRIPLE}-gcc"
STRIP="${TOOLS}/bin/${TARGET_TRIPLE}-strip"

# ── BusyBox ──────────────────────────────────────────────
echo "==> BusyBox ${BUSYBOX_VERSION}"
cd "${SOURCES}"
tar -xf busybox-${BUSYBOX_VERSION}.tar.bz2
cd busybox-${BUSYBOX_VERSION}

# Use our minimal config (no telnet, no ftpd, no legacy cruft)
if [ -f "${BUILD_DIR}/../config/busybox.config" ]; then
    cp "${BUILD_DIR}/../config/busybox.config" .config
else
    make defconfig
fi

# Force static linking for the base install
sed -i 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
sed -i 's/CONFIG_STATIC=n/CONFIG_STATIC=y/' .config

make CROSS_COMPILE="${TARGET_TRIPLE}-" -j${NPROC}
make CROSS_COMPILE="${TARGET_TRIPLE}-" CONFIG_PREFIX="${ROOTFS}" install

cd "${SOURCES}"

# ── Base rootfs directory layout ─────────────────────────
echo "==> Creating rootfs hierarchy"
mkdir -p "${ROOTFS}"/{boot,dev,etc,home,lib,mnt,opt,proc,root,run,srv,sys,tmp,usr/{bin,lib,share},var/{log,run,tmp}}
chmod 1777 "${ROOTFS}/tmp"
chmod 700  "${ROOTFS}/root"

# ── Copy musl libc into rootfs ────────────────────────────
echo "==> Installing musl into rootfs"
cp -a "${SYSROOT}/usr/lib/libc.so"               "${ROOTFS}/lib/libc.musl-x86_64.so.1"
ln -sfn libc.musl-x86_64.so.1                    "${ROOTFS}/lib/ld-musl-x86_64.so.1"

# ── Strip everything ──────────────────────────────────────
echo "==> Stripping binaries"
find "${ROOTFS}" -type f | xargs -I{} sh -c \
    'file "{}" | grep -q "ELF" && '"${STRIP}"' --strip-all "{}" 2>/dev/null || true'

echo ""
echo "Base rootfs ready: ${ROOTFS}"
du -sh "${ROOTFS}"
