/* draw_icon() -- ICON-PIPELINE.md Stage 2, the runtime half of the icon
 * pipeline. Same shape as draw_text()'s per-glyph blit: reads a fixed
 * bitmap (here, an 8-bit coverage mask instead of a 1-bit glyph) and
 * writes it into a wl_shm ARGB8888 (ownership: caller's ) buffer. Zero
 * new libraries -- plain per-pixel loops, matching draw_rect()'s own
 * style in novi-panel/main.c and novi-launcher/main.c.
 */
#ifndef NOVI_ICON_BLIT_H
#define NOVI_ICON_BLIT_H

#include <stdint.h>

#include "icons.h"

/* Composites novi_icons[icon_id] at (x, y) into px (stride_px pixels per
 * row, buf_w x buf_h pixels total -- rows fully or partially off-buffer
 * are clipped, not undefined behavior). fg_color is 0xAARRGGBB,
 * *straight* (non-premultiplied) alpha in its own alpha byte; the
 * icon's own per-pixel coverage further scales that alpha for
 * antialiased edges. px is written as premultiplied ARGB8888 (the wl_shm
 * format novi-launcher's drop-shadow/rounded-corner code already
 * produces), via a real "over" blend against whatever is already in the
 * buffer -- not a raw overwrite -- so an icon can be drawn onto
 * non-opaque backgrounds (e.g. inside a card that already carries
 * rounded-corner alpha) without clobbering them. */
void draw_icon(uint32_t *px, uint32_t stride_px, uint32_t buf_w, uint32_t buf_h,
	int x, int y, enum novi_icon_id icon_id, uint32_t fg_color);

#endif
