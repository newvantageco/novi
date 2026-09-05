/* Shared icon data, consumed by novi-shell, novi-panel, and novi-launcher
 * (ICON-PIPELINE.md's Stage 2). Hand-authored and stable: the enum below
 * is the contract svg2icon's JOBS table (tools/svg2icon/svg2icon.c) must
 * stay in sync with, and icons_generated.c (Stage 1 output -- do not
 * hand-edit that file) defines novi_icons[] against it.
 *
 * Deliberately excludes ICON_LAYOUT_GRID (the apps button): per
 * ICON-PIPELINE.md's "First icon shipped" section, that one stays a
 * hand-coded parametric shape in novi-panel/main.c, not part of this
 * SVG-sourced set.
 */
#ifndef NOVI_ICONS_H
#define NOVI_ICONS_H

#include <stdint.h>

enum novi_icon_id {
	ICON_TERMINAL,       /* app-grid: foot */
	ICON_FOLDER,         /* app-grid: files */
	ICON_GLOBE,          /* app-grid: web */
	ICON_PENCIL,         /* app-grid: editor */
	ICON_FILE,           /* files: a plain file */
	ICON_IMAGE,          /* files: a file the viewer can open */
	ICON_PACKAGE,        /* app-grid: pkg */
	ICON_SETTINGS,       /* app-grid: settings */
	ICON_SHIELD,         /* app-grid: security tools */
	ICON_WIFI,           /* status bar */
	ICON_BATTERY,        /* status bar */
	ICON_POWER,          /* status bar */
	ICON_CHEVRON_RIGHT,  /* disclosure, collapsed */
	ICON_CHEVRON_DOWN,   /* disclosure, expanded */
	NOVI_ICON_COUNT,
};

/* coverage is w*h bytes, row-major, one byte per pixel: 0 = fully
 * transparent, 255 = fully covered. Colorless by design -- draw_icon()
 * (icon_blit.h) applies the caller's own fg_color, the same split
 * draw_text() already has between glyph shape and rendered color. */
struct novi_icon {
	uint32_t w;
	uint32_t h;
	const uint8_t *coverage;
};

extern const struct novi_icon novi_icons[NOVI_ICON_COUNT];

#endif
