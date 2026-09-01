#!/bin/bash
# ============================================================
# 11-pkg.sh — Install pkg (installer) into the rootfs
#
# Unlike every other build/*.sh stage, there's nothing to cross-
# compile here: packages/pkg is a plain POSIX shell script that runs
# directly under BusyBox ash on the target (see its own header
# comment -- shellcheck-verified against the real busybox binary
# build/03-base.sh produces, not just assumed). This stage installs
# it into the rootfs and creates the directory layout packages/pkg-
# format.md documents (`/var/lib/pkg/`, `/var/cache/pkg/`).
#
# packages/mkpkg (the package *builder*) is deliberately NOT installed
# here -- it's a build-host tool (see its own header comment: it uses
# GNU tar's --owner=/--group= long options, which BusyBox's tar applet
# doesn't implement), run from this repo checkout to produce
# .pkg.tar.gz files, not shipped inside the OS it builds.
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/00-versions.sh"

[ -f "${ROOTFS}/bin/busybox" ] || {
    echo "ERROR: ${ROOTFS}/bin/busybox not found -- run build/03-base.sh first." >&2
    exit 1
}

install -D -m 755 "${REPO_ROOT}/packages/pkg" "${ROOTFS}/usr/bin/pkg"

# packages/pkg-format.md's documented layout:
#   /var/lib/pkg/installed/   <- one dir per installed package (MANIFEST, files, scripts)
#   /var/cache/pkg/archives/  <- downloaded/copied-in .pkg.tar.gz files (pkg's PKG_CACHE)
#   /var/cache/pkg/repo/      <- a local package repository (pkg's PKG_REPO default)
mkdir -p \
    "${ROOTFS}/var/lib/pkg/installed" \
    "${ROOTFS}/var/cache/pkg/archives" \
    "${ROOTFS}/var/cache/pkg/repo"

echo ""
echo "pkg installed:"
ls -la "${ROOTFS}/usr/bin/pkg"
