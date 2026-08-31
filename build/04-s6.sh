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
    # --enable-slashpackage), so its sysdeps/include land under
    # ${ROOTFS}/usr/lib/skalibs/sysdeps and ${ROOTFS}/usr/include -- not
    # the slashpackage-style /package/<category>/<name> layout. Pass
    # both --with-lib (static libskarnet.a, used to link this package's
    # own command binaries -- omitting it makes configure fall back to
    # guessing /usr/lib/<depname> for every declared dependency) and
    # --with-dynlib (shared libskarnet.so, used for this package's own
    # .so build).
    ./configure \
        --target="${TARGET_TRIPLE}" \
        --prefix="/usr" \
        --with-sysdeps="${ROOTFS}/usr/lib/skalibs/sysdeps" \
        --with-include="${ROOTFS}/usr/include" \
        --with-lib="${ROOTFS}/usr/lib/skalibs" \
        --with-dynlib="${ROOTFS}/usr/lib" \
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

# /dev/urandom and posix_spawn()'s return-timing can't be autodetected
# when cross-compiling (skalibs' configure refuses to execute target
# binaries on the build host), so provide them explicitly: modern Linux
# always has /dev/urandom, and musl's posix_spawn() is implemented via
# vfork()-equivalent (CLONE_VM|CLONE_VFORK) semantics, which structurally
# cannot return to the parent before the child has exec'd or exited --
# i.e. it does not return early.
#
# Build both shared and static (skalibs' own configure default is
# shared=true static=true -- previously overridden to shared-only here,
# which broke execline's link step: it needs static libskarnet.a to
# link its own command binaries, only libexecline.so needs the shared
# variant).
./configure \
    --target="${TARGET_TRIPLE}" \
    --prefix="/usr" \
    --with-sysdep-devurandom=yes \
    --with-sysdep-posixspawnearlyreturn=no

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
