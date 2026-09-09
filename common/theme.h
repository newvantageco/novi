/* common/theme.h — the design tokens, in one place.
 *
 * docs/design/GUI-DESIGN-LANGUAGE.md §1-§3, as C constants. That
 * document has been the adopted reference since September 2026 and
 * every client was nonetheless carrying its own hex literals:
 * novi-panel called the card background 0xff232430, novi-files called
 * it 0xff232430 too, novi-notifyd called it 0xff1b1b26, and nothing
 * connected any of them to the token they were all trying to be. A
 * palette copied into six files is a palette that drifts, and it had.
 *
 * TWO REPRESENTATIONS OF EVERY COLOUR, because this codebase draws in
 * two ways and always will: raw ARGB8888 written into the shm buffer
 * (rectangles, icon tints) and pixman_color_t (text, via fcft). They
 * are generated from the same hex digits by macro so a token cannot be
 * updated in one form and not the other.
 *
 * NOVI_PIX() expands the 8-bit channels to pixman's 16-bit ones by
 * replication (0xA3 -> 0xA3A3), not by shifting left 8 (0xA300).
 * Replication is what maps 0xFF to 0xFFFF -- a left shift maps it to
 * 0xFF00, so pure white would come out 0.4% grey and full alpha would
 * be very slightly transparent. Several of the hand-written
 * pixman_color_t literals in this repo had exactly that shift in them.
 *
 * ── THE COLOURS ARE RUNTIME NOW; EVERYTHING ELSE IS NOT ────────────
 *
 * RFC 0030. Each colour token reads a field of `novi_theme`, a struct
 * a client fills from a theme file at startup (novi_theme_load()).
 * Type, spacing and radius stay compile-time constants, deliberately:
 * a theme that can move a 12px gap to 11 is a theme that can break a
 * layout, and §3 of the design language exists precisely to stop ad
 * hoc numbers. What a theme may change is what a theme is for --
 * colour.
 *
 * The struct is initialised with the palette below, so a client that
 * never calls novi_theme_load(), or one whose theme file is missing or
 * unreadable, draws exactly what it drew before. There is no state in
 * which this system has no colours.
 *
 * The cost is that a token is no longer a constant expression, so
 * `static const pixman_color_t X = NOVI_PIX(TOKEN);` at file scope no
 * longer compiles. Those became `#define X NOVI_PIX(TOKEN)` -- a
 * compound literal evaluated at each use, which is what they always
 * morally were. Do not reintroduce a file-scope `static const`
 * initialised from a token; the compiler will tell you, but the
 * message ("initializer element is not constant") does not explain
 * itself.
 */
#ifndef NOVI_THEME_H
#define NOVI_THEME_H

#include <pixman.h>
#include <stdbool.h>
#include <stdint.h>

#define NOVI_R(c) (((c) >> 16) & 0xff)
#define NOVI_G(c) (((c) >> 8) & 0xff)
#define NOVI_B(c) ((c) & 0xff)
#define NOVI_EXPAND(v) ((uint16_t)((v) * 0x101))

/* A pixman_color_t for any 0xAARRGGBB token, opaque. */
#define NOVI_PIX(c) ((pixman_color_t){ \
	.red   = NOVI_EXPAND(NOVI_R(c)), \
	.green = NOVI_EXPAND(NOVI_G(c)), \
	.blue  = NOVI_EXPAND(NOVI_B(c)), \
	.alpha = 0xffff })

/* ── §1 Colour ─────────────────────────────────────────────────── */

/* One field per token. The names match the theme-file keys exactly
 * (bg.base <-> bg_base), so the loader is a table and not a switch
 * with twenty branches -- see common/theme.c. */
struct novi_palette {
	/* Background layers. Each a fixed step lighter than the one
	 * below, so elevation reads from colour alone before any shadow
	 * is drawn. */
	uint32_t bg_base;         /* desktop, behind everything */
	uint32_t bg_panel;        /* top bar, non-floating chrome */
	uint32_t bg_card;         /* floating cards, toasts, windows */
	uint32_t bg_card_raised;  /* a card on a card; hovered row */

	/* Accent. One hue, used sparingly -- it is a signal colour,
	 * never a large fill. */
	uint32_t accent;
	uint32_t accent_hover;
	uint32_t accent_active;   /* pressed: DARKER, so it sinks in */
	uint32_t accent_subtle;   /* wash behind a selected row */
	uint32_t text_on_accent;

	/* Text. */
	uint32_t text_primary;
	uint32_t text_secondary;
	uint32_t text_muted;

	/* Borders and dividers. */
	uint32_t border_subtle;
	uint32_t border_strong;

	/* Status. Deliberately no "info": accent already means notable,
	 * and a second blue-ish hue beside teal would only compete. */
	uint32_t status_success;
	uint32_t status_warning;
	uint32_t status_error;
};

/* The live palette. Defined in common/theme.c, pre-filled with the
 * design language's own values, overwritten in place by
 * novi_theme_load(). */
extern struct novi_palette novi_theme;

/* Read the active theme and overwrite `novi_theme`.
 *
 * Never fails and never partially applies a broken file: it parses
 * into a copy and commits only if the file was readable. Call it once,
 * early in main(), BEFORE anything computes a colour. Returns the name
 * of the theme that was applied, or NULL if the built-in defaults are
 * still in force -- clients need not check, and the return exists so a
 * tool can report which theme is live. */
