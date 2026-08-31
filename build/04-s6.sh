#!/bin/bash
# ============================================================
# 04-s6.sh — Build the full s6 supervision stack
#
# Build order (dependency chain):
#   skalibs → execline → s6 → s6-rc → s6-linux-init
# ============================================================
set -euo pipefail
source "$(dirname "$0")/00-versions.sh"

NPROC=$(nproc)

build_skarnet() {
    local name="$1"
    local version="$2"
    local extra_flags="${3:-}"

    echo "==> Building ${name}-${version}"
    cd "${SOURCES}"
    tar -xf ${name}-${version}.tar.gz
    cd ${name}-${version}

    # skalibs was installed with a plain --prefix=/usr (no
    # --enable-slashpackage), so its sysdeps/include/lib land under
    # ${ROOTFS}/usr/lib/skalibs and ${ROOTFS}/usr/include -- not the
    # slashpackage-style /package/<category>/<name> layout.
    ./configure \
        --target="${TARGET_TRIPLE}" \
        --prefix="/usr" \
        --with-sysdeps="${ROOTFS}/usr/lib/skalibs/sysdeps" \
        --with-include="${ROOTFS}/usr/include" \
        --with-lib="${ROOTFS}/usr/lib/skalibs" \
        ${extra_flags}

    make -j${NPROC}
    make DESTDIR="${ROOTFS}" install

    echo "   done: ${name}"
    cd "${SOURCES}"
    rm -rf ${name}-${version}
}

# ── 1. skalibs (base library for all skarnet software) ────
echo "==> [1/5] skalibs-${SKALIBS_VERSION}"
cd "${SOURCES}"
tar -xf skalibs-${SKALIBS_VERSION}.tar.gz
cd skalibs-${SKALIBS_VERSION}

./configure \
    --target="${TARGET_TRIPLE}" \
    --prefix="/usr" \
    --enable-shared \
    --disable-static \
    --datadir="/usr/lib/skalibs"

make -j${NPROC}
make DESTDIR="${ROOTFS}" install
cd "${SOURCES}"
rm -rf skalibs-${SKALIBS_VERSION}

# ── 2. execline (lightweight scripting for service scripts) ─
build_skarnet "execline" "${EXECLINE_VERSION}"

# ── 3. s6 (supervision suite) ─────────────────────────────
build_skarnet "s6" "${S6_VERSION}" \
    "--with-execline=${ROOTFS}/usr"

# ── 4. s6-rc (service manager / dependency resolver) ──────
build_skarnet "s6-rc" "${S6_RC_VERSION}" \
    "--with-s6=${ROOTFS}/usr"

# ── 5. s6-linux-init (PID 1 integration) ──────────────────
echo "==> [5/5] s6-linux-init-${S6_LINUX_INIT_VERSION}"
cd "${SOURCES}"
tar -xf s6-linux-init-${S6_LINUX_INIT_VERSION}.tar.gz
cd s6-linux-init-${S6_LINUX_INIT_VERSION}

./configure \
    --target="${TARGET_TRIPLE}" \
    --prefix="/usr" \
    --with-s6="${ROOTFS}/usr" \
    --with-s6-rc="${ROOTFS}/usr"

make -j${NPROC}
make DESTDIR="${ROOTFS}" install
cd "${SOURCES}"
rm -rf s6-linux-init-${S6_LINUX_INIT_VERSION}

echo ""
echo "s6 stack installed. Binaries:"
ls "${ROOTFS}/usr/bin/s6-"* 2>/dev/null | head -20
