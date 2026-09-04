#!/bin/bash
# ============================================================
# 18-network.sh — Install the DHCP client hook and resolver plumbing
#
# BusyBox already provides udhcpc; what it does NOT provide is the
# script udhcpc hands the lease to. Without one, the client negotiates
# a perfectly good lease and then applies none of it -- no address, no
# route, no resolver -- which is the kind of failure that looks like a
# network problem for an hour.
#
# /etc/resolv.conf is a symlink into /run rather than a real file:
#
#   * A DHCP lease is runtime state. /etc/novi/system.conf is where
#     Novi keeps configuration, and rewriting a file under /etc on
#     every lease renewal blurs a line this project draws deliberately.
#   * It also keeps a squashfs live boot honest -- /etc there is a
#     read-only lower layer with a tmpfs overlay, and pointing at /run
#     means the resolver lands in the same place either way.
#
# The kernel side is already in place: CONFIG_PACKET=y (udhcpc needs a
# raw socket), CONFIG_INET=y, e1000e/r8169 built in, virtio_net as a
# module that init/services/network/run modprobes.
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/00-versions.sh"

BUSYBOX="${ROOTFS}/bin/busybox"
[ -f "${BUSYBOX}" ] || {
    echo "ERROR: ${BUSYBOX} not found -- run build/03-base.sh first." >&2
    exit 1
}

echo ">>> Checking the BusyBox applets networking depends on ..."
APPLET_LIST="$("${BUSYBOX}" --list 2>/dev/null || true)"
MISSING=()
for applet in udhcpc ip ifconfig ping nslookup wget; do
    grep -qx "${applet}" <<<"${APPLET_LIST}" || MISSING+=("${applet}")
done
if (( ${#MISSING[@]} > 0 )); then
    echo "ERROR: BusyBox is missing applets networking needs: ${MISSING[*]}" >&2
    exit 1
fi
echo "    all present"

install -D -m 755 "${REPO_ROOT}/rootfs/usr/share/udhcpc/default.script" \
    "${ROOTFS}/usr/share/udhcpc/default.script"

# /etc/resolv.conf -> /run/novi/resolv.conf
mkdir -p "${ROOTFS}/run/novi"
ln -sfn /run/novi/resolv.conf "${ROOTFS}/etc/resolv.conf"

# /etc/hosts: loopback must resolve before any network exists at all.
install -D -m 644 /dev/stdin "${ROOTFS}/etc/hosts" <<'HOSTS'
# /etc/hosts — Novi Linux
127.0.0.1   localhost
::1         localhost ip6-localhost ip6-loopback
HOSTS

# musl reads /etc/nsswitch.conf not at all and /etc/services rarely, but
# a resolver with no /etc/resolv.conf present falls back to 127.0.0.1,
# which on a machine with no local resolver just times out. The symlink
# above dangles until the first lease; that is intended (a dangling
# symlink and a missing file behave identically to the resolver), and
# it is why the network service writes its file before announcing.

echo ""
echo "networking installed:"
ls -la "${ROOTFS}/usr/share/udhcpc/default.script" "${ROOTFS}/etc/resolv.conf" \
       "${ROOTFS}/etc/hosts"
