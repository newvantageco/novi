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

# ── Font libraries: NOT here any more ────────────────────────────────
#
# freetype, fontconfig, tllist and fcft used to be built in this stage.
# They moved to 06-wayland.sh, and that is a correctness fix rather than
# tidying: novi-launcher (stage 08) and novi-panel (stage 10) both link
# fcft, and both run BEFORE this stage. novi-launcher's own Makefile
# said "all already built for foot (build/09-foot.sh), no new
# dependency" -- true in a tree where stage 09 had run at some point in
# the past, false in build order. A genuinely clean `bash build.sh`
# stopped at stage 08 with `cannot find -lfcft`.
#
# It survived because nobody had built this project from an empty
# /build in a long time, and CI's "Build & Test" job validates sources
# and manifests without compiling anything.

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

# ── 5b. Inter (the UI sans) ──────────────────────────────────────────
#
# RFC 0025. GUI-DESIGN-LANGUAGE.md §2 specified a proportional UI face
# in September 2026 -- "a monospace UI reads as a terminal wearing a
# costume, not a desktop" -- recommended Inter, and explicitly deferred
# actually adding it. Every client shipped with JetBrains Mono for its
# labels in the meantime, which is exactly the costume the doc warned
# about.
#
# STATIC WEIGHTS, not the variable font the doc recommended, and the
# divergence is deliberate. InterVariable.ttf is one 880 KB file
# against three static files at ~1.2 MB, which is not a difference
# worth caring about -- but selecting a weight out of a variable font
# depends on fontconfig's named-instance handling, and a build where
# that silently does not work gives you Regular everywhere with no
# error to notice. Three static files match by weight the way
# JetBrains Mono's four already do, through a code path this image has
# been exercising since it had a terminal.
#
# Regular/Medium/SemiBold are the three the type scale in §2 names
# (body/caption at 400, display at 500, title at 600). Nothing in this
# UI is italic, and for the desktop's own clients that is still true.
#
# THE ITALICS ARE HERE FOR THE BROWSER (RFC 0031). A web page is not
# this UI: `<em>`, citations and titles are italic constantly, and
# with no italic face NetSurf rendered every one of them identically
# to body text -- so emphasis, which is the whole point of the markup,
# was INVISIBLE. That is a correctness problem in a browser rather
# than a matter of taste, which is why two more faces are worth
# ~840 KB.
#
# SemiBoldItalic rather than BoldItalic, to match the upright bold:
# 35-devtools.sh maps NETSURF_FB_FONT_SANS_SERIF_BOLD to
# Inter-SemiBold because SemiBold is what NOVI_FONT_TITLE uses.
echo "==> Installing Inter ${INTER_VERSION} (UI sans)"
INTER_DIR="${ROOTFS}/usr/share/fonts/inter"
mkdir -p "${INTER_DIR}"
cd "${SOURCES}"
rm -rf inter-extract
mkdir inter-extract
unzip -q -o "inter-${INTER_VERSION}.zip" \
    "extras/ttf/Inter-Regular.ttf" \
    "extras/ttf/Inter-Medium.ttf" \
    "extras/ttf/Inter-SemiBold.ttf" \
    "extras/ttf/Inter-Italic.ttf" \
    "extras/ttf/Inter-SemiBoldItalic.ttf" \
    -d inter-extract
cp inter-extract/extras/ttf/*.ttf "${INTER_DIR}/"
echo "   done: Inter ($(ls "${INTER_DIR}" | wc -l) files)"

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
echo ""
# Checked, not assumed: every client asks for "Inter" by name, and a
# fontconfig that cannot find it answers with whatever it does have --
# silently, and the UI comes up in the wrong face with nothing to say
# why.
echo "UI sans match (chrooted fc-match Inter):"
chroot "${ROOTFS}" /usr/bin/fc-match Inter
chroot "${ROOTFS}" /usr/bin/fc-match "Inter:weight=semibold"

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

# ── 8. Register foot as a launchable GUI app ─────────────────────────
#
# packages/pkg-format.md's "GUI Application Registration" convention:
# novi-launcher (Alt+Space) scans usr/share/novi/apps/*.app for
# launchable apps. foot isn't pkg-installed (it's baked into the base
# rootfs right here, not a .pkg.tar.gz), so its descriptor is written
# directly instead of shipped in a package -- but the file format and
# the directory novi-launcher scans are exactly what a real package
# would use.
echo "==> Registering foot as a launchable GUI app"
APPS_DIR="${ROOTFS}/usr/share/novi/apps"
mkdir -p "${APPS_DIR}"
cat > "${APPS_DIR}/foot.app" <<'EOF'
name=Terminal
exec=/usr/bin/foot
icon=terminal
description=foot terminal emulator
EOF
echo "   done: ${APPS_DIR}/foot.app"
