#!/bin/bash
# ============================================================
# 32-openssl.sh — OpenSSL, as a package
#
# This project has said "no OpenSSL" since RFC 0006, and it is worth
# being exact about what that rule was, because the vague version of it
# would block this forever and the precise version does not.
#
# RFC 0006's rule is about the TRUST PATH: checking a package signature
# must not require a TLS stack, so `novi-verify` is ~10 KB of static
# TweetNaCl and nothing else. That is unchanged and unchangeable here.
# RFC 0020's rule is about the BASE IMAGE: no TLS library ships in the
# console base, which is why mbedTLS and curl are packages. Also
# unchanged -- this installs nothing into ${ROOTFS}.
#
# RFC 0021 already had to make this distinction once, when "no TLS in
# the base" was invoked against wolfSSL and turned out to forbid
# something the base had been doing all along (wpa_supplicant's
# CONFIG_TLS=internal was ~200 KB of unaudited crypto). Getting the
# rule right is how work stops being blocked by a slogan.
#
# WHY IT IS HERE AT ALL: CPython's `ssl` module is written against
# OpenSSL specifically. Not "a TLS library" -- OpenSSL, whose API it
# tracks version by version. mbedTLS (RFC 0020) and wolfSSL (RFC 0021)
# are both already in this build and CPython has a backend for neither,
# and LibreSSL has been explicitly unsupported by CPython since 3.10.
# So a Python that can fetch an https:// URL means this package, and a
# Python that cannot is a Python most existing programs will not start
# under. RFC 0027.
#
#   bash build/32-openssl.sh
#
# Two outputs, like 31-mbedtls.sh:
#
#   ${BUILD_DIR}/openssl-target   headers + libraries, for LINKING
#                                 (38-python.sh points at this)
#   ${BUILD_DIR}/stage-devtools/openssl   the package, published by
#                                 43-devtools-repo.sh
#
# Never ${ROOTFS}. A TLS stack in the base image is the thing RFC 0020
# is careful to avoid, and nothing about needing one in Python changes
# that.
#
# The stage number is 32 because Python (38) links it and stages run in
# numeric order. It sits beside 31-mbedtls.sh on purpose: two TLS
# implementations, both packages, neither in the base, for two
# consumers that each accept only one of them.
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-versions.sh"

CROSS="${TOOLS}/bin/${TARGET_TRIPLE}"
[ -x "${CROSS}-gcc" ] || { echo "ERROR: ${CROSS}-gcc not found -- run build/02-toolchain.sh." >&2; exit 1; }

WORK="${BUILD_DIR}/openssl-build"
PREFIX="${BUILD_DIR}/openssl-target"
STAGE_DIR="${BUILD_DIR}/stage-devtools"
SRC="${WORK}/openssl-${OPENSSL_VERSION}"
JOBS="$(nproc)"

rm -rf "${WORK}" "${PREFIX}"
mkdir -p "${WORK}" "${PREFIX}" "${STAGE_DIR}"

echo ">>> Unpacking OpenSSL ${OPENSSL_VERSION} ..."
tar xf "${SOURCES}/openssl-${OPENSSL_VERSION}.tar.gz" -C "${WORK}"

echo ">>> Configuring ..."
(
    cd "${SRC}"
    # OpenSSL has its own Configure, not autoconf, so the cross setup is
    # a target name plus --cross-compile-prefix rather than
    # --host/--build.
    #
    #   --prefix=/usr        where these files will live ON THE TARGET.
    #                        Compiled into the library (it is how
    #                        OPENSSLDIR and the engines/modules paths are
    #                        derived), so it must be the target's path,
    #                        not the staging directory -- the same
    #                        mistake RFC 0015 records pkgconf making with
    #                        --with-system-libdir.
    #   --openssldir=/etc/ssl  where it looks for the CA store at RUN
    #                        time. /etc/ssl/certs is exactly where the
    #                        ca-certificates package puts the bundle,
    #                        which is what makes verification work with
    #                        no environment variable set.
    #   no-tests             the test suite is target binaries this host
    #                        cannot run, and it is ~40% of the build.
    #   no-docs              ~1000 pod pages rendered into man pages
    #                        nothing here can display.
    #   shared               Python's _ssl, curl and the openssl CLI all
    #                        link it; three static copies is not a
    #                        package.
    #
    # -DOPENSSL_NO_BUFFER_OVERFLOW... is deliberately NOT set, and
    # neither is any -O3: the flags are this repo's ordinary hardening
    # set, minus the -pie/-fPIE pair, because most of what is built here
    # is a shared object (the same constraint 38-python.sh hits).
    CFLAGS="-O2 -fstack-protector-strong -D_FORTIFY_SOURCE=2" \
    ./Configure linux-x86_64 \
        --cross-compile-prefix="${TARGET_TRIPLE}-" \
        --prefix=/usr \
        --libdir=lib \
        --openssldir=/etc/ssl \
        shared \
        no-tests \
        no-docs \
        enable-ktls >"${WORK}/configure.log" 2>&1 \
        || { tail -40 "${WORK}/configure.log" >&2; exit 1; }
)

