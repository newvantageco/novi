/* ============================================================
 * novi-view — an image viewer for the Novi desktop
 *
 * The third first-party application, and the one that closes an
 * embarrassing loop: novi-screenshot has been able to WRITE an image
 * since the day it was written, and nothing on this system could read
 * one back. You could press PrintScreen and never look at the result.
 *
 * It also gives novi-files its first real dispatch decision. Until now
 * everything that was not a directory went to the editor, because the
 * editor was the only place to send it. Now an image goes here.
 *
 * Formats:
 *
 *   PNG   via libpng (build/21-imagelibs.sh). The one format anyone
 *         will actually hand you.
 *   BMP   uncompressed 24- and 32-bit, because that is exactly what
 *         novi-screenshot writes, and the whole point is being able to
 *         look at a screenshot.
 *   PPM   binary P6, because that is what a QEMU screendump produces
 *         and this project takes a great many of them.
 *
 * No JPEG: it needs libjpeg, which is another dependency for a format
 * nothing on this system produces. Worth adding the day something does.
 *
 * Scaling is nearest-neighbour and deliberately so. A box filter would
 * look better and wants either a real resampler or Mesa; the honest
 * version of "fit to window" today is the one that is obviously simple
 * rather than the one that is subtly wrong.
 * ============================================================ */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <setjmp.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <png.h>
#include <pixman.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>

#include "text.h"
#include "xdg-shell-client-protocol.h"

#define WINDOW_WIDTH  900
#define WINDOW_HEIGHT 640
#define PAD           12
#define STATUS_H      28

/* An image bigger than this is refused rather than attempted: the
 * decode buffer is width*height*4 bytes and this machine may have no
 * swap. 8000x8000 is 256 MB, which is already generous. */
#define MAX_DIM 8000

#define BG_COLOR      0xff101016u
#define STATUS_BG     0xff232430u

static const pixman_color_t STATUS_PIX = {0xa3a3, 0xa7a7, 0xb7b7, 0xffff};
static const pixman_color_t ERROR_PIX  = {0xf0f0, 0x7a7a, 0x7a7a, 0xffff};

struct novi_view {
	struct wl_display *display;
	struct wl_registry *registry;
	struct wl_compositor *compositor;
	struct wl_shm *shm;
	struct wl_seat *seat;
	struct wl_keyboard *keyboard;
	struct wl_surface *surface;
	struct xdg_wm_base *wm_base;
	struct xdg_surface *xdg_surface;
	struct xdg_toplevel *xdg_toplevel;

	struct xkb_context *xkb_context;
	struct xkb_keymap *xkb_keymap;
	struct xkb_state *xkb_state;
	struct fcft_font *font_small;

	uint32_t width, height;
	bool configured;
	bool running;

	/* Decoded image: XRGB8888, top row first, tightly packed. */
	uint32_t *img;
	int iw, ih;

	bool fit;          /* scale to window, or show 1:1 */
	char path[PATH_MAX];
	char status[256];
	bool status_is_error;
};

static void set_status(struct novi_view *v, bool err, const char *fmt, ...)
	__attribute__((format(printf, 3, 4)));

static void set_status(struct novi_view *v, bool err, const char *fmt, ...) {
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(v->status, sizeof(v->status), fmt, ap);
	va_end(ap);
	v->status_is_error = err;
}

/* ── Decoders ──────────────────────────────────────────────────── */

static uint32_t *alloc_pixels(int w, int h) {
	if (w <= 0 || h <= 0 || w > MAX_DIM || h > MAX_DIM) {
		return NULL;
	}
	return calloc((size_t)w * (size_t)h, sizeof(uint32_t));
}

