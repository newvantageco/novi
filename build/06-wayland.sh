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

NPROC=$(nproc)
CROSS_FILE="${BUILD_DIR}/meson-cross-${TARGET_TRIPLE}.ini"
NATIVE_PREFIX="${TOOLS}/native"

command -v meson >/dev/null 2>&1 || { echo "ERROR: meson not found (pip install meson)" >&2; exit 1; }
command -v ninja >/dev/null 2>&1 || { echo "ERROR: ninja not found" >&2; exit 1; }

# ── Cross-compilation scaffolding ─────────────────────────────────
#
# pkg-config wrapper: search ONLY the target rootfs's .pc files, never
# the host's -- PKG_CONFIG_SYSROOT_DIR rewrites -I/-L paths in those
# .pc files against the rootfs, since they're written as if installed
# at "/usr/..." on the real (target) root.
mkdir -p "${TOOLS}/bin"
cat > "${TOOLS}/bin/${TARGET_TRIPLE}-pkg-config" <<WRAP
#!/bin/sh
export PKG_CONFIG_DIR=
export PKG_CONFIG_LIBDIR="${ROOTFS}/usr/lib/pkgconfig:${ROOTFS}/usr/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="${ROOTFS}"
exec pkg-config "\$@"
WRAP
chmod +x "${TOOLS}/bin/${TARGET_TRIPLE}-pkg-config"

# exe_wrapper: lets meson/autotools run TARGET (musl/x86_64) binaries
# during configure-time feature checks. Target arch == this build
# host's arch, so musl's own loader can run them directly (it doubles
# as its own ld.so) -- no QEMU user-mode emulation needed.
cat > "${TOOLS}/bin/${TARGET_TRIPLE}-exe-wrapper" <<WRAP
#!/bin/sh
export LD_LIBRARY_PATH="${ROOTFS}/usr/lib:\${LD_LIBRARY_PATH:-}"
exec "${ROOTFS}/lib/ld-musl-x86_64.so.1" "\$@"
WRAP
chmod +x "${TOOLS}/bin/${TARGET_TRIPLE}-exe-wrapper"

cat > "${CROSS_FILE}" <<CROSS
[binaries]
c = '${TARGET_TRIPLE}-gcc'
cpp = '${TARGET_TRIPLE}-g++'
ar = '${TARGET_TRIPLE}-ar'
strip = '${TARGET_TRIPLE}-strip'
ranlib = '${TARGET_TRIPLE}-ranlib'
pkg-config = '${TARGET_TRIPLE}-pkg-config'
exe_wrapper = '${TARGET_TRIPLE}-exe-wrapper'

[host_machine]
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'

[properties]
sys_root = '${ROOTFS}'
CROSS

meson_cross() {
    meson setup "$@" --cross-file "${CROSS_FILE}"
}

# autotools packages (libffi, expat, mtdev) all follow the same
# configure/make/make-install shape; --libdir=/usr/lib is not the
# default on every one of these (libffi in particular defaults to a
# GCC-runtime-style ${libdir}/../lib64 split via
# --enable-multi-os-directory, confirmed by an actual build landing in
# /build/rootfs/usr/lib64 -- musl's dynamic linker has no lib64
# convention and would never find it there at runtime) -- pin it
# explicitly everywhere rather than trust each project's default.
build_autotools() {
    local name="$1" version="$2"
    shift 2
    echo "==> Building ${name}-${version}"
    cd "${SOURCES}"
    rm -rf "${name}-${version}"
    tar -xf "${name}-${version}.tar.gz"
    cd "${name}-${version}"
    ./configure \
        --host="${TARGET_TRIPLE}" \
        --prefix=/usr \
        --libdir=/usr/lib \
        "$@"
    make -j"${NPROC}"
    make DESTDIR="${ROOTFS}" install
    echo "   done: ${name}"
}

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


# meson-built packages that just need a --prefix and a handful of
# feature flags to disable -- one helper for the common shape,
# packages needing a nonstandard extracted-directory name (libdrm's
# GitLab archive expands to "libdrm-libdrm-<version>-<hash>/", not
# "libdrm-<version>/", when the ref doesn't resolve to a plain tag
# name -- confirmed by actually listing the tarball's contents) pass
# their own extracted dir via -d.
build_meson() {
    local name="$1" version="$2"
    local dir="${name}-${version}"
    shift 2
    if [ "${1:-}" = "-d" ]; then
        dir="$2"
        shift 2
    fi
    echo "==> Building ${name}-${version}"
    cd "${SOURCES}"
    rm -rf "${dir}"
    tar -xf "${name}-${version}.tar.gz"
    cd "${dir}"
    meson_cross build --prefix=/usr "$@"
    ninja -C build
    DESTDIR="${ROOTFS}" ninja -C build install
    echo "   done: ${name}"
}

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
build_meson libxkbcommon "${LIBXKBCOMMON_VERSION}" \
    -Denable-x11=false -Denable-tools=false -Denable-wayland=false \
    -Denable-docs=false -Denable-bash-completion=false \
    -Denable-xkbregistry=false

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

echo ""
echo "Wayland/wlroots stack installed. Libraries:"
find "${ROOTFS}/usr/lib" -maxdepth 1 -iname "libwlroots*" -o -iname "libseat*" -o -iname "libinput*"
