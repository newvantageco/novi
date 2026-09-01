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

# ── 12. libdisplay-info (EDID parsing for the DRM backend) ──────────
build_meson libdisplay-info "${LIBDISPLAY_INFO_VERSION}"

# ── 13. seatd (logind-free seat/session management) ─────────────────
#
# libseat-logind=disabled: no systemd-logind, no elogind, matching
# RFC 0001's "no systemd anywhere" decision explicitly, not just by
# omission.
build_meson seatd "${SEATD_VERSION}" \
    -Dlibseat-logind=disabled -Dlibseat-seatd=enabled -Dserver=enabled \
    -Dman-pages=disabled

# ── 14. wlroots ────────────────────────────────────────────────────
#
# First milestone is "a compositor can come up and render," not "full
# hardware acceleration" -- so this deliberately stays Mesa-free:
#   - renderers=[] : only the mandatory pixman (software) renderer
#     builds; wlroots' optional gles2/vulkan renderers are skipped.
#   - allocators=[]: only wlroots' always-built-in shm + DRM dumb-buffer
#     allocators are used; the optional gbm allocator (needs libgbm,
#     i.e. Mesa) is skipped. Confirmed by reading
#     render/allocator/meson.build directly: allocator.c, shm.c and
#     drm_dumb.c are unconditional sources, gbm.c is added only if the
#     'gbm' feature is requested.
#   - xwayland=disabled, xcb-errors=disabled: no X11 anywhere yet.
#   - backends=drm,libinput: no x11 backend (nested-in-X11 testing
#     backend, irrelevant here).
# hwdata (native-only, a build-time PCI/USB ID data lookup) and
# libdisplay-info (a real target dependency, built just above) were
# both missing on the first configure attempt -- added after reading
# the actual meson.build dependency() calls, not guessed.
build_meson wlroots "${WLROOTS_VERSION}" \
    -Drenderers=[] -Dbackends=drm,libinput -Dallocators=[] \
    -Dxwayland=disabled -Dexamples=false -Dcolor-management=disabled \
    -Dlibliftoff=disabled -Dxcb-errors=disabled

# ── 15. xkeyboard-config (runtime keyboard layout database) ───────
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
