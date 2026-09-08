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
 */
#ifndef NOVI_THEME_H
#define NOVI_THEME_H

#include <pixman.h>
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

/* Background layers. Each a fixed step lighter than the one below, so
 * elevation reads from colour alone before any shadow is drawn. */
#define NOVI_BG_BASE        0xff0a0a0fu /* desktop, behind everything */
#define NOVI_BG_PANEL       0xff15161du /* top bar, non-floating chrome */
#define NOVI_BG_CARD        0xff1b1c26u /* floating cards, toasts, windows */
#define NOVI_BG_CARD_RAISED 0xff232430u /* a card on a card; hovered row */

/* Accent. One hue, used sparingly -- it is a signal colour, never a
 * large fill. */
#define NOVI_ACCENT          0xff2dd4bfu
#define NOVI_ACCENT_HOVER    0xff5eead4u
#define NOVI_ACCENT_ACTIVE   0xff14b8a6u /* pressed: DARKER, so it sinks in */
#define NOVI_ACCENT_SUBTLE   0xff17302cu /* wash behind a selected row */
#define NOVI_TEXT_ON_ACCENT  0xff071310u

/* Text. */
#define NOVI_TEXT_PRIMARY   0xfff2f3f7u
#define NOVI_TEXT_SECONDARY 0xffa3a7b7u
#define NOVI_TEXT_MUTED     0xff6b6f80u

/* Borders and dividers. */
#define NOVI_BORDER_SUBTLE  0xff292b35u
#define NOVI_BORDER_STRONG  0xff3a3d4au

/* Status. Deliberately no "info": accent already means notable, and a
 * second blue-ish hue beside teal would only compete with it. */
#define NOVI_STATUS_SUCCESS 0xff22c55eu
#define NOVI_STATUS_WARNING 0xfff59e0bu
#define NOVI_STATUS_ERROR   0xffef4444u

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
