/* common/text.h — shared fcft+pixman text rendering for novi-shell's
 * layer-shell UI clients (novi-panel, novi-launcher).
 *
 * Replaces the earlier hand-drawn 3x5 bitmap font placeholder with
 * real, anti-aliased glyph rendering, using the exact same fcft+pixman
 * compositing pipeline foot itself uses for terminal glyphs (see
 * foot's render.c: fcft_glyph_rasterize() + pixman_image_composite32()
 * with the glyph as either a direct ARGB source, for pre-colored
 * glyphs like color emoji, or as a mask over a solid-color fill, for
 * the normal anti-aliased-coverage case). Both novi-shell UI clients
 * only ever render ASCII (digits, clock punctuation, calculator
 * operators), so the API below takes plain `const char *` and treats
 * each byte as its own codepoint -- not a general UTF-8 API.
 */
#pragma once

#include <fcft/fcft.h>
#include <pixman.h>

/* fontname is a fontconfig-style name string, e.g.
 * "JetBrains Mono:size=11" -- the same font this repo already built
 * for foot (build/09-foot.sh), so this adds no new font dependency.
 * Returns NULL on failure (logs via fcft's own logging if enabled). */
struct fcft_font *novi_text_load_font(const char *fontname);

/* Draws `ascii_text`'s baseline at (x, baseline_y) into `dest` (a
 * pixman image wrapping the caller's shm buffer) in `color`. Returns
 * the x position just past the last glyph, so callers can chain
 * multiple draws left-to-right. */
int novi_text_draw(pixman_image_t *dest, struct fcft_font *font,
	int x, int baseline_y, const char *ascii_text, pixman_color_t color);

/* Width in pixels `ascii_text` would occupy if drawn -- for
 * right-aligning text (the panel clock) without actually drawing.
 * Does not touch `dest`. */
int novi_text_width(struct fcft_font *font, const char *ascii_text);
