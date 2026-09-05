#!/bin/bash
# ============================================================
# 32-toolchain-repo.sh — publish the native toolchain into the repo
#
# 28-native-toolchain.sh builds gcc, binutils, make, pkgconf and
# musl-dev and stages them; this packages them into ${BUILD_DIR}/repo
# and re-signs the index.
#
# They are two stages because they happen at two different times.
# 30-repo.sh wipes and recreates the repository from the rootfs, so
# anything that adds to it must run afterwards -- and the toolchain
# build takes the better part of an hour, so it cannot be deferred to
# the end. Build early, publish late.
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${SCRIPT_DIR}/28-native-toolchain.sh" repo
