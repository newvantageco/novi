#!/bin/bash
# ============================================================
# 31-mbedtls.sh — mbedTLS, for the things that need to verify a server
#
# RFC 0020. Three RFCs stopped at the same wall: RFC 0009 could not do
# WPA3, RFC 0019 could not do `git clone https://`, RFC 0006 fetches
# over plain HTTP. Each named a missing TLS library and each declined
# to add one as a side effect of something else. This is that decision
# made on its own.
#
# A PACKAGE, NOT THE BASE IMAGE. That is the whole reason this is
# allowed: RFC 0006's argument -- a 10 KB static Ed25519 verifier
# rather than OpenSSL, so that checking a package signature does not
# put a TLS stack in a console-only image -- is about the BASE. A
# machine that never installs this has exactly the surface it had
# before.
#
# Dual Apache-2.0 / GPL-2.0-or-later, so it is clean under this
# project's own GPLv2.
#
# Built here rather than inside 35-devtools.sh because a library more
# than one client links belongs in a stage of its own -- the lesson
# from novi-launcher linking fcft out of a later stage (CLAUDE.md).
# 31 < 35 is what makes curl able to link it.
#
# Two destinations, deliberately:
#   ${BUILD_DIR}/tls-deps   headers and libraries, for curl to LINK
#                           against at build time. Never ${ROOTFS}:
#                           that would put a TLS stack in the base.
#   the `mbedtls` package   the shared libraries, for the target to
#                           LOAD at run time from /usr/lib.
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/00-versions.sh"

CROSS="${TOOLS}/bin/${TARGET_TRIPLE}"
[ -x "${CROSS}-gcc" ] || { echo "ERROR: ${CROSS}-gcc not found -- run build/02-toolchain.sh." >&2; exit 1; }

WORK="${BUILD_DIR}/mbedtls-build"
DEPS="${BUILD_DIR}/tls-deps"
STAGE_DIR="${BUILD_DIR}/stage-devtools"
rm -rf "${WORK}" "${DEPS}"
mkdir -p "${WORK}" "${DEPS}" "${STAGE_DIR}"

echo ">>> Building mbedTLS ${MBEDTLS_VERSION} ..."
tar xf "${SOURCES}/mbedtls-${MBEDTLS_VERSION}.tar.bz2" -C "${WORK}"
SRC="${WORK}/mbedtls-${MBEDTLS_VERSION}"

# cmake, like json-c in 34-cryptsetup.sh, and the same toolchain file
# says the same four things meson and cmake each spell differently.
cat > "${WORK}/cross-toolchain.cmake" <<CMAKE
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CMAKE_C_COMPILER ${CROSS}-gcc)
set(CMAKE_AR ${CROSS}-ar)
set(CMAKE_RANLIB ${CROSS}-ranlib)
set(CMAKE_FIND_ROOT_PATH ${SYSROOT})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
CMAKE

# ENABLE_TESTING=Off and ENABLE_PROGRAMS=Off: the tests and the ~40
# sample programs are built for the TARGET and could not be run here
# anyway, and the programs would be 40 binaries nobody asked for --
# which, in an image whose base/desktop split is computed from what is
# present, is not inert (RFC 0007).
cmake -S "${SRC}" -B "${WORK}/obj" \
    -DCMAKE_TOOLCHAIN_FILE="${WORK}/cross-toolchain.cmake" \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_BUILD_TYPE=Release \
    -DUSE_SHARED_MBEDTLS_LIBRARY=On \
    -DUSE_STATIC_MBEDTLS_LIBRARY=Off \
    -DENABLE_TESTING=Off \
    -DENABLE_PROGRAMS=Off >/dev/null
cmake --build "${WORK}/obj" -j"$(nproc)" >/dev/null
DESTDIR="${DEPS}" cmake --install "${WORK}/obj" >/dev/null

# mbedTLS installs to ${DESTDIR}/usr; flatten so ${DEPS}/{include,lib}
# is what a -I/-L pair points at, the same shape crypt-deps has.
if [ -d "${DEPS}/usr" ]; then
    cp -a "${DEPS}/usr/." "${DEPS}/"
    rm -rf "${DEPS}/usr"
fi

# ── Stage the runtime half as a package ───────────────────────────────
# stage_pkg's twin lives in 28-native-toolchain.sh and 35-devtools.sh;
# this shares STAGE_DIR with the latter so 43-devtools-repo.sh
# publishes all of it in one pass.
d="${STAGE_DIR}/mbedtls"
rm -rf "$d"; mkdir -p "$d/files/usr/lib"
{
    echo "name=mbedtls"
    echo "version=${MBEDTLS_VERSION}"
    echo "arch=${TARGET_ARCH}"
    echo "depends="
    echo "description=mbedTLS: TLS and X.509 for the things that verify a server"
} > "$d/MANIFEST"

# The .so and its soname link, not the development symlink: a package
# ships what the loader opens. A library's names must move or stay as a
# unit (RFC 0007), and here the unit that ships is the two runtime
# names.
for lib in libmbedtls libmbedx509 libmbedcrypto; do
    cp -a "${DEPS}/lib/${lib}.so"* "$d/files/usr/lib/"
done
rm -f "$d"/files/usr/lib/*.a
find "$d/files" -type f -name '*.so*' -exec "${CROSS}-strip" --strip-unneeded {} + 2>/dev/null || true

echo ""
echo "mbedTLS built:"
ls -la "${DEPS}/lib/" | grep -E '\.so' | head
echo "Link inputs: ${DEPS}/{include,lib}  (never ${ROOTFS} -- see the header)"
echo "Staged package: $d ($(du -sh "$d/files" | cut -f1))"