static bool load_png(struct novi_view *v, FILE *f) {
	png_structp png = png_create_read_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
	if (png == NULL) {
		return false;
	}
	png_infop info = png_create_info_struct(png);
	if (info == NULL) {
		png_destroy_read_struct(&png, NULL, NULL);
		return false;
	}
	/* libpng reports errors by longjmp, so every failure path below
	 * lands here rather than returning a code. */
	if (setjmp(png_jmpbuf(png))) {
		png_destroy_read_struct(&png, &info, NULL);
		return false;
	}

	png_init_io(png, f);
	png_read_info(png, info);

	png_uint_32 w = 0, h = 0;
	int depth = 0, color = 0;
	png_get_IHDR(png, info, &w, &h, &depth, &color, NULL, NULL, NULL);

	/* Normalise everything to 8-bit RGBA so there is exactly one pixel
	 * path below instead of one per PNG colour type. */
	if (color == PNG_COLOR_TYPE_PALETTE) {
		png_set_palette_to_rgb(png);
	}
	if (color == PNG_COLOR_TYPE_GRAY && depth < 8) {
		png_set_expand_gray_1_2_4_to_8(png);
	}
	if (png_get_valid(png, info, PNG_INFO_tRNS)) {
		png_set_tRNS_to_alpha(png);
	}
	if (depth == 16) {
		png_set_strip_16(png);
	}
	if (color == PNG_COLOR_TYPE_GRAY || color == PNG_COLOR_TYPE_GRAY_ALPHA) {
		png_set_gray_to_rgb(png);
	}
	png_set_filler(png, 0xff, PNG_FILLER_AFTER);
	png_read_update_info(png, info);

	uint32_t *pixels = alloc_pixels((int)w, (int)h);
	if (pixels == NULL) {
		png_destroy_read_struct(&png, &info, NULL);
		set_status(v, true, "image too large or out of memory");
		return false;
	}

	png_bytep *rows = malloc((size_t)h * sizeof(*rows));
	if (rows == NULL) {
		free(pixels);
		png_destroy_read_struct(&png, &info, NULL);
		return false;
	}
	/* Decode straight into the destination as RGBA, then convert in
	 * place to the XRGB8888 the compositor wants. */
	for (png_uint_32 y = 0; y < h; y++) {
		rows[y] = (png_bytep)(pixels + (size_t)y * w);
	}
	png_read_image(png, rows);
	free(rows);
	png_destroy_read_struct(&png, &info, NULL);

	for (size_t i = 0; i < (size_t)w * h; i++) {
		uint8_t *p = (uint8_t *)&pixels[i];
		uint8_t r = p[0], g = p[1], b = p[2];
		pixels[i] = 0xff000000u | ((uint32_t)r << 16) | ((uint32_t)g << 8) | b;
	}

	v->img = pixels;
	v->iw = (int)w;
	v->ih = (int)h;
	return true;
}

