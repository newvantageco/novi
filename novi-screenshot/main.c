/* novi-screenshot — PrintScreen capture (RFC 0001 decision 7).
 *
 * A one-shot tool, not a persistent UI surface: unlike novi-launcher/
 * novi-panel it creates no wl_surface of its own -- it captures one
 * frame via wlr-screencopy-unstable-v1 (the standard protocol grim and
 * every other wlroots screenshot tool use; novi-shell's own server
 * side is a single wlr_screencopy_manager_v1_create() call, the exact
 * same "wlroots implements the protocol, we just enable it" shape as
 * wlr_data_device_manager_v1/wlr_foreign_toplevel_manager_v1), writes
 * it to a BMP file, and exits. novi-shell spawns a fresh instance on
 * PrintScreen the same way it spawns novi-launcher on Alt+Space.
 *
 * v1 scope: whole-output capture only (`capture_output`), not
 * `capture_output_region` -- RFC 0001's Shift+PrintScreen "region
 * select" needs an interactive rubber-band-selection overlay client,
 * a real UI surface this tool deliberately isn't; that binding stays
 * unwired until that overlay exists, tracked as a follow-up rather
 * than half-built here. Also file-only, not "clipboard + file" as RFC
 * 0001 describes -- copying an image to the clipboard needs the same
 * wl_data_source machinery novi-launcher's symbol picker already
 * proved out for text, just with an image/bmp MIME type instead of
 * text/plain; a real, separate follow-up, not done in this pass.
 *
 * BMP, not PNG: this repo has zero image *encoding* capability
 * anywhere (ICON-PIPELINE.md's own "zero image-loading capability"
 * finding was about *decoding*, but the same is true in reverse -- no
 * libpng, no zlib-based compressor, nothing). A 24-bit uncompressed
 * BMP needs none of that (a fixed 54-byte header plus raw, unpacked
 * pixel rows) while still being a real, widely-recognized image format
 * any image viewer can open, not a placeholder. Real PNG output is
 * future work gated on actually vendoring an encoder, the same
 * "reuse, don't reinvent" judgment ICON-PIPELINE.md already made for
 * SVG rasterization.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>

#include "wlr-screencopy-unstable-v1-protocol.h"

struct novi_screenshot {
	struct wl_display *display;
	struct wl_registry *registry;
	struct wl_shm *shm;
	struct wl_output *output;
	struct zwlr_screencopy_manager_v1 *screencopy_manager;

	struct zwlr_screencopy_frame_v1 *frame;
	uint32_t shm_format;
	uint32_t width, height, stride;
	bool y_invert;

	uint32_t *pixels; /* mmap'd shm buffer, valid once `done` is true */
	bool done;
	bool failed;
};

static int allocate_shm_file(size_t size) {
	char name[] = "/novi-screenshot-XXXXXX";
	struct timespec ts;
	int fd = -1;
	for (int tries = 0; tries < 100 && fd < 0; tries++) {
		clock_gettime(CLOCK_REALTIME, &ts);
		long r = ts.tv_nsec + tries;
		for (int i = 0; i < 6; i++) {
			name[17 + i] = 'A' + (r & 15) + (r & 16) * 2;
			r >>= 5;
		}
		fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
	}
	if (fd < 0) {
		return -1;
	}
	shm_unlink(name);
	if (ftruncate(fd, (off_t)size) < 0) {
		close(fd);
		return -1;
	}
	return fd;
}

/* Writes `pixels` (top-down or bottom-up per `y_invert`, 32bpp with a
 * B,G,R byte order in the low 3 bytes -- true for every wl_shm format
 * the pixman renderer this repo builds against actually produces,
 * ARGB8888 and XRGB8888 alike, since both agree on channel order and
 * differ only in whether the 4th byte is meaningful) as an
 * uncompressed 24-bit BMP. BMP's own native row order is bottom-up,
 * which conveniently needs no format-specific pixel repacking beyond
 * dropping each pixel's 4th (alpha/pad) byte -- just a row-order
 * choice, made explicit here rather than left to auto-detection. */
