/* novi-bg — the desktop background.
 *
 * A layer-shell client on the background layer that paints a gradient
 * and then does nothing. No timer, no socket, no input: it draws on
 * configure and sleeps.
 *
 * WHY THIS IS A CLIENT AND NOT A COLOUR IN THE COMPOSITOR. novi-shell
 * had a `wlr_scene_rect` behind everything, added because otherwise an
 * empty desktop showed the scene's clear colour -- pure black,
 * indistinguishable from a monitor that is not being driven. Its own
 * comment calls it flat. A scene rect is one solid colour by
 * construction; there is no gradient to be had from it without
 * teaching the compositor to rasterise, which is exactly the UI work
 * RFC 0001 says does not belong there. swaybg solves this the same
 * way, for the same reason.
 *
 * GENERATED, NOT AN IMAGE FILE. No asset to ship, no decoder to link,
 * no resolution to be wrong at, and it costs about forty lines. A
 * photograph would also be a claim about taste that a distribution
 * should let its users make rather than make for them; a dark gradient
 * is the neutral ground everything else in the design language was
 * drawn against.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include <wayland-client.h>

#include "wlr-layer-shell-unstable-v1-protocol.h"
#include "../common/theme.h"

struct bg {
	struct wl_display *display;
	struct wl_registry *registry;
	struct wl_compositor *compositor;
	struct wl_shm *shm;
	struct zwlr_layer_shell_v1 *layer_shell;
	struct wl_surface *surface;
	struct zwlr_layer_surface_v1 *layer_surface;
	uint32_t width, height;
	bool configured;
	bool running;
};

static uint8_t clamp8(double v) {
	if (v <= 0.0) {
		return 0;
	}
	if (v >= 255.0) {
		return 255;
	}
	return (uint8_t)(v + 0.5);
}

/* Two things, composited: a vertical ramp, and one soft off-centre
 * glow in the accent hue at a few percent.
 *
 * The glow is what stops this reading as a flat fill. A pure vertical
 * ramp on a near-black palette is nearly invisible -- the eye needs a
 * light SOURCE, not a gradient, to read a surface as lit. It sits
 * up-left of centre because that is where a viewer assumes light comes
 * from, and it is weak enough (6% peak) that it never competes with an
 * actual accent-coloured control.
 *
 * smoothstep rather than a linear falloff: a linear radial edge leaves
 * a visible ring at the radius, which is the exact artefact that makes
 * a generated background look generated.
 */
static void paint(uint32_t *px, int w, int h, int stride_px) {
	const double top[3]    = { 0x11, 0x12, 0x1b };
	const double bottom[3] = { 0x07, 0x07, 0x0b };

	const double gx = w * 0.32, gy = h * 0.22;
	const double gr = (w > h ? w : h) * 0.95;
	const double gcol[3] = { 0x2d, 0xd4, 0xbf };  /* NOVI_ACCENT */
	const double gpeak = 0.06;

	for (int y = 0; y < h; y++) {
		double t = h > 1 ? (double)y / (h - 1) : 0.0;
		for (int x = 0; x < w; x++) {
			double dx = x - gx, dy = y - gy;
			double d = sqrt(dx * dx + dy * dy) / gr;
			double g = 0.0;
			if (d < 1.0) {
				/* smoothstep(1, 0, d) */
				double u = 1.0 - d;
				g = u * u * (3.0 - 2.0 * u) * gpeak;
			}
			double c[3];
			for (int i = 0; i < 3; i++) {
				c[i] = top[i] + (bottom[i] - top[i]) * t;
				c[i] += (gcol[i] - c[i]) * g;
			}
			px[y * stride_px + x] = 0xff000000u |
				((uint32_t)clamp8(c[0]) << 16) |
				((uint32_t)clamp8(c[1]) << 8) |
				(uint32_t)clamp8(c[2]);
		}
	}
}

static int allocate_shm_file(size_t size) {
	char name[] = "/novi-bg-XXXXXX";
	for (int retries = 100; retries > 0; retries--) {
		struct timespec ts;
		clock_gettime(CLOCK_REALTIME, &ts);
		long r = ts.tv_nsec;
		for (int i = 0; i < 6; i++, r >>= 5) {
			name[sizeof(name) - 7 + i] = 'A' + (r & 15) + (r & 16) * 2;
		}
		int fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
		if (fd >= 0) {
			shm_unlink(name);
			if (ftruncate(fd, (off_t)size) < 0) {
				close(fd);
				return -1;
			}
			return fd;
		}
		if (errno != EEXIST) {
			return -1;
		}
	}
	return -1;
}