static uint32_t rd32(const uint8_t *p) {
	return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
	       ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

/* Uncompressed 24/32-bit BMP -- exactly what novi-screenshot writes.
 * Not a general BMP reader: RLE, 1/4/8-bit palettes and the older
 * BITMAPCOREHEADER are all refused with a message rather than
 * misdecoded into garbage. */
static bool load_bmp(struct novi_view *v, FILE *f) {
	uint8_t hdr[54];
	if (fread(hdr, 1, sizeof(hdr), f) != sizeof(hdr)) {
		set_status(v, true, "truncated BMP header");
		return false;
	}
	if (hdr[0] != 'B' || hdr[1] != 'M') {
		set_status(v, true, "not a BMP");
		return false;
	}
	uint32_t offset = rd32(hdr + 10);
	uint32_t dib = rd32(hdr + 14);
	if (dib < 40) {
		set_status(v, true, "unsupported BMP header (%u bytes)", dib);
		return false;
	}
	int32_t w = (int32_t)rd32(hdr + 18);
	int32_t h = (int32_t)rd32(hdr + 22);
	uint16_t bpp = (uint16_t)(hdr[28] | (hdr[29] << 8));
	uint32_t comp = rd32(hdr + 30);
	if (comp != 0) {
		set_status(v, true, "compressed BMP not supported");
		return false;
	}
	if (bpp != 24 && bpp != 32) {
		set_status(v, true, "%u-bit BMP not supported", bpp);
		return false;
	}

	/* A negative height means the rows are stored top-down. Positive --
	 * the common case, and what novi-screenshot writes -- means
	 * bottom-up, which is the single most-missed detail in BMP readers
	 * and shows up as a vertically mirrored image. */
	bool bottom_up = h > 0;
	int ah = h > 0 ? h : -h;

	uint32_t *pixels = alloc_pixels(w, ah);
	if (pixels == NULL) {
		set_status(v, true, "image too large or out of memory");
		return false;
	}
	if (fseek(f, (long)offset, SEEK_SET) != 0) {
		free(pixels);
		set_status(v, true, "bad BMP pixel offset");
		return false;
	}

	int bytes_pp = bpp / 8;
	size_t stride = ((size_t)w * bytes_pp + 3) & ~(size_t)3; /* rows pad to 4 */
	uint8_t *row = malloc(stride);
	if (row == NULL) {
		free(pixels);
		return false;
	}
	for (int y = 0; y < ah; y++) {
		if (fread(row, 1, stride, f) != stride) {
			free(row); free(pixels);
			set_status(v, true, "truncated BMP data");
			return false;
		}
		int dst_y = bottom_up ? (ah - 1 - y) : y;
		for (int x = 0; x < w; x++) {
			const uint8_t *p = row + (size_t)x * bytes_pp;
			pixels[(size_t)dst_y * w + x] =
				0xff000000u | ((uint32_t)p[2] << 16) |
				((uint32_t)p[1] << 8) | p[0];
		}
	}
	free(row);

	v->img = pixels;
	v->iw = w;
	v->ih = ah;
	return true;
}

/* Binary PPM (P6), which is what `screendump` in QEMU writes. */
static bool load_ppm(struct novi_view *v, FILE *f) {
	int w = 0, h = 0, maxval = 0;
	char magic[3] = {0};
	if (fscanf(f, "%2s", magic) != 1 || strcmp(magic, "P6") != 0) {
		set_status(v, true, "not a binary PPM");
		return false;
	}
	/* PPM allows comments between any two tokens. */
	int vals[3], got = 0;
	while (got < 3) {
		int c = fgetc(f);
		if (c == EOF) {
			set_status(v, true, "truncated PPM header");
			return false;
		}
		if (c == '#') {
			while (c != '\n' && c != EOF) { c = fgetc(f); }
			continue;
		}
		if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
			continue;
		}
		ungetc(c, f);
		if (fscanf(f, "%d", &vals[got]) != 1) {
			set_status(v, true, "bad PPM header");
			return false;
		}
		got++;
	}
	w = vals[0]; h = vals[1]; maxval = vals[2];
	if (maxval != 255) {
		set_status(v, true, "only 8-bit PPM supported");
		return false;
	}
	fgetc(f); /* the single whitespace byte before the data */

	uint32_t *pixels = alloc_pixels(w, h);
	if (pixels == NULL) {
		set_status(v, true, "image too large or out of memory");
		return false;
	}
	uint8_t *row = malloc((size_t)w * 3);
	if (row == NULL) {
		free(pixels);
		return false;
	}
	for (int y = 0; y < h; y++) {
		if (fread(row, 1, (size_t)w * 3, f) != (size_t)w * 3) {
			free(row); free(pixels);
			set_status(v, true, "truncated PPM data");
			return false;
		}
		for (int x = 0; x < w; x++) {
			pixels[(size_t)y * w + x] = 0xff000000u |
				((uint32_t)row[x * 3] << 16) |
				((uint32_t)row[x * 3 + 1] << 8) | row[x * 3 + 2];
		}
	}
	free(row);
	v->img = pixels;
	v->iw = w;
	v->ih = h;
	return true;
}

/* Sniff the file's own first bytes rather than trust the extension: a
 * screenshot saved as .png that is really a BMP should still open, and
 * an extension is a hint the filesystem happens to carry, not a fact
 * about the contents. */
