/* decoration.c — see decoration.h. */
#define _GNU_SOURCE
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <drm_fourcc.h>
#include <pixman.h>
#include <wlr/interfaces/wlr_buffer.h>
#include <wlr/types/wlr_buffer.h>
#include <wlr/types/wlr_scene.h>

#include "decoration.h"
#include "../common/text.h"
#include "../common/theme.h"

#define TITLE_MAX 256

/* Controls: 8px dots, 8px of clearance between them (16px centre to
 * centre), 12px from the bar's right edge. GUI-DESIGN-LANGUAGE.md §6
 * spells "8px gap between centers" for 8px dots, which would overlap
 * them by a full diameter -- edge-to-edge is the conventional reading
 * and what this implements. */
#define DOT_SIZE 8
#define DOT_GAP 16
#define DOT_PAD NOVI_SP_MD

/* The SPRITE is 16px and the disc inside it is 8px, the rest
 * transparent. That is the whole hit-target mechanism: the scene
 * graph hit-tests a buffer node by its box, so an 8px node would mean
 * an 8px target, and landing a pointer on eight pixels is a thing
 * people fail at. A 16px box with the dot centred in it gives the
 * conventional pad for free, without a second invisible node per dot
 * to keep in sync. 16 is also DOT_GAP, so two neighbouring targets
 * meet exactly and never overlap. */
#define DOT_BOX DOT_GAP

/* Elevation-1, from §4's table: 4px down, 16px feather, 35% black.
 * SHADOW_EXTENT is the feather plus a little, so the sprite reaches
 * zero inside its own edge rather than being cut off at a visible
 * step. */
#define SHADOW_FEATHER 16
#define SHADOW_EXTENT 20
#define SHADOW_OFFSET 4
#define SHADOW_ALPHA 0.35f
/* An unfocused window is still lifted off the desktop, just less. The
 * scene graph scales the same sprites, so this costs one float. */
#define SHADOW_UNFOCUSED_OPACITY 0.45f

/* ── A wlr_buffer over plain memory ─────────────────────────────────
 *
 * Only two of the five callbacks do anything: this buffer has no
 * dmabuf and no shm fd behind it, it is malloc'd memory, so
 * get_dmabuf/get_shm correctly answer "no" and the renderer falls
 * back to reading the pointer -- which is what the pixman renderer
 * this compositor uses wants anyway (RFC 0001: -Drenderers=[],
 * software only).
 *
 * ARGB8888 here is PREMULTIPLIED, which is the whole reason the
 * drawing code below multiplies every colour by its own coverage
 * before storing it. Getting that wrong is silent rather than a
 * crash: main.c already carries a note about a "dimmed" scene rect
 * that rendered BRIGHTER than the full-strength ones next to it for
 * exactly this reason.
 */
struct mem_buffer {
	struct wlr_buffer base;
	uint32_t *data;
	size_t stride;
};

static void mem_buffer_destroy(struct wlr_buffer *buf) {
	struct mem_buffer *mb = (struct mem_buffer *)buf;
	free(mb->data);
	free(mb);
}

static bool mem_buffer_begin_data_ptr_access(struct wlr_buffer *buf,
		uint32_t flags, void **data, uint32_t *format, size_t *stride) {
	struct mem_buffer *mb = (struct mem_buffer *)buf;
	(void)flags;
	*data = mb->data;
	*format = DRM_FORMAT_ARGB8888;
	*stride = mb->stride;
	return true;
}

static void mem_buffer_end_data_ptr_access(struct wlr_buffer *buf) {
	(void)buf;
}

static const struct wlr_buffer_impl mem_buffer_impl = {
	.destroy = mem_buffer_destroy,
	.begin_data_ptr_access = mem_buffer_begin_data_ptr_access,
	.end_data_ptr_access = mem_buffer_end_data_ptr_access,
};

static struct mem_buffer *mem_buffer_create(int w, int h) {
	if (w <= 0 || h <= 0) {
		return NULL;
	}
	struct mem_buffer *mb = calloc(1, sizeof(*mb));
	if (mb == NULL) {
		return NULL;
	}
	mb->stride = (size_t)w * 4;
	mb->data = calloc(1, mb->stride * (size_t)h);
	if (mb->data == NULL) {
		free(mb);
		return NULL;
	}
	wlr_buffer_init(&mb->base, &mem_buffer_impl, w, h);
	return mb;
}

