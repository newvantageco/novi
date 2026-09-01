/* novi-panel — top bar (part of RFC 0001's "novi-shell" UI layer).
 *
 * Another separate wlr-layer-shell-v1 client, same split novi-launcher
 * established: novi-shell (the compositor) owns no UI of its own, this
 * process owns the always-visible chrome. Anchored full-width to the
 * top edge, top layer, with a positive exclusive zone so it reserves
 * real screen space rather than floating over other content.
 *
 * v1 scope is deliberately narrow: a live clock, nothing else. No
 * workspace switcher (novi-shell has no workspace concept yet), no
 * app launcher button (Alt+Space already opens novi-launcher directly,
 * and there's no app registry for a launcher button to open anyway --
 * see novi-launcher/main.c's own header comment), no click handling
 * at all (novi-shell doesn't route pointer input to layer-shell
 * surfaces yet). Each of those is real, separate follow-up work, not
 * an oversight here.
 *
 * Rendering uses real, anti-aliased text via fcft+pixman (see
 * common/text.h) -- the same font-rendering pipeline foot itself
 * uses for terminal glyphs, and JetBrains Mono, the same font
 * build/09-foot.sh already installs. This replaces an earlier
 * hand-drawn 3x5 bitmap font placeholder, which existed only because
 * nothing else in this repo needed real font rendering before foot.
 */
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/timerfd.h>
#include <time.h>
#include <poll.h>
#include <unistd.h>
#include <wayland-client.h>

#include "wlr-layer-shell-unstable-v1-protocol.h"
#include "../common/text.h"

#define PANEL_HEIGHT 32
#define BG_COLOR 0xff181820u /* opaque near-black, XRGB8888 */
#define BORDER_COLOR 0xff3a3a4au

struct novi_panel {
	struct wl_display *display;
	struct wl_registry *registry;
	struct wl_compositor *compositor;
	struct wl_shm *shm;
	struct zwlr_layer_shell_v1 *layer_shell;

	struct wl_surface *surface;
	struct zwlr_layer_surface_v1 *layer_surface;

	struct fcft_font *font;

	uint32_t width, height;
	bool configured;
	bool running;
};

