#!/bin/bash
# ============================================================
# 06-wayland.sh — Build the Wayland/wlroots stack for novi-shell
#
# Everything RFC 0001's compositor needs before any compositor code
# can be written: wayland, wayland-protocols, libxkbcommon, pixman,
# libudev-zero, libevdev, mtdev, libinput, libdrm, seatd, wlroots --
# plus libffi and expat, two small transitive deps neither musl/gcc
# nor this repo's existing packages provide.
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-versions.sh"
source "${SCRIPT_DIR}/lib-meson-cross.sh"

# ── 1. libffi (wayland dependency) ────────────────────────────────
build_autotools libffi "${LIBFFI_VERSION}" \
    --disable-multi-os-directory --disable-static --enable-shared

# ── 2. expat (wayland dependency) ─────────────────────────────────
build_autotools expat "${EXPAT_VERSION}" \
    --disable-static --enable-shared --without-docbook

# ── 3. wayland ─────────────────────────────────────────────────────
#
# wayland-scanner is a build-time code generator that has to run ON
# THE BUILD HOST, but meson still resolves it as a versioned
# dependency ("need wayland-scanner >= this project's own version")
# even when cross-compiling -- so a plain `apt install libwayland-bin`
# copy that happens to be older than the version we're building here
# fails meson's version check outright (confirmed: "Found 1.22.0 but
# need: '1.23.0'"). Build our own native (host-targeted, not
# cross-compiled) copy of just the scanner first, at the exact same
# version, and point the CROSS build's build-machine dependency
# lookup at it.
#
# PKG_CONFIG_PATH_FOR_BUILD, not plain PKG_CONFIG_PATH: meson
# disambiguates build-machine vs. host-machine pkg-config search
# paths via the _FOR_BUILD/_FOR_HOST suffix once a cross file is in
# play (confirmed empirically -- plain PKG_CONFIG_PATH measurably
# reaches bare `pkg-config` but meson's own build-machine dependency
# resolution ignored it during an actual cross configure run, while
# the _FOR_BUILD-suffixed variable was picked up immediately).
echo "==> [3/wayland stack] wayland-${WAYLAND_VERSION} (native scanner)"
cd "${SOURCES}"
rm -rf "wayland-${WAYLAND_VERSION}"
tar -xf "wayland-${WAYLAND_VERSION}.tar.gz"
cd "wayland-${WAYLAND_VERSION}"
meson setup build-native \
    --prefix="${NATIVE_PREFIX}" \
    -Dscanner=true -Dlibraries=false -Ddocumentation=false \
    -Dtests=false -Ddtd_validation=false
ninja -C build-native
ninja -C build-native install

echo "==> wayland-${WAYLAND_VERSION} (target libraries)"
NATIVE_SCANNER_PC="$(find "${NATIVE_PREFIX}" -name 'wayland-scanner.pc' -printf '%h' -quit)"
PKG_CONFIG_PATH_FOR_BUILD="${NATIVE_SCANNER_PC}" \
meson_cross build \
    --prefix=/usr \
    -Dscanner=false -Ddocumentation=false -Dtests=false -Ddtd_validation=false
ninja -C build
DESTDIR="${ROOTFS}" ninja -C build install


# ── 4. wayland-protocols (pure XML + pkg-config metadata) ─────────
build_meson wayland-protocols "${WAYLAND_PROTOCOLS_VERSION}" \
    -Dtests=false

