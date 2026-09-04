#!/bin/bash
# ============================================================
# 24-novi-gpt.sh — Build novi-gpt, the GPT writer
#
# RFC 0008. BusyBox's fdisk can only create MBR labels -- it reads a
# GPT and cannot write one -- and the installed system is a static
# BusyBox with no sfdisk, no sgdisk and no parted. No GPT means no UEFI
# install, and no UEFI install means Novi cannot go on most machines
# built since about 2012.
#
# Static, like novi-verify, and for a related reason: this runs at the
# moment a disk is being repartitioned, which is the worst possible
# time to discover a missing shared library.
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

WORK="${BUILD_DIR}/novi-gpt-build"
rm -rf "${WORK}"; mkdir -p "${WORK}"

echo ">>> Building novi-gpt (static, musl) ..."
"${CC}" -O2 -static -Wall -Wextra -Werror \
    -o "${WORK}/novi-gpt" "${REPO_ROOT}/novi-gpt/main.c"
"${TOOLS}/bin/${TARGET_TRIPLE}-strip" "${WORK}/novi-gpt"

install -D -m 755 "${WORK}/novi-gpt" "${ROOTFS}/sbin/novi-gpt"

echo ""
echo "novi-gpt installed:"
ls -la "${ROOTFS}/sbin/novi-gpt"
