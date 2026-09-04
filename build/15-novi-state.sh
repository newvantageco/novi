#!/bin/bash
# ============================================================
# 15-novi-state.sh — Install novi-state, the declarative state engine
#
# RFC 0002. Like build/11-pkg.sh there's nothing to cross-compile:
# packages/novi-state is a plain POSIX shell script that runs under
# BusyBox ash on the target. This stage installs it plus the two
# directories it owns:
#
#   /etc/novi/system.conf                  the declared system state
#   /var/lib/novi-state/generations/       one immutable snapshot per apply
#
# The shipped system.conf is not a placeholder -- it declares exactly
# the state a stock Novi boot actually produces (the `default` bundle:
# syslog + both gettys up, the graphical session off), so a freshly
# booted machine reports "system matches declared state" rather than
# spurious drift on first run. That property is worth protecting: a
# state engine whose very first `diff` is wrong teaches users to
# ignore it.
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/00-versions.sh"

[ -f "${ROOTFS}/bin/busybox" ] || {
    echo "ERROR: ${ROOTFS}/bin/busybox not found -- run build/03-base.sh first." >&2
    exit 1
}

install -D -m 755 "${REPO_ROOT}/packages/novi-state" "${ROOTFS}/usr/bin/novi-state"
install -D -m 644 "${REPO_ROOT}/rootfs/etc/novi/system.conf" \
    "${ROOTFS}/etc/novi/system.conf"
mkdir -p "${ROOTFS}/var/lib/novi-state/generations"

echo ""
echo "novi-state installed:"
ls -la "${ROOTFS}/usr/bin/novi-state" "${ROOTFS}/etc/novi/system.conf"
