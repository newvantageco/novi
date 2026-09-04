/* common/text.h — shared fcft+pixman text rendering for novi-shell's
 * layer-shell UI clients (novi-panel, novi-launcher).
 *
 * Replaces the earlier hand-drawn 3x5 bitmap font placeholder with
 * real, anti-aliased glyph rendering, using the exact same fcft+pixman
 * compositing pipeline foot itself uses for terminal glyphs (see
 * foot's render.c: fcft_glyph_rasterize() + pixman_image_composite32()
 * with the glyph as either a direct ARGB source, for pre-colored
 * glyphs like color emoji, or as a mask over a solid-color fill, for
 * the normal anti-aliased-coverage case).
 *
 * Takes real UTF-8 `const char *`, not just ASCII: novi-launcher's
 * symbol picker (--symbols) needs actual multi-byte codepoints (e.g.
 * U+2192 "->", a real 3-byte UTF-8 sequence) rendered as one glyph
 * each, not as mojibake from three separate byte-as-codepoint draws --
 * confirmed live in QEMU as a real, visible bug before this was UTF-8
 * aware. Every plain-ASCII caller (the panel clock, calculator
 * operators) is unaffected: ASCII bytes are already valid one-byte
 * UTF-8 sequences that decode to themselves.
 */
#pragma once

#include <fcft/fcft.h>
#include <pixman.h>

/* fontname is a fontconfig-style name string, e.g.
 * "JetBrains Mono:size=11" -- the same font this repo already built
 * for foot (build/09-foot.sh), so this adds no new font dependency.
 * Returns NULL on failure (logs via fcft's own logging if enabled). */
struct fcft_font *novi_text_load_font(const char *fontname);

/* Draws `text`'s (real UTF-8) baseline at (x, baseline_y) into `dest`
 * (a pixman image wrapping the caller's shm buffer) in `color`.
 * Returns the x position just past the last glyph, so callers can
 * chain multiple draws left-to-right. */
int novi_text_draw(pixman_image_t *dest, struct fcft_font *font,
	int x, int baseline_y, const char *text, pixman_color_t color);

/* Width in pixels `text` (real UTF-8) would occupy if drawn -- for
 * right-aligning text (the panel clock) without actually drawing.
 * Does not touch `dest`. */
int novi_text_width(struct fcft_font *font, const char *text);
