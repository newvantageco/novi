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

# BusyBox's `make install` creates /sbin/init and /linuxrc symlinks to
# itself. Novi's PID 1 is s6-linux-init, never BusyBox init -- which
# looks for a sysvinit-style /etc/init.d/rcS this repo does not have
# and does not want.
#
# 04-s6.sh already deletes /sbin/init before installing the real one,
# so a clean 01..05 run has always been fine. The failure is on a
# RE-RUN: running this stage again after 04 silently hands PID 1 back
# to BusyBox, and the next boot dies immediately after switch_root with
# "can't run '/etc/init.d/rcS': No such file or directory". Confirmed
# live, twice -- once when 04-s6.sh was first written, and again here.
#
# Removing the symlinks at the source means no stage ordering can
# reintroduce it. The `init` applet itself stays in the binary; only
# the claim on /sbin/init goes.
rm -f "${ROOTFS}/sbin/init" "${ROOTFS}/linuxrc"

cd "${SOURCES}"

# ── Base rootfs directory layout ─────────────────────────
echo "==> Creating rootfs hierarchy"
mkdir -p "${ROOTFS}"/{boot,dev,etc,home,lib,mnt,opt,proc,root,run,srv,sys,tmp,usr/{bin,lib,share},var/{log,run,tmp}}
chmod 1777 "${ROOTFS}/tmp"
chmod 700  "${ROOTFS}/root"

# ── User/group database ──────────────────────────────────
# Nothing ever created /etc/passwd or /etc/group -- confirmed via a
# live boot where s6-envuidgid (used by s6-rc's oneshot-runner and
# fdholder service rules) crash-looped with "unknown user: root" and
# s6-setuidgid (used by this repo's own getty run scripts) would hit
# the same wall the moment boot got that far, since musl's NSS-less
# getpwnam() only ever reads /etc/passwd -- there is no compiled-in
# fallback.
#
# These three files are repo content (rootfs/etc/) rather than
# heredocs, because they are policy: fixed GIDs a squashed image's
# baked-in file modes depend on, and a root entry whose password field
# decides whether anyone can log into the shipped image at all. Policy
# belongs somewhere a reviewer sees it in a diff.
#
# /etc/shadow in particular had never been created by ANY build stage
# -- the one in /build/rootfs was a leftover from a hand-run command in
# some earlier session, so a genuinely clean build produced an image
# with no shadow file at all. It is generated from the repo now.
#
# The comment headers in them are safe: musl skips unparseable lines in
# all three, verified by running a static musl getpwnam()/getgrnam()
# binary against these exact files in a chroot, not assumed.
install -D -m 644 "${REPO_ROOT}/rootfs/etc/passwd" "${ROOTFS}/etc/passwd"
install -D -m 644 "${REPO_ROOT}/rootfs/etc/group"  "${ROOTFS}/etc/group"
install -D -m 600 "${REPO_ROOT}/rootfs/etc/shadow" "${ROOTFS}/etc/shadow"

# Login environment. Without this every login shell inherits whatever
# PATH login(1) hands it, which does not include /sbin -- so a normal
# user typing `ip addr` on an installed machine gets "ip: not found"
# even though /sbin/ip is the same BusyBox binary as /bin/ls. See the
# file's own comments.
install -D -m 644 "${REPO_ROOT}/rootfs/etc/profile" "${ROOTFS}/etc/profile"

# The generic driver loader (RFC 0011). Base image, not a package: a
# machine that cannot load the driver for its own disk or NIC cannot
# install a package to fix that.
install -D -m 755 "${REPO_ROOT}/packages/novi-hwdetect" "${ROOTFS}/sbin/novi-hwdetect"
install -D -m 755 "${REPO_ROOT}/packages/novi-hotplug" "${ROOTFS}/sbin/novi-hotplug"

# The live-boot desktop helper (RFC 0007): the base image is
# console-only, so a live boot that wants a desktop installs one from
# the repository on the medium, and this is the script that does it.
# init/skel/rc.init calls it when `novi.live.desktop` is on the kernel
# command line.
#
# It used to be build/22-live-desktop.sh -- a whole discovered build
# stage whose entire body was this one `install` line, for a file that
# is repo content under rootfs/ exactly like the seven above it. It
# came back here when novi-view needed stage number 22 and the 20s
# turned out to be full; a stage that cross-compiles nothing and
# installs one shell script was the one that did not need to exist.
install -D -m 755 "${REPO_ROOT}/rootfs/usr/bin/novi-live-desktop" \
    "${ROOTFS}/usr/bin/novi-live-desktop"

# ACPI event handlers. The two path names are dictated by busybox
# acpid's compiled-in action table (PWRF -> power button, LID -> lid),
# not chosen here; renaming either means acpid runs nothing.
install -D -m 755 "${REPO_ROOT}/rootfs/etc/acpi/PWRF/00000080" "${ROOTFS}/etc/acpi/PWRF/00000080"
install -D -m 755 "${REPO_ROOT}/rootfs/etc/acpi/LID/00000080"  "${ROOTFS}/etc/acpi/LID/00000080"

# Battery, AC, CPU frequency and suspend. Base image for the same
# reason: a laptop that cannot tell you it is about to die, and cannot
# be told to sleep, is not usable enough to go install something that
# fixes that.
install -D -m 755 "${REPO_ROOT}/packages/novi-power" "${ROOTFS}/usr/bin/novi-power"
mkdir -p "${ROOTFS}/etc/profile.d"

# ── Copy musl libc into rootfs ────────────────────────────
echo "==> Installing musl into rootfs"
cp -a "${SYSROOT}/usr/lib/libc.so"               "${ROOTFS}/lib/libc.musl-x86_64.so.1"
ln -sfn libc.musl-x86_64.so.1                    "${ROOTFS}/lib/ld-musl-x86_64.so.1"

# ── Strip everything except kernel modules ────────────────
# `--strip-all` on a .ko removes .symtab, which the module loader needs
# for relocation -- the module survives as a file and becomes
# permanently unloadable. That does not bite a clean build, because
# this stage runs before 05-kernel.sh puts any modules in the rootfs.
# It bites hard on a re-run: running 03-base.sh again after the kernel
# stage silently destroys every module in the image.
#
# Confirmed live rather than reasoned about. After a re-run of this
# stage, a boot that had worked minutes earlier failed with all 22 of
# /init's `modprobe` calls returning non-zero -- including virtio_blk,
# so there was no /dev/vda, no live medium, and a PANIC into the
# emergency shell. `readelf -S` on virtio_blk.ko showed the symbol
# table gone.
#
# The kernel's own INSTALL_MOD_STRIP uses --strip-debug for exactly
# this reason; 05-kernel.sh owns module stripping, not this stage.
echo "==> Stripping binaries (kernel modules excluded -- see comment)"
find "${ROOTFS}" -type f -not -path "${ROOTFS}/lib/modules/*" -print0 | xargs -0 -I{} sh -c \
    'file "{}" | grep -q "ELF" && '"${STRIP}"' --strip-all "{}" 2>/dev/null || true'

echo ""
echo "Base rootfs ready: ${ROOTFS}"
du -sh "${ROOTFS}"
