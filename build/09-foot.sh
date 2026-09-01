#!/bin/bash
# ============================================================
# 09-foot.sh — Build foot, the default terminal (RFC 0001 decision 6)
#
# foot is a small wlroots-native Wayland terminal with no GTK/Qt
# dependency chain -- but it does need REAL font rendering, which
# nothing else in this repo has needed before now: freetype, fontconfig,
# fcft (the font-loading/rasterizing library, by foot's own author),
# tllist (a header-only typed linked list, also used by fcft), and an
# actual font to point fontconfig at.
#
# Run after build/06-wayland.sh (needs pixman, wayland-client,
# wayland-cursor, xkbcommon, and this script's own cross-compilation
# scaffolding, shared via lib-meson-cross.sh) and build/07-novi-shell.sh
# (novi-shell's Super+Return keybinding is what spawns this).
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-versions.sh"
source "${SCRIPT_DIR}/lib-meson-cross.sh"

command -v chroot >/dev/null 2>&1 || { echo "ERROR: chroot not found (needed for fc-cache)" >&2; exit 1; }
command -v unzip >/dev/null 2>&1 || { echo "ERROR: unzip not found (needed to unpack the font)" >&2; exit 1; }

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

# ── 5. JetBrains Mono (default terminal font) ────────────────────────
#
# OFL-1.1 licensed (fully redistributable). Only the four weights a
# terminal actually uses (regular/bold/italic/bold-italic) are
# extracted from the release zip -- not the variable-width family, the
# non-cascading "NL" variants, or the extra weight steps that ship
# alongside them.
echo "==> Installing JetBrains Mono font"
FONT_DIR="${ROOTFS}/usr/share/fonts/jetbrains-mono"
mkdir -p "${FONT_DIR}"
cd "${SOURCES}"
rm -rf jetbrains-mono-extract
mkdir jetbrains-mono-extract
unzip -q -o "jetbrains-mono-${JETBRAINS_MONO_VERSION}.zip" \
    "fonts/ttf/JetBrainsMono-Regular.ttf" \
    "fonts/ttf/JetBrainsMono-Bold.ttf" \
    "fonts/ttf/JetBrainsMono-Italic.ttf" \
    "fonts/ttf/JetBrainsMono-BoldItalic.ttf" \
    -d jetbrains-mono-extract
cp jetbrains-mono-extract/fonts/ttf/*.ttf "${FONT_DIR}/"
echo "   done: JetBrains Mono ($(ls "${FONT_DIR}" | wc -l) files)"

# ── 6. Build the fontconfig cache, chrooted ──────────────────────────
#
# fc-cache reads /etc/fonts/fonts.conf and scans the ABSOLUTE paths it
# names (e.g. /usr/share/fonts) -- running the freshly cross-compiled
# TARGET fc-cache binary un-chrooted (the same-arch musl-loader trick
# build/04-s6.sh's run_target() uses elsewhere) would resolve those
# paths against THIS BUILD HOST's real root, not the rootfs, either
# finding nothing or (worse) caching the host's own installed fonts.
# chroot makes /usr/share/fonts inside the chroot actually mean
# ${ROOTFS}/usr/share/fonts, which is what's needed here.
echo "==> Building fontconfig cache (chrooted)"
chroot "${ROOTFS}" /usr/bin/fc-cache -fv
echo ""
echo "Installed fonts (chrooted fc-list):"
chroot "${ROOTFS}" /usr/bin/fc-list
echo ""
echo "Default monospace match (chrooted fc-match monospace):"
chroot "${ROOTFS}" /usr/bin/fc-match monospace

# ── 7. foot ───────────────────────────────────────────────────────────
#
# foot 1.9.2's xdg_toplevel_configure() has an exhaustive switch (no
# default: case) over enum xdg_toplevel_state, written before the
# xdg-shell protocol added XDG_TOPLEVEL_STATE_SUSPENDED -- but this
# repo's wayland-protocols (1.37, pinned in build/06-wayland.sh) is new
# enough to generate that enum value, and foot compiles with -Werror.
# Confirmed live: the build failed with "enumeration value
# 'XDG_TOPLEVEL_STATE_SUSPENDED' not handled in switch
# [-Werror=switch]". Patched narrowly (add the missing case, matching
# every other state foot doesn't act on: no-op) rather than disabling
# -Werror wholesale, which would also hide any other, unrelated
# warning-class bug the same build might turn up.
build_meson foot "${FOOT_VERSION}" -d foot \
    -p "sed -i '/case XDG_TOPLEVEL_STATE_RESIZING:/a\\        case XDG_TOPLEVEL_STATE_SUSPENDED:    break;' wayland.c" \
    -Dgrapheme-clustering=disabled -Dime=true -Ddocs=disabled

echo ""
echo "foot installed:"
ls -la "${ROOTFS}/usr/bin/foot"
