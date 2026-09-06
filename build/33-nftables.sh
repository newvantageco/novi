#!/bin/bash
# ============================================================
# 33-nftables.sh — libmnl, libnftnl, nftables
#
# RFC 0016. kernel/config-x86_64 has had CONFIG_NETFILTER=y and
# CONFIG_NF_TABLES=m for as long as it has existed, and the image has
# never contained one program that could configure them: no nft, no
# iptables, and BusyBox has no applet for either. Novi has been
# shipping a packet filter that cannot be turned on, which is worse
# than not having one -- reading the kernel config suggests otherwise.
#
# Base image, not a package. A console server wants a firewall at
# least as much as a desktop does, and the whole set is under a
# megabyte next to the 699 MB of firmware already here.
#
# Configured to need nothing else:
#   --with-mini-gmp    nftables bundles a small GMP for its
#                      arbitrary-precision integers; without this it
#                      wants system libgmp
#   --without-cli      no readline/linenoise; `nft -f file` and
#                      `nft list` are what novi-state calls, and an
#                      interactive rule editor is not something this
#                      image needs to carry
#   (JSON and the python bindings are off by default in 1.0.9 and
#    have no --disable- switch; passing one only produces a warning)
#   --disable-man-doc  no docbook toolchain on the build host
#
# Writing the netlink messages by hand was considered, in the spirit of
# novi-gpt -- which exists because BusyBox fdisk cannot write a GPT and
# a purpose-built writer emitting exactly one layout beat a general
# tool. The difference is what being subtly wrong costs. A malformed
# GPT fails loudly at boot; a malformed firewall rule fails silently
# and passes traffic you believe is blocked. So: the tested
# implementation, with the "exactly one layout" discipline applied to
# the policy instead -- one table, in one file, in the repo
# (rootfs/etc/novi/firewall.nft).
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/00-versions.sh"

CROSS="${TOOLS}/bin/${TARGET_TRIPLE}"
[ -x "${CROSS}-gcc" ] || { echo "ERROR: ${CROSS}-gcc not found -- run build/02-toolchain.sh." >&2; exit 1; }

BUILD="${BUILD_DIR}/nft-build"
mkdir -p "${BUILD}"

# These land in the rootfs and are linked against from there, the same
# arrangement 25-wifi.sh uses for libnl.
export PKG_CONFIG_PATH="${ROOTFS}/usr/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="${ROOTFS}/usr/lib/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR=""

# -L alone is not enough, and the failure it produces names the wrong
# thing. Linking `nft` pulls in ./.libs/libnftables.so, whose DT_NEEDED
# says libnftnl.so.11; the linker then has to *find that file* to
# resolve the symbols libnftables refers to. The cross-gcc's sysroot is
# ${SYSROOT}, not ${ROOTFS}, so it looked nowhere useful and reported
# five "undefined reference to `nftnl_expr_alloc@LIBNFTNL_11'" -- which
# reads like libnftnl is too old or built without those symbols, and it
# is neither: readelf showed all five exported, with that exact version
# node, in the library that had just been installed. -rpath-link is
# what tells the linker where transitive DT_NEEDED libraries live; the
# same reason build/lib-meson-cross.sh sets it.
export LDFLAGS="-L${ROOTFS}/usr/lib -Wl,-rpath-link,${ROOTFS}/usr/lib"

common_configure=(
    --host="${TARGET_TRIPLE}"
    --prefix=/usr
    --disable-static
)