static void draw(struct bg *b) {
	if (!b->configured || b->width == 0 || b->height == 0) {
		return;
	}
	uint32_t stride = b->width * 4;
	size_t size = (size_t)stride * b->height;

	int fd = allocate_shm_file(size);
	if (fd < 0) {
		return;
	}
	uint32_t *px = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (px == MAP_FAILED) {
		close(fd);
		return;
	}
	struct wl_shm_pool *pool = wl_shm_create_pool(b->shm, fd, (int32_t)size);
	struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0,
		(int32_t)b->width, (int32_t)b->height, (int32_t)stride,
		WL_SHM_FORMAT_XRGB8888);
	wl_shm_pool_destroy(pool);
	close(fd);

	paint(px, (int)b->width, (int)b->height, (int)b->width);
	munmap(px, size);

	/* An empty input region: the desktop background must never take a
	 * click. Without this the background surface swallows every press
	 * that does not land on a window, which on a desktop whose only
	 * other surfaces are the panel and the occasional toast means
	 * almost all of them. */
	struct wl_region *empty = wl_compositor_create_region(b->compositor);
	if (empty != NULL) {
		wl_surface_set_input_region(b->surface, empty);
		wl_region_destroy(empty);
	}

	wl_surface_attach(b->surface, buffer, 0, 0);
	wl_surface_damage_buffer(b->surface, 0, 0, (int32_t)b->width,
		(int32_t)b->height);
	wl_surface_commit(b->surface);
	wl_buffer_destroy(buffer);
}

static void layer_surface_configure(void *data,
		struct zwlr_layer_surface_v1 *surface, uint32_t serial,
		uint32_t w, uint32_t h) {
	struct bg *b = data;
	zwlr_layer_surface_v1_ack_configure(surface, serial);
	b->width = w;
	b->height = h;
	b->configured = true;
	draw(b);
}

static void layer_surface_closed(void *data,
		struct zwlr_layer_surface_v1 *surface) {
	(void)surface;
	((struct bg *)data)->running = false;
}

static const struct zwlr_layer_surface_v1_listener layer_surface_listener = {
	.configure = layer_surface_configure,
	.closed = layer_surface_closed,
};

static void registry_global(void *data, struct wl_registry *registry,
		uint32_t name, const char *interface, uint32_t version) {
	(void)version;
	struct bg *b = data;
	if (strcmp(interface, wl_compositor_interface.name) == 0) {
		b->compositor = wl_registry_bind(registry, name,
			&wl_compositor_interface, 4);
	} else if (strcmp(interface, wl_shm_interface.name) == 0) {
		b->shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
	} else if (strcmp(interface, zwlr_layer_shell_v1_interface.name) == 0) {
		b->layer_shell = wl_registry_bind(registry, name,
			&zwlr_layer_shell_v1_interface, 1);
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
	struct bg b;
	memset(&b, 0, sizeof(b));
	b.running = true;

	b.display = wl_display_connect(NULL);
	if (b.display == NULL) {
		fprintf(stderr, "novi-bg: no Wayland display\n");
		return 1;
	}
	b.registry = wl_display_get_registry(b.display);
	wl_registry_add_listener(b.registry, &registry_listener, &b);
	wl_display_roundtrip(b.display);

	if (b.compositor == NULL || b.shm == NULL || b.layer_shell == NULL) {
		fprintf(stderr, "novi-bg: compositor is missing a required global\n");
		return 1;
	}

	b.surface = wl_compositor_create_surface(b.compositor);
	b.layer_surface = zwlr_layer_shell_v1_get_layer_surface(
		b.layer_shell, b.surface, NULL,
		ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND, "novi-bg");
	/* Size 0x0 with all four anchors means "the whole output, whatever
	 * that is" -- the compositor answers the configure with the real
	 * dimensions, and answers again if the mode changes. Asking for a
	 * fixed size here would be a wallpaper that is wrong on every
	 * monitor but the one it was written on. */
	zwlr_layer_surface_v1_set_size(b.layer_surface, 0, 0);
	zwlr_layer_surface_v1_set_anchor(b.layer_surface,
		ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP |
		ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM |
		ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT |
		ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT);
	/* -1: ignore other surfaces' exclusive zones. The wallpaper goes
	 * behind the panel, not beside it. */
	zwlr_layer_surface_v1_set_exclusive_zone(b.layer_surface, -1);
	zwlr_layer_surface_v1_set_keyboard_interactivity(b.layer_surface,
		ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE);
	zwlr_layer_surface_v1_add_listener(b.layer_surface,
		&layer_surface_listener, &b);
	wl_surface_commit(b.surface);

	/* Nothing to poll: no timer, no socket, no input. The only events
	 * this ever sees are a configure when the output resolution
	 * changes and the compositor going away. */
	while (b.running && wl_display_dispatch(b.display) != -1) {
		;
	}
	wl_display_disconnect(b.display);
	return 0;
}
