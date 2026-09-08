#!/bin/bash
# ============================================================
# 25-wifi.sh — WiFi: libnl, wpa_supplicant, iw (+ hostapd, test-only)
#
# RFC 0009. After RFC 0008 Novi installs on real hardware -- and a
# laptop with no Ethernet port then cannot reach the package
# repository, which is the delivery mechanism for everything past the
# base image. WiFi is what makes the rest of the system reachable on
# the machines people actually own.
#
# wpa_supplicant is built with its INTERNAL crypto
# (wolfSSL since RFC 0021, internal + libtommath before it), so it
# pulls in no OpenSSL. The
# base image deliberately has none -- novi-verify exists precisely so
# that stays true (RFC 0006) -- and adding a TLS stack to get onto a
# network would undo that in one step.
#
# iwd was the alternative and is rejected: its control interface is
# D-Bus, so it would drag a message bus daemon into a base image whose
# entire point is that it does not have one.
#
# hostapd comes out of the same upstream tree and is built here but
# NOT installed into the rootfs. It exists to test against: QEMU has
# no WiFi hardware, so verification runs two mac80211_hwsim radios,
# one running hostapd as an access point and one running
# wpa_supplicant as a station, doing a real WPA2 four-way handshake.
# A test dependency in the shipped image would be a worse bargain than
# an untested feature.
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/00-versions.sh"

CROSS="${TOOLS}/bin/${TARGET_TRIPLE}"
PKGCONF="${CROSS}-pkg-config"
[ -x "${CROSS}-gcc" ] || { echo "ERROR: ${CROSS}-gcc not found -- run build/02-toolchain.sh." >&2; exit 1; }
[ -x "${PKGCONF}" ]   || { echo "ERROR: ${PKGCONF} not found -- run build/06-wayland.sh once." >&2; exit 1; }

# EXPORTED, not passed on the make command line, and that distinction
# is the whole reason this builds:
#
# wpa_supplicant's src/drivers/drivers.mak hardcodes `DRV_LIBS +=
# -lnl-3` and only ever asks pkg-config for --cflags, never --libs. So
# nothing supplies a -L, and the cross-linker searches its own sysroot
# rather than the target rootfs where libnl was just installed:
# "cannot find -lnl-3". Supplying it through LDFLAGS in the ENVIRONMENT
# lets the Makefile's own `LDFLAGS +=` append to it; a command-line
# `make LDFLAGS=...` would override those additions and silently drop
# whatever else upstream wanted on the link line.
export LDFLAGS="-L${ROOTFS}/usr/lib"

WORK="${BUILD_DIR}/wifi-build"
TESTDIR="${BUILD_DIR}/wifi-test"
rm -rf "${WORK}"; mkdir -p "${WORK}" "${TESTDIR}"

# ── libnl ─────────────────────────────────────────────────────────────────
# Built by 06-wayland.sh now, not here. novi-panel (stage 10) links it
# for the network indicator's nl80211 query, and a library built in a
# LATER stage than one of its consumers is invisible in a warm tree and
# fatal in a clean one -- the novi-launcher/fcft trap, exactly (RFC
# 0005). A library with more than one consumer belongs in the library
# stage.
[ -f "${ROOTFS}/usr/lib/pkgconfig/libnl-genl-3.0.pc" ] || {
    echo "ERROR: libnl not found in ${ROOTFS} -- run build/06-wayland.sh first." >&2
    exit 1
}