/* Premultiplied ARGB from a 0xAARRGGBB token and a coverage in
 * [0,1]. The token's own alpha is ignored: every colour in theme.h is
 * opaque, and coverage is the only source of transparency here. */
static uint32_t px(uint32_t rgb, float a) {
	if (a <= 0.0f) {
		return 0;
	}
	if (a > 1.0f) {
		a = 1.0f;
	}
	uint32_t A = (uint32_t)(a * 255.0f + 0.5f);
	uint32_t r = (uint32_t)(NOVI_R(rgb) * a + 0.5f);
	uint32_t g = (uint32_t)(NOVI_G(rgb) * a + 0.5f);
	uint32_t b = (uint32_t)(NOVI_B(rgb) * a + 0.5f);
	return (A << 24) | (r << 16) | (g << 8) | b;
}

/* Coverage of a disc of radius r centred at (cx, cy), sampled 4x4
 * inside the pixel. pixman has no circle primitive and this runs on a
 * handful of 8x8 sprites exactly once, so the naive version is the
 * right one. */
static float disc_coverage(float x, float y, float cx, float cy, float r) {
	int hits = 0;
	for (int sy = 0; sy < 4; sy++) {
		for (int sx = 0; sx < 4; sx++) {
			float px_ = x + (sx + 0.5f) / 4.0f;
			float py_ = y + (sy + 0.5f) / 4.0f;
			float dx = px_ - cx, dy = py_ - cy;
			if (dx * dx + dy * dy <= r * r) {
				hits++;
			}
		}
	}
	return hits / 16.0f;
}

/* The shadow's one-dimensional falloff, `d` pixels outside the edge.
 * A smoothstep rather than a true Gaussian integral: §4 asks for a
 * pre-rendered sprite, not a correct blur, and the difference is not
 * visible at 35% black. A Gaussian is separable, so a rectangle's
 * blur really is the product of two of these -- which is what makes
 * the nine-slice exact rather than an approximation of a shape. */
static float shadow_falloff(float d) {
	if (d <= 0.0f) {
		return 1.0f;
	}
	if (d >= SHADOW_FEATHER) {
		return 0.0f;
	}
	float g = 1.0f - d / (float)SHADOW_FEATHER;
	return g * g * (3.0f - 2.0f * g);
}

/* ── Shared sprites ────────────────────────────────────────────── */

/* The nine-slice, minus the centre. Index order matches shadow_place()
 * below; each is rendered once and referenced by every window. */
enum {
	SH_TOP, SH_BOTTOM, SH_LEFT, SH_RIGHT,
	SH_TL, SH_TR, SH_BL, SH_BR,
	SH_COUNT,
};

static struct fcft_font *title_font;
static struct wlr_buffer *shadow_sprite[SH_COUNT];
static struct wlr_buffer *dot_sprite[2]; /* [0] at rest, [1] hovered */

/* The bottom slices carry SHADOW_OFFSET rows of full-strength shadow
 * before their falloff starts, because the shadow rectangle is the
 * window pushed down by that much: without those rows there would be
 * a four-pixel band of nothing between the window's bottom edge and
 * the top of its own shadow. */
#define SH_BOT_H (SHADOW_EXTENT + SHADOW_OFFSET)

/* `lead` is how many rows of FULL-strength shadow come before the
 * falloff starts. It is SHADOW_OFFSET for the bottom slices only, and
 * zero everywhere else -- including the left and right slices, which
 * is the whole reason it is a parameter rather than a constant in
 * here. The offset pushes the shadow DOWN; applying it sideways would
 * hang four columns of full-strength black off the right edge of
 * every window, symmetric with nothing. */