# After every install, immediately -- not once at the end.
#
# A libtool .la file records the absolute path the library was
# installed to, and DESTDIR installs record /usr/lib, which on the
# build host is the host's own /usr/lib. Leaving libmnl.la in place
# meant libnftnl's link found it, tried to read /usr/lib/libmnl.la,
# and died with "is not a valid libtool archive". Same trap
# 21-imagelibs.sh and 27-audio.sh document; the difference here is
# that three packages link against each other in sequence, so removing
# them at the end of the stage is too late for the middle of it.
drop_la() {
    rm -f "${ROOTFS}"/usr/lib/*.la
}

# ── libmnl ────────────────────────────────────────────────────────────
echo ">>> Building libmnl ${LIBMNL_VERSION} ..."
rm -rf "${BUILD}/libmnl-${LIBMNL_VERSION}"
tar xf "${SOURCES}/libmnl-${LIBMNL_VERSION}.tar.bz2" -C "${BUILD}"
(
    cd "${BUILD}/libmnl-${LIBMNL_VERSION}"
    ./configure "${common_configure[@]}" >/dev/null
    make -j"$(nproc)" >/dev/null
    make DESTDIR="${ROOTFS}" install >/dev/null
)
drop_la

# ── libnftnl ──────────────────────────────────────────────────────────
echo ">>> Building libnftnl ${LIBNFTNL_VERSION} ..."
rm -rf "${BUILD}/libnftnl-${LIBNFTNL_VERSION}"
tar xf "${SOURCES}/libnftnl-${LIBNFTNL_VERSION}.tar.xz" -C "${BUILD}"
(
    cd "${BUILD}/libnftnl-${LIBNFTNL_VERSION}"
    ./configure "${common_configure[@]}" \
        LIBMNL_CFLAGS="-I${ROOTFS}/usr/include" \
        LIBMNL_LIBS="-L${ROOTFS}/usr/lib -lmnl" >/dev/null
    make -j"$(nproc)" >/dev/null
    make DESTDIR="${ROOTFS}" install >/dev/null
)
drop_la

# ── nftables ──────────────────────────────────────────────────────────
echo ">>> Building nftables ${NFTABLES_VERSION} ..."
rm -rf "${BUILD}/nftables-${NFTABLES_VERSION}"
tar xf "${SOURCES}/nftables-${NFTABLES_VERSION}.tar.xz" -C "${BUILD}"
(
    cd "${BUILD}/nftables-${NFTABLES_VERSION}"
    ./configure "${common_configure[@]}" \
        --with-mini-gmp --without-cli --disable-man-doc \
        LIBMNL_CFLAGS="-I${ROOTFS}/usr/include" \
        LIBMNL_LIBS="-L${ROOTFS}/usr/lib -lmnl" \
        LIBNFTNL_CFLAGS="-I${ROOTFS}/usr/include" \
        LIBNFTNL_LIBS="-L${ROOTFS}/usr/lib -lnftnl" >/dev/null
    make -j"$(nproc)" >/dev/null
    make DESTDIR="${ROOTFS}" install >/dev/null
)

drop_la

# The ruleset itself is repo content, installed here beside the tool
# that reads it. Policy belongs in a diff (RFC 0016), the same argument
# as rootfs/etc/{passwd,group,shadow}.
install -D -m 644 "${REPO_ROOT}/rootfs/etc/novi/firewall.nft" \
    "${ROOTFS}/etc/novi/firewall.nft"

# libnftables.so is where nearly all of this lives -- `nft` itself is
# 18 KB of argument parsing in front of a 3.3 MB library -- so leaving
# it out of the strip list would have left the whole point of the
# stage's size argument unmet.
find "${ROOTFS}/usr/lib" -maxdepth 1 -type f \
    \( -name 'libmnl.so.*' -o -name 'libnftnl.so.*' -o -name 'libnftables.so.*' \) \
    -exec "${CROSS}-strip" --strip-unneeded {} + 2>/dev/null || true
"${CROSS}-strip" --strip-unneeded "${ROOTFS}/usr/sbin/nft" 2>/dev/null || true

echo ""
echo "nftables installed:"
ls -la "${ROOTFS}/usr/sbin/nft" "${ROOTFS}"/usr/lib/libmnl.so.*.* \
       "${ROOTFS}"/usr/lib/libnftnl.so.*.* "${ROOTFS}"/usr/lib/libnftables.so.*.* 2>/dev/null
echo "Ruleset: ${ROOTFS}/etc/novi/firewall.nft"