# ── 5. libxkbcommon ─────────────────────────────────────────────────
#
# enable-xkbregistry needs libxml2, a dependency chain not worth
# pulling in for the "compositor renders something" milestone this
# build stage exists to reach -- xkbregistry is for GUI layout
# pickers, not core keymap handling; revisit when building that UI.
# xkeyboard-config (the runtime layout database, a separate package
# providing the actual rules/layout data files) is a soft warning
# here, not a build failure, but is a real *runtime* dependency for
# keyboard input to work at all -- not yet added anywhere in this
# repo, tracked as a follow-up.
# -Dxkb-config-root=/usr/share/X11/xkb: pinned explicitly rather than
# left to xkbcommon's own auto-detection. Its meson.build (see
# XKBCONFIGROOT logic) queries xkeyboard-config's "xkb_base" pkg-config
# variable when that package is already installed, through our
# sysroot-aware pkg-config wrapper (PKG_CONFIG_SYSROOT_DIR=${ROOTFS}) --
# and pkg-config's sysroot rewriting applies to that value too, not
# just Cflags/Libs, producing "${ROOTFS}/usr/share/X11/xkb" baked into
# libxkbcommon.so as its compiled-in RUNTIME default (DFLT_XKB_CONFIG_ROOT),
# a build-host path that doesn't exist inside the booted VM at all.
# Confirmed live: this exact bug fired on a re-run of this script after
# xkeyboard-config (step 15, below) already existed in the rootfs from
# an earlier run -- the very first build predates xkeyboard-config
# entirely, so it never hit xkeyboard_config_dep.found() and fell back
# to a correct, unprefixed default, silently working by step-ordering
# accident rather than by design. Passing this explicitly makes the
# correct runtime value (no sysroot prefix -- /usr/... is exactly right
# at boot time) independent of both build order and pkg-config's
# variable-substitution behavior.
build_meson libxkbcommon "${LIBXKBCOMMON_VERSION}" \
    -Denable-x11=false -Denable-tools=false -Denable-wayland=false \
    -Denable-docs=false -Denable-bash-completion=false \
    -Denable-xkbregistry=false -Dxkb-config-root=/usr/share/X11/xkb

# ── 6. pixman (wlroots' mandatory software renderer backend) ──────
# name+version deliberately built as "pixman"+"pixman-X.Y.Z": the
# tarball and its extracted directory are both "pixman-pixman-X.Y.Z"
# (GitLab archive naming includes the project name twice when the
# ref itself is "pixman-X.Y.Z", not a bare "X.Y.Z" tag).
build_meson pixman "pixman-${PIXMAN_VERSION}" \
    -Dgtk=disabled -Dlibpng=disabled -Dtests=disabled -Ddemos=disabled \
    -Dopenmp=disabled

# ── 7. libudev-zero ────────────────────────────────────────────────
#
# Plain non-meson Makefile, not wlroots-specific -- a musl-friendly
# drop-in libudev replacement that reads sysfs directly instead of
# running a systemd-udevd-style daemon, exactly the "no systemd
# anywhere" constraint RFC 0001 states. Satisfies every downstream
# package's plain "libudev" pkg-config lookup (libinput, wlroots).
echo "==> Building libudev-zero-${LIBUDEV_ZERO_VERSION}"
cd "${SOURCES}"
rm -rf "libudev-zero-${LIBUDEV_ZERO_VERSION}"
tar -xf "libudev-zero-${LIBUDEV_ZERO_VERSION}.tar.gz"
cd "libudev-zero-${LIBUDEV_ZERO_VERSION}"
make CC="${TARGET_TRIPLE}-gcc" AR="${TARGET_TRIPLE}-ar" PREFIX=/usr LIBDIR=/usr/lib
make DESTDIR="${ROOTFS}" CC="${TARGET_TRIPLE}-gcc" AR="${TARGET_TRIPLE}-ar" \
    PREFIX=/usr LIBDIR=/usr/lib install
echo "   done: libudev-zero"

# ── 8. libevdev ─────────────────────────────────────────────────────
# Same double-name-in-archive situation as pixman above.
build_meson libevdev "libevdev-${LIBEVDEV_VERSION}" \
    -Dtests=disabled -Dtools=disabled -Ddocumentation=disabled

# ── 9. mtdev ─────────────────────────────────────────────────────────
build_autotools mtdev "${MTDEV_VERSION}" \
    --disable-static --enable-shared