# ── wolfSSL: the crypto backend that has EC ───────────────────────────────
#
# RFC 0021. This replaces CONFIG_TLS=internal, and the distinction that
# makes it acceptable is worth being precise about: THE BASE IMAGE
# ALREADY LINKED A TLS IMPLEMENTATION. `CONFIG_TLS=internal` is not
# "no crypto" -- it is ~200 KB of AES, SHA, RSA, bignum and a TLS
# handshake written by the wpa_supplicant authors, compiled straight
# into the binary. RFC 0009's rule was "no OpenSSL", and RFC 0006's
# was "checking a package signature must not need a TLS stack"
# (novi-verify, still static, still separate). Neither said the
# supplicant may not have crypto; it always had some.
#
# So this swaps one crypto implementation for a bigger, far more
# reviewed one, and gets WPA3 for it -- SAE and OWE need
# elliptic-curve operations that internal TLS simply does not
# implement.
#
# WHY WOLFSSL AND NOT MBEDTLS: RFC 0020 went looking and found that
# wpa_supplicant 2.11 has no mbedTLS backend at all -- its Makefile
# offers openssl, gnutls, wolfssl, internal, linux and none, and
# `grep -rli mbedtls` over the tarball returns nothing. RFC 0009 named
# mbedTLS as the way in and was wrong. wolfSSL is dual GPL-2.0 /
# commercial, and the GPL half is clean under this project's own
# GPLv2.
#
# BUILT HERE, IN THE WIFI STAGE, and that is deliberate rather than
# lazy. The rule this repo learned from novi-launcher linking fcft is
# about a library built in a LATER stage than its consumer -- a
# backwards dependency invisible except in a clean tree. wolfSSL's
# only consumers are wpa_supplicant and hostapd, both built right
# here, so there is no ordering hazard at all. The day something else
# links it, it moves to a stage of its own; until then a stage number
# below 25 does not exist to give it.
echo ">>> Building wolfSSL ${WOLFSSL_VERSION} (wpa_supplicant backend) ..."
rm -rf "${WORK}/wolfssl-${WOLFSSL_VERSION}" "${WORK}/wolfssl-obj"
tar -xf "${SOURCES}/wolfssl-${WOLFSSL_VERSION}.tar.gz" -C "${WORK}"

# AUTOTOOLS, not cmake, and the difference is not cosmetic.
#
# cmake has a WOLFSSL_WPAS option and it is NOT the same set as
# autotools' --enable-wpas. Built with the cmake flag, wpa_supplicant's
# tls_wolfssl.c failed on fourteen errors -- `SSL_OP_NO_TLSv1`
# undeclared, implicit declarations of wolfSSL_get_client_random,
# wolfSSL_export_keying_material, wolfSSL_get_peer_finished -- because
# --enable-wpas also turns on OPENSSL_EXTRA and about twenty other
# defines (HAVE_SECRET_CALLBACK, HAVE_KEYING_MATERIAL, KEEP_PEER_CERT,
# WOLFSSL_DER_LOAD ...) that the cmake option does not. Reconstructing
# that list by hand is exactly the mistake this comment used to warn
# about, so: use the switch upstream maintains.
#
# The price is autoconf/automake/libtoolize on the build host, because
# this tarball comes from `git archive` (GitHub's /archive/ endpoint is
# unreachable here) and has no generated `configure`. CONTRIBUTING.md
# lists them.
(
    cd "${WORK}/wolfssl-${WOLFSSL_VERSION}"
    ./autogen.sh >/dev/null 2>&1

    # --enable-wpas is the whole point. --disable-examples and
    # --disable-crypttests drop programs built for the TARGET that
    # could not run here anyway and that nothing asked for -- in an
    # image whose base/desktop split is computed from what is present,
    # dead weight is not inert (RFC 0007).
    #
    # CFLAGS carries -Wno-error=stringop-overflow, and only that one.
    # GCC 14 flags Hmac_UpdateFinal_CT's constant-time trick: it writes
    # into `hmac->innerHash` as a flat byte array past the union member
    # GCC sized it from ("writing 16 bytes into a region of size 0 ...
    # at offset 816 into destination object 'hmac' of size 784"). That
    # is deliberate in a routine whose point is to touch the same
    # memory regardless of digest length. Disabling the one diagnostic
    # rather than -Werror wholesale keeps every other warning fatal.
    ./configure \
        --build="$(gcc -dumpmachine)" \
        --host="${TARGET_TRIPLE}" \
        --prefix=/usr \
        --enable-wpas \
        --enable-shared \
        --disable-static \
        --disable-examples \
        --disable-crypttests \
        CFLAGS="-O2 -Wno-error=stringop-overflow" >/dev/null
    make -j"$(nproc)" >/dev/null
    make install DESTDIR="${ROOTFS}" >/dev/null
)
rm -f "${ROOTFS}"/usr/lib/libwolfssl.la
find "${ROOTFS}/usr/lib" -maxdepth 1 -type f -name 'libwolfssl.so.*' \
    -exec "${CROSS}-strip" --strip-unneeded {} + 2>/dev/null || true

