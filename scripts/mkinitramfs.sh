#!/usr/bin/env bash
# mkinitramfs.sh — Build a minimal initramfs for Novi Linux
#
# The resulting initramfs contains:
#   - busybox (statically linked) for all shell utilities
#   - musl libc (if needed by any dynamic binaries)
#   - An /init script that:
#       1. Mounts devtmpfs, proc, sysfs
#       2. Waits for and identifies the live media device
#       3. Mounts the squashfs image read-only
#       4. Sets up overlayfs (tmpfs upperdir) for writable root
#       5. Populates /dev, /proc, /sys in new root
#       6. exec's switch_root into the new root
#
# Usage: sudo ./mkinitramfs.sh [--output FILE] [--busybox PATH]
# Requires: busybox (static), cpio, gzip, find, install

set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-${REPO_ROOT}/build}"
OUTPUT="${OUTPUT:-${BUILD_DIR}/initramfs.cpio.gz}"
WORK_DIR="${BUILD_DIR}/initramfs-work"

# Busybox binary — prefer static, fallback to system
BUSYBOX_BIN="${BUSYBOX_BIN:-}"
BUSYBOX_CANDIDATES=(
    # Novi's own build (build/03-base.sh installs to /build/rootfs, per
    # BUILD_DIR=/build in build/00-versions.sh -- not repo-relative)
    "/build/rootfs/bin/busybox"
    "${REPO_ROOT}/build/busybox-static"
    "/usr/lib/busybox/busybox-static"
    "$(command -v busybox 2>/dev/null || true)"
)

# Squashfs image name (must match mkiso.sh)
SQUASHFS_IMG_NAME="${SQUASHFS_IMG_NAME:-live/filesystem.squashfs}"
# Label of the live media (must match mkiso.sh ISO_LABEL)
LIVE_LABEL="${LIVE_LABEL:-NOVI}"

# ─── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)   OUTPUT="$2"; shift 2 ;;
        --busybox)  BUSYBOX_BIN="$2"; shift 2 ;;
        --workdir)  WORK_DIR="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--output FILE] [--busybox PATH] [--workdir DIR]"
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# ─── Locate busybox ──────────────────────────────────────────────────────────
if [[ -z "${BUSYBOX_BIN}" ]]; then
    for candidate in "${BUSYBOX_CANDIDATES[@]}"; do
        if [[ -n "${candidate}" && -x "${candidate}" ]]; then
            BUSYBOX_BIN="${candidate}"
            break
        fi
    done
fi
[[ -n "${BUSYBOX_BIN}" && -x "${BUSYBOX_BIN}" ]] || {
    echo "ERROR: busybox not found. Install it or set BUSYBOX_BIN." >&2
    echo "  Debian/Ubuntu: sudo apt install busybox-static" >&2
    echo "  Alpine/Arch:   static busybox is the default" >&2
    exit 1
}
echo ">>> Using busybox: ${BUSYBOX_BIN}"

# Warn if busybox is not statically linked
if ldd "${BUSYBOX_BIN}" &>/dev/null; then
    echo "WARNING: busybox at ${BUSYBOX_BIN} appears to be dynamically linked." >&2
    echo "  Dynamic libraries will NOT be included. Use a static build." >&2
fi

# ─── Prerequisite checks ──────────────────────────────────────────────────────
require() {
    command -v "$1" &>/dev/null || { echo "ERROR: '$1' not found in PATH" >&2; exit 1; }
}
require cpio
require gzip
require find

# ─── Prepare work directory ──────────────────────────────────────────────────
echo ">>> Preparing initramfs work directory: ${WORK_DIR} ..."
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"

# ─── Directory structure ──────────────────────────────────────────────────────
echo ">>> Creating directory skeleton ..."
for d in \
    bin sbin usr/bin usr/sbin \
    lib lib64 usr/lib \
    dev proc sys run tmp \
    mnt/root mnt/squashfs mnt/overlay/upper mnt/overlay/work \
    newroot