# ── 10. libinput ─────────────────────────────────────────────────────
#
# libwacom (tablet identification) and debug-gui (needs GTK/cairo) are
# both real features, deliberately deferred -- neither is needed for
# a compositor to come up and render.
build_meson libinput "${LIBINPUT_VERSION}" \
    -Dlibwacom=false -Ddebug-gui=false -Dtests=false -Ddocumentation=false

# ── 11. libdrm ────────────────────────────────────────────────────────
# The tarball is "drm-libdrm-X.Y.Z.tar.gz" (matches the URL path,
# fetched as "drm/-/archive/libdrm-X.Y.Z/..."), but it actually
# extracts to "libdrm-libdrm-X.Y.Z-<commit-hash>/" -- GitLab appends a
# commit hash to the archive's internal directory name whenever the
# requested archive filename doesn't exactly match its own canonical
# "<project>-<ref>" naming, confirmed by listing the tarball's actual
# contents rather than assuming. build_meson's own name/version-based
# default can't express that, so extract once here to discover the
# real directory name via a glob, then let build_meson's own (harmless
# to repeat) extraction take over from there.
#
# NOT `tar -tzf ... | head -1 | ...`: under `set -o pipefail`, head
# closing its input after one line sends SIGPIPE back to tar before it
# finishes writing the rest of the (much longer) listing, which
# pipefail turns into a silent script-aborting failure -- confirmed by
# this exact pipeline killing the script immediately after the
# libinput step, twice, with no error output at all (the failure is in
# the pipeline itself, before anything downstream ever runs).
cd "${SOURCES}"
rm -rf libdrm-libdrm-"${LIBDRM_VERSION}"-*
tar -xf "drm-libdrm-${LIBDRM_VERSION}.tar.gz"
LIBDRM_DIR="$(compgen -G "libdrm-libdrm-${LIBDRM_VERSION}-*")"
build_meson drm-libdrm "${LIBDRM_VERSION}" -d "${LIBDRM_DIR}" \
    -Dcairo-tests=disabled -Dman-pages=disabled -Dvalgrind=disabled -Dtests=false

# ── 12. zlib ───────────────────────────────────────────────────────
#
# Moved here from 21-imagelibs.sh, where it used to live beside libpng.
# Mesa links it (libgallium's DT_NEEDED names libz.so.1) and Mesa has
# to be built before wlroots, so a zlib that only appears at stage 21
# is a library built AFTER its consumer -- invisible in a warm tree and
# fatal in a clean one. That is the novi-launcher/fcft bug and the
# novi-panel/libnl bug for a third time; the rule is that a library
# more than one thing links belongs in the library stage, and this is
# the library stage.
#
# zlib's configure is hand-written, not autotools: it has no --host and
# reads CHOST from the environment instead. Passing --host would be
# silently accepted and ignored -- the same catchall trap the skarnet
# packages have -- and the build would succeed and produce HOST
# binaries.
echo "==> [12/wayland stack] zlib-${ZLIB_VERSION}"
cd "${SOURCES}"
rm -rf "zlib-${ZLIB_VERSION}"
tar -xf "zlib-${ZLIB_VERSION}.tar.gz"
(
    cd "zlib-${ZLIB_VERSION}"
    CHOST="${TARGET_TRIPLE}" \
    CC="${TARGET_TRIPLE}-gcc" AR="${TARGET_TRIPLE}-ar" \
    RANLIB="${TARGET_TRIPLE}-ranlib" \
        ./configure --prefix=/usr >/dev/null
    make -j"${NPROC}" >/dev/null
    make DESTDIR="${ROOTFS}" install >/dev/null
)

