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
# (CONFIG_TLS=internal + libtommath), so it pulls in no OpenSSL. The
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
# wpa_supplicant's nl80211 driver talks to the kernel through netlink,
# and libnl is what it uses to do that. --disable-cli drops nl-* tools
# nothing here runs.
echo ">>> Building libnl ${LIBNL_VERSION} ..."
tar -xf "${SOURCES}/libnl-${LIBNL_VERSION}.tar.gz" -C "${WORK}"
(
    cd "${WORK}/libnl-${LIBNL_VERSION}"
    ./configure --host="${TARGET_TRIPLE}" --prefix=/usr \
        --disable-static --disable-cli >/dev/null
    make -j"$(nproc)" >/dev/null
    make install DESTDIR="${ROOTFS}" >/dev/null
)
# libtool leaves .la files that point at build-tree paths; nothing on
# the target reads them and they are a classic source of confusing
# link failures later.
rm -f "${ROOTFS}"/usr/lib/libnl*.la

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

# Internal crypto, so this links no OpenSSL. The base image has none
# and should keep having none.
CONFIG_TLS=internal
CONFIG_INTERNAL_LIBTOMMATH=y
CONFIG_INTERNAL_LIBTOMMATH_FAST=y

# NO WPA3 (SAE/OWE), and this is a real limitation, not an oversight.
#
# SAE and OWE need elliptic-curve crypto -- crypto_ec_*, and the
# bignum operations dragonfly.c calls -- and CONFIG_TLS=internal does
# not implement EC. Turning them on links cleanly right up to
# "undefined reference to crypto_ec_get_prime", which is where this
# was found.
#
# The three ways out are: link OpenSSL (undoes the reason this whole
# stage exists), link mbedTLS (small, self-contained, has EC,
# supported by wpa_supplicant 2.11 -- the real answer, and its own
# piece of work), or ship WPA2 only. WPA2-Personal and WPA2-Enterprise
# cover essentially every network in service, and WPA3 routers run
# transition mode, so this connects to them too. It will not connect
# to a WPA3-ONLY network. RFC 0009 says so out loud rather than
# leaving someone to discover it in a cafe.

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
    # CONFIG_TLS=internal here too. hostapd's default crypto backend is
    # OpenSSL and it does not ask -- it just compiles
    # src/crypto/crypto_openssl.c and fails on <openssl/opensslv.h>.
    # This binary never ships, but a test harness that needs a library
    # the product refuses to have is a test harness that will rot.
    cat > .config <<'HAPCONF'
CONFIG_DRIVER_NL80211=y
CONFIG_LIBNL32=y
CONFIG_IEEE80211N=y
CONFIG_TLS=internal
CONFIG_INTERNAL_LIBTOMMATH=y
HAPCONF
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