static bool load_image(struct novi_view *v, const char *path) {
	FILE *f = fopen(path, "rb");
	if (f == NULL) {
		set_status(v, true, "cannot open: %s", strerror(errno));
		return false;
	}
	uint8_t magic[8] = {0};
	size_t n = fread(magic, 1, sizeof(magic), f);
	rewind(f);

	bool ok = false;
	if (n >= 8 && png_sig_cmp(magic, 0, 8) == 0) {
		ok = load_png(v, f);
		if (!ok && v->status[0] == '\0') {
			set_status(v, true, "PNG decode failed");
		}
	} else if (n >= 2 && magic[0] == 'B' && magic[1] == 'M') {
		ok = load_bmp(v, f);
	} else if (n >= 2 && magic[0] == 'P' && magic[1] == '6') {
		ok = load_ppm(v, f);
	} else {
		set_status(v, true, "unrecognised image format");
	}
	fclose(f);
	return ok;
}

/* ── Rendering ─────────────────────────────────────────────────── */

static void draw_rect(uint32_t *px, uint32_t stride_px, uint32_t buf_w,
		uint32_t buf_h, int x, int y, int w, int h, uint32_t color) {
	for (int row = y; row < y + h && row < (int)buf_h; row++) {
		if (row < 0) { continue; }
		for (int col = x; col < x + w && col < (int)buf_w; col++) {
			if (col < 0) { continue; }
			px[row * (int)stride_px + col] = color;
		}
	}
}

static void render(struct novi_view *v, uint32_t *px, uint32_t stride_px) {
	uint32_t w = v->width, h = v->height;
	pixman_image_t *dest = pixman_image_create_bits(PIXMAN_x8r8g8b8,
		(int)w, (int)h, px, (int)(stride_px * 4));

	draw_rect(px, stride_px, w, h, 0, 0, (int)w, (int)h, BG_COLOR);

	int area_h = (int)h - STATUS_H;
	if (v->img != NULL && area_h > 0) {
		/* Fit scales down only -- blowing a 16x16 icon up to fill a
		 * 900px window is not "fitting", it is a magnifier nobody
		 * asked for. 1:1 mode shows the top-left corner of anything
		 * bigger than the window; there is no panning yet. */
		int dw = v->iw, dh = v->ih;
		if (v->fit && (v->iw > (int)w || v->ih > area_h)) {
			double sx = (double)w / v->iw;
			double sy = (double)area_h / v->ih;
			double sc = sx < sy ? sx : sy;
			dw = (int)(v->iw * sc);
			dh = (int)(v->ih * sc);
			if (dw < 1) { dw = 1; }
			if (dh < 1) { dh = 1; }
		}
		int ox = ((int)w - dw) / 2;
		int oy = (area_h - dh) / 2;
		if (ox < 0) { ox = 0; }
		if (oy < 0) { oy = 0; }

		/* Nearest-neighbour, sampled per destination pixel. A box
		 * filter would look better on a downscale and wants either a
		 * real resampler or Mesa; the honest version of "fit to
		 * window" today is the one that is obviously simple rather
		 * than the one that is subtly wrong. */
		for (int y = 0; y < dh && oy + y < area_h; y++) {
			for (int x = 0; x < dw && ox + x < (int)w; x++) {
				int sxp = v->iw == dw ? x : (int)((int64_t)x * v->iw / dw);
				int syp = v->ih == dh ? y : (int)((int64_t)y * v->ih / dh);
				if (sxp >= v->iw) { sxp = v->iw - 1; }
				if (syp >= v->ih) { syp = v->ih - 1; }
				uint32_t c = v->img[(size_t)syp * v->iw + sxp];
				px[(oy + y) * (int)stride_px + (ox + x)] = c;
			}
		}
	}

	int sy = (int)h - STATUS_H;
	draw_rect(px, stride_px, w, h, 0, sy, (int)w, STATUS_H, STATUS_BG);
	int sbase = sy + (STATUS_H - v->font_small->height) / 2 + v->font_small->ascent;

	const char *name = v->path[0] ? v->path : "(no file)";
	novi_text_draw(dest, v->font_small, PAD, sbase, name, STATUS_PIX);

	char right[sizeof(v->status) + 96];
	if (v->status[0]) {
		snprintf(right, sizeof(right), "%s", v->status);
	} else if (v->img != NULL) {
		snprintf(right, sizeof(right), "%dx%d   %s   F fit   ^Q quit",
			v->iw, v->ih, v->fit ? "fit" : "1:1");
	} else {
		snprintf(right, sizeof(right), "^Q quit");
	}
	int rw = novi_text_width(v->font_small, right);
	novi_text_draw(dest, v->font_small, (int)w - PAD - rw, sbase, right,
		v->status_is_error ? ERROR_PIX : STATUS_PIX);

	pixman_image_unref(dest);
}