# ── 13. Mesa (EGL, GLESv2, GBM) ────────────────────────────────────
#
# The GL stack. Until this existed there was none at all: novi-shell
# rendered through wlroots' pixman software renderer, and no program
# that wanted OpenGL could run on this system even in principle.
#
# WHICH DRIVERS, and why so few:
#
#   softpipe  pure software rasterisation and no LLVM. The only driver
#             guaranteed to work in QEMU without host GL, which makes
#             it the one the whole pipeline can be VERIFIED on rather
#             than reasoned about.
#   virgl     the accelerated path inside a VM -- QEMU's virtio-gpu-gl
#             passes GL through to the host. Small, and no LLVM either.
#
# NOT radeonsi and NOT llvmpipe: both need LLVM, which is an enormous
# cross-build in its own right. Intel's `iris` needs no LLVM and is the
# obvious next one, but it could not be verified here -- QEMU emulates
# no Intel GPU -- so it is deliberately absent rather than shipped
# untested, the same call as the panel's battery indicator.
#
# `-Dglx=disabled` costs desktop libGL: this ships EGL + GLESv2 only.
# That is exactly what wlroots' gles2 renderer wants, and it is NOT
# enough for most existing OpenGL games, which want full GL through
# libglvnd. Worth stating plainly rather than letting "Mesa" imply a
# gaming stack.
#
# `-Dshader-cache=disabled` avoids zstd; zlib is linked regardless,
# which is why section 12 above exists.
python3 -c 'import mako' 2>/dev/null || {
    echo "ERROR: Mesa's build needs the Python 'mako' template engine on" >&2
    echo "       the BUILD HOST (pip install mako)." >&2
    echo "       Checked up front rather than left to fail deep inside a" >&2
    echo "       generated-source rule -- same reason 05-kernel.sh checks" >&2
    echo "       for depmod before trusting modules_install." >&2
    exit 1
}
echo "==> [13/wayland stack] mesa-${MESA_VERSION}"
cd "${SOURCES}"
rm -rf "mesa-${MESA_VERSION}"
tar -xf "mesa-${MESA_VERSION}.tar.xz"
cd "mesa-${MESA_VERSION}"
MESA_SCANNER_PC="$(find "${NATIVE_PREFIX}" -name 'wayland-scanner.pc' -printf '%h' -quit)"
PKG_CONFIG_PATH_FOR_BUILD="${MESA_SCANNER_PC}" \
meson_cross build --prefix=/usr --libdir=/usr/lib \
    -Dgallium-drivers=softpipe,virgl -Dvulkan-drivers= \
    -Dplatforms=wayland -Degl=enabled -Dgbm=enabled \
    -Dgles1=disabled -Dgles2=enabled -Dopengl=true \
    -Dglx=disabled -Dglvnd=disabled \
    -Dllvm=disabled -Ddraw-use-llvm=false \
    -Dshader-cache=disabled -Dzstd=disabled -Dosmesa=false \
    -Dgallium-va=disabled -Dgallium-vdpau=disabled \
    -Dgallium-xa=disabled -Dgallium-nine=false \
    -Dgallium-opencl=disabled -Dgallium-rusticl=false \
    -Dvideo-codecs= -Dvalgrind=disabled -Dlibunwind=disabled \
    -Dlmsensors=disabled -Dselinux=false -Dperfetto=false \
    -Dbuild-tests=false -Dtools=
ninja -C build
DESTDIR="${ROOTFS}" ninja -C build install
# 75 of the 82 MB installed is debug info, nearly all in one megadriver.
"${TARGET_TRIPLE}-strip" "${ROOTFS}"/usr/lib/libgallium-*.so \
    "${ROOTFS}"/usr/lib/libEGL.so.*.* "${ROOTFS}"/usr/lib/libGLESv2.so.*.* \
    "${ROOTFS}"/usr/lib/libgbm.so.*.* "${ROOTFS}"/usr/lib/libglapi.so.*.* \
    2>/dev/null || true

