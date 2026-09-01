#include "text.h"

struct fcft_font *novi_text_load_font(const char *fontname) {
	const char *names[] = {fontname};
	return fcft_from_name(1, names, NULL);
}

static int glyph_advance(struct fcft_font *font, unsigned char ch) {
	const struct fcft_glyph *glyph =
		fcft_glyph_rasterize(font, (wchar_t)ch, FCFT_SUBPIXEL_NONE);
	return glyph != NULL ? glyph->advance.x : 0;
}

int novi_text_draw(pixman_image_t *dest, struct fcft_font *font,
		int x, int baseline_y, const char *ascii_text, pixman_color_t color) {
	pixman_image_t *src = pixman_image_create_solid_fill(&color);

	for (const unsigned char *c = (const unsigned char *)ascii_text; *c; c++) {
		const struct fcft_glyph *glyph =
			fcft_glyph_rasterize(font, (wchar_t)*c, FCFT_SUBPIXEL_NONE);
		if (glyph == NULL) {
			continue;
		}

		int gx = x + glyph->x;
		int gy = baseline_y - glyph->y;

		/* A pre-colored glyph (e.g. a color emoji) carries its own
		 * ARGB pixels and is composited directly; the normal case is
		 * a grayscale anti-aliased coverage mask, composited as the
		 * mask argument over a solid fill in `color` -- exactly
		 * foot's own render.c glyph-drawing branch. */
		if (pixman_image_get_format(glyph->pix) == PIXMAN_a8r8g8b8) {
			pixman_image_composite32(PIXMAN_OP_OVER, glyph->pix, NULL, dest,
				0, 0, 0, 0, gx, gy, glyph->width, glyph->height);
		} else {
			pixman_image_composite32(PIXMAN_OP_OVER, src, glyph->pix, dest,
				0, 0, 0, 0, gx, gy, glyph->width, glyph->height);
		}

		x += glyph->advance.x;
	}

	pixman_image_unref(src);
	return x;
}

int novi_text_width(struct fcft_font *font, const char *ascii_text) {
	int x = 0;
	for (const unsigned char *c = (const unsigned char *)ascii_text; *c; c++) {
		x += glyph_advance(font, *c);
	}
	return x;
}
