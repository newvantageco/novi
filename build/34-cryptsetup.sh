#!/bin/bash
# ============================================================
# 34-cryptsetup.sh — LUKS2, and the four libraries it needs
#
# RFC 0018. kernel/config-x86_64 has had CONFIG_DM_CRYPT since it was
# written and the image has never contained anything that could create
# or open a container -- the same shape of gap RFC 0016 found with
# nf_tables. A laptop you can lose is the threat this project has been
# quietest about.
#
# ONE STATIC BINARY. Everything below is built as a static library into
# a private prefix and linked into `cryptsetup.static`, which is what
# gets installed. Two reasons, and the second is the important one:
#
#   1. The initramfs has to unlock the root filesystem, and it is a
#      different root -- shipping a dynamic cryptsetup means shipping
#      the loader and four libraries into the initramfs too, and
#      keeping that list correct forever. One file cannot rot.
#   2. Static libraries never reach ${ROOTFS}, so pkgsplit never sees
#      a .a or a header it has no pattern for, and the base/desktop
#      split does not have to learn about any of this.
#
# harden_flags() is deliberately NOT applied, the same call as busybox
# and novi-verify: static PIE is a different flag with different
# failure modes, and this binary runs in the initramfs before anything
# else does.
#
# WHY EACH DEPENDENCY IS HERE. cryptsetup's configure.ac requires all
# four and offers a switch for none of them:
#
#   popt        AC_CHECK_LIB(popt, ...) -- the CLI's argument parser
#   json-c      PKG_CHECK_MODULES([JSON_C]) -- LUKS2 metadata IS JSON
#   libuuid     AC_CHECK_LIB(uuid, uuid_clear) -- header UUIDs
#   libdevmapper  PKG_CHECK_MODULES([DEVMAPPER]) -- talking to dm-crypt
#
# util-linux and LVM2 are enormous trees fetched for exactly one
# library each. Both know how to build just that library
# (`--disable-all-programs --enable-libuuid`, and `make
# device-mapper`, which LVM2's own configure suggests by name when
# libaio is absent), so neither is built in full.
#
# The crypto backend is `kernel`: AF_ALG, the kernel's own crypto
# through a socket. Every other backend is a library this image has
# refused to carry -- OpenSSL, gcrypt, NSS, nettle -- and the whole
# argument for novi-verify (RFC 0006) was that a base image with no TLS
# stack stays that way. Argon2 comes from cryptsetup's own bundled
# implementation for the same reason.
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/00-versions.sh"

CROSS="${TOOLS}/bin/${TARGET_TRIPLE}"
[ -x "${CROSS}-gcc" ] || { echo "ERROR: ${CROSS}-gcc not found -- run build/02-toolchain.sh." >&2; exit 1; }

BUILD="${BUILD_DIR}/crypt-build"
# The private prefix. NOT ${ROOTFS}: see the header.
DEPS="${BUILD_DIR}/crypt-deps"
mkdir -p "${BUILD}" "${DEPS}"

export PKG_CONFIG_PATH="${DEPS}/lib/pkgconfig:${DEPS}/share/pkgconfig"
export PKG_CONFIG_LIBDIR="${PKG_CONFIG_PATH}"
export PKG_CONFIG_SYSROOT_DIR=""
export CPPFLAGS="-I${DEPS}/include"
export LDFLAGS="-L${DEPS}/lib"

common=(
    --host="${TARGET_TRIPLE}"
    --prefix="${DEPS}"
    --disable-shared
    --enable-static
)

# ── popt ──────────────────────────────────────────────────────────────
echo ">>> Building popt ${POPT_VERSION} ..."
rm -rf "${BUILD}/popt-${POPT_VERSION}"
tar xf "${SOURCES}/popt-${POPT_VERSION}.tar.gz" -C "${BUILD}"
(
    cd "${BUILD}/popt-${POPT_VERSION}"
    ./configure "${common[@]}" --disable-nls >/dev/null
    make -j"$(nproc)" >/dev/null
    make install >/dev/null
)