/* ── Wayland plumbing ──────────────────────────────────────────── */

static int allocate_shm_file(size_t size) {
	char name[] = "/novi-view-XXXXXX";
	struct timespec ts;
	int fd = -1;
	for (int tries = 0; tries < 100 && fd < 0; tries++) {
		clock_gettime(CLOCK_REALTIME, &ts);
		long r = ts.tv_nsec + tries;
		for (int i = 0; i < 6; i++) {
			name[11 + i] = 'A' + (r & 15) + (r & 16) * 2;
			r >>= 5;
		}
		fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
	}
	if (fd < 0) { return -1; }
	shm_unlink(name);
	if (ftruncate(fd, (off_t)size) < 0) {
		close(fd);
		return -1;
	}
	return fd;
}

static void surface_draw_frame(struct novi_view *v) {
	if (!v->configured) { return; }
	uint32_t stride = v->width * 4;
	size_t size = (size_t)stride * v->height;

	int fd = allocate_shm_file(size);
	if (fd < 0) {
		fprintf(stderr, "novi-view: failed to allocate shm buffer\n");
		return;
	}
	uint32_t *data = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (data == MAP_FAILED) {
		fprintf(stderr, "novi-view: mmap failed\n");
		close(fd);
		return;
	}
	struct wl_shm_pool *pool = wl_shm_create_pool(v->shm, fd, (int32_t)size);
	struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0,
		(int32_t)v->width, (int32_t)v->height, (int32_t)stride,
		WL_SHM_FORMAT_XRGB8888);
	wl_shm_pool_destroy(pool);
	wl_display_flush(v->display);
	close(fd);

	render(v, data, v->width);
	munmap(data, size);

	wl_surface_attach(v->surface, buffer, 0, 0);
	wl_surface_damage_buffer(v->surface, 0, 0,
		(int32_t)v->width, (int32_t)v->height);
	wl_surface_commit(v->surface);
}

static void keyboard_keymap(void *data, struct wl_keyboard *kb,
		uint32_t format, int fd, uint32_t size) {
	struct novi_view *v = data;
	if (format != WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) { close(fd); return; }
	char *map = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
	if (map == MAP_FAILED) { close(fd); return; }
	struct xkb_keymap *keymap = xkb_keymap_new_from_string(v->xkb_context,
		map, XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS);
	munmap(map, size);
	close(fd);
	if (keymap == NULL) { return; }
	struct xkb_state *st = xkb_state_new(keymap);
	if (v->xkb_state != NULL) { xkb_state_unref(v->xkb_state); }
	if (v->xkb_keymap != NULL) { xkb_keymap_unref(v->xkb_keymap); }
	v->xkb_keymap = keymap;
	v->xkb_state = st;
}

static void keyboard_enter(void *data, struct wl_keyboard *kb, uint32_t serial,
		struct wl_surface *surface, struct wl_array *keys) {
	(void)data; (void)kb; (void)serial; (void)surface; (void)keys;
}

static void keyboard_leave(void *data, struct wl_keyboard *kb, uint32_t serial,
		struct wl_surface *surface) {
	(void)data; (void)kb; (void)serial; (void)surface;
}