static struct wlr_buffer *make_shadow_edge(int w, int h, bool vertical,
		bool falloff_first, int lead) {
	struct mem_buffer *mb = mem_buffer_create(w, h);
	if (mb == NULL) {
		return NULL;
	}
	int n = vertical ? h : w;
	for (int i = 0; i < n; i++) {
		/* Distance outside the window edge, in pixels. */
		float d = falloff_first ? (float)(n - 1 - i) : (float)(i - lead);
		float a = shadow_falloff(d) * SHADOW_ALPHA;
		uint32_t v = px(0x000000u, a);
		if (vertical) {
			for (int x = 0; x < w; x++) {
				mb->data[(size_t)i * (mb->stride / 4) + x] = v;
			}
		} else {
			for (int y = 0; y < h; y++) {
				mb->data[(size_t)y * (mb->stride / 4) + i] = v;
			}
		}
	}
	return &mb->base;
}

static struct wlr_buffer *make_shadow_corner(bool right, bool bottom) {
	int w = SHADOW_EXTENT;
	int h = bottom ? SH_BOT_H : SHADOW_EXTENT;
	struct mem_buffer *mb = mem_buffer_create(w, h);
	if (mb == NULL) {
		return NULL;
	}
	for (int y = 0; y < h; y++) {
		float dy = bottom ? (float)(y - SHADOW_OFFSET) : (float)(h - 1 - y);
		for (int x = 0; x < w; x++) {
			float dx = right ? (float)x : (float)(w - 1 - x);
			float a = shadow_falloff(dx) * shadow_falloff(dy) * SHADOW_ALPHA;
			mb->data[(size_t)y * (mb->stride / 4) + x] = px(0x000000u, a);
		}
	}
	return &mb->base;
}

static struct wlr_buffer *make_dot(uint32_t colour) {
	struct mem_buffer *mb = mem_buffer_create(DOT_BOX, DOT_BOX);
	if (mb == NULL) {
		return NULL;
	}
	float c = DOT_BOX / 2.0f;
	for (int y = 0; y < DOT_BOX; y++) {
		for (int x = 0; x < DOT_BOX; x++) {
			float a = disc_coverage((float)x, (float)y, c, c,
				DOT_SIZE / 2.0f - 0.35f);
			mb->data[(size_t)y * (mb->stride / 4) + x] = px(colour, a);
		}
	}
	return &mb->base;
}

bool novi_decor_init(void) {
	title_font = novi_text_load_font(NOVI_FONT_TITLE);
	if (title_font == NULL) {
		return false;
	}
	shadow_sprite[SH_TOP] = make_shadow_edge(1, SHADOW_EXTENT, true, true, 0);
	shadow_sprite[SH_BOTTOM] =
		make_shadow_edge(1, SH_BOT_H, true, false, SHADOW_OFFSET);
	shadow_sprite[SH_LEFT] = make_shadow_edge(SHADOW_EXTENT, 1, false, true, 0);
	shadow_sprite[SH_RIGHT] = make_shadow_edge(SHADOW_EXTENT, 1, false, false, 0);
	shadow_sprite[SH_TL] = make_shadow_corner(false, false);
	shadow_sprite[SH_TR] = make_shadow_corner(true, false);
	shadow_sprite[SH_BL] = make_shadow_corner(false, true);
	shadow_sprite[SH_BR] = make_shadow_corner(true, true);
	dot_sprite[0] = make_dot(NOVI_TEXT_MUTED);
	dot_sprite[1] = make_dot(NOVI_TEXT_SECONDARY);
	for (int i = 0; i < SH_COUNT; i++) {
		if (shadow_sprite[i] == NULL) {
			return false;
		}
	}
	return dot_sprite[0] != NULL && dot_sprite[1] != NULL;
}

void novi_decor_finish(void) {
	for (int i = 0; i < SH_COUNT; i++) {
		if (shadow_sprite[i] != NULL) {
			wlr_buffer_drop(shadow_sprite[i]);
			shadow_sprite[i] = NULL;
		}
	}
	for (int i = 0; i < 2; i++) {
		if (dot_sprite[i] != NULL) {
			wlr_buffer_drop(dot_sprite[i]);
			dot_sprite[i] = NULL;
		}
	}
	if (title_font != NULL) {
		fcft_destroy(title_font);
		title_font = NULL;
	}
}

