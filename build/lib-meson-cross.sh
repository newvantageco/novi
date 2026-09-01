# ============================================================
# lib-meson-cross.sh — shared meson/autotools cross-compilation
# scaffolding for musl/x86_64 target packages.
#
# Sourced (not executed) by any build/*.sh stage that cross-compiles
# meson- or autotools-based packages against the target rootfs --
# originally written for build/06-wayland.sh's 15-package wlroots
# stack, factored out here once build/09-foot.sh needed the exact same
# scaffolding for its own font-rendering dependency chain, rather than
# duplicate it a second time.
#
# Requires 00-versions.sh already sourced (BUILD_DIR/SOURCES/TOOLS/
# ROOTFS/TARGET_TRIPLE) before this file is sourced.
# ============================================================

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

[built-in options]
# The static linker only consults -L when resolving a DIRECTLY named
# -l<lib> -- never for a shared library's own transitive DT_NEEDED
# entries (confirmed twice now: novi-launcher linking against
# libwayland-client.so, which itself needs libffi; fontconfig's own
# fc-cache linking against the libfontconfig.so this same build just
# produced, which itself needs libfreetype/libexpat). -rpath-link is
# the linker's actual purpose-built mechanism for this -- point it at
# the rootfs's lib dir globally here so every future meson-cross build
# gets this for free, rather than rediscovering and patching around it
# package by package.
c_link_args = ['-Wl,-rpath-link,${ROOTFS}/usr/lib']
cpp_link_args = ['-Wl,-rpath-link,${ROOTFS}/usr/lib']
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

# meson-built packages that just need a --prefix and a handful of
# feature flags to disable -- one helper for the common shape,
# packages needing a nonstandard extracted-directory name (libdrm's
# GitLab archive expands to "libdrm-libdrm-<version>-<hash>/", not
# "libdrm-<version>/", when the ref doesn't resolve to a plain tag
# name; codeberg.org (Forgejo) archives expand to a bare "<name>/"
# with no version suffix at all -- both confirmed by actually listing
# the tarball's contents) pass their own extracted dir via -d.
#
# -p 'shell command' (optional, evaluated in the extracted source dir
# right after extraction, before configure) mirrors build_skarnet()'s
# existing patch-eval argument in build/04-s6.sh -- for the same
# reason: a pinned version pairing can turn up a real, narrow
# incompatibility (confirmed live: foot 1.9.2's exhaustive switch over
# enum xdg_toplevel_state predates XDG_TOPLEVEL_STATE_SUSPENDED, which
# this repo's newer wayland-protocols now generates, and foot compiles
# with -Werror) that's better fixed with a small source patch than by
# bumping versions across an unrelated stack or disabling warnings
# wholesale.
build_meson() {
    local name="$1" version="$2"
    local dir="${name}-${version}"
    shift 2
    if [ "${1:-}" = "-d" ]; then
        dir="$2"
        shift 2
    fi
    local patch=""
    if [ "${1:-}" = "-p" ]; then
        patch="$2"
        shift 2
    fi
    echo "==> Building ${name}-${version}"
    cd "${SOURCES}"
    rm -rf "${dir}"
    tar -xf "${name}-${version}.tar.gz"
    cd "${dir}"
    if [ -n "${patch}" ]; then
        eval "${patch}"
    fi
    meson_cross build --prefix=/usr "$@"
    ninja -C build
    DESTDIR="${ROOTFS}" ninja -C build install
    echo "   done: ${name}"
}