static bool write_bmp(const char *path, const uint32_t *pixels,
		uint32_t width, uint32_t height, uint32_t stride_px, bool y_invert) {
	FILE *f = fopen(path, "wb");
	if (f == NULL) {
		fprintf(stderr, "novi-screenshot: cannot open %s: %s\n",
			path, strerror(errno));
		return false;
	}

	uint32_t row_bytes = width * 3;
	uint32_t bmp_stride = (row_bytes + 3) & ~3u; /* rows padded to 4 bytes */
	uint32_t pixel_data_size = bmp_stride * height;
	uint32_t file_size = 14 + 40 + pixel_data_size;

	uint8_t file_header[14] = {
		'B', 'M',
		(uint8_t)(file_size), (uint8_t)(file_size >> 8),
		(uint8_t)(file_size >> 16), (uint8_t)(file_size >> 24),
		0, 0, 0, 0, /* reserved */
		54, 0, 0, 0, /* pixel data offset: 14 + 40 */
	};
	fwrite(file_header, 1, sizeof(file_header), f);

	uint8_t info_header[40] = {0};
	info_header[0] = 40; /* biSize */
	memcpy(&info_header[4], &width, 4);
	memcpy(&info_header[8], &height, 4); /* positive: bottom-up in the file */
	info_header[12] = 1; /* biPlanes */
	info_header[14] = 24; /* biBitCount */
	memcpy(&info_header[20], &pixel_data_size, 4);
	fwrite(info_header, 1, sizeof(info_header), f);

	uint8_t *row_buf = calloc(1, bmp_stride);
	bool ok = true;
	for (uint32_t file_row = 0; file_row < height && ok; file_row++) {
		/* File row 0 is the bottom of the image (BMP's own convention).
		 * Map that back to whichever source row is actually the bottom,
		 * depending on the compositor-reported y_invert flag, rather
		 * than assuming a fixed source orientation. */
		uint32_t src_row = y_invert ? file_row : (height - 1 - file_row);
		const uint32_t *src = pixels + (size_t)src_row * stride_px;
		for (uint32_t x = 0; x < width; x++) {
			uint32_t px = src[x];
			row_buf[x * 3 + 0] = (uint8_t)(px & 0xff);         /* B */
			row_buf[x * 3 + 1] = (uint8_t)((px >> 8) & 0xff);  /* G */
			row_buf[x * 3 + 2] = (uint8_t)((px >> 16) & 0xff); /* R */
		}
		if (fwrite(row_buf, 1, bmp_stride, f) != bmp_stride) {
			ok = false;
		}
	}
	free(row_buf);
	fclose(f);
	if (!ok) {
		fprintf(stderr, "novi-screenshot: short write to %s\n", path);
	}
	return ok;
}

static void frame_handle_buffer(void *data, struct zwlr_screencopy_frame_v1 *frame,
		uint32_t format, uint32_t width, uint32_t height, uint32_t stride) {
	(void)frame;
	struct novi_screenshot *state = data;
	state->shm_format = format;
	state->width = width;
	state->height = height;
	state->stride = stride;

	size_t size = (size_t)stride * height;
	int fd = allocate_shm_file(size);
	if (fd < 0) {
		fprintf(stderr, "novi-screenshot: failed to allocate shm buffer\n");
		state->failed = true;
		return;
	}
	state->pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (state->pixels == MAP_FAILED) {
		fprintf(stderr, "novi-screenshot: mmap failed\n");
		close(fd);
		state->failed = true;
		return;
	}

	struct wl_shm_pool *pool = wl_shm_create_pool(state->shm, fd, (int32_t)size);
	struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0,
		(int32_t)width, (int32_t)height, (int32_t)stride, format);
	wl_shm_pool_destroy(pool);
	wl_display_flush(state->display); /* see novi-launcher's identical note on why */
	close(fd);

	zwlr_screencopy_frame_v1_copy(frame, buffer);
}

static void frame_handle_flags(void *data, struct zwlr_screencopy_frame_v1 *frame,
		uint32_t flags) {
	(void)frame;
	struct novi_screenshot *state = data;
	state->y_invert = (flags & ZWLR_SCREENCOPY_FRAME_V1_FLAGS_Y_INVERT) != 0;
}

static void frame_handle_ready(void *data, struct zwlr_screencopy_frame_v1 *frame,
		uint32_t tv_sec_hi, uint32_t tv_sec_lo, uint32_t tv_nsec) {
	(void)frame; (void)tv_sec_hi; (void)tv_sec_lo; (void)tv_nsec;
	struct novi_screenshot *state = data;
	state->done = true;
}

static void frame_handle_failed(void *data, struct zwlr_screencopy_frame_v1 *frame) {
	(void)frame;
	struct novi_screenshot *state = data;
	state->failed = true;
}

static void frame_handle_damage(void *data, struct zwlr_screencopy_frame_v1 *frame,
		uint32_t x, uint32_t y, uint32_t width, uint32_t height) {
	(void)data; (void)frame; (void)x; (void)y; (void)width; (void)height;
	/* Only sent for copy_with_damage, which this tool never requests
	 * (a screenshot wants the whole current frame, not "wait for the
	 * next change") -- kept as a no-op stub since the listener struct
	 * still declares the field. */
}

