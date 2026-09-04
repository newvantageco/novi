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

# An installed Novi system (packages/novi-install, RFC 0003) boots with a
# real root filesystem on disk -- no ISO to find, no squashfs, no overlay,
# and crucially no tmpfs upperdir, so changes survive a reboot. That is the
# entire difference between "live" and "installed".
#
# `boot=live` forces the live path even when a root= is also present. The
# ISO's own GRUB entries pass it, so an installed disk sitting in the same
# machine can never hijack a live boot.
ROOT_SPEC="$(get_param root)"
case "${ROOT_SPEC}" in
    # dracut-style live spec (`root=live:/dev/disk/by-label/NOVI`, which the
    # ISO's own menu entries pass) names the live media, not a root
    # filesystem. boot=live already covers the ISO; this covers a
    # hand-edited command line that dropped it.
    live:*) ROOT_SPEC="" ;;
esac
ROOTFSTYPE="$(get_param rootfstype)"
ROOTFLAGS="$(get_param rootflags)"

# ── Handoff to the real root ──────────────────────────────────────────────────
#
# Everything below this point is identical whether /newroot came from a
# squashfs+overlay (live) or from a real partition (installed), so both
# paths end here rather than each growing its own copy that can drift.
finalize_and_switch() {
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

    # The live media has to be reachable from the installed-system side:
    # novi-install reads the kernel, the initramfs and the staged GRUB
    # artifacts out of /run/live, and none of them exist anywhere else.
    #
    # This bind MUST come after the /run move above, not before it.
    # Binding first and then moving the initramfs's own /run on top of
    # /newroot/run buries the bind under the new mount -- the mount is
    # still there, but nothing can reach it, and /run/live simply does
    # not exist in the booted system. Confirmed live: `ls /run/live` ->
    # "No such file or directory", with the bind reported as successful.
    if [ -n "${LIVE_MOUNT:-}" ] && [ -d "${LIVE_MOUNT}" ]; then
        mkdir -p /newroot/run/live
        mount --bind "${LIVE_MOUNT}" /newroot/run/live || \
            warn "could not bind ${LIVE_MOUNT} to /run/live -- novi-install will not find the media"
    fi

    # scripts/mkiso.sh's mksquashfs invocation excludes /tmp from the
    # squashed image entirely (`-e proc sys dev run tmp`, the same
    # exclusion list as the other runtime-mounted directories), but unlike
    # dev/proc/sys/run above, nothing ever mounted anything AT /tmp -- so a
    # live boot ended up with no /tmp directory at all (confirmed live: `ls
    # /tmp` failed with "No such file or directory", not guessed). 1777 to
    # match the mode build/03-base.sh already sets on the build-time
    # rootfs's own (squashed-out) /tmp.
    mkdir -p /newroot/tmp
    mount -t tmpfs -o mode=1777 tmpfs /newroot/tmp

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
}

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

# ── Disk-root boot path (installed system) ────────────────────────────────────
#
# Taken when the bootloader passed a root= and did NOT pass boot=live. This
# is the path an installed Novi uses: mount the partition read-write and
# hand off. No squashfs, no overlay, no tmpfs -- the root filesystem IS the
# writable one, so nothing is discarded on reboot.
resolve_root_device() {
    local spec="$1"
    local key="" want="" attempt=0 blkdev out got

    case "${spec}" in
        LABEL=*) key="LABEL"; want="${spec#LABEL=}" ;;
        UUID=*)  key="UUID";  want="${spec#UUID=}"  ;;
        /dev/*)  key="";      want="${spec}"        ;;
        *)       return 1 ;;
    esac

    while [ ${attempt} -lt 30 ]; do
        if [ -z "${key}" ]; then
            if [ -b "${want}" ]; then
                echo "${want}"
                return 0
            fi
        else
            # Partitions before whole disks: root lives on a partition on
            # every layout novi-install produces, and a whole-disk match
            # would only ever be a coincidence worth losing to the real one.
            #
            # BusyBox blkid ignores "-s FOO -o value" and always prints its
            # default `dev: LABEL="x" UUID="y" TYPE="z"` line (the same trap
            # find_live_device() documents below), so parse that instead.
            # The [ :] before the key name is what keeps a UUID= query from
            # matching the PARTUUID= field on the same line.
            for blkdev in /dev/sd?? /dev/vd?? /dev/nvme?n?p? /dev/mmcblk?p? \
                          /dev/sd? /dev/vd? /dev/nvme?n? /dev/mmcblk?; do
                [ -b "${blkdev}" ] || continue
                out="$(blkid "${blkdev}" 2>/dev/null)"
                got="$(printf '%s' "${out}" | sed -n "s/.*[ :]${key}=\"\([^\"]*\)\".*/\1/p")"
                if [ "${got}" = "${want}" ]; then
                    echo "${blkdev}"
                    return 0
                fi
            done
        fi

        attempt=$((attempt + 1))
        info "Waiting for root device ${spec}... (${attempt}/30)"
        sleep 1
        [ $((attempt % 5)) -eq 0 ] && mdev -s 2>/dev/null || true
    done

    return 1
}