echo ">>> Building (this takes a few minutes) ..."
make -C "${SRC}" -j"${JOBS}" >"${WORK}/build.log" 2>&1 \
    || { tail -60 "${WORK}/build.log" >&2; exit 1; }

echo ">>> Installing into ${PREFIX} (for linking) ..."
# install_sw: libraries, headers and the openssl(1) binary. NOT
# install_ssldirs, which would write /etc/ssl/openssl.cnf and a cert
# directory -- those are the package's business, staged below, and
# writing them here would put them under the link prefix where nothing
# reads them.
make -C "${SRC}" DESTDIR="${PREFIX}" install_sw >"${WORK}/install.log" 2>&1 \
    || { tail -40 "${WORK}/install.log" >&2; exit 1; }

# ── Stage the package ─────────────────────────────────────────────────
D="${STAGE_DIR}/openssl"
rm -rf "${D}"; mkdir -p "${D}/files"

# Runtime only: the libraries, the CLI, the config, and the loadable
# providers. Headers, .pc files and .a archives are build inputs, and
# they stay in ${PREFIX} -- shipping them would be a -dev package this
# system has no compiler in (that is novi-devel, RFC 0015), and 3 MB of
# libcrypto.a nothing can use.
mkdir -p "${D}/files/usr/lib" "${D}/files/usr/bin" "${D}/files/etc/ssl"
cp -a "${PREFIX}/usr/lib/"libcrypto.so* "${D}/files/usr/lib/"
cp -a "${PREFIX}/usr/lib/"libssl.so*    "${D}/files/usr/lib/"
if [ -d "${PREFIX}/usr/lib/ossl-modules" ]; then
    cp -a "${PREFIX}/usr/lib/ossl-modules" "${D}/files/usr/lib/"
fi
cp -a "${PREFIX}/usr/bin/openssl" "${D}/files/usr/bin/openssl"

# openssl.cnf. Without it the library still works, but the CLI warns on
# every invocation and anything reading a config section (an `openssl
# req` with -config, most notably) fails. Taken from the source tree's
# own apps/openssl.cnf, which is what `make install_ssldirs` installs.
install -D -m 644 "${SRC}/apps/openssl.cnf" "${D}/files/etc/ssl/openssl.cnf"

find "${D}/files" -type f \( -name '*.so*' -o -name openssl \) \
    -exec "${CROSS}-strip" --strip-unneeded {} + 2>/dev/null || true

{
    echo "name=openssl"
    echo "version=${OPENSSL_VERSION}"
    echo "arch=${TARGET_ARCH}"
    echo "depends=ca-certificates"
    echo "description=OpenSSL ${OPENSSL_VERSION} (LTS) -- libssl, libcrypto and the openssl CLI. A package: nothing in the base image links it, and package signatures never go near it"
} > "${D}/MANIFEST"

echo ""
echo ">>> Linking prefix : ${PREFIX}/usr"
echo ">>> Staged under   : ${D}  ($(du -sh "${D}/files" | cut -f1))"
"${CROSS}-readelf" -d "${D}/files/usr/bin/openssl" | grep NEEDED || true
echo ""
echo "Publish it with:  bash build/43-devtools-repo.sh"
