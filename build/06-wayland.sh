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

echo ""
echo "Wayland core installed. Libraries:"
find "${ROOTFS}/usr/lib" -maxdepth 1 -iname "libwayland*"