if [ -n "${ROOT_SPEC}" ] && ! has_param boot=live; then
    info "Disk root requested: root=${ROOT_SPEC}"

    ROOT_DEV="$(resolve_root_device "${ROOT_SPEC}")" || \
        panic "Could not find root device '${ROOT_SPEC}'"
    info "Root device resolved to: ${ROOT_DEV}"

    # rw is the default and the point; `ro` on the command line still wins
    # for anyone who wants the traditional fsck-then-remount-rw sequence.
    # Written as full `if`s, not `cond && assign`: /init runs under `set -e`,
    # where a trailing `&&` whose test is false makes the whole list exit 1
    # and takes the boot down with it.
    ROOT_OPTS="rw,noatime"
    if has_param ro; then
        ROOT_OPTS="ro,noatime"
    fi
    if [ -n "${ROOTFLAGS}" ]; then
        ROOT_OPTS="${ROOT_OPTS},${ROOTFLAGS}"
    fi

    info "Mounting ${ROOT_DEV} on /newroot (${ROOT_OPTS}) ..."
    if [ -n "${ROOTFSTYPE}" ]; then
        mount -t "${ROOTFSTYPE}" -o "${ROOT_OPTS}" "${ROOT_DEV}" /newroot || \
            panic "Could not mount ${ROOT_DEV} as ${ROOTFSTYPE}"
    else
        # ext2/3/4 all mount through the ext4 driver here
        # (CONFIG_EXT4_USE_FOR_EXT2=y in kernel/config-x86_64), which is
        # what makes BusyBox mke2fs's journal-less ext2 usable as a root.
        mount -o "${ROOT_OPTS}" "${ROOT_DEV}" /newroot 2>/dev/null || \
        mount -t ext4 -o "${ROOT_OPTS}" "${ROOT_DEV}" /newroot || \
            panic "Could not mount ${ROOT_DEV}"
    fi

    finalize_and_switch "$@"
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
        #
        # BusyBox's blkid applet ignores "-s LABEL -o value" entirely and
        # always prints its plain default-format line (confirmed with
        # set -x tracing: `blkid -s LABEL -o value /dev/vda` printed
        # `/dev/vda: LABEL="NOVI" TYPE="iso9660"`, not a bare "NOVI") --
        # so the exact-equality comparison this used to do could never
        # match, even against the correct device, every single loop
        # iteration. Parse LABEL="..." out of the plain output instead,
        # which is what both BusyBox's and util-linux's blkid print by
        # default with no -o flag at all.
        #
        # LABEL alone is not enough to identify the right device, either:
        # grub-mkrescue's hybrid ISO also carries an Apple HFS+ partition
        # (for Mac EFI boot) that xorriso stamps with the *same* volume
        # label as the real ISO9660 filesystem. Confirmed via a live boot
        # trace -- /dev/vda3 matched LABEL="NOVI" but was
        # `TYPE="hfsplus"`, and mounting it as iso9660/vfat failed with
        # "Invalid argument" every time, because /dev/vd?? (partition
        # devices) is scanned before /dev/vd? (the whole disk, where the
        # actual ISO9660 volume lives) and the decoy partition matched
        # first. Requiring TYPE to be one we can actually mount (iso9660
        # or vfat) skips the decoy regardless of scan order.
        for blkdev in /dev/sd?? /dev/sd? /dev/vd?? /dev/vd? /dev/sr? /dev/nvme?n? /dev/mmcblk?; do
            [ -b "${blkdev}" ] || continue
            blkid_out="$(blkid "${blkdev}" 2>/dev/null)"
            found_label="$(printf '%s' "${blkid_out}" | sed -n 's/.*[ :]LABEL="\([^"]*\)".*/\1/p')"
            found_type="$(printf '%s' "${blkid_out}" | sed -n 's/.*[ :]TYPE="\([^"]*\)".*/\1/p')"
            if [ "${found_label}" = "${label}" ] && \
               { [ "${found_type}" = "iso9660" ] || [ "${found_type}" = "vfat" ]; }; then
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

finalize_and_switch "$@"
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

# ─── Kernel modules ───────────────────────────────────────────────────────────
# /init's load_module() calls (virtio_blk, squashfs, overlay, ...) are only
# meaningful if the .ko files + depmod metadata actually exist somewhere
# modprobe can see -- and at this point in boot, before the live media is
# even found, the initramfs IS the only filesystem available. Embed the
# whole built module tree (small: ~34M/158 .ko at last count) rather than
# hand-pick a subset and risk missing a transitive dependency.
mkdir -p "${WORK_DIR}/lib/modules"
MODULES_SRC="${MODULES_SRC:-/build/rootfs/lib/modules}"
if [[ -d "${MODULES_SRC}" ]]; then
    KVER="$(basename "$(find "${MODULES_SRC}" -mindepth 1 -maxdepth 1 -type d | head -1)")"
    if [[ -n "${KVER}" ]]; then
        echo ">>> Embedding kernel modules (${KVER}) ..."
        cp -a "${MODULES_SRC}/${KVER}" "${WORK_DIR}/lib/modules/"
    else
        echo "WARNING: no kernel module tree found under ${MODULES_SRC} -- modprobe will find nothing in the initramfs." >&2
    fi
else
    echo "WARNING: MODULES_SRC (${MODULES_SRC}) not found -- modprobe will find nothing in the initramfs." >&2
fi

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
