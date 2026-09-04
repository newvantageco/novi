#!/bin/bash
# ============================================================
# 27-audio.sh — ALSA: make the sound hardware usable
#
# RFC 0011. This kernel has had `CONFIG_SOUND=y`,
# `CONFIG_SND_HDA_INTEL=y` and 57 other sound options compiled in since
# the beginning, and nothing in userspace has ever touched one of them.
# A machine with working drivers and no way to open, mix or unmute a
# device does not have audio; it has the potential for audio.
#
# alsa-lib plus four tools: amixer (set levels), alsactl (save and
# restore the mixer across reboots), aplay (play something and find
# out), speaker-test (find out which channel is which).
#
# NOT alsamixer: the interactive one needs ncurses, which is a whole
# further dependency for a nicer version of what amixer already does.
# Listed on the RFC's roadmap rather than pulled in quietly.
#
# NOT PipeWire or PulseAudio either. Those are session-level sound
# servers -- they matter when several applications want the card at
# once, which needs applications first. ALSA is the layer that decides
# whether the hardware works at all, and that is the question a
# hardware test is asking.
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-versions.sh"

CROSS="${TOOLS}/bin/${TARGET_TRIPLE}"
[ -x "${CROSS}-gcc" ] || { echo "ERROR: ${CROSS}-gcc not found -- run build/02-toolchain.sh." >&2; exit 1; }

WORK="${BUILD_DIR}/audio-build"
rm -rf "${WORK}"; mkdir -p "${WORK}"

export PKG_CONFIG="${CROSS}-pkg-config"
export LDFLAGS="-L${ROOTFS}/usr/lib"
# alsa-utils' configure finds libasound with AM_PATH_ALSA, an
# autoconf link test -- not pkg-config. So PKG_CONFIG alone is not
# enough: without these it compiles against the BUILD HOST's headers,
# finds none, and stops with "Sufficiently new version of libasound not
# found" while the freshly cross-compiled one sits in the rootfs.
export CPPFLAGS="-I${ROOTFS}/usr/include"

# ── alsa-lib ──────────────────────────────────────────────────────────────
echo ">>> Building alsa-lib ${ALSA_VERSION} ..."
tar -xf "${SOURCES}/alsa-lib-${ALSA_VERSION}.tar.bz2" -C "${WORK}"
(
    cd "${WORK}/alsa-lib-${ALSA_VERSION}"
    # --disable-python: there is no python on the target.
    # --with-pcm-plugins/--with-ctl-plugins: the software mixing and
    # rate conversion that make a card usable by more than one caller;
    # leaving them out is how you end up with "device busy".
    ./configure --host="${TARGET_TRIPLE}" --prefix=/usr \
        --disable-python --disable-static --disable-old-symbols \
        --with-pcm-plugins=all --with-ctl-plugins=all >/dev/null
    make -j"$(nproc)" >/dev/null
    make install DESTDIR="${ROOTFS}" >/dev/null
)
# ALL of libtool's .la files, not just libasound's. They record
# absolute build-tree paths and reference each other: leaving
# libatopology.la behind while removing libasound.la made alsa-utils'
# link step stop with "cannot find the library '/usr/lib/libasound.la'"
# -- a path that is correct on the target and meaningless on the build
# host. Nothing on the target reads them.
rm -f "${ROOTFS}"/usr/lib/lib{asound,atopology}.la

# ── alsa-utils ────────────────────────────────────────────────────────────
echo ">>> Building alsa-utils ${ALSA_VERSION} ..."
tar -xf "${SOURCES}/alsa-utils-${ALSA_VERSION}.tar.bz2" -C "${WORK}"
(
    cd "${WORK}/alsa-utils-${ALSA_VERSION}"
    ./configure --host="${TARGET_TRIPLE}" --prefix=/usr \
        --with-alsa-prefix="${ROOTFS}/usr/lib" \
        --with-alsa-inc-prefix="${ROOTFS}/usr/include" \
        --disable-alsamixer --disable-xmlto --disable-nls \
        --disable-alsaconf --disable-bat --disable-alsaloop >/dev/null
    make -j"$(nproc)" >/dev/null
    make install DESTDIR="${ROOTFS}" >/dev/null
)

# Strip what we installed; these are the only new ELF files.
for b in amixer alsactl aplay arecord speaker-test aserver; do
    for d in bin sbin usr/bin usr/sbin; do
        [ -f "${ROOTFS}/${d}/${b}" ] && "${CROSS}-strip" "${ROOTFS}/${d}/${b}" 2>/dev/null || true
    done
done
"${CROSS}-strip" "${ROOTFS}"/usr/lib/libasound.so.*.*.* 2>/dev/null || true

# alsactl needs somewhere to keep the mixer state it restores at boot.
mkdir -p "${ROOTFS}/var/lib/alsa"

echo ""
echo "ALSA installed:"
ls -la "${ROOTFS}/usr/bin/amixer" "${ROOTFS}/usr/bin/aplay" 2>/dev/null || true
ls -la "${ROOTFS}/usr/sbin/alsactl" 2>/dev/null || ls -la "${ROOTFS}/usr/bin/alsactl" 2>/dev/null || true
du -sh "${ROOTFS}/usr/share/alsa" 2>/dev/null || true