# ── wpa_supplicant configuration ──────────────────────────────────────────
#
# Written out here rather than shipped as a file, because it is the
# argument for the whole shape of this stage and belongs next to it.
write_wpa_config() {
    cat > "$1" <<'WPACONF'
# Novi: wpa_supplicant build configuration (RFC 0009)

# nl80211 is the only driver worth having: wext is deprecated and
# cannot do WPA2 on a modern mac80211 stack.
CONFIG_DRIVER_NL80211=y
CONFIG_LIBNL32=y

# wolfSSL, not OpenSSL and not the internal implementation (RFC 0021).
# The stage header has the whole argument; the short version is that
# CONFIG_TLS=internal was already a TLS stack -- just one without
# elliptic curves, which is what WPA3 needs.
CONFIG_TLS=wolfssl

# WPA3. SAE is WPA3-Personal; OWE is opportunistic encryption on open
# networks. Both need the crypto_ec_* operations dragonfly.c calls,
# which is precisely what CONFIG_TLS=internal did not have -- it linked
# cleanly right up to "undefined reference to crypto_ec_get_prime".
#
# CONFIG_SAE_PK is SAE Public Key: it binds an SSID to a key so a
# rogue AP with the same name and the same password cannot impersonate
# the real one. It costs nothing once SAE is on.
CONFIG_SAE=y
CONFIG_SAE_PK=y
CONFIG_OWE=y

# Management frame protection. Not optional with SAE -- WPA3 requires
# it -- and this is also the option that makes a WPA2 association
# negotiate PMF when the AP offers it. Off, a WPA3 AP simply refuses
# to associate.
CONFIG_IEEE80211W=y

# Enterprise EAP methods: eduroam, corporate networks. These are what
# make this usable somewhere other than a house.
CONFIG_IEEE8021X_EAPOL=y
CONFIG_EAP_MD5=y
CONFIG_EAP_TLS=y
CONFIG_EAP_PEAP=y
CONFIG_EAP_TTLS=y
CONFIG_EAP_MSCHAPV2=y
CONFIG_EAP_GTC=y
CONFIG_EAP_OTP=y
CONFIG_PKCS12=y

# The control socket wpa_cli talks to, and the config backend
# novi-state writes.
CONFIG_CTRL_IFACE=y
CONFIG_BACKEND=file
CONFIG_DEBUG_FILE=y

# Logging to syslog. Not cosmetic: the wifi service's run script passes
# -s, and without this option compiled in wpa_supplicant does not
# recognise it -- it prints its usage message and exits, s6 restarts
# it, and `s6-rc -a list` still says the service is up because for a
# longrun that means "wanted up", not "running". Confirmed live
# exactly that way: the service reported up, diff reported clean, and
# nothing had ever associated.
CONFIG_DEBUG_SYSLOG=y

# Deliberately off: WPS is a protocol with a well-known offline PIN
# attack, and nothing here has a use for smartcards.
WPACONF

    # Appended UNQUOTED, because these two need ${ROOTFS} expanded.
    #
    # wpa_supplicant's Makefile adds `LIBS += -lwolfssl` for
    # CONFIG_TLS=wolfssl and nothing else: no pkg-config lookup, no
    # search path. Cross-compiling, that finds neither the header nor
    # the library and stops at `wolfssl/options.h: No such file or
    # directory`. .config IS a makefile fragment included before those
    # rules, so `+=` here is the supported way to widen the search --
    # passing CFLAGS= on the make command line would REPLACE everything
    # the config just computed.
    cat >> "$1" <<EOF
CFLAGS += -I${ROOTFS}/usr/include
LIBS += -L${ROOTFS}/usr/lib
LIBS_p += -L${ROOTFS}/usr/lib
EOF
}

