#!/bin/bash
# ============================================================
# 05-kernel.sh — Configure and build the Linux kernel
#
# We apply a minimal defconfig and strip anything unused.
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/00-versions.sh"

NPROC=$(nproc)
CROSS="${TARGET_TRIPLE}-"

# modules_install silently WARNS (doesn't fail) and skips generating
# modules.dep/modules.alias when depmod is missing -- set -e doesn't
# catch it, so a build host without kmod produces a kernel that builds
# fine but can't modprobe/auto-load any module (including virtio_blk,
# which this config builds as a module, not built-in). Fail loudly
# instead of shipping an incomplete module tree.
command -v depmod >/dev/null 2>&1 || {
    echo "ERROR: depmod not found (package: kmod). Required for module dependency metadata." >&2
    exit 1
}

cd "${SOURCES}"
[ -d "linux-${LINUX_VERSION}" ] || tar -xf linux-${LINUX_VERSION}.tar.xz
cd linux-${LINUX_VERSION}

echo "==> Applying kernel config"
if [ -f "${REPO_ROOT}/kernel/config-${TARGET_ARCH}" ]; then
    cp "${REPO_ROOT}/kernel/config-${TARGET_ARCH}" .config
    # The curated config doesn't mention BINFMT_ELF, TTY, SERIAL_8250,
    # or BLK_DEV_INITRD at all (not even disabled) -- olddefconfig would
    # fill them from Kconfig defaults, but these are too boot-critical
    # to leave to inference (no BINFMT_ELF means the kernel can't exec
    # anything at all). Force them explicitly, same safety net the
    # tinyconfig fallback below already has.
    scripts/config --enable CONFIG_BINFMT_ELF
    scripts/config --enable CONFIG_BLK_DEV_INITRD
    scripts/config --enable CONFIG_TTY
    scripts/config --enable CONFIG_SERIAL_8250
    scripts/config --enable CONFIG_SERIAL_8250_CONSOLE
    # Same gap for ISO9660: the curated config never mentions it (not
    # even disabled), so olddefconfig left it entirely out of the
    # kernel -- confirmed via a live QEMU boot where mount -t iso9660
    # on the GRUB-built live ISO failed outright ("Could not mount live
    # media"), because there was no iso9660 driver, built-in or
    # module, to try. Joliet/zisofs are what grub-mkrescue's xorriso
    # output actually uses, so pull those in too rather than relying on
    # bare Rock Ridge/plain ISO9660 fallback parsing.
    scripts/config --enable CONFIG_ISO9660_FS
    scripts/config --enable CONFIG_JOLIET
    scripts/config --enable CONFIG_ZISOFS
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
    scripts/config --enable CONFIG_ISO9660_FS
    scripts/config --enable CONFIG_JOLIET
    scripts/config --enable CONFIG_ZISOFS
    scripts/config --enable CONFIG_SQUASHFS
    scripts/config --enable CONFIG_OVERLAY_FS
    scripts/config --enable CONFIG_NET
    scripts/config --enable CONFIG_INET
    scripts/config --enable CONFIG_VIRTIO
    scripts/config --enable CONFIG_VIRTIO_PCI
    scripts/config --enable CONFIG_VIRTIO_BLK
    scripts/config --enable CONFIG_VIRTIO_NET
    make ARCH=x86_64 CROSS_COMPILE="${CROSS}" olddefconfig
fi

# ==> A `CONFIG_X=y` LINE IS A CLAIM, AND olddefconfig MAY IGNORE IT.
#
# A symbol whose dependencies are unmet, or that upstream renamed or
# removed, is dropped SILENTLY: the line stays in the curated config
# reading as policy and the kernel is built without it. `CONFIG_IPC_NS`
# did exactly that -- stated for a kernel that never had it, because it
# needs SYSVIPC which this config deliberately omits -- and was found
# only when novi-sandbox asked for an IPC namespace on a booted machine
# and got EINVAL (RFC 0039). A sweep for the same shape then found
# THIRTY-TWO more.
#
# So: every `=y` in the curated file must be `=y` in the generated
# one. Derived, with no list to maintain -- the alternative is a
# hand-written set of symbols to watch, which is a list that rots and
# would not have contained IPC_NS either.
#
# The way to state something this config cannot honour is a comment
# saying so, which is what those thirty-two became.
if [ -f "${REPO_ROOT}/kernel/config-${TARGET_ARCH}" ]; then
    echo "==> Checking every stated symbol survived olddefconfig"
    dropped=""
    while read -r line; do
        sym="${line%=y}"
        grep -q "^${sym}=y$" .config || dropped="${dropped} ${sym}"
    done < <(grep -E '^CONFIG_[A-Z0-9_]+=y$' "${REPO_ROOT}/kernel/config-${TARGET_ARCH}")
    if [ -n "${dropped}" ]; then
        echo "ERROR: the curated config states symbols the build did not honour:" >&2
        for sym in ${dropped}; do echo "  ${sym}" >&2; done
        echo "" >&2
        echo "Each is either renamed or removed upstream, or has a dependency" >&2
        echo "this config does not set. A line that cannot be honoured is a" >&2
        echo "claim about this kernel that is not true -- fix the dependency" >&2
        echo "or say so in a comment, as the existing NOT BUILT lines do." >&2
        exit 1
    fi
    echo "    every stated symbol is in the generated .config"
fi

echo "==> Building kernel (this takes a while)"
make ARCH=x86_64 CROSS_COMPILE="${CROSS}" -j${NPROC} bzImage modules

echo "==> Installing kernel"
mkdir -p "${ROOTFS}/boot"
cp arch/x86_64/boot/bzImage "${ROOTFS}/boot/vmlinuz-${LINUX_VERSION}"
cp System.map "${ROOTFS}/boot/System.map-${LINUX_VERSION}"
cp .config "${ROOTFS}/boot/config-${LINUX_VERSION}"

make ARCH=x86_64 CROSS_COMPILE="${CROSS}" INSTALL_MOD_PATH="${ROOTFS}" modules_install

# ==> DROP THE COMMANDS THIS KERNEL CANNOT SUPPORT.
#
# busybox is one binary under ~400 names and the names are chosen at
# BUSYBOX config time, while what they NEED is decided here. Nothing
# connected the two, so the base image shipped `ipcs` and `ipcrm` --
# which answer "kernel not configured for message queues" and "unknown
# errror in id (1)" -- for the life of the project, plus `hwclock`,
# `rtcwake`, `nbd-client`, five `ubi*` and `vconfig`. A command that
# cannot work is worse than one that is absent (RFC 0026's `idle3`,
# RFC 0040's `bashbug`, RFC 0040 roadmap 2's busybox `man`).
#
# It runs HERE rather than in `03-base.sh`, which installs those
# symlinks, because the answer comes from the GENERATED config and on
# a clean build that file does not exist until this stage. Re-running
# 03 afterwards puts them back -- the /sbin/init hazard exactly -- so
# `16-s6-rc-db.sh` runs the same script again as part of the repair it
# already does.
#
# Found while measuring the util-linux gap (RFC 0040 roadmap 3,
# tests/utillinux-gap/).
echo "==> Removing applets this kernel cannot support"
bash "${REPO_ROOT}/scripts/prune-dead-applets.sh" "${ROOTFS}" .config

echo ""
echo "Kernel built: ${ROOTFS}/boot/vmlinuz-${LINUX_VERSION}"
ls -lh "${ROOTFS}/boot/"
