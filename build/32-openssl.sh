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
#                                 (43-python.sh points at this)
#   ${BUILD_DIR}/stage-devtools/openssl   the package, published by
#                                 53-devtools-repo.sh
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

# ── What is turned OFF, and why each one (RFC 0027 roadmap 4) ─────────
#
# The build was near-stock -- no-tests, no-docs, enable-ktls and
# nothing else -- so the legacy provider, every algorithm OpenSSL has
# ever shipped and the deprecated API surface all rode along in 8.0 MB.
# That is on EVERY machine that installs this, which since RFC 0031 is
# every machine with a browser and since RFC 0026 every machine with
# Python.
#
# The rule for this list is the one RFC 0007 states about dead weight:
# it is not inert. Each entry is something nothing in this system uses,
# and the ones that could plausibly be used are NOT here -- see the
# bottom of this comment for what was considered and kept.
#
#   no-legacy       The legacy PROVIDER (MD4, RC4, DES-in-CBC, RC2,
#                   Blowfish, CAST, IDEA, SEED, Whirlpool...). It is
#                   not loaded unless openssl.cnf activates it, and
#                   this one does not -- so it shipped as 171 KB that
#                   could not be reached without editing a config file
#                   nobody edits.
#   no-md2/mdc2/rc5 Algorithms OpenSSL itself disables by default in
#   no-idea/seed    some builds, or which no TLS suite and nothing in
#   no-whirlpool    this image uses.
#   no-rc2/rc4/bf/cast
#   no-camellia     A real cipher nothing negotiates here: TLS 1.2/1.3
#                   suites in use are AES-GCM and ChaCha20-Poly1305.
#   no-ssl3         SSLv3 is broken (POODLE) and its methods are a
#   no-ssl3-method  liability rather than a compatibility story.
#   no-weak-ssl-ciphers
#                   EXPORT and low-strength suites.
#   no-comp         TLS compression is CRIME.
#   no-dtls         Datagram TLS. Nothing here speaks it: curl is built
#                   against mbedTLS, and Python 3.11's ssl exposes no
#                   DTLS protocol constant at all.
#   no-srp/psk      Password-authenticated suites nothing here offers.
#   no-engine       The pre-3.0 plugin mechanism, superseded by
#                   providers and deprecated upstream. CPython guards
#                   every ENGINE call with #ifndef OPENSSL_NO_ENGINE.
#   no-quic         Server and client QUIC. Nothing here speaks it --
#                   and HTTP/3 would be curl's business, on the other
#                   TLS stack.
#
# CONSIDERED AND KEPT, because guessing wrong here is a runtime
# failure on somebody else's machine:
#
#   no-deprecated   Would compile the deprecated API surface out of the
#                   library. CPython's _ssl and _hashlib still use
#                   parts of it, and the failure is a build error here
#                   or a missing module there. Worth trying on its own,
#                   not folded into a size trim.
#   no-des          3DES is gone from TLS but DES still appears in
#                   PKCS#12 and older key encryption, which `openssl`
#                   the CLI is exactly the tool somebody reaches for.
#   no-sm2/3/4      Small, and the one set where "nobody here uses it"
#                   is a statement about who is holding the machine.
#   no-ec/dh/dsa    Load-bearing for TLS itself.
#
# The saving is MEASURED at the end of this stage rather than claimed:
# a trim that removes nothing is a trim that should be deleted.
OPENSSL_TRIM="no-legacy no-md2 no-mdc2 no-rc5 no-idea no-seed
    no-whirlpool no-rc2 no-rc4 no-bf no-cast no-camellia
    no-ssl3 no-ssl3-method no-weak-ssl-ciphers no-comp
    no-dtls no-srp no-psk no-engine no-quic"

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
    # is a shared object (the same constraint 43-python.sh hits).
    CFLAGS="-O2 -fstack-protector-strong -D_FORTIFY_SOURCE=2" \
    ./Configure linux-x86_64 \
        --cross-compile-prefix="${TARGET_TRIPLE}-" \
        --prefix=/usr \
        --libdir=lib \
        --openssldir=/etc/ssl \
        shared \
        no-tests \
        no-docs \
        ${OPENSSL_TRIM} \
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
# ossl-modules holds the loadable providers. With no-legacy there are
# none, and `make install` still creates the directory -- so the test
# is whether it has anything IN it, not whether it exists. An empty
# directory in a package is dead weight of the purest kind: it is a
# statement that something loadable lives there.
if [ -n "$(ls -A "${PREFIX}/usr/lib/ossl-modules" 2>/dev/null)" ]; then
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
echo "Publish it with:  bash build/53-devtools-repo.sh"
