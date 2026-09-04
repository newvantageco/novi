#!/bin/bash
# ============================================================
# 23-e2fsprogs.sh — Real mke2fs and e2fsck
#
# RFC 0008. BusyBox's mke2fs writes ext2 with no journal. On a VM that
# is merely untidy; on real hardware it means an unclean shutdown turns
# into a full fsck of the whole filesystem and a genuine risk to data,
# where a journalled filesystem replays a few seconds of log at mount
# time and carries on. That is a correctness gap, not a missing
# feature, and it is the reason novi-install has been shipping a
# documented limitation instead of a filesystem.
#
# Installed SELECTIVELY, not with `make install`. e2fsprogs also builds
# blkid, findfs, fsck, uuidgen and logsave, all of which BusyBox
# already provides as applets that other parts of this system are
# written against -- scripts/mkinitramfs.sh's live-media search parses
# BusyBox blkid's exact output. Silently swapping those out underneath
# would be a change nobody asked for, in code nobody would think to
# re-check.
#
# mke2fs.conf comes with it and is not optional: without it mke2fs has
# no idea what "ext4" means as a feature set and falls back to a bare
# filesystem, which would defeat the entire point of this stage.
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-versions.sh"

SRC="${SOURCES}/e2fsprogs-${E2FSPROGS_VERSION}.tar.xz"
[ -f "${SRC}" ] || {
    echo "ERROR: ${SRC} not found -- run build/01-fetch.sh first." >&2
    exit 1
}

WORK="${BUILD_DIR}/e2fsprogs-build"
rm -rf "${WORK}"
mkdir -p "${WORK}"
tar -xf "${SRC}" -C "${WORK}"
cd "${WORK}/e2fsprogs-${E2FSPROGS_VERSION}"

# ── One narrow source patch, for musl ─────────────────────────────────────
#
# lib/blkid/llseek.c picks an implementation of `my_llseek` from what
# the libc offers. glibc lands on `#define my_llseek lseek64`. musl
# 1.2.4 removed the LFS64 aliases, so there is no lseek64 and no
# llseek, and the fallback branch for "long is as wide as long long"
# reads:
#
#     #define llseek lseek
#
# which defines the wrong name -- `my_llseek` is what the code below
# actually calls, so the file does not compile:
# "implicit declaration of function 'my_llseek'".
#
# On x86_64 this function is dead code anyway: blkid_llseek() returns
# through plain lseek() before ever reaching it, because off_t is
# already 64-bit. It still has to compile. Fixing the name is the
# smallest correct change; the alternative -- carrying a configure
# override that claims a lseek64 musl does not have -- would be a lie
# that breaks somewhere less obvious.
sed -i 's/^#define llseek lseek$/#define my_llseek lseek/' lib/blkid/llseek.c
grep -q '^#define my_llseek lseek$' lib/blkid/llseek.c || {
    echo "ERROR: the musl llseek patch did not apply -- upstream changed." >&2
    exit 1
}

echo ">>> Configuring e2fsprogs for ${TARGET_TRIPLE} ..."
# --disable-*: everything this system does not need. fuse2fs wants
# libfuse, uuidd is a daemon, defrag needs an ioctl this kernel config
# does not enable, and debugfs is a filesystem debugger nobody is
# running on a 30 MB base image.
#
# No --disable-libuuid/--disable-libblkid: those mean "link the SYSTEM
# ones", and there is no system libuuid or libblkid on the target. The
# internal copies are what makes these binaries self-contained.
./configure \
    --host="${TARGET_TRIPLE}" \
    --prefix=/usr \
    --with-root-prefix="" \
    --disable-nls \
    --disable-uuidd \
    --disable-fuse2fs \
    --disable-defrag \
    --disable-debugfs \
    --disable-imager \
    --disable-backtrace \
    --disable-e2initrd-helper \
    >/dev/null

echo ">>> Building ..."
make -j"$(nproc)" >/dev/null

# ── Install only what we actually want ────────────────────────────────────
echo ">>> Installing (selectively) ..."
STRIP="${TOOLS}/bin/${TARGET_TRIPLE}-strip"

install_bin() {
    local src="$1" dst="$2"
    [ -f "${src}" ] || { echo "ERROR: ${src} was not built" >&2; exit 1; }
    install -D -m 755 "${src}" "${ROOTFS}${dst}"
    "${STRIP}" "${ROOTFS}${dst}" 2>/dev/null || true
}

install_bin misc/mke2fs     /sbin/mke2fs.e2fsprogs
install_bin e2fsck/e2fsck   /sbin/e2fsck
install_bin misc/tune2fs    /sbin/tune2fs
install_bin resize/resize2fs /sbin/resize2fs
install_bin misc/dumpe2fs   /sbin/dumpe2fs

# mke2fs lands beside BusyBox's applet rather than on top of it, and
# the callers that want a journal ask for it by name. BusyBox's
# /sbin/mke2fs keeps working for anything that only needs an ext2, and
# nothing that used to work starts behaving differently because this
# stage ran.
for fs in ext2 ext3 ext4; do
    ln -sfn e2fsck "${ROOTFS}/sbin/fsck.${fs}"
    ln -sfn mke2fs.e2fsprogs "${ROOTFS}/sbin/mkfs.${fs}"
done

install -D -m 644 misc/mke2fs.conf "${ROOTFS}/etc/mke2fs.conf"

echo ""
echo "e2fsprogs installed:"
ls -la "${ROOTFS}/sbin/mke2fs.e2fsprogs" "${ROOTFS}/sbin/e2fsck" "${ROOTFS}/etc/mke2fs.conf"
