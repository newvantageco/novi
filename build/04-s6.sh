#!/bin/bash
# ============================================================
# 04-s6.sh — Build the full s6 supervision stack
#
# Build order (dependency chain):
#   skalibs → execline → s6 → s6-rc → s6-linux-init
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/00-versions.sh"

NPROC=$(nproc)

build_skarnet() {
    local name="$1"
    local version="$2"
    local extra_flags="${3:-}"
    local pre_configure_patch="${4:-}"

    echo "==> Building ${name}-${version}"
    cd "${SOURCES}"
    tar -xf ${name}-${version}.tar.gz
    cd ${name}-${version}

    if [ -n "${pre_configure_patch}" ]; then
        eval "${pre_configure_patch}"
    fi

    # skalibs was installed with a plain --prefix=/usr (no
    # --enable-slashpackage), so its sysdeps/include land under
    # ${ROOTFS}/usr/lib/skalibs/sysdeps and ${ROOTFS}/usr/include -- not
    # the slashpackage-style /package/<category>/<name> layout. Pass
    # both --with-lib (static libskarnet.a, used to link this package's
    # own command binaries -- omitting it makes configure fall back to
    # guessing /usr/lib/<depname> for every declared dependency) and
    # --with-dynlib (shared libskarnet.so, used for this package's own
    # .so build).
    ./configure \
        --target="${TARGET_TRIPLE}" \
        --prefix="/usr" \
        --with-sysdeps="${ROOTFS}/usr/lib/skalibs/sysdeps" \
        --with-include="${ROOTFS}/usr/include" \
        --with-lib="${ROOTFS}/usr/lib/skalibs" \
        --with-dynlib="${ROOTFS}/usr/lib" \
        ${extra_flags}

    make -j${NPROC}
    make DESTDIR="${ROOTFS}" install

    echo "   done: ${name}"
    cd "${SOURCES}"
    rm -rf ${name}-${version}
}

# ── 1. skalibs (base library for all skarnet software) ────
echo "==> [1/5] skalibs-${SKALIBS_VERSION}"
cd "${SOURCES}"
tar -xf skalibs-${SKALIBS_VERSION}.tar.gz
cd skalibs-${SKALIBS_VERSION}

# /dev/urandom and posix_spawn()'s return-timing can't be autodetected
# when cross-compiling (skalibs' configure refuses to execute target
# binaries on the build host), so provide them explicitly: modern Linux
# always has /dev/urandom, and musl's posix_spawn() is implemented via
# vfork()-equivalent (CLONE_VM|CLONE_VFORK) semantics, which structurally
# cannot return to the parent before the child has exec'd or exited --
# i.e. it does not return early.
#
# Build both shared and static (skalibs' own configure default is
# shared=true static=true -- previously overridden to shared-only here,
# which broke execline's link step: it needs static libskarnet.a to
# link its own command binaries, only libexecline.so needs the shared
# variant).
./configure \
    --target="${TARGET_TRIPLE}" \
    --prefix="/usr" \
    --with-sysdep-devurandom=yes \
    --with-sysdep-posixspawnearlyreturn=no

make -j${NPROC}
make DESTDIR="${ROOTFS}" install
cd "${SOURCES}"
rm -rf skalibs-${SKALIBS_VERSION}

# ── 2. execline (lightweight scripting for service scripts) ─
build_skarnet "execline" "${EXECLINE_VERSION}"

# ── 3. s6 (supervision suite) ─────────────────────────────
# s6-2.12.0.2 predates a skalibs API change: socket_recv46() gained a
# trailing flags argument (skalibs/ip46.h now declares 6 params, s6's
# call site still passes 5), so it fails to compile against our pinned
# skalibs-2.14.1.1. Current s6 requires skalibs >= 2.15.1.0, newer than
# what we have; rather than chase a cascade of version bumps across the
# whole skarnet stack (execline/s6/s6-rc/s6-linux-init all need to move
# together), patch the one call site with the missing argument (0 = no
# special recv flags, matching the pre-change implicit behavior). Only
# affects s6-socklog, a network syslog receiver not used anywhere in
# this repo's init/services/.
#
# --with-execline=DIR (used below for s6, and --with-s6=/--with-s6-rc=
# for s6-rc/s6-linux-init previously) is not a real option in any of
# these configure scripts -- confirmed by reading them: only
# --with-lib/--with-dynlib/--with-include/--with-sysdeps are recognized,
# and the generic --with-*/--without-*/--*dir=* catchall silently no-ops
# anything else, the same way --datadir was a no-op for skalibs earlier.
# Each package's real build-time deps (package/deps-build) need their
# actual install locations passed via --with-lib (accumulates across
# repeated flags): s6 needs execline; s6-rc needs execline+s6;
# s6-linux-init needs execline+s6 (not s6-rc -- it doesn't declare
# s6-rc as a build dependency at all, despite the old --with-s6-rc=
# flag suggesting otherwise).
build_skarnet "s6" "${S6_VERSION}" \
    "--with-lib=${ROOTFS}/usr/lib/execline" \
    "sed -i 's/socket_recv46(x\[2\]\.fd, line, linelen + 1, &ip, &port)/socket_recv46(x[2].fd, line, linelen + 1, \&ip, \&port, 0)/' src/daemontools-extras/s6-socklog.c"