do
    mkdir -p "${WORK_DIR}/${d}"
done

# Symlinks for compat
ln -sfn ../bin "${WORK_DIR}/usr/bin"     2>/dev/null || true
ln -sfn ../sbin "${WORK_DIR}/usr/sbin"   2>/dev/null || true

# ─── Install busybox ─────────────────────────────────────────────────────────
echo ">>> Installing busybox ..."
install -m 0755 "${BUSYBOX_BIN}" "${WORK_DIR}/bin/busybox"

# Install busybox applet symlinks
APPLETS=(
    sh ash bash echo cat ls mkdir mknod mount umount sleep
    switch_root pivot_root chroot
    ln cp mv rm rmdir chmod chown
    grep sed awk cut sort uniq head tail wc
    find xargs
    insmod modprobe lsmod rmmod
    dmesg sysctl
    blkid udevadm
    ps kill killall
    ip ifconfig
    uname hostname date
    dd blockdev
    hexdump xxd
    gzip gunzip zcat
    cpio
    true false test
    '[' '[['
    printf
)
for applet in "${APPLETS[@]}"; do
    ln -sf busybox "${WORK_DIR}/bin/${applet}" 2>/dev/null || true
done
# Also put critical ones in /sbin
for applet in modprobe insmod mount umount switch_root pivot_root blkid; do
    ln -sf ../bin/busybox "${WORK_DIR}/sbin/${applet}" 2>/dev/null || true
done

# ─── /init script ─────────────────────────────────────────────────────────────
echo ">>> Writing /init script ..."
cat > "${WORK_DIR}/init" <<'INIT_SCRIPT'
#!/bin/sh
# Novi Linux — initramfs /init
# Mounts squashfs+overlayfs then switch_root
# Runs in: busybox sh (ash), no bash features

set -e

# ── Helpers ───────────────────────────────────────────────────────────────────
info()  { echo "[init] $*"; }
warn()  { echo "[init] WARNING: $*" >&2; }
die()   { echo "[init] FATAL: $*" >&2; exec sh; }
panic() { echo "[init] PANIC: $*" >&2; echo "Dropping to emergency shell."; exec sh; }

# ── Basic mounts ──────────────────────────────────────────────────────────────
info "Mounting virtual filesystems ..."
mount -t devtmpfs  devtmpfs /dev  2>/dev/null || \
    mount -t tmpfs -o size=1m,mode=0755 tmpfs /dev
mount -t proc      proc     /proc
mount -t sysfs     sysfs    /sys
mount -t tmpfs     tmpfs    /run

# /dev/pts for ptys
mkdir -p /dev/pts
mount -t devpts -o gid=5,mode=620 devpts /dev/pts 2>/dev/null || true

# /sys/firmware/efi/efivars (UEFI only, ignore failure)
mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>/dev/null || true

# ── Parse kernel command line ─────────────────────────────────────────────────
CMDLINE="$(cat /proc/cmdline)"
info "Kernel cmdline: ${CMDLINE}"

get_param() {
    local key="$1" val=""
    for token in ${CMDLINE}; do
        case "${token}" in
            ${key}=*) val="${token#${key}=}" ;;
        esac
    done
    echo "${val}"
}

has_param() {
    local key="$1"
    for token in ${CMDLINE}; do
        [ "${token}" = "${key}" ] && return 0
    done
    return 1
}

LIVE_MEDIA_LABEL="$(get_param live-media-label)"
LIVE_MEDIA_LABEL="${LIVE_MEDIA_LABEL:-NOVI}"
SQUASHFS_IMG="$(get_param rd.live.squashimg)"
SQUASHFS_IMG="${SQUASHFS_IMG:-live/filesystem.squashfs}"
INIT_PATH="$(get_param init)"
INIT_PATH="${INIT_PATH:-/sbin/init}"

# ── Load kernel modules ───────────────────────────────────────────────────────
info "Loading essential kernel modules ..."

load_module() {
    modprobe "$1" 2>/dev/null || warn "Could not load module: $1"
}