/* ── One window's chrome ───────────────────────────────────────── */

struct novi_decor {
	struct wlr_scene_buffer *shadow[SH_COUNT];
	struct wlr_scene_buffer *bar;
	struct wlr_scene_buffer *dot[NOVI_DECO_CONTROL_COUNT];

	int width, height;
	char title[TITLE_MAX + 1];
	bool focused;
	enum novi_deco_control hover;

	/* What the bar buffer currently depicts, so a redraw is skipped
	 * when nothing it depends on moved. */
	int drawn_width;
	bool drawn_focused;
	char drawn_title[TITLE_MAX + 1];
};

/* Decorations are not surfaces, so a click on one has to be resolved
 * by the compositor's own hit test (main.c's decoration_node_toplevel_
 * at()). The shadow is the exception: it is a soft edge hanging
 * outside the window, and a pointer there is over the desktop, not
 * over the window. Without this, twenty pixels around every window
 * would swallow clicks meant for whatever is behind it. */
static bool reject_input(struct wlr_scene_buffer *buffer,
		double *sx, double *sy) {
	(void)buffer; (void)sx; (void)sy;
	return false;
}

struct novi_decor *novi_decor_create(struct wlr_scene_tree *tree) {
	if (title_font == NULL) {
		return NULL;
	}
	struct novi_decor *d = calloc(1, sizeof(*d));
	if (d == NULL) {
		return NULL;
	}
	d->hover = NOVI_DECO_CONTROL_NONE;
	d->drawn_width = -1;

	for (int i = 0; i < SH_COUNT; i++) {
		d->shadow[i] = wlr_scene_buffer_create(tree, shadow_sprite[i]);
		if (d->shadow[i] == NULL) {
			free(d);
			return NULL;
		}
		d->shadow[i]->point_accepts_input = reject_input;
		/* The client's surface node was created before any of this
		 * (it is what the tree was made for), so a node added now
		 * paints on top of it. A shadow that covers the window is not
		 * a shadow. */
		wlr_scene_node_lower_to_bottom(&d->shadow[i]->node);
	}
	/* No buffer yet: the scene treats that as nothing to draw, which
	 * is right for a window whose size is not known until its first
	 * real commit. */
	d->bar = wlr_scene_buffer_create(tree, NULL);
	if (d->bar == NULL) {
		free(d);
		return NULL;
	}
	for (int i = 0; i < NOVI_DECO_CONTROL_COUNT; i++) {
		/* Created after the bar so they paint over it -- a scene tree
		 * draws children oldest first. */
		d->dot[i] = wlr_scene_buffer_create(tree, dot_sprite[0]);
		if (d->dot[i] == NULL) {
			free(d);
			return NULL;
		}
	}
	return d;
}

void novi_decor_destroy(struct novi_decor *d) {
	/* The scene nodes are owned by the tree they were parented to and
	 * go with it; only the bookkeeping is ours. */
	free(d);
}

/* Where each nine-slice piece sits, in the toplevel's own
 * coordinates: the client content starts at (0, 0) and the title bar
 * sits above it at negative y. */
static void shadow_place(struct novi_decor *d) {
	int top = -NOVI_DECO_HEIGHT;
	int w = d->width;
	int h = d->height + NOVI_DECO_HEIGHT;
	int e = SHADOW_EXTENT;
	int o = SHADOW_OFFSET;

	struct { int x, y, w, h; } box[SH_COUNT] = {
		[SH_TOP]    = { 0,      top + o - e,   w, e },
		[SH_BOTTOM] = { 0,      top + h,       w, SH_BOT_H },
		[SH_LEFT]   = { -e,     top + o,       e, h - o },
		[SH_RIGHT]  = { w,      top + o,       e, h - o },
		[SH_TL]     = { -e,     top + o - e,   e, e },
		[SH_TR]     = { w,      top + o - e,   e, e },
		[SH_BL]     = { -e,     top + h,       e, SH_BOT_H },
		[SH_BR]     = { w,      top + h,       e, SH_BOT_H },
	};
	for (int i = 0; i < SH_COUNT; i++) {
		if (box[i].w <= 0 || box[i].h <= 0) {
			wlr_scene_node_set_enabled(&d->shadow[i]->node, false);
			continue;
		}
		wlr_scene_node_set_enabled(&d->shadow[i]->node, true);
		wlr_scene_node_set_position(&d->shadow[i]->node, box[i].x, box[i].y);
		wlr_scene_buffer_set_dest_size(d->shadow[i], box[i].w, box[i].h);
		wlr_scene_buffer_set_opacity(d->shadow[i],
			d->focused ? 1.0f : SHADOW_UNFOCUSED_OPACITY);
	}
}