static int allocate_shm_file(size_t size) {
	char name[] = "/novi-panel-XXXXXX";
	struct timespec ts;
	int fd = -1;
	for (int tries = 0; tries < 100 && fd < 0; tries++) {
		clock_gettime(CLOCK_REALTIME, &ts);
		long r = ts.tv_nsec + tries;
		for (int i = 0; i < 6; i++) {
			name[12 + i] = 'A' + (r & 15) + (r & 16) * 2;
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

static void draw_rect(uint32_t *px, uint32_t stride_px, uint32_t buf_w,
		uint32_t buf_h, int x, int y, int w, int h, uint32_t color) {
	for (int row = y; row < y + h && row < (int)buf_h; row++) {
		if (row < 0) {
			continue;
		}
		for (int col = x; col < x + w && col < (int)buf_w; col++) {
			if (col < 0) {
				continue;
			}
			px[row * (int)stride_px + col] = color;
		}
	}
}

static void render(struct novi_panel *panel, uint32_t *px, uint32_t stride_px) {
	uint32_t w = panel->width, h = panel->height;
	draw_rect(px, stride_px, w, h, 0, 0, (int)w, (int)h, BG_COLOR);
	draw_rect(px, stride_px, w, h, 0, (int)h - 1, (int)w, 1, BORDER_COLOR);

	time_t now = time(NULL);
	struct tm tm_now;
	localtime_r(&now, &tm_now);
	char clock_str[9];
	snprintf(clock_str, sizeof(clock_str), "%02d:%02d:%02d",
		tm_now.tm_hour, tm_now.tm_min, tm_now.tm_sec);

	/* Wraps the same buffer draw_rect() already filled above -- both
	 * write into the identical memory in place, no double buffering.
	 * _no_clear: the background is already painted, no need for
	 * pixman to zero it again. */
	pixman_image_t *dest = pixman_image_create_bits_no_clear(
		PIXMAN_x8r8g8b8, (int)w, (int)h, px, (int)stride_px * 4);

	static const pixman_color_t clock_color = {
		.red = 0xe000, .green = 0xe000, .blue = 0xf000, .alpha = 0xffff,
	};
	int text_w = novi_text_width(panel->font, clock_str);
	int text_x = (int)w - text_w - 12;
	int baseline_y = ((int)h + panel->font->ascent - panel->font->descent) / 2;
	novi_text_draw(dest, panel->font, text_x, baseline_y, clock_str, clock_color);

	pixman_image_unref(dest);
}

static void surface_draw_frame(struct novi_panel *panel) {
	if (!panel->configured) {
		return;
	}
	uint32_t stride = panel->width * 4;
	size_t size = (size_t)stride * panel->height;

	int fd = allocate_shm_file(size);
	if (fd < 0) {
		fprintf(stderr, "novi-panel: failed to allocate shm buffer\n");
		return;
	}
	uint32_t *data = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (data == MAP_FAILED) {
		fprintf(stderr, "novi-panel: mmap failed\n");
		close(fd);
		return;
	}

	struct wl_shm_pool *pool = wl_shm_create_pool(panel->shm, fd, (int32_t)size);
	struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0,
		(int32_t)panel->width, (int32_t)panel->height, (int32_t)stride,
		WL_SHM_FORMAT_XRGB8888);
	wl_shm_pool_destroy(pool);
	/* Flush before closing: wl_shm_create_pool's fd is only actually
	 * written to the socket (as SCM_RIGHTS ancillary data) at the next
	 * real flush, not at the moment this call returns -- confirmed
	 * live, the hard way: this client's own hand-rolled poll loop
	 * (prepare_read/poll/read_events, not a plain wl_display_dispatch()
	 * loop) left enough of a gap between this close() and the loop's
	 * own next flush() that the fd was already invalid by write time,
	 * and wlroots rejected the request server-side: "file descriptor
	 * expected, object (4), message create_pool(nhi)". Flushing here
	 * removes any dependency on the caller's own event-loop timing. */
	wl_display_flush(panel->display);
	close(fd);

	render(panel, data, panel->width);
	munmap(data, size);

	wl_surface_attach(panel->surface, buffer, 0, 0);
	wl_surface_damage_buffer(panel->surface, 0, 0,
		(int32_t)panel->width, (int32_t)panel->height);
	wl_surface_commit(panel->surface);
	/* Same v1 simplification as novi-launcher: buffer release isn't
	 * tracked, so this leaks one buffer per redraw (once a second
	 * here). Acceptable for now, not for a compositor-lifetime daemon
	 * -- tracked alongside novi-launcher's identical note. */
}

static void layer_surface_configure(void *data,
		struct zwlr_layer_surface_v1 *layer_surface, uint32_t serial,
		uint32_t width, uint32_t height) {
	struct novi_panel *panel = data;
	zwlr_layer_surface_v1_ack_configure(layer_surface, serial);
	panel->width = width > 0 ? width : 1920;
	panel->height = height > 0 ? height : PANEL_HEIGHT;
	panel->configured = true;
	surface_draw_frame(panel);
}

static void layer_surface_closed(void *data,
		struct zwlr_layer_surface_v1 *layer_surface) {
	(void)layer_surface;
	struct novi_panel *panel = data;
	panel->running = false;
}

static const struct zwlr_layer_surface_v1_listener layer_surface_listener = {
	.configure = layer_surface_configure,
	.closed = layer_surface_closed,
};

static void registry_global(void *data, struct wl_registry *registry,
		uint32_t name, const char *interface, uint32_t version) {
	(void)version;
	struct novi_panel *panel = data;
	if (strcmp(interface, wl_compositor_interface.name) == 0) {
		panel->compositor = wl_registry_bind(registry, name,
			&wl_compositor_interface, 4);
	} else if (strcmp(interface, wl_shm_interface.name) == 0) {
		panel->shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
	} else if (strcmp(interface, zwlr_layer_shell_v1_interface.name) == 0) {
		panel->layer_shell = wl_registry_bind(registry, name,
			&zwlr_layer_shell_v1_interface, 4);
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
	struct novi_panel panel = {0};
	panel.running = true;

	panel.display = wl_display_connect(NULL);
	if (panel.display == NULL) {
		fprintf(stderr, "novi-panel: failed to connect to Wayland display "
			"(is WAYLAND_DISPLAY set?)\n");
		return 1;
	}

	panel.registry = wl_display_get_registry(panel.display);
	wl_registry_add_listener(panel.registry, &registry_listener, &panel);
	wl_display_roundtrip(panel.display);

	if (panel.compositor == NULL || panel.shm == NULL ||
			panel.layer_shell == NULL) {
		fprintf(stderr, "novi-panel: compositor is missing a required "
			"global (wl_compositor/wl_shm/zwlr_layer_shell_v1)\n");
		return 1;
	}

	panel.font = novi_text_load_font("JetBrains Mono:size=11");
	if (panel.font == NULL) {
		fprintf(stderr, "novi-panel: failed to load JetBrains Mono\n");
		return 1;
	}

	panel.surface = wl_compositor_create_surface(panel.compositor);
	panel.layer_surface = zwlr_layer_shell_v1_get_layer_surface(
		panel.layer_shell, panel.surface, NULL,
		ZWLR_LAYER_SHELL_V1_LAYER_TOP, "novi-panel");
	zwlr_layer_surface_v1_set_size(panel.layer_surface, 0, PANEL_HEIGHT);
	zwlr_layer_surface_v1_set_anchor(panel.layer_surface,
		ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP |
		ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT |
		ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT);
	zwlr_layer_surface_v1_set_exclusive_zone(panel.layer_surface, PANEL_HEIGHT);
	zwlr_layer_surface_v1_set_keyboard_interactivity(panel.layer_surface,
		ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE);
	zwlr_layer_surface_v1_add_listener(panel.layer_surface,
		&layer_surface_listener, &panel);

	wl_surface_commit(panel.surface);

	/* A plain wl_display has no built-in periodic timer (that's a
	 * wl_event_loop / server-side feature, not exposed to clients) --
	 * the standard client-side pattern is to drive the Wayland fd and
	 * a timerfd through the same poll() loop, using
	 * prepare_read/read_events/cancel_read for correct multi-thread-
	 * safe dispatch even though this client is single-threaded (it's
	 * still the only way to poll() the display fd without racing
	 * wl_display_dispatch()'s own internal read). */
	int timer_fd = timerfd_create(CLOCK_REALTIME, 0);
	if (timer_fd < 0) {
		fprintf(stderr, "novi-panel: timerfd_create failed\n");
		return 1;
	}
	struct itimerspec its = {
		.it_interval = {.tv_sec = 1, .tv_nsec = 0},
		.it_value = {.tv_sec = 1, .tv_nsec = 0},
	};
	timerfd_settime(timer_fd, 0, &its, NULL);

	while (panel.running) {
		while (wl_display_prepare_read(panel.display) != 0) {
			if (wl_display_dispatch_pending(panel.display) < 0) {
				panel.running = false;
				break;
			}
		}
		wl_display_flush(panel.display);

		struct pollfd fds[2] = {
			{.fd = wl_display_get_fd(panel.display), .events = POLLIN},
			{.fd = timer_fd, .events = POLLIN},
		};
		int ret = poll(fds, 2, -1);
		if (ret < 0) {
			wl_display_cancel_read(panel.display);
			break;
		}

		if (fds[0].revents & POLLIN) {
			wl_display_read_events(panel.display);
		} else {
			wl_display_cancel_read(panel.display);
		}
		if (wl_display_dispatch_pending(panel.display) < 0) {
			break;
		}

		if (fds[1].revents & POLLIN) {
			uint64_t expirations;
			if (read(timer_fd, &expirations, sizeof(expirations)) > 0) {
				surface_draw_frame(&panel);
			}
		}
	}

	close(timer_fd);
	if (panel.layer_surface != NULL) {
		zwlr_layer_surface_v1_destroy(panel.layer_surface);
	}
	if (panel.surface != NULL) {
		wl_surface_destroy(panel.surface);
	}
	if (panel.font != NULL) {
		fcft_destroy(panel.font);
	}
	wl_display_disconnect(panel.display);
	return 0;
}