# Block & storage
load_module nvme
load_module nvme_core
load_module ahci
load_module libahci
load_module sd_mod
load_module sr_mod
load_module usb_storage
load_module uas
load_module virtio_blk

# Filesystems
load_module squashfs
load_module overlay
load_module isofs
load_module vfat
load_module fat
load_module ext4
load_module btrfs

# USB host controllers
load_module xhci_hcd
load_module xhci_pci
load_module ehci_hcd
load_module ehci_pci

# Input (early, for keyboard in panic shell)
load_module hid_generic
load_module usbhid

# ── Populate /dev with uevents ────────────────────────────────────────────────
info "Triggering uevents ..."
if [ -x /sbin/udevadm ]; then
    udevadm trigger --action=add 2>/dev/null || true
else
    # Busybox mdev fallback
    echo /sbin/mdev > /proc/sys/kernel/hotplug 2>/dev/null || true
    mdev -s 2>/dev/null || true
fi

# ── Find live media device ────────────────────────────────────────────────────
info "Searching for live media (label=${LIVE_MEDIA_LABEL}) ..."

find_live_device() {
    local label="$1"
    local dev=""
    local attempt=0
    local max_attempts=30

    while [ ${attempt} -lt ${max_attempts} ]; do
        # Try by-label symlink first
        if [ -b "/dev/disk/by-label/${label}" ]; then
            dev="$(readlink -f "/dev/disk/by-label/${label}")"
            echo "${dev}"
            return 0
        fi

        # Fallback: scan all block devices with blkid
        # (includes /dev/vd* -- virtio-blk's device naming, used for both
        # the ISO and the installer disk in scripts/mkvm.sh)
        for blkdev in /dev/sd?? /dev/sd? /dev/vd?? /dev/vd? /dev/sr? /dev/nvme?n? /dev/mmcblk?; do
            [ -b "${blkdev}" ] || continue
            found_label="$(blkid -s LABEL -o value "${blkdev}" 2>/dev/null || true)"
            if [ "${found_label}" = "${label}" ]; then
                echo "${blkdev}"
                return 0
            fi
        done

        attempt=$((attempt + 1))
        info "Waiting for live media... (${attempt}/${max_attempts})"
        sleep 1

        # Trigger uevents again in case hotplug was slow
        [ $((attempt % 5)) -eq 0 ] && mdev -s 2>/dev/null || true
    done

    return 1
}

LIVE_DEV="$(find_live_device "${LIVE_MEDIA_LABEL}")" || \
    panic "Could not find live media with label '${LIVE_MEDIA_LABEL}'"

info "Found live media at: ${LIVE_DEV}"

# ── Mount live media ──────────────────────────────────────────────────────────
info "Mounting live media (${LIVE_DEV}) ..."
LIVE_MOUNT="/mnt/live"
mkdir -p "${LIVE_MOUNT}"

# Try ISO 9660 first (CD/USB ISO), then vfat
mount -t iso9660 -o ro,noatime "${LIVE_DEV}" "${LIVE_MOUNT}" 2>/dev/null || \
mount -t vfat    -o ro,noatime "${LIVE_DEV}" "${LIVE_MOUNT}" 2>/dev/null || \
    panic "Could not mount live media ${LIVE_DEV}"

SQUASHFS_PATH="${LIVE_MOUNT}/${SQUASHFS_IMG}"
[ -f "${SQUASHFS_PATH}" ] || panic "squashfs not found at ${SQUASHFS_PATH}"
info "Found squashfs: ${SQUASHFS_PATH} ($(ls -lh "${SQUASHFS_PATH}" | awk '{print $5}'))"

# ── Mount squashfs (read-only base) ──────────────────────────────────────────
info "Mounting squashfs ..."
mount -t squashfs -o ro,loop "${SQUASHFS_PATH}" /mnt/squashfs || \
    panic "Failed to mount squashfs"

# ── Set up overlayfs (writable layer over squashfs) ───────────────────────────
info "Setting up overlayfs ..."