/* The title bar: a vertical gradient from bg-card-raised down to
 * bg-card, radius-lg on the top corners only, a border-subtle
 * hairline along the bottom, and the title. The gradient is four
 * levels across 32 rows -- enough for the bar to have a direction to
 * it, far short of anything you would call a gradient if you were
 * looking for one. */
static void draw_bar(struct novi_decor *d) {
	int w = d->width;
	int h = NOVI_DECO_HEIGHT;
	if (w <= 0) {
		wlr_scene_buffer_set_buffer(d->bar, NULL);
		return;
	}
	struct mem_buffer *mb = mem_buffer_create(w, h);
	if (mb == NULL) {
		return;
	}
	int span = (int)mb->stride / 4;
	float r = (float)NOVI_RADIUS_LG;

	uint32_t top_rgb = d->focused ? NOVI_BG_CARD_RAISED : NOVI_BG_CARD;
	for (int y = 0; y < h; y++) {
		/* Mix top_rgb into bg-card by how far down the bar we are. */
		float t = 1.0f - (float)y / (float)(h - 1);
		uint32_t rgb =
			(((uint32_t)(NOVI_R(NOVI_BG_CARD) +
				(NOVI_R(top_rgb) - (int)NOVI_R(NOVI_BG_CARD)) * t)) << 16) |
			(((uint32_t)(NOVI_G(NOVI_BG_CARD) +
				(NOVI_G(top_rgb) - (int)NOVI_G(NOVI_BG_CARD)) * t)) << 8) |
			 ((uint32_t)(NOVI_B(NOVI_BG_CARD) +
				(NOVI_B(top_rgb) - (int)NOVI_B(NOVI_BG_CARD)) * t));
		/* The hairline that separates chrome from content. */
		if (y == h - 1) {
			rgb = NOVI_BORDER_SUBTLE;
		}
		for (int x = 0; x < w; x++) {
			float a = 1.0f;
			if ((float)y < r) {
				if ((float)x < r) {
					a = disc_coverage((float)x, (float)y, r, r, r);
				} else if ((float)x > (float)w - r) {
					a = disc_coverage((float)x, (float)y,
						(float)w - r, r, r);
				}
			}
			mb->data[(size_t)y * span + x] = px(rgb, a);
		}
	}

	/* The title. Focus is carried by the WEIGHT of the colour, not by
	 * a different hue: an unfocused window's title recedes rather than
	 * turning a colour that means something else in this palette. */
	/* Everything left of the leftmost control, less the bar's own left
	 * padding and one more gap so a long name never runs up against
	 * the dots. */
	int avail = (w - DOT_PAD - DOT_SIZE - 2 * DOT_GAP)
		- NOVI_SP_MD - NOVI_SP_MD;
	if (d->title[0] != '\0' && avail >= 24) {
		pixman_image_t *dest = pixman_image_create_bits(PIXMAN_a8r8g8b8,
			w, h, mb->data, (int)mb->stride);
		if (dest != NULL) {
			char shown[TITLE_MAX + 8];
			novi_text_truncate(title_font, d->title, avail,
				shown, sizeof(shown));
			pixman_color_t col = d->focused
				? NOVI_PIX(NOVI_TEXT_PRIMARY)
				: NOVI_PIX(NOVI_TEXT_MUTED);
			int baseline = (h - title_font->height) / 2 + title_font->ascent;
			novi_text_draw(dest, title_font, NOVI_SP_MD, baseline, shown, col);
			pixman_image_unref(dest);
		}
	}

	wlr_scene_buffer_set_buffer(d->bar, &mb->base);
	/* The scene took its own reference; drop ours, so the buffer is
	 * freed when the node stops pointing at it -- which is the next
	 * time this function runs. Without this every redraw leaks a bar. */
	wlr_buffer_drop(&mb->base);
	wlr_scene_node_set_position(&d->bar->node, 0, -NOVI_DECO_HEIGHT);
}

