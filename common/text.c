#include "text.h"

#include <stdint.h>

struct fcft_font *novi_text_load_font(const char *fontname) {
	const char *names[] = {fontname};
	return fcft_from_name(1, names, NULL);
}

/* Decodes one UTF-8 codepoint starting at *pp, advancing *pp past it.
 * Every plain-ASCII byte (0x00-0x7F) is already a valid one-byte UTF-8
 * sequence that decodes to itself, so this is a strict superset of the
 * old per-byte iteration -- every existing ASCII-only caller (the
 * panel clock, calculator operators) behaves identically. An invalid
 * lead byte or a truncated/invalid continuation byte falls back to
 * treating that one byte as a raw codepoint and resyncing from the
 * next byte, rather than aborting the whole string -- reasonable
 * degradation for malformed input, not a case this repo's own callers
 * (all real literal string constants) ever actually hit. */
static uint32_t utf8_decode(const unsigned char **pp) {
	const unsigned char *p = *pp;
	unsigned char lead = p[0];
	uint32_t cp;
	int extra;
	if (lead < 0x80) {
		*pp = p + 1;
		return lead;
	} else if ((lead & 0xE0) == 0xC0) {
		cp = lead & 0x1F;
		extra = 1;
	} else if ((lead & 0xF0) == 0xE0) {
		cp = lead & 0x0F;
		extra = 2;
	} else if ((lead & 0xF8) == 0xF0) {
		cp = lead & 0x07;
		extra = 3;
	} else {
		*pp = p + 1;
		return lead;
	}
	p++;
	for (int i = 0; i < extra; i++) {
		if ((p[0] & 0xC0) != 0x80) {
			*pp = p;
			return cp;
		}
		cp = (cp << 6) | (p[0] & 0x3F);
		p++;
	}
	*pp = p;
	return cp;
}

static int glyph_advance(struct fcft_font *font, uint32_t cp) {
	const struct fcft_glyph *glyph =
		fcft_glyph_rasterize(font, (wchar_t)cp, FCFT_SUBPIXEL_NONE);
	return glyph != NULL ? glyph->advance.x : 0;
}

int novi_text_draw(pixman_image_t *dest, struct fcft_font *font,
		int x, int baseline_y, const char *text, pixman_color_t color) {
	pixman_image_t *src = pixman_image_create_solid_fill(&color);

	const unsigned char *p = (const unsigned char *)text;
	while (*p) {
		uint32_t cp = utf8_decode(&p);
		const struct fcft_glyph *glyph =
			fcft_glyph_rasterize(font, (wchar_t)cp, FCFT_SUBPIXEL_NONE);
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

int novi_text_width(struct fcft_font *font, const char *text) {
	int x = 0;
	const unsigned char *p = (const unsigned char *)text;
	while (*p) {
		uint32_t cp = utf8_decode(&p);
		x += glyph_advance(font, cp);
	}
	return x;
}