# ── 13b. The C++ runtime ───────────────────────────────────────────
#
# Mesa is the first thing in this image with any C++ in it, so
# libgallium names libstdc++.so.6 and libgcc_s.so.1 in its DT_NEEDED
# and NOTHING shipped them. They exist only in the cross toolchain, and
# there in `lib64` -- which musl's loader never searches, since it
# looks in /lib:/usr/local/lib:/usr/lib and nowhere else. RFC 0015
# records the identical trap for the native toolchain: C worked
# perfectly and C++ died at exec.
#
# Copied from the toolchain rather than rebuilt: it is the runtime for
# the exact compiler that produced these objects, and a separate build
# of it is an ABI risk for no gain.
echo "==> [13b/wayland stack] libstdc++ / libgcc_s"
for lib in "${TOOLS}/${TARGET_TRIPLE}/lib64/libstdc++.so.6."* \
           "${TOOLS}/${TARGET_TRIPLE}/lib64/libgcc_s.so.1"; do
    case "${lib}" in *-gdb.py) continue ;; esac
    [ -f "${lib}" ] || continue
    install -m 755 "${lib}" "${ROOTFS}/usr/lib/$(basename "${lib}")"
done
"${TARGET_TRIPLE}-strip" "${ROOTFS}"/usr/lib/libstdc++.so.6.* \
    "${ROOTFS}"/usr/lib/libgcc_s.so.1 2>/dev/null || true
( cd "${ROOTFS}/usr/lib" && ln -sfn "$(basename "$(ls libstdc++.so.6.*)")" libstdc++.so.6 )

# ── 14. libdisplay-info (EDID parsing for the DRM backend) ──────────
build_meson libdisplay-info "${LIBDISPLAY_INFO_VERSION}"

# ── 15. seatd (logind-free seat/session management) ─────────────────
#
# libseat-logind=disabled: no systemd-logind, no elogind, matching
# RFC 0001's "no systemd anywhere" decision explicitly, not just by
# omission.
build_meson seatd "${SEATD_VERSION}" \
    -Dlibseat-logind=disabled -Dlibseat-seatd=enabled -Dserver=enabled \
    -Dman-pages=disabled

# ── 16. wlroots ────────────────────────────────────────────────────
#
# This used to be built deliberately Mesa-free -- `renderers=[]` and
# `allocators=[]`, so only the mandatory pixman software renderer and
# the built-in shm / DRM-dumb-buffer allocators existed. That was the
# right call while the first milestone was "a compositor can come up
# and render at all" and there was no GL stack to link against. Mesa
# (section 13) is that stack, so:
#
#   - renderers=gles2 : builds the GL renderer ALONGSIDE pixman, which
#     is mandatory and always present. Both ship, and wlroots picks at
#     runtime -- `WLR_RENDERER=pixman` or `=gles2` forces either. That
#     is deliberate: in QEMU there is no host GL, so gles2 runs on
#     softpipe, and software rasterisation through a GL API is not
#     obviously faster than pixman drawing directly. Shipping both is
#     what makes it possible to MEASURE that rather than assume it.
#   - allocators=gbm : the GL renderer needs buffers it can render
#     into. Confirmed by reading render/allocator/meson.build:
#     allocator.c, shm.c and drm_dumb.c are unconditional sources,
#     gbm.c is added only if the 'gbm' feature is requested.
#   - xwayland=disabled, xcb-errors=disabled: no X11 anywhere yet.
#   - backends=drm,libinput: no x11 backend (nested-in-X11 testing
#     backend, irrelevant here).
# hwdata (native-only, a build-time PCI/USB ID data lookup) and
# libdisplay-info (a real target dependency, built just above) were
# both missing on the first configure attempt -- added after reading
# the actual meson.build dependency() calls, not guessed.
build_meson wlroots "${WLROOTS_VERSION}" \
    -Drenderers=gles2 -Dbackends=drm,libinput -Dallocators=gbm \
    -Dxwayland=disabled -Dexamples=false -Dcolor-management=disabled \
    -Dlibliftoff=disabled -Dxcb-errors=disabled