# ── json-c ────────────────────────────────────────────────────────────
# The only cmake build in this repo. json-c dropped autotools at 0.14,
# so a toolchain file is the price of LUKS2 metadata; the file says the
# same four things build/lib-meson-cross.sh says in meson's dialect.
echo ">>> Building json-c ${JSON_C_VERSION} ..."
rm -rf "${BUILD}/json-c-${JSON_C_VERSION}" "${BUILD}/json-c-obj"
tar xf "${SOURCES}/json-c-${JSON_C_VERSION}.tar.gz" -C "${BUILD}"
cat > "${BUILD}/cross-toolchain.cmake" <<CMAKE
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CMAKE_C_COMPILER ${CROSS}-gcc)
set(CMAKE_AR ${CROSS}-ar)
set(CMAKE_RANLIB ${CROSS}-ranlib)
set(CMAKE_FIND_ROOT_PATH ${SYSROOT};${DEPS})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
CMAKE
(
    cmake -S "${BUILD}/json-c-${JSON_C_VERSION}" -B "${BUILD}/json-c-obj" \
        -DCMAKE_TOOLCHAIN_FILE="${BUILD}/cross-toolchain.cmake" \
        -DCMAKE_INSTALL_PREFIX="${DEPS}" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_STATIC_LIBS=ON \
        -DBUILD_TESTING=OFF \
        -DDISABLE_WERROR=ON >/dev/null
    cmake --build "${BUILD}/json-c-obj" -j"$(nproc)" >/dev/null
    cmake --install "${BUILD}/json-c-obj" >/dev/null
)

# ── libuuid (util-linux) ──────────────────────────────────────────────
# --disable-all-programs then --enable-libuuid: util-linux builds one
# library and not one of its ~100 binaries. Installing any of them
# would put a second `mount`, `dmesg` or `blkid` beside BusyBox's
# applets -- the exact trap 23-e2fsprogs.sh documents about
# mke2fs.e2fsprogs, and mkinitramfs.sh parses BusyBox blkid's exact
# output.
echo ">>> Building libuuid (util-linux ${UTIL_LINUX_VERSION}) ..."
rm -rf "${BUILD}/util-linux-${UTIL_LINUX_VERSION}"
tar xf "${SOURCES}/util-linux-${UTIL_LINUX_VERSION}.tar.xz" -C "${BUILD}"
(
    cd "${BUILD}/util-linux-${UTIL_LINUX_VERSION}"
    ./configure "${common[@]}" \
        --disable-all-programs \
        --enable-libuuid \
        --disable-nls \
        --without-python \
        --without-systemd \
        --without-udev >/dev/null
    make -j"$(nproc)" >/dev/null
    make install >/dev/null
)

# ── libdevmapper (LVM2) ───────────────────────────────────────────────
# `make device-mapper`, not `make`. LVM2's own configure prints
# "Only libdm part can be build without libaio: make [install_]
# device-mapper" when libaio is missing, which names the target for us
# -- so the absence of libaio is not worked around here, it is the
# supported path.
echo ">>> Building libdevmapper (LVM2 ${LVM2_VERSION}) ..."
rm -rf "${BUILD}/LVM2.${LVM2_VERSION}"
tar xf "${SOURCES}/LVM2.${LVM2_VERSION}.tgz" -C "${BUILD}"
(
    cd "${BUILD}/LVM2.${LVM2_VERSION}"
    # --enable-static_link is what makes libdevmapper.a exist at all;
    # without it LVM2 installs only the shared object, cryptsetup's
    # PKG_CHECK_MODULES falls back to a bare -ldevmapper, and the
    # static link dies with `cannot find -ldevmapper` naming a library
    # that is right there. --enable-pkgconfig writes devmapper.pc so
    # the fallback is never reached in the first place.
    ./configure \
        --host="${TARGET_TRIPLE}" \
        --prefix="${DEPS}" \
        --enable-static_link \
        --enable-pkgconfig \
        --disable-selinux \
        --disable-readline \
        --disable-udev_sync \
        --without-udev \
        --without-blkid \
        --disable-blkid_wiping \
        --disable-dmeventd \
        --with-thin=none \
        --with-cache=none \
        --with-vdo=none \
        --with-writecache=none \
        --with-integrity=none >/dev/null
    # `env -u SOURCES`, and this is not superstition. 00-versions.sh
    # exports SOURCES=/build/sources, and LVM2's make.tmpl says
    # `OBJECTS = $(SOURCES:%.c=%.o)` -- a variable name so ordinary that
    # a makefile is entitled to it. The top-level makefile never assigns
    # it, so the environment's value came straight through and the build
    # died with `make: *** /build/sources: Is a directory. Stop.`, which
    # names our own export and no part of LVM2. Any autotools tree with
    # a plain `SOURCES` can hit this.
    env -u SOURCES make device-mapper -j"$(nproc)" >/dev/null
    env -u SOURCES make install_device-mapper >/dev/null
)