# Upper and work dirs live in a tmpfs (RAM) — changes are discarded on reboot
# For persistent changes, upper could be on a real partition
OVERLAY_TMP="/mnt/overlay-tmp"
mkdir -p "${OVERLAY_TMP}"
mount -t tmpfs -o size=75%,mode=0755 tmpfs "${OVERLAY_TMP}"
mkdir -p "${OVERLAY_TMP}/upper" "${OVERLAY_TMP}/work"

mount -t overlay overlay \
    -o "lowerdir=/mnt/squashfs,upperdir=${OVERLAY_TMP}/upper,workdir=${OVERLAY_TMP}/work" \
    /newroot || panic "Failed to mount overlayfs"

info "Overlay mounted at /newroot"

# ── Bind-mount live media into new root (for installer access) ────────────────
mkdir -p /newroot/run/live
mount --bind "${LIVE_MOUNT}" /newroot/run/live 2>/dev/null || true

# ── Move virtual mounts into new root ────────────────────────────────────────
info "Moving /dev, /proc, /sys into new root ..."
mkdir -p /newroot/dev /newroot/proc /newroot/sys /newroot/run

# Move (not bind) so they're owned by the new root
mount --move /dev  /newroot/dev  2>/dev/null || \
    mount -t devtmpfs devtmpfs /newroot/dev
mount --move /proc /newroot/proc 2>/dev/null || \
    mount -t proc proc /newroot/proc
mount --move /sys  /newroot/sys  2>/dev/null || \
    mount -t sysfs sysfs /newroot/sys
mount --move /run  /newroot/run  2>/dev/null || \
    mount -t tmpfs tmpfs /newroot/run

# ── Verify new root has an init ───────────────────────────────────────────────
for candidate in "${INIT_PATH}" /sbin/init /usr/sbin/init /lib/systemd/systemd /bin/sh; do
    if [ -x "/newroot${candidate}" ]; then
        REAL_INIT="${candidate}"
        break
    fi
done

[ -n "${REAL_INIT:-}" ] || panic "/newroot has no usable init binary"
info "Handing off to: /newroot${REAL_INIT}"

# ── switch_root ───────────────────────────────────────────────────────────────
exec switch_root /newroot "${REAL_INIT}" "$@" \
    || panic "switch_root failed"
INIT_SCRIPT

chmod 0755 "${WORK_DIR}/init"
echo ">>> /init written ($(wc -l < "${WORK_DIR}/init") lines)"

# ─── /etc/mdev.conf (for mdev-based hotplug) ─────────────────────────────────
mkdir -p "${WORK_DIR}/etc"
cat > "${WORK_DIR}/etc/mdev.conf" <<'MDEV_CONF'
# mdev.conf — minimal hotplug rules for Novi initramfs
# Syntax: regex  uid:gid  octal_perms  [>|=path]  [@|-|$cmd]

# Disk devices
sd[a-z][0-9]*   0:6  0660
nvme[0-9]*      0:6  0660
sr[0-9]*        0:6  0660
mmcblk[0-9]*    0:6  0660

# Symlinks for disk label support
SUBSYSTEM=block;ACTION=add;.*      0:0  0660  @/sbin/blkid -p $MDEV >/dev/null 2>&1

# Input
event[0-9]*     0:0  0600
js[0-9]*        0:0  0660

# Misc
null            0:0  0666
zero            0:0  0666
random          0:0  0666
urandom         0:0  0666
console         0:0  0600
tty[0-9]*       0:5  0660
ttyS[0-9]*      0:5  0660
MDEV_CONF

# ─── /etc/group (minimal, for devpts gid=5) ──────────────────────────────────
cat > "${WORK_DIR}/etc/group" <<'GROUP'
root:x:0:
tty:x:5:
disk:x:6:
GROUP

# ─── /etc/passwd (minimal) ────────────────────────────────────────────────────
cat > "${WORK_DIR}/etc/passwd" <<'PASSWD'
root:x:0:0:root:/root:/bin/sh
PASSWD