# ── 17. xkeyboard-config (runtime keyboard layout database) ───────
#
# libxkbcommon (step 5) builds and links fine on its own, but it does
# not embed any keyboard layout data -- xkb_keymap_new_from_names()
# needs an actual rules/symbols/keycodes/compat/types database on disk
# at runtime to compile ANY keymap. Confirmed live: novi-shell got all
# the way through DRM backend + pixman renderer + DRM-dumb allocator +
# libinput init, then hard-failed the moment libinput handed it a real
# keyboard device ("xkbcommon: ERROR: failed to add default include
# path /usr/share/X11/xkb"), because that path never existed. This
# package is pure data (compat/geometry/keycodes/symbols/types text
# files plus generated rules) processed at build time entirely by
# build-machine python3/perl -- there is nothing target-arch-specific
# to cross-compile, meson_cross's cross-file is a no-op here beyond
# picking the install prefix. -Dnls=false skips gettext/msgfmt (locale
# translation of layout descriptions), not needed for keymap
# compilation to work; xkeyboard-config's own meson.build (2.48)
# installs both the canonical /usr/share/xkeyboard-config-2/ tree AND
# a legacy /usr/share/X11/xkb symlink pointing at it, which is exactly
# the path libxkbcommon's default include path expects.
build_meson xkeyboard-config "xkeyboard-config-${XKEYBOARD_CONFIG_VERSION}" \
    -Dnls=false

echo ""
echo "Wayland/wlroots stack installed. Libraries:"
find "${ROOTFS}/usr/lib" -maxdepth 1 -iname "libwlroots*" -o -iname "libseat*" -o -iname "libinput*"

# ─────────────────────────────────────────────────────────────────────
# Text rendering: freetype -> fontconfig -> fcft (+ tllist)
# ─────────────────────────────────────────────────────────────────────
#
# These live here, with the rest of the shared library stack, because
# three separate clients need them: novi-launcher (stage 08),
# novi-panel (stage 10) and foot (stage 09). They were originally built
# in 09-foot.sh, on the assumption that foot was their only consumer;
# once the launcher and panel gained real anti-aliased text they became
# a dependency of stages that run *earlier*, and a clean build stopped
# at stage 08 with `cannot find -lfcft`. Nothing noticed, because a
# from-scratch build is rare and CI compiles nothing.
#
# Same rule as everywhere else in this file: a library that more than
# one thing links belongs in the library stage, not inside whichever
# application happened to need it first.

# ── 1. freetype ─────────────────────────────────────────────────────
#
# -Dzlib=internal: freetype bundles its own minimal gzip decompressor
# (src/gzip/) specifically so consumers don't need a system zlib just
# to read gzip-compressed font tables -- avoids pulling in zlib as a
# whole separate new dependency for this one feature. harfbuzz/brotli/
# bzip2/png are all optional advanced-hinting/format features this
# terminal-font use case doesn't need; disabled to keep the dependency
# chain from growing any further than it already has.
build_meson freetype "VER-${FREETYPE_VERSION}" \
    -Dzlib=internal -Dharfbuzz=disabled -Dbrotli=disabled \
    -Dbzip2=disabled -Dpng=disabled -Dtests=disabled

# ── 2. fontconfig ────────────────────────────────────────────────────
#
# -Dxml-backend=expat: already built (build/06-wayland.sh step 2),
# avoids needing libxml2 as a second, redundant XML parser in the
# rootfs. -Dcache-build=disabled: that option runs fc-cache at `ninja
# install` time on the BUILD machine, which would try to execute a
# freshly cross-compiled TARGET fc-cache binary directly on this x86_64
# Linux host -- same architecture, so it wouldn't even fail loudly, it
# would just scan and cache the *host's* font directories into the
# rootfs's cache path instead of the rootfs's own fonts (which aren't
# installed yet at this point in the build anyway). Cache is built
# correctly, chrooted, after the font is installed -- see below.
build_meson fontconfig "${FONTCONFIG_VERSION}" \
    -Dnls=disabled -Dtests=disabled -Dtests-external-fonts=disabled \
    -Dxml-backend=expat -Ddoc=disabled -Dcache-build=disabled