# ── wpa_supplicant ────────────────────────────────────────────────────────
echo ">>> Building wpa_supplicant ${WPA_SUPPLICANT_VERSION} ..."
tar -xf "${SOURCES}/wpa_supplicant-${WPA_SUPPLICANT_VERSION}.tar.gz" -C "${WORK}"
(
    cd "${WORK}/wpa_supplicant-${WPA_SUPPLICANT_VERSION}/wpa_supplicant"
    write_wpa_config .config
    make -j"$(nproc)" \
        CC="${CROSS}-gcc" \
        LD="${CROSS}-gcc" \
        AR="${CROSS}-ar" \
        PKG_CONFIG="${PKGCONF}" \
        wpa_supplicant wpa_cli wpa_passphrase >/dev/null
    for b in wpa_supplicant wpa_cli wpa_passphrase; do
        install -D -m 755 "${b}" "${ROOTFS}/sbin/${b}"
        "${CROSS}-strip" "${ROOTFS}/sbin/${b}"
    done
)

# ── hostapd: test-only, never installed ───────────────────────────────────
echo ">>> Building hostapd ${WPA_SUPPLICANT_VERSION} (test harness only) ..."
tar -xf "${SOURCES}/hostapd-${WPA_SUPPLICANT_VERSION}.tar.gz" -C "${WORK}"
(
    cd "${WORK}/hostapd-${WPA_SUPPLICANT_VERSION}/hostapd"
    # CONFIG_TLS=wolfssl here too, and CONFIG_SAE so this can be a
    # WPA3 access point -- the test peer has to speak what the client
    # is being tested for. hostapd's default crypto backend is
    # OpenSSL and it does not ask -- it just compiles
    # src/crypto/crypto_openssl.c and fails on <openssl/opensslv.h>.
    # This binary never ships, but a test harness that needs a library
    # the product refuses to have is a test harness that will rot.
    cat > .config <<'HAPCONF'
CONFIG_DRIVER_NL80211=y
CONFIG_LIBNL32=y
CONFIG_IEEE80211N=y
CONFIG_TLS=wolfssl
CONFIG_SAE=y
CONFIG_IEEE80211W=y
HAPCONF
    cat >> .config <<EOF
CFLAGS += -I${ROOTFS}/usr/include
LIBS += -L${ROOTFS}/usr/lib
EOF
    make -j"$(nproc)" \
        CC="${CROSS}-gcc" \
        LD="${CROSS}-gcc" \
        AR="${CROSS}-ar" \
        PKG_CONFIG="${PKGCONF}" \
        hostapd >/dev/null
    install -D -m 755 hostapd "${TESTDIR}/hostapd"
    "${CROSS}-strip" "${TESTDIR}/hostapd"
)

# ── iw ────────────────────────────────────────────────────────────────────
# Diagnostics. When WiFi does not work, the first question is always
# "does the kernel see a radio, and what does it think it can do", and
# nothing else on this system can answer it.
echo ">>> Building iw ${IW_VERSION} ..."
tar -xf "${SOURCES}/iw-${IW_VERSION}.tar.xz" -C "${WORK}"
(
    cd "${WORK}/iw-${IW_VERSION}"
    make -j"$(nproc)" \
        CC="${CROSS}-gcc" \
        LD="${CROSS}-gcc" \
        AR="${CROSS}-ar" \
        PKG_CONFIG="${PKGCONF}" \
        V=1 iw >/dev/null 2>&1 || make CC="${CROSS}-gcc" PKG_CONFIG="${PKGCONF}" iw
    install -D -m 755 iw "${ROOTFS}/sbin/iw"
    "${CROSS}-strip" "${ROOTFS}/sbin/iw"
)

# ── novi-wifi ─────────────────────────────────────────────────────────────
# The credential store's front end. A shell script, like pkg,
# novi-state and novi-install -- nothing to cross-compile.
install -D -m 755 "${REPO_ROOT}/packages/novi-wifi" "${ROOTFS}/usr/bin/novi-wifi"

echo ""
echo "WiFi userland installed:"
ls -la "${ROOTFS}/sbin/wpa_supplicant" "${ROOTFS}/sbin/wpa_cli" \
       "${ROOTFS}/sbin/wpa_passphrase" "${ROOTFS}/sbin/iw" \
       "${ROOTFS}/usr/bin/novi-wifi"
echo ""
echo "Test-only (NOT in the image): ${TESTDIR}/hostapd"
