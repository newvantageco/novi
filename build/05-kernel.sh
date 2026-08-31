#!/bin/bash
# ============================================================
# 05-kernel.sh — Configure and build the Linux kernel
#
# We apply a minimal defconfig and strip anything unused.
# ============================================================
set -euo pipefail
source "$(dirname "$0")/00-versions.sh"

NPROC=$(nproc)
CROSS="${TARGET_TRIPLE}-"

cd "${SOURCES}"
[ -d "linux-${LINUX_VERSION}" ] || tar -xf linux-${LINUX_VERSION}.tar.xz
cd linux-${LINUX_VERSION}

echo "==> Applying kernel config"
if [ -f "${BUILD_DIR}/../kernel/config-${TARGET_ARCH}" ]; then
    cp "${BUILD_DIR}/../kernel/config-${TARGET_ARCH}" .config
    make ARCH=x86_64 CROSS_COMPILE="${CROSS}" olddefconfig
else
    echo "   No custom config found, using tinyconfig as base"
    make ARCH=x86_64 CROSS_COMPILE="${CROSS}" tinyconfig
    # Minimum viable additions for tinyconfig
    scripts/config --enable CONFIG_64BIT
    scripts/config --enable CONFIG_SMP
    scripts/config --enable CONFIG_PRINTK
    scripts/config --enable CONFIG_TTY
    scripts/config --enable CONFIG_SERIAL_8250
    scripts/config --enable CONFIG_SERIAL_8250_CONSOLE
    scripts/config --enable CONFIG_PROC_FS
    scripts/config --enable CONFIG_SYSFS
    scripts/config --enable CONFIG_TMPFS
    scripts/config --enable CONFIG_DEVTMPFS
    scripts/config --enable CONFIG_DEVTMPFS_MOUNT
    scripts/config --enable CONFIG_EXT4_FS
    scripts/config --enable CONFIG_NET
    scripts/config --enable CONFIG_INET
    scripts/config --enable CONFIG_VIRTIO
    scripts/config --enable CONFIG_VIRTIO_PCI
    scripts/config --enable CONFIG_VIRTIO_BLK
    scripts/config --enable CONFIG_VIRTIO_NET
    make ARCH=x86_64 CROSS_COMPILE="${CROSS}" olddefconfig
fi

echo "==> Building kernel (this takes a while)"
make ARCH=x86_64 CROSS_COMPILE="${CROSS}" -j${NPROC} bzImage modules

echo "==> Installing kernel"
mkdir -p "${ROOTFS}/boot"
cp arch/x86_64/boot/bzImage "${ROOTFS}/boot/vmlinuz-${LINUX_VERSION}"
cp System.map "${ROOTFS}/boot/System.map-${LINUX_VERSION}"
cp .config "${ROOTFS}/boot/config-${LINUX_VERSION}"

make ARCH=x86_64 CROSS_COMPILE="${CROSS}" INSTALL_MOD_PATH="${ROOTFS}" modules_install

echo ""
echo "Kernel built: ${ROOTFS}/boot/vmlinuz-${LINUX_VERSION}"
ls -lh "${ROOTFS}/boot/"