# ── cryptsetup ────────────────────────────────────────────────────────
echo ">>> Building cryptsetup ${CRYPTSETUP_VERSION} ..."
rm -rf "${BUILD}/cryptsetup-${CRYPTSETUP_VERSION}"
tar xf "${SOURCES}/cryptsetup-${CRYPTSETUP_VERSION}.tar.xz" -C "${BUILD}"
(
    cd "${BUILD}/cryptsetup-${CRYPTSETUP_VERSION}"
    # Every --disable here removes a dependency or a tool this image
    # has no use for, not a feature of LUKS:
    #   asciidoc            no docbook toolchain on the build host
    #   nls / selinux       no gettext catalogues, no SELinux
    #   udev                there is no udev here (RFC 0012)
    #   blkid               libblkid is a fifth library, and it is used
    #                       only to warn about overwriting a signature;
    #                       novi-install already knows what it is
    #                       formatting
    #   external-tokens     dlopen()ing plugins from a static binary
    #   ssh-token           libssh
    #   veritysetup /       dm-verity and dm-integrity are their own
    #   integritysetup      features with their own design questions
    #   luks2-reencryption  changing the key in place is a large
    #                       feature with a failure mode of "the disk is
    #                       now half one cipher"; not v1
    ./configure "${common[@]}" \
        --with-crypto_backend=kernel \
        --enable-static-cryptsetup \
        --enable-internal-argon2 \
        --disable-asciidoc \
        --disable-nls \
        --disable-selinux \
        --disable-udev \
        --disable-blkid \
        --disable-external-tokens \
        --disable-ssh-token \
        --disable-veritysetup \
        --disable-integritysetup \
        --disable-luks2-reencryption >/dev/null
    make -j"$(nproc)" >/dev/null
)

STATIC_BIN="${BUILD}/cryptsetup-${CRYPTSETUP_VERSION}/cryptsetup.static"
[ -f "${STATIC_BIN}" ] || {
    echo "ERROR: cryptsetup.static was not produced -- --enable-static-cryptsetup" >&2
    echo "       silently built only the dynamic tool. Nothing else here is" >&2
    echo "       usable from the initramfs, so this is fatal, not a warning." >&2
    exit 1
}

# Refuse to install a binary that is not actually static. The whole
# argument above collapses if it turns out to need a loader, and a
# dynamic binary in the initramfs fails at the worst possible moment --
# with the root filesystem locked and no shell to fix it from.
if "${CROSS}-readelf" -l "${STATIC_BIN}" | grep -q 'INTERP'; then
    echo "ERROR: ${STATIC_BIN} has a PT_INTERP -- it is not static." >&2
    exit 1
fi

install -D -m 755 "${STATIC_BIN}" "${ROOTFS}/sbin/cryptsetup"
"${CROSS}-strip" "${ROOTFS}/sbin/cryptsetup"

echo ""
echo "cryptsetup installed:"
ls -la "${ROOTFS}/sbin/cryptsetup"
echo "Build-only static libraries stayed in ${DEPS} (never in the rootfs)."