/* Left edge of the 16px hit box whose 8px dot is `n` places in from
 * the right. */
static int dot_box_x(const struct novi_decor *d, int n) {
	int centre = d->width - DOT_PAD - DOT_SIZE / 2 - n * DOT_GAP;
	return centre - DOT_BOX / 2;
}

static void place_dots(struct novi_decor *d) {
	/* Right to left: close (rightmost), then maximize, then minimize. */
	int y = -NOVI_DECO_HEIGHT + (NOVI_DECO_HEIGHT - DOT_BOX) / 2;
	for (int i = 0; i < NOVI_DECO_CONTROL_COUNT; i++) {
		bool on = d->width > 0;
		wlr_scene_node_set_enabled(&d->dot[i]->node, on);
		if (!on) {
			continue;
		}
		wlr_scene_node_set_position(&d->dot[i]->node,
			dot_box_x(d, NOVI_DECO_CLOSE - i), y);
		wlr_scene_buffer_set_buffer(d->dot[i],
			dot_sprite[d->hover == i ? 1 : 0]);
		/* A dot on an unfocused window is present but quieter -- the
		 * same argument as the title receding, and the reason the
		 * sprite itself does not need a third colour. */
		wlr_scene_buffer_set_opacity(d->dot[i], d->focused ? 1.0f : 0.5f);
	}
}

static void refresh(struct novi_decor *d) {
	if (d->width <= 0) {
		wlr_scene_buffer_set_buffer(d->bar, NULL);
		for (int i = 0; i < NOVI_DECO_CONTROL_COUNT; i++) {
			wlr_scene_node_set_enabled(&d->dot[i]->node, false);
		}
		for (int i = 0; i < SH_COUNT; i++) {
			wlr_scene_node_set_enabled(&d->shadow[i]->node, false);
		}
		return;
	}
	if (d->width != d->drawn_width || d->focused != d->drawn_focused ||
			strcmp(d->title, d->drawn_title) != 0) {
		draw_bar(d);
		d->drawn_width = d->width;
		d->drawn_focused = d->focused;
		snprintf(d->drawn_title, sizeof(d->drawn_title), "%s", d->title);
	}
	place_dots(d);
	shadow_place(d);
}

void novi_decor_set_size(struct novi_decor *d, int width, int height) {
	if (d == NULL || (width == d->width && height == d->height)) {
		return;
	}
	d->width = width;
	d->height = height;
	refresh(d);
}

void novi_decor_set_title(struct novi_decor *d, const char *title) {
	if (d == NULL) {
		return;
	}
	if (title == NULL) {
		title = "";
	}
	if (strncmp(d->title, title, TITLE_MAX) == 0) {
		return;
	}
	snprintf(d->title, sizeof(d->title), "%s", title);
	refresh(d);
}

void novi_decor_set_focused(struct novi_decor *d, bool focused) {
	if (d == NULL || focused == d->focused) {
		return;
	}
	d->focused = focused;
	refresh(d);
}

void novi_decor_set_hover(struct novi_decor *d, enum novi_deco_control c) {
	if (d == NULL || c == d->hover) {
		return;
	}
	d->hover = c;
	place_dots(d);
}

enum novi_deco_control novi_decor_control_at(const struct novi_decor *d,
		const struct wlr_scene_node *node) {
	if (d == NULL || node == NULL) {
		return NOVI_DECO_CONTROL_NONE;
	}
	for (int i = 0; i < NOVI_DECO_CONTROL_COUNT; i++) {
		if (&d->dot[i]->node == node) {
			return i;
		}
	}
	return NOVI_DECO_CONTROL_NONE;
}

bool novi_decor_is_bar(const struct novi_decor *d,
		const struct wlr_scene_node *node) {
	return d != NULL && node != NULL && &d->bar->node == node;
}