# ── 4. s6-rc (service manager / dependency resolver) ──────
build_skarnet "s6-rc" "${S6_RC_VERSION}" \
    "--with-lib=${ROOTFS}/usr/lib/execline --with-lib=${ROOTFS}/usr/lib/s6"

# ── 5. s6-linux-init (PID 1 integration) ──────────────────
build_skarnet "s6-linux-init" "${S6_LINUX_INIT_VERSION}" \
    "--with-lib=${ROOTFS}/usr/lib/execline --with-lib=${ROOTFS}/usr/lib/s6"

# ── 6. Wire up PID 1: compile the s6-rc service database, generate
# the s6-linux-init runtime tree from this repo's init/skel and
# init/services, and install it as /sbin/init ─────────────────────
#
# s6-linux-init-maker and s6-rc-compile are themselves TARGET
# (musl/x86_64) binaries, not host tools -- but the target arch here
# matches the build host's arch, so they can be run directly by
# invoking musl's own dynamic linker as a loader (the same trick
# musl's libc.so plays on itself: it doubles as its own ld.so). That
# avoids needing a whole second, host-native build of the skarnet
# stack just to run two build-time code generators.
MUSL_LOADER="${ROOTFS}/lib/ld-musl-x86_64.so.1"
run_target() {
    LD_LIBRARY_PATH="${ROOTFS}/usr/lib" "${MUSL_LOADER}" "$@"
}

echo "==> [6/6] Compiling s6-rc service database"
rm -rf "${ROOTFS}/etc/s6-rc"
mkdir -p "${ROOTFS}/etc/s6-rc"
run_target "${ROOTFS}/usr/bin/s6-rc-compile" \
    "${ROOTFS}/etc/s6-rc/compiled" "${REPO_ROOT}/init/services"

echo "==> Generating s6-linux-init runtime tree"
rm -rf "${BUILD_DIR}/s6-linux-init-gen"
# s6-linux-init-maker's compiled-in default skeleton path is an
# absolute host path baked in at ./configure time (--prefix=/usr means
# /usr/etc/s6-linux-init/skel), which is meaningless when running the
# TARGET-built binary directly on the build host outside a chroot --
# -f must point explicitly at this repo's skeleton instead.
# -p: s6-linux-init-maker's own default initial PATH is "/usr/bin:/bin"
# -- no /sbin, no /usr/sbin. That's every s6-rc service's PATH too,
# inherited from PID 1. Confirmed missing the hard way: a novi-shell
# service run script's bare `modprobe virtio_gpu` failed with
# "modprobe: not found" on a live boot, even though
# /sbin/modprobe -> ../bin/busybox exists -- just not on this PATH.
# Root cause fixed here, not by hardcoding /sbin/modprobe in one
# script, since any future service or interactive `s6-rc`-managed
# tooling under /sbin or /usr/sbin would hit the identical wall.
run_target "${ROOTFS}/usr/bin/s6-linux-init-maker" \
    -c /etc/s6-linux-init \
    -f "${REPO_ROOT}/init/skel" \
    -p "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    -N "${BUILD_DIR}/s6-linux-init-gen"

echo "==> Installing s6-linux-init runtime tree and PID 1"
rm -rf "${ROOTFS}/etc/s6-linux-init"
mkdir -p "${ROOTFS}/etc/s6-linux-init"
cp -a "${BUILD_DIR}/s6-linux-init-gen/env" \
      "${BUILD_DIR}/s6-linux-init-gen/run-image" \
      "${BUILD_DIR}/s6-linux-init-gen/scripts" \
      "${ROOTFS}/etc/s6-linux-init/"

# bin/{init,halt,poweroff,reboot,shutdown,telinit} are meant to be
# installed as real system commands, not left under the basedir --
# "init" specifically must land at /sbin/init (PID 1), replacing the
# BusyBox init symlink 03-base.sh put there. BusyBox's own init looks
# for a sysvinit-style /etc/init.d/rcS this repo doesn't have -- and
# indeed does not want, since the whole point of this repo is s6, not
# sysvinit -- confirmed via a live QEMU boot that got exactly that far
# and failed right after switch_root handed off to /sbin/init: "can't
# run '/etc/init.d/rcS': No such file or directory".
rm -f "${ROOTFS}/sbin/init"
for cmd in init halt poweroff reboot shutdown telinit; do
    install -m 0755 "${BUILD_DIR}/s6-linux-init-gen/bin/${cmd}" "${ROOTFS}/sbin/${cmd}"
done
rm -rf "${BUILD_DIR}/s6-linux-init-gen"

echo "novi" > "${ROOTFS}/etc/hostname"

echo ""
echo "s6 stack installed. Binaries:"
ls "${ROOTFS}/usr/bin/s6-"* 2>/dev/null | head -20