const char *novi_theme_load(void);

/* Reload only if the published theme has CHANGED since the last call.
 *
 * Returns true if the palette was replaced, so a caller that repaints
 * on a timer can do `if (novi_theme_reload()) redraw();` without
 * re-parsing a file every tick. The check is one stat(2); the parse
 * happens only on a real change.
 *
 * This is what makes a theme switch visible on a long-lived surface
 * (the panel, the background) without restarting it. Everything else
 * still picks the palette up when it next starts -- a window that
 * repaints only on input has nowhere to hang this. */
bool novi_theme_reload(void);

/* Load a NAMED theme into `out` without touching the live palette.
 *
 * `out` starts from the BUILT-IN palette, so a theme file naming only
 * three colours still yields a complete one, and reading theme X gives
 * the same answer whichever theme happens to be running. Returns true
 * if the file was readable.
 *
 * This exists for a picker. Showing a list of theme NAMES is not
 * showing a person their themes, and the only way to draw a swatch of
 * one you are not running is to read it. */
bool novi_theme_read(const char *name, struct novi_palette *out);

/* Where the active theme's name is published, by novi-state's
 * converger for display.theme. A file rather than an environment
 * variable, for the same reason the network interface and the health
 * verdict are files (RFC 0009, RFC 0014): a client that starts later
 * has to be able to find out. */
#define NOVI_THEME_ACTIVE "/run/novi/theme"
/* The palette compiled into common/theme.c, by name. It is here so
 * that the ONE place that knows "the built-in colours are axiom's" is
 * this header: a picker showing which theme is live has to be able to
 * say so on a machine where display.theme was never declared and
 * nothing was ever published, and the alternative is that name
 * appearing a second time inside the picker. */
#define NOVI_THEME_DEFAULT "axiom"
#define NOVI_THEME_DIR    "/usr/share/novi/themes"

#define NOVI_BG_BASE        (novi_theme.bg_base)
#define NOVI_BG_PANEL       (novi_theme.bg_panel)
#define NOVI_BG_CARD        (novi_theme.bg_card)
#define NOVI_BG_CARD_RAISED (novi_theme.bg_card_raised)

#define NOVI_ACCENT          (novi_theme.accent)
#define NOVI_ACCENT_HOVER    (novi_theme.accent_hover)
#define NOVI_ACCENT_ACTIVE   (novi_theme.accent_active)
#define NOVI_ACCENT_SUBTLE   (novi_theme.accent_subtle)
#define NOVI_TEXT_ON_ACCENT  (novi_theme.text_on_accent)

#define NOVI_TEXT_PRIMARY   (novi_theme.text_primary)
#define NOVI_TEXT_SECONDARY (novi_theme.text_secondary)
#define NOVI_TEXT_MUTED     (novi_theme.text_muted)

#define NOVI_BORDER_SUBTLE  (novi_theme.border_subtle)
#define NOVI_BORDER_STRONG  (novi_theme.border_strong)

#define NOVI_STATUS_SUCCESS (novi_theme.status_success)
#define NOVI_STATUS_WARNING (novi_theme.status_warning)
#define NOVI_STATUS_ERROR   (novi_theme.status_error)

/* ── §2 Type ───────────────────────────────────────────────────────
 *
 * Inter for anything a person reads as language; JetBrains Mono only
 * for things that are literally machine output -- a path, a command, a
 * log line, a size in bytes. That split is the whole point of adding a
 * second family, so resist widening the mono side.
 *
 * The `:weight=` values are fontconfig's own names, matched against
 * the three static Inter faces build/09-foot.sh installs. Asking for a
 * weight that is not installed does not fail: fontconfig substitutes
 * the nearest, which is why only 400/500/600 are named here.
 */
#define NOVI_FONT_DISPLAY "Inter:weight=medium:size=15"   /* launcher input */
#define NOVI_FONT_TITLE   "Inter:weight=semibold:size=14" /* card + window titles */
#define NOVI_FONT_BODY    "Inter:size=13"                 /* default UI text */
#define NOVI_FONT_CAPTION "Inter:size=12"                 /* clock, metadata */
#define NOVI_FONT_MONO    "JetBrains Mono:size=13"        /* paths, sizes, output */
#define NOVI_FONT_MONO_SM "JetBrains Mono:size=11"

/* ── §3 Spacing and radius ─────────────────────────────────────────
 *
 * One 4px-rooted scale for every padding, margin and gap. No ad hoc
 * numbers -- an 11 or a 14 in a layout is how a grid stops being one.
 */
#define NOVI_SP_XS  4
#define NOVI_SP_SM  8
#define NOVI_SP_MD  12
#define NOVI_SP_LG  16
#define NOVI_SP_XL  24
#define NOVI_SP_2XL 32

/* Radius tracks element size rather than being one number. */
#define NOVI_RADIUS_SM  6.0  /* chips, status pills */
#define NOVI_RADIUS_MD  8.0  /* icon buttons, inputs, single-line controls */
#define NOVI_RADIUS_LG 12.0  /* cards, the launcher panel, toasts, windows */

/* A comfortable list row for 13px body text: 4px above and below the
 * line box, which lands on the 4px scale and leaves room for a 16px
 * icon without the row growing to fit it. */
#define NOVI_ROW_H 28

#endif
