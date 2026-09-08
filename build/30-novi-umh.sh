#!/bin/bash
# ============================================================
# 30-novi-umh.sh — Build /sbin/usermode-helper
#
# The file CONFIG_STATIC_USERMODEHELPER has been pointing at, and this
# image has never contained. novi-umh/main.c has the whole argument;
# the short version is that every kernel-initiated module autoload on
# this system has been failing silently since the hardening block was
# written, and it took nftables asking the kernel for `nft_ct` to
# notice.
#
# The path is not ours to choose: CONFIG_STATIC_USERMODEHELPER_PATH is
# compiled into the kernel and it says /sbin/usermode-helper. Rename
# this and the kernel execs nothing again -- the same trap as busybox
# acpid's compiled-in /etc/acpi/PWRF/00000080 (RFC 0013).
#
# Static, like novi-verify and for a related reason: it stands between
# the kernel and everything the kernel wants to run, so it must not
# depend on a loader path or a shared library that could be replaced.
# harden_flags() is deliberately NOT applied, for the same reason it is
# not applied to busybox and novi-verify -- static PIE is a different
# flag with different failure modes, and this binary runs in the
# kernel's own exec path.
#
# It goes in the initramfs too (scripts/mkinitramfs.sh): the initramfs
# is a different root filesystem, so a kernel autoload attempted before
# switch_root looks for /sbin/usermode-helper there and finds nothing
# unless it is put there as well.
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/00-versions.sh"

CC="${TOOLS}/bin/${TARGET_TRIPLE}-gcc"
[ -x "${CC}" ] || {
    echo "ERROR: ${CC} not found -- run build/02-toolchain.sh first." >&2
    exit 1
}

# The allowlist in main.c names /sbin/modprobe because that is what
# CONFIG_MODPROBE_PATH says. If the kernel config ever changes it, the
# two must move together, so check rather than assume: a mismatch here
# is silent at build time and silent at runtime, which is exactly the
# failure mode this whole program exists to end.
KCONFIG="${REPO_ROOT}/kernel/config-x86_64"
want_modprobe="$(sed -n 's/^CONFIG_MODPROBE_PATH="\(.*\)"$/\1/p' "${KCONFIG}")"
want_modprobe="${want_modprobe:-/sbin/modprobe}"
grep -q "\"${want_modprobe}\"" "${REPO_ROOT}/novi-umh/main.c" || {
    echo "ERROR: kernel CONFIG_MODPROBE_PATH is '${want_modprobe}' but" >&2
    echo "       novi-umh/main.c does not allow that path." >&2
    exit 1
}

want_path="$(sed -n 's/^CONFIG_STATIC_USERMODEHELPER_PATH="\(.*\)"$/\1/p' "${KCONFIG}")"
want_path="${want_path:-/sbin/usermode-helper}"

WORK="${BUILD_DIR}/novi-umh-build"
rm -rf "${WORK}"
mkdir -p "${WORK}"

echo ">>> Building novi-umh (static, musl) -> ${want_path} ..."
(
    cd "${WORK}"
    "${CC}" -O2 -Wall -Wextra -Werror -static \
        -o novi-umh "${REPO_ROOT}/novi-umh/main.c"
    "${TOOLS}/bin/${TARGET_TRIPLE}-strip" novi-umh
)

install -D -m 755 "${WORK}/novi-umh" "${ROOTFS}${want_path}"

echo ""
echo "novi-umh installed:"
ls -la "${ROOTFS}${want_path}"