# ─── /proc /sys /dev placeholder nodes ───────────────────────────────────────
# Create minimal static device nodes (mdev/devtmpfs will add the rest)
mknod -m 0666 "${WORK_DIR}/dev/null"    c 1 3  2>/dev/null || true
mknod -m 0666 "${WORK_DIR}/dev/zero"    c 1 5  2>/dev/null || true
mknod -m 0666 "${WORK_DIR}/dev/random"  c 1 8  2>/dev/null || true
mknod -m 0666 "${WORK_DIR}/dev/urandom" c 1 9  2>/dev/null || true
mknod -m 0600 "${WORK_DIR}/dev/console" c 5 1  2>/dev/null || true
mknod -m 0666 "${WORK_DIR}/dev/tty"     c 5 0  2>/dev/null || true
mknod -m 0666 "${WORK_DIR}/dev/tty0"    c 4 0  2>/dev/null || true
mknod -m 0666 "${WORK_DIR}/dev/tty1"    c 4 1  2>/dev/null || true

# ─── /lib/modules symlink (init will load from real root after switch) ────────
# Modules aren't embedded in initramfs — the running kernel should have them
# built-in, or the rootfs must provide /lib/modules/<kver>
mkdir -p "${WORK_DIR}/lib/modules"

# ─── Optional: copy musl libc if dynamic busybox ─────────────────────────────
# If busybox is dynamic, we need the linker + musl/glibc
if ldd "${BUSYBOX_BIN}" &>/dev/null 2>&1; then
    echo ">>> busybox is dynamic — copying runtime libraries ..."
    INTERP="$(ldd "${BUSYBOX_BIN}" | awk '/ld-/ {print $NF; exit}')"
    LIBS="$(ldd "${BUSYBOX_BIN}" | awk '/=>/ {print $3}')"

    for lib in "${INTERP}" ${LIBS}; do
        [[ -f "${lib}" ]] || continue
        LIB_DIR="${WORK_DIR}$(dirname "${lib}")"
        mkdir -p "${LIB_DIR}"
        cp -v "${lib}" "${LIB_DIR}/"
    done
fi

# ─── Build the cpio archive ───────────────────────────────────────────────────
echo ">>> Building cpio archive ..."
mkdir -p "$(dirname "${OUTPUT}")"

# Use a reproducible, sorted find to build the archive
(
    cd "${WORK_DIR}"
    # Ensure init is listed first so the kernel finds it immediately
    echo "init"
    find . ! -name "." ! -name "init" \
        | sort \
        | sed 's|^\./||'
) | (
    cd "${WORK_DIR}"
    cpio --create \
         --format=newc \
         --reproducible \
         --owner=0:0 \
         --quiet
) | gzip -9 > "${OUTPUT}"

# ─── Result ───────────────────────────────────────────────────────────────────
INITRD_SIZE="$(du -sh "${OUTPUT}" | cut -f1)"
WORK_SIZE="$(du -sh "${WORK_DIR}" | cut -f1)"
FILE_COUNT="$(find "${WORK_DIR}" | wc -l)"

echo ""
echo "╔════════════════════════════════════════════════════╗"
echo "║  initramfs Build Complete                          ║"
echo "╠════════════════════════════════════════════════════╣"
printf "║  Output     : %-36s║\n" "${OUTPUT}"
printf "║  Size       : %-36s║\n" "${INITRD_SIZE}"
printf "║  Work size  : %-36s║\n" "${WORK_SIZE}"
printf "║  Files      : %-36s║\n" "${FILE_COUNT}"
printf "║  Busybox    : %-36s║\n" "$(basename "${BUSYBOX_BIN}")"
echo "╚════════════════════════════════════════════════════╝"
echo ""
echo "Inspect contents: zcat ${OUTPUT} | cpio -tv | head -60"
echo "Extract:          zcat ${OUTPUT} | cpio -idmv -D /tmp/initrd-extract"