static void keyboard_key(void *data, struct wl_keyboard *kb, uint32_t serial,
		uint32_t time, uint32_t key, uint32_t key_state) {
	struct novi_view *v = data;
	if (key_state != WL_KEYBOARD_KEY_STATE_PRESSED || v->xkb_state == NULL) {
		return;
	}
	xkb_keysym_t sym = xkb_state_key_get_one_sym(v->xkb_state, key + 8);
	bool ctrl = xkb_state_mod_name_is_active(v->xkb_state, XKB_MOD_NAME_CTRL,
		XKB_STATE_MODS_EFFECTIVE) > 0;
	if (ctrl && (sym == XKB_KEY_q || sym == XKB_KEY_Q)) {
		v->running = false;
		return;
	}
	switch (sym) {
	case XKB_KEY_Escape: case XKB_KEY_q: case XKB_KEY_Q:
		v->running = false;
		return;
	case XKB_KEY_f: case XKB_KEY_F:
		v->fit = !v->fit;
		v->status[0] = '\0';
		break;
	default:
		break;
	}
	surface_draw_frame(v);
}

static void keyboard_modifiers(void *data, struct wl_keyboard *kb,
		uint32_t serial, uint32_t depressed, uint32_t latched,
		uint32_t locked, uint32_t group) {
	struct novi_view *v = data;
	if (v->xkb_state != NULL) {
		xkb_state_update_mask(v->xkb_state, depressed, latched, locked, 0, 0, group);
	}
}

static void keyboard_repeat_info(void *data, struct wl_keyboard *kb,
		int32_t rate, int32_t delay) {
	(void)data; (void)kb; (void)rate; (void)delay;
}

static const struct wl_keyboard_listener keyboard_listener = {
	.keymap = keyboard_keymap,
	.enter = keyboard_enter,
	.leave = keyboard_leave,
	.key = keyboard_key,
	.modifiers = keyboard_modifiers,
	.repeat_info = keyboard_repeat_info,
};

static void seat_capabilities(void *data, struct wl_seat *seat, uint32_t caps) {
	struct novi_view *v = data;
	if ((caps & WL_SEAT_CAPABILITY_KEYBOARD) && v->keyboard == NULL) {
		v->keyboard = wl_seat_get_keyboard(seat);
		wl_keyboard_add_listener(v->keyboard, &keyboard_listener, v);
	}
}

static void seat_name(void *data, struct wl_seat *seat, const char *name) {
	(void)data; (void)seat; (void)name;
}

static const struct wl_seat_listener seat_listener = {
	.capabilities = seat_capabilities,
	.name = seat_name,
};

static void wm_base_ping(void *data, struct xdg_wm_base *wm_base, uint32_t serial) {
	(void)data;
	xdg_wm_base_pong(wm_base, serial);
}

static const struct xdg_wm_base_listener wm_base_listener = { .ping = wm_base_ping };

static void xdg_surface_configure(void *data, struct xdg_surface *xdg_surface,
		uint32_t serial) {
	struct novi_view *v = data;
	xdg_surface_ack_configure(xdg_surface, serial);
	v->configured = true;
	surface_draw_frame(v);
}

static const struct xdg_surface_listener xdg_surface_listener_impl = {
	.configure = xdg_surface_configure,
};

static void toplevel_configure(void *data, struct xdg_toplevel *toplevel,
		int32_t width, int32_t height, struct wl_array *states) {
	struct novi_view *v = data;
	if (width > 0 && height > 0) {
		v->width = (uint32_t)width;
		v->height = (uint32_t)height;
	}
}

static void toplevel_close(void *data, struct xdg_toplevel *toplevel) {
	struct novi_view *v = data;
	v->running = false;
}

static const struct xdg_toplevel_listener toplevel_listener = {
	.configure = toplevel_configure,
	.close = toplevel_close,
};