static void frame_handle_linux_dmabuf(void *data, struct zwlr_screencopy_frame_v1 *frame,
		uint32_t format, uint32_t width, uint32_t height) {
	(void)data; (void)frame; (void)format; (void)width; (void)height;
	/* Binding the manager at version 1 (see registry_global()) means
	 * this event is never actually sent (added in version 3) -- a
	 * no-op stub for the same "listener struct declares every field"
	 * reason as frame_handle_damage() above. */
}

static void frame_handle_buffer_done(void *data, struct zwlr_screencopy_frame_v1 *frame) {
	(void)data; (void)frame;
	/* Version-3-only, like linux_dmabuf above; never fires at version 1. */
}

static const struct zwlr_screencopy_frame_v1_listener frame_listener = {
	.buffer = frame_handle_buffer,
	.flags = frame_handle_flags,
	.ready = frame_handle_ready,
	.failed = frame_handle_failed,
	.damage = frame_handle_damage,
	.linux_dmabuf = frame_handle_linux_dmabuf,
	.buffer_done = frame_handle_buffer_done,
};

static void registry_global(void *data, struct wl_registry *registry,
		uint32_t name, const char *interface, uint32_t version) {
	(void)version;
	struct novi_screenshot *state = data;
	if (strcmp(interface, wl_shm_interface.name) == 0) {
		state->shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
	} else if (strcmp(interface, wl_output_interface.name) == 0) {
		/* First output only -- this repo's compositor is single-output
		 * today (see novi-shell's own initial-placement comments making
		 * the same simplification), so there's nothing to choose between
		 * yet. */
		if (state->output == NULL) {
			state->output = wl_registry_bind(registry, name, &wl_output_interface, 1);
		}
	} else if (strcmp(interface, zwlr_screencopy_manager_v1_interface.name) == 0) {
		/* Version 1: the buffer event is unconditionally guaranteed at
		 * this version (no buffer_done gate to wait through), and this
		 * tool only ever wants a plain wl_shm buffer -- the linux-dmabuf
		 * path (version 3) buys nothing here. */
		state->screencopy_manager = wl_registry_bind(registry, name,
			&zwlr_screencopy_manager_v1_interface, 1);
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

int main(void) {
	struct novi_screenshot state = {0};

	state.display = wl_display_connect(NULL);
	if (state.display == NULL) {
		fprintf(stderr, "novi-screenshot: failed to connect to Wayland display "
			"(is WAYLAND_DISPLAY set?)\n");
		return 1;
	}

	state.registry = wl_display_get_registry(state.display);
	wl_registry_add_listener(state.registry, &registry_listener, &state);
	wl_display_roundtrip(state.display);

	if (state.shm == NULL || state.output == NULL || state.screencopy_manager == NULL) {
		fprintf(stderr, "novi-screenshot: compositor is missing a required "
			"global (wl_shm/wl_output/zwlr_screencopy_manager_v1)\n");
		return 1;
	}

	state.frame = zwlr_screencopy_manager_v1_capture_output(
		state.screencopy_manager, 1 /* overlay_cursor */, state.output);
	zwlr_screencopy_frame_v1_add_listener(state.frame, &frame_listener, &state);

	while (!state.done && !state.failed) {
		if (wl_display_dispatch(state.display) < 0) {
			state.failed = true;
			break;
		}
	}

	int result = 1;
	if (state.done && !state.failed && state.pixels != NULL) {
		time_t now = time(NULL);
		struct tm tm_now;
		localtime_r(&now, &tm_now);
		char path[128];
		snprintf(path, sizeof(path),
			"/root/screenshot-%04d%02d%02d-%02d%02d%02d.bmp",
			tm_now.tm_year + 1900, tm_now.tm_mon + 1, tm_now.tm_mday,
			tm_now.tm_hour, tm_now.tm_min, tm_now.tm_sec);
		if (write_bmp(path, state.pixels, state.width, state.height,
				state.stride / 4, state.y_invert)) {
			fprintf(stderr, "novi-screenshot: wrote %s\n", path);
			result = 0;
		}
	} else {
		fprintf(stderr, "novi-screenshot: capture failed\n");
	}

	if (state.pixels != NULL) {
		munmap(state.pixels, (size_t)state.stride * state.height);
	}
	wl_display_disconnect(state.display);
	return result;
}
