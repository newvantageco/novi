#!/bin/bash
# ============================================================
# build.sh — Master build orchestrator
# Run this to build everything in order.
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_SCRIPTS="${SCRIPT_DIR}/build"

log() { echo -e "\n\033[1;32m>>> $*\033[0m\n"; }
err() { echo -e "\n\033[1;31m!!! $*\033[0m\n" >&2; exit 1; }

# Require Linux
[[ "$(uname)" == "Linux" ]] || err "Must run on Linux (use WSL2 or a VM)"

# Require build tools
for tool in gcc make curl tar; do
    command -v $tool &>/dev/null || err "Missing required tool: ${tool}"
done

log "Step 1/5: Fetching sources"
bash "${BUILD_SCRIPTS}/01-fetch.sh"

log "Step 2/5: Building cross-compiler toolchain"
bash "${BUILD_SCRIPTS}/02-toolchain.sh"

log "Step 3/5: Building base userland (BusyBox)"
bash "${BUILD_SCRIPTS}/03-base.sh"

log "Step 4/5: Building s6 supervision stack"
bash "${BUILD_SCRIPTS}/04-s6.sh"

log "Step 5/5: Building Linux kernel"
bash "${BUILD_SCRIPTS}/05-kernel.sh"

log "Build complete!"
source "${BUILD_SCRIPTS}/00-versions.sh"
echo "Rootfs size: $(du -sh ${ROOTFS} | cut -f1)"
echo "Kernel: ${ROOTFS}/boot/vmlinuz-${LINUX_VERSION}"