# ── 3. tllist (header-only, used by both fcft and foot) ─────────────
build_meson tllist "${TLLIST_VERSION}" -d tllist

# ── 4. fcft ───────────────────────────────────────────────────────────
#
# Pinned to the 2.x line in 00-versions.sh (not latest) because foot
# 1.9.2 requires fcft <3.0.0 -- confirmed by reading foot's own
# meson.build, not assumed. grapheme-shaping=disabled and
# run-shaping=disabled together avoid needing harfbuzz or libutf8proc
# at all: this is a monospace terminal font (Latin text, no complex
# script shaping), so neither buys anything for this use case. (fcft
# 2.5.1 -- unlike the 3.x line -- has no SVG/color-emoji option at all,
# so there's nothing to disable there; confirmed by reading this exact
# version's meson_options.txt after -Dsvg-backend=none, copied from
# having inspected the 3.x tag instead of this one, failed with
# "Unknown option: svg-backend".)
build_meson fcft "${FCFT_VERSION}" -d fcft \
    -Dgrapheme-shaping=disabled -Drun-shaping=disabled \
    -Ddocs=disabled -Dexamples=false -Dtest-text-shaping=false

# ── 5. libnl ──────────────────────────────────────────────────────────
#
# HERE, not in 25-wifi.sh where it used to be, and the move is RFC
# 0005's rule applied to the letter: a library more than one client
# links belongs in the library stage, not inside whichever application
# happened to need it first.
#
# libnl had exactly one consumer -- wpa_supplicant, built in stage 25 --
# right up until novi-panel's network indicator started asking the
# kernel for a WiFi signal over nl80211. novi-panel is stage 10. In a
# warm tree that is invisible; a clean `bash build.sh` stops at stage
# 10, which is exactly how novi-launcher/fcft failed before it.
#
# The error it gives is worth recording, because it names the wrong
# thing. pkg-config was asked for `wayland-client fcft libnl-genl-3.0`
# in one query, and a query with ONE missing package fails as a whole:
# it reported all three as not found, and the build died on
# "wayland-client.h: No such file or directory" with wayland-client.pc
# sitting right there in the rootfs. One missing .pc file, three
# libraries blamed.
#
# --disable-cli drops nl-* tools nothing here runs.
echo ">>> Building libnl ${LIBNL_VERSION} ..."
rm -rf "${SOURCES}/libnl-${LIBNL_VERSION}"
tar -xf "${SOURCES}/libnl-${LIBNL_VERSION}.tar.gz" -C "${SOURCES}"
(
    cd "${SOURCES}/libnl-${LIBNL_VERSION}"
    ./configure --host="${TARGET_TRIPLE}" --prefix=/usr \
        --disable-static --disable-cli >/dev/null
    make -j"$(nproc)" >/dev/null
    make install DESTDIR="${ROOTFS}" >/dev/null
)
# libtool leaves .la files pointing at build-tree paths; nothing on the
# target reads them and they are a classic source of confusing link
# failures later.
rm -f "${ROOTFS}"/usr/lib/libnl*.la

# libnl builds six libraries; wpa_supplicant, iw and novi-panel link
# two of them. The other four -- route, nf, xfrm, idiag -- are 3 MB of
# netlink families nothing in this image speaks.
rm -f "${ROOTFS}"/usr/lib/libnl-route-3.so* \
      "${ROOTFS}"/usr/lib/libnl-nf-3.so* \
      "${ROOTFS}"/usr/lib/libnl-xfrm-3.so* \
      "${ROOTFS}"/usr/lib/libnl-idiag-3.so*
