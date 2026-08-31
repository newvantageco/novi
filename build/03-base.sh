#!/bin/bash
# ============================================================
# 03-base.sh — Build base userland (BusyBox) into rootfs
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/00-versions.sh"

NPROC=$(nproc)
STRIP="${TOOLS}/bin/${TARGET_TRIPLE}-strip"

# ── BusyBox ──────────────────────────────────────────────
echo "==> BusyBox ${BUSYBOX_VERSION}"
cd "${SOURCES}"
tar -xf busybox-${BUSYBOX_VERSION}.tar.bz2
cd busybox-${BUSYBOX_VERSION}

# Use our minimal config (no telnet, no ftpd, no legacy cruft) if the
# repo ships one; otherwise fall back to defconfig (not curated -- see
# docs/PLATFORM-ROADMAP.md tracked follow-up to commit a trimmed config).
if [ -f "${REPO_ROOT}/config/busybox.config" ]; then
    cp "${REPO_ROOT}/config/busybox.config" .config
    make CROSS_COMPILE="${TARGET_TRIPLE}-" oldconfig </dev/null
else
    echo "   No config/busybox.config in repo yet, using defconfig"
    make defconfig
fi

# Force static linking for the base install
sed -i 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
sed -i 's/CONFIG_STATIC=n/CONFIG_STATIC=y/' .config

# Disable the tc applet: its CBQ support (networking/tc.c) references
# kernel pkt_sched.h structures (struct tc_cbq_lssopt, TCF_CBQ_LSS_*,
# TC_CBQ_MAXPRIO) that no longer exist -- CBQ was removed from Linux's
# UAPI headers years ago and BusyBox 1.36.1 hasn't caught up. tc is an
# advanced traffic-shaping CLI, not required to boot; not gated behind
# its own config knob, so disable the whole applet rather than patch
# BusyBox's source or reintroduce dead kernel-header definitions.
sed -i 's/^CONFIG_TC=y/# CONFIG_TC is not set/' .config
sed -i 's/^CONFIG_FEATURE_TC_INGRESS=y/# CONFIG_FEATURE_TC_INGRESS is not set/' .config
make CROSS_COMPILE="${TARGET_TRIPLE}-" oldconfig </dev/null

make CROSS_COMPILE="${TARGET_TRIPLE}-" -j${NPROC}
make CROSS_COMPILE="${TARGET_TRIPLE}-" CONFIG_PREFIX="${ROOTFS}" install

cd "${SOURCES}"

# ── Base rootfs directory layout ─────────────────────────
echo "==> Creating rootfs hierarchy"
mkdir -p "${ROOTFS}"/{boot,dev,etc,home,lib,mnt,opt,proc,root,run,srv,sys,tmp,usr/{bin,lib,share},var/{log,run,tmp}}
chmod 1777 "${ROOTFS}/tmp"
chmod 700  "${ROOTFS}/root"

# ── Minimal user/group database ──────────────────────────
# Nothing ever created /etc/passwd or /etc/group -- confirmed via a
# live boot where s6-envuidgid (used by s6-rc's oneshot-runner and
# fdholder service rules) crash-looped with "unknown user: root" and
# s6-setuidgid (used by this repo's own getty run scripts) would hit
# the same wall the moment boot got that far, since musl's NSS-less
# getpwnam() only ever reads /etc/passwd -- there is no compiled-in
# fallback. A minimal root entry is enough to unblock UID/GID
# resolution; it deliberately says nothing about login/password
# policy (locked vs. passwordless root, /etc/shadow) -- that is a
# separate decision, not a boot-blocking one.
cat > "${ROOTFS}/etc/passwd" <<-'EOF'
	root:x:0:0:root:/root:/bin/sh
EOF
cat > "${ROOTFS}/etc/group" <<-'EOF'
	root:x:0:
EOF
chmod 644 "${ROOTFS}/etc/passwd" "${ROOTFS}/etc/group"

# ── Copy musl libc into rootfs ────────────────────────────
echo "==> Installing musl into rootfs"
cp -a "${SYSROOT}/usr/lib/libc.so"               "${ROOTFS}/lib/libc.musl-x86_64.so.1"
ln -sfn libc.musl-x86_64.so.1                    "${ROOTFS}/lib/ld-musl-x86_64.so.1"

# ── Strip everything ──────────────────────────────────────
echo "==> Stripping binaries"
find "${ROOTFS}" -type f -print0 | xargs -0 -I{} sh -c \
    'file "{}" | grep -q "ELF" && '"${STRIP}"' --strip-all "{}" 2>/dev/null || true'

echo ""
echo "Base rootfs ready: ${ROOTFS}"
du -sh "${ROOTFS}"