static void registry_global(void *data, struct wl_registry *registry,
		uint32_t name, const char *interface, uint32_t version) {
	(void)version;
	struct novi_view *v = data;
	if (strcmp(interface, wl_compositor_interface.name) == 0) {
		v->compositor = wl_registry_bind(registry, name, &wl_compositor_interface, 4);
	} else if (strcmp(interface, wl_shm_interface.name) == 0) {
		v->shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
	} else if (strcmp(interface, wl_seat_interface.name) == 0) {
		v->seat = wl_registry_bind(registry, name, &wl_seat_interface, 5);
		wl_seat_add_listener(v->seat, &seat_listener, v);
	} else if (strcmp(interface, xdg_wm_base_interface.name) == 0) {
		v->wm_base = wl_registry_bind(registry, name, &xdg_wm_base_interface, 1);
		xdg_wm_base_add_listener(v->wm_base, &wm_base_listener, v);
	}
}

static void registry_global_remove(void *data, struct wl_registry *registry,
		uint32_t name) {
	(void)data; (void)registry; (void)name;
}

static const struct wl_registry_listener registry_listener = {
	.global = registry_global,
	.global_remove = registry_global_remove,
};

int main(int argc, char **argv) {
	struct novi_view v = {0};
	v.running = true;
	v.fit = true;
	v.width = WINDOW_WIDTH;
	v.height = WINDOW_HEIGHT;

	if (argc != 2) {
		fprintf(stderr, "usage: novi-view FILE\n");
		return 2;
	}
	snprintf(v.path, sizeof(v.path), "%s", argv[1]);

	/* Decode before opening a window. A file that is not an image
	 * should say so on the terminal and exit, not flash up an empty
	 * window with an error in its status bar -- when novi-files
	 * dispatches by extension it can be wrong, and being wrong should
	 * be cheap. */
	if (!load_image(&v, v.path)) {
		fprintf(stderr, "novi-view: %s: %s\n", v.path,
			v.status[0] ? v.status : "cannot decode");
		return 1;
	}

	v.display = wl_display_connect(NULL);
	if (v.display == NULL) {
		fprintf(stderr, "novi-view: failed to connect to Wayland display "
			"(is WAYLAND_DISPLAY set?)\n");
		return 1;
	}
	v.xkb_context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
	v.registry = wl_display_get_registry(v.display);
	wl_registry_add_listener(v.registry, &registry_listener, &v);
	wl_display_roundtrip(v.display);

	if (v.compositor == NULL || v.shm == NULL || v.wm_base == NULL) {
		fprintf(stderr, "novi-view: compositor is missing a required global\n");
		return 1;
	}

	v.font_small = novi_text_load_font("JetBrains Mono:size=12");
	if (v.font_small == NULL) {
		fprintf(stderr, "novi-view: failed to load JetBrains Mono\n");
		return 1;
	}

	v.surface = wl_compositor_create_surface(v.compositor);
	v.xdg_surface = xdg_wm_base_get_xdg_surface(v.wm_base, v.surface);
	xdg_surface_add_listener(v.xdg_surface, &xdg_surface_listener_impl, &v);
	v.xdg_toplevel = xdg_surface_get_toplevel(v.xdg_surface);
	xdg_toplevel_add_listener(v.xdg_toplevel, &toplevel_listener, &v);

	/* The suffix is 17 bytes, not 16: the em-dash is three of them.
	 * A PATH_MAX path plus a suffix that does not fit is a title cut
	 * short -- harmless, but it is also a warning on every build, and
	 * a warning nobody can act on is how a build stops being read. */
	char title[PATH_MAX + 32];
	snprintf(title, sizeof(title), "%s — Image Viewer", v.path);
	xdg_toplevel_set_title(v.xdg_toplevel, title);
	xdg_toplevel_set_app_id(v.xdg_toplevel, "novi-view");

	wl_surface_commit(v.surface);

	while (v.running && wl_display_dispatch(v.display) != -1) {
		;
	}

	free(v.img);
	if (v.xkb_state != NULL) { xkb_state_unref(v.xkb_state); }
	if (v.xkb_keymap != NULL) { xkb_keymap_unref(v.xkb_keymap); }
	if (v.xkb_context != NULL) { xkb_context_unref(v.xkb_context); }
	wl_display_disconnect(v.display);
	return 0;
}
