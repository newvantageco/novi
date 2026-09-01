#include "icon_blit.h"

void draw_icon(uint32_t *px, uint32_t stride_px, uint32_t buf_w, uint32_t buf_h,
	int x, int y, enum novi_icon_id icon_id, uint32_t fg_color) {
	if (icon_id < 0 || icon_id >= NOVI_ICON_COUNT) return;
	const struct novi_icon *icon = &novi_icons[icon_id];

	uint32_t fg_a = (fg_color >> 24) & 0xff;
	uint32_t fg_r = (fg_color >> 16) & 0xff;
	uint32_t fg_g = (fg_color >> 8) & 0xff;
	uint32_t fg_b = fg_color & 0xff;

	for (uint32_t iy = 0; iy < icon->h; iy++) {
		int py = y + (int)iy;
		if (py < 0 || py >= (int)buf_h) continue;
		for (uint32_t ix = 0; ix < icon->w; ix++) {
			int pxx = x + (int)ix;
			if (pxx < 0 || pxx >= (int)buf_w) continue;

			uint32_t coverage = icon->coverage[iy * icon->w + ix];
			if (coverage == 0) continue;

			/* Effective straight alpha of this source pixel: the
			 * caller's fg alpha scaled by how much of this pixel the
			 * icon shape actually covers (nanosvg's own antialiasing,
			 * carried straight through from svg2icon). */
			uint32_t src_a = (fg_a * coverage) / 255;
			if (src_a == 0) continue;

			/* Premultiply for the "over" blend, same convention
			 * novi-launcher's apply_rounded_corners()/draw_shadow()
			 * already use for this buffer format. */
			uint32_t src_pr = (fg_r * src_a) / 255;
			uint32_t src_pg = (fg_g * src_a) / 255;
			uint32_t src_pb = (fg_b * src_a) / 255;

			uint32_t *dst = &px[py * (int)stride_px + pxx];
			uint32_t dst_a = (*dst >> 24) & 0xff;
			uint32_t dst_r = (*dst >> 16) & 0xff;
			uint32_t dst_g = (*dst >> 8) & 0xff;
			uint32_t dst_b = *dst & 0xff;

			uint32_t inv_src_a = 255 - src_a;
			uint32_t out_a = src_a + (dst_a * inv_src_a) / 255;
			uint32_t out_r = src_pr + (dst_r * inv_src_a) / 255;
			uint32_t out_g = src_pg + (dst_g * inv_src_a) / 255;
			uint32_t out_b = src_pb + (dst_b * inv_src_a) / 255;

			*dst = (out_a << 24) | (out_r << 16) | (out_g << 8) | out_b;
		}
	}
}
