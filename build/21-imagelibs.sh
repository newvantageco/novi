#!/bin/bash
# ============================================================
# 21-imagelibs.sh — zlib and libpng, so something can decode an image
#
# novi-screenshot has been able to WRITE an image since it was written,
# and nothing on the system could read one back. It writes BMP for
# exactly that reason -- its own header says "this repo has zero image
# encoding capability", and BMP needs none. Fine for producing a file;
# useless for looking at it.
#
# PNG is the format anyone will actually hand you, and decoding it
# needs libpng, which needs zlib. zlib is also the first
# general-purpose compression library in this image: freetype was built
# with -Dzlib=internal precisely because there was none to link.
#
# Numbered 21 because it must run before 30-repo.sh packages it and
# before 31-desktop-split.sh removes the headers -- same constraint as
# every other library stage. 21 came free when 21-desktop-split.sh
# moved to 31.
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-versions.sh"

CROSS="${TOOLS}/bin/${TARGET_TRIPLE}"
[ -x "${CROSS}-gcc" ] || { echo "ERROR: ${CROSS}-gcc not found -- run build/02-toolchain.sh." >&2; exit 1; }

WORK="${BUILD_DIR}/imagelibs-build"
rm -rf "${WORK}"; mkdir -p "${WORK}"

# ── zlib ──────────────────────────────────────────────────────────────
#
# zlib's configure is hand-written, not autotools: it has no --host and
# reads CHOST from the environment instead. Passing --host would be
# silently accepted and ignored, which is the same catchall trap the
# skarnet packages have (see CLAUDE.md) -- the build would succeed and
# produce host binaries.
echo ">>> Building zlib ${ZLIB_VERSION} ..."
tar -xf "${SOURCES}/zlib-${ZLIB_VERSION}.tar.gz" -C "${WORK}"
(
    cd "${WORK}/zlib-${ZLIB_VERSION}"
    CHOST="${TARGET_TRIPLE}" \
    CC="${CROSS}-gcc" AR="${CROSS}-ar" RANLIB="${CROSS}-ranlib" \
        ./configure --prefix=/usr >/dev/null
    make -j"$(nproc)" >/dev/null
    make DESTDIR="${ROOTFS}" install >/dev/null
)

# ── libpng ────────────────────────────────────────────────────────────
echo ">>> Building libpng ${LIBPNG_VERSION} ..."
tar -xf "${SOURCES}/libpng-${LIBPNG_VERSION}.tar.xz" -C "${WORK}"
(
    cd "${WORK}/libpng-${LIBPNG_VERSION}"
    # CPPFLAGS/LDFLAGS point at the zlib just installed into the rootfs;
    # without them configure finds the BUILD HOST's zlib headers and
    # fails the link test, which is the same mistake 27-audio.sh's
    # AM_PATH_ALSA note documents.
    ./configure --build="$(gcc -dumpmachine)" --host="${TARGET_TRIPLE}" \
        --prefix=/usr --disable-static \
        CPPFLAGS="-I${ROOTFS}/usr/include" \
        LDFLAGS="-L${ROOTFS}/usr/lib" >/dev/null
    make -j"$(nproc)" >/dev/null
    make DESTDIR="${ROOTFS}" install >/dev/null
)

# libtool .la files reference each other by absolute build-host path and
# break the next thing that links against them -- the exact failure
# 27-audio.sh hit with libasound.la/libatopology.la.
rm -f "${ROOTFS}"/usr/lib/libpng*.la

# libpng's `make install` also drops four programs into /usr/bin, and
# leaving them there is what broke the base/desktop split the first
# time this stage ran.
#
# `pngfix` and `png-fix-itxt` are ELF binaries that link libpng and
# zlib. pkgsplit decides what moves out with the desktop by taking the
# desktop binaries' dependency closure MINUS everything else's, so two
# unasked-for utilities sitting in the console base were enough to
# claim `libpng16.so.16` and `libz.so.1` as base files. Their targets
# still moved out with the desktop (the table claims them), so the base
# kept two dangling symlinks, the packages shipped without their soname
# links, and `novi-view` died at exec with "Error loading shared
# library libpng16.so.16" on a system where `pkg install` had just
# reported success. pkgsplit now refuses that split outright; this is
# the other half -- do not put things in the image that nothing asked
# for.
#
# `libpng-config`/`libpng16-config` go for a duller reason: they are
# the pre-pkg-config way to find libpng, and this system has pkgconf
# and a libpng.pc (RFC 0015). Two answers to one question is one too
# many.
rm -f "${ROOTFS}"/usr/bin/pngfix \
      "${ROOTFS}"/usr/bin/png-fix-itxt \
      "${ROOTFS}"/usr/bin/libpng-config \
      "${ROOTFS}"/usr/bin/libpng16-config

find "${ROOTFS}/usr/lib" -maxdepth 1 -name 'libz.so*' -o -maxdepth 1 -name 'libpng*.so*' \
    | while read -r f; do "${CROSS}-strip" --strip-unneeded "$f" 2>/dev/null || true; done

echo ""
echo "Image libraries installed:"
ls -la "${ROOTFS}"/usr/lib/libz.so* "${ROOTFS}"/usr/lib/libpng16.so* 2>/dev/null | head -6
