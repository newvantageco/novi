/* novi-panel — top bar (part of RFC 0001's "novi-shell" UI layer).
 *
 * Another separate wlr-layer-shell-v1 client, same split novi-launcher
 * established: novi-shell (the compositor) owns no UI of its own, this
 * process owns the always-visible chrome. Anchored full-width to the
 * top edge, top layer, with a positive exclusive zone so it reserves
 * real screen space rather than floating over other content.
 *
 * v1 scope was a live clock, nothing else -- that's grown by a
 * left-aligned "Apps" button (icon + text, per GUI-DESIGN-LANGUAGE.md
 * §7's spec) that opens novi-launcher on click, the mouse-driven
 * equivalent of Alt+Space. Getting a click to reach here needed the
 * client side of a gap novi-shell's compositor side had already closed
 * without a client to exercise it: wlr_seat_pointer_notify_enter/
 * motion/button() already route correctly to whatever wl_surface is
 * under the cursor (verified by reading desktop_toplevel_at() -- it
 * sets its `*surface` out-param before the toplevel-vs-layer-shell
 * discriminator check, so a layer-shell surface's wl_surface was
 * always being resolved correctly), but nothing reached this *client*
 * because it never created a wl_pointer to receive them. This is that
 * missing half: bind wl_seat, create a wl_pointer, track local surface
 * coordinates, and hit-test them against the button's own rect --
 * exactly how Wayland expects per-widget hit-testing to work (the
 * compositor only ever resolves "which surface," never "which button
 * inside it").
 *
 * The apps button's icon is Lucide's "layout-grid"
 * (https://lucide.dev, ISC-licensed -- verified directly against
 * lucide-icons/lucide's own LICENSE file, not assumed), hand-coded as
 * a parametric shape (see apps_icon_coverage()) rather than rasterized
 * from the actual SVG: this repo's build host has no SVG rasterizer
 * available (checked -- no rsvg-convert/ImageMagick/inkscape/
 * cairosvg), and the icon itself is simple enough (four stroked
 * rounded squares, confirmed by reading the real upstream SVG source)
 * that hand-coding it is squarely within docs/design/ICON-PIPELINE.md's
 * own sanctioned "a few purely parametric shapes hand-coded directly
 * rather than via SVG" category, not a shortcut around it.
 *
 * Still not done: workspace switcher (novi-shell has no workspace
 * concept yet), status icons (wifi/battery/power -- would reuse the
 * same coverage-mask technique, just needs real status data sources
 * this repo doesn't have yet).
 *
 * Rendering uses real, anti-aliased text via fcft+pixman (see
 * common/text.h) -- the same font-rendering pipeline foot itself
 * uses for terminal glyphs, and JetBrains Mono, the same font
 * build/09-foot.sh already installs. This replaces an earlier
 * hand-drawn 3x5 bitmap font placeholder, which existed only because
 * nothing else in this repo needed real font rendering before foot.
 */
#include <fcntl.h>
#include <linux/input-event-codes.h>
#include <math.h>
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
/* GUI-DESIGN-LANGUAGE.md's bg-card-raised / accent-subtle-bg tokens,
 * for the apps button's rest/hover backgrounds. */
#define BUTTON_BG_COLOR 0xff232430u
#define BUTTON_HOVER_BG_COLOR 0xff17302cu
/* Left edge / apps button internal padding, both from the same doc's
 * §3 spacing scale ("md" = 12px edge padding, button padding
 * 8px horizontal). */
#define PANEL_EDGE_PADDING 12
#define BUTTON_H_PADDING 8
#define BUTTON_V_MARGIN 4 /* top/bottom gap between button and panel edge */

/* Lucide's layout-grid.svg: four 7-unit rounded squares (rx=1) with a
 * 4-unit gap between them, 2-unit stroke, on a 24x24 canvas
 * (https://github.com/lucide-icons/lucide/blob/main/icons/layout-grid.svg,
 * fetched and read directly, not guessed). Reproduced here at its own
 * native square/gap/stroke units (7/4/2) rather than scaled to fill a
 * 24px canvas -- APPS_ICON_SIZE (18 = 2*7+4) comfortably fits the
 * button's 24px content height (BUTTON_V_MARGIN already applied) with
 * a few px of breathing room, and preserves Lucide's exact 7:4 square-
 * to-gap ratio and 2:7 stroke-to-square ratio (so the icon reads with
 * the same visual weight as the original), just at a smaller overall
 * canvas than 24px. */
#define APPS_ICON_SQUARE 7
#define APPS_ICON_GAP 4
#define APPS_ICON_RADIUS 1
#define APPS_ICON_STROKE 2
#define APPS_ICON_SIZE (2 * APPS_ICON_SQUARE + APPS_ICON_GAP)
#define APPS_ICON_TEXT_GAP 8 /* gap between the icon and the "Apps" label */
/* text-secondary / accent, matching apps_label_color/apps_label_hover_
 * color below exactly (same tokens, packed 0xRRGGBB here since the
 * icon is drawn via plain draw_rect()-style writes, not pixman). */
#define APPS_ICON_COLOR 0xa3a7b7u
#define APPS_ICON_HOVER_COLOR 0x2dd4bfu

/* RFC 0001 decision 7: Alt+Space already opens novi-launcher via
 * novi-shell directly; this is the same command, run from the panel
 * client instead, for the mouse-driven path. Kept as its own macro
 * (not shared with novi-shell's NOVI_DEFAULT_LAUNCHER) since these are
 * separate processes/binaries -- duplicating one string is simpler and
 * more honest than inventing shared config machinery for it. */
#define NOVI_DEFAULT_LAUNCHER "novi-launcher"

struct novi_panel {
	struct wl_display *display;
	struct wl_registry *registry;
	struct wl_compositor *compositor;
	struct wl_shm *shm;
	struct wl_seat *seat;
	struct wl_pointer *pointer;
	struct zwlr_layer_shell_v1 *layer_shell;

	struct wl_surface *surface;
	struct zwlr_layer_surface_v1 *layer_surface;

	struct fcft_font *font;
	int apps_button_w; /* text width of "Apps" + horizontal padding */

	double pointer_x, pointer_y; /* last-known surface-local coords */
	bool apps_button_hover;
	bool apps_button_pressed; /* press happened inside the button */

	uint32_t width, height;
	bool configured;
	bool running;
};

/* Same fork/exec/detach pattern novi-shell's own spawn() uses for its
 * keybindings -- setsid() so the launcher's lifetime isn't tied to
 * novi-panel, execl via /bin/sh so NOVI_LAUNCHER can be a full command
 * line, not just a bare binary path. */
static void spawn(const char *cmd) {
	pid_t pid = fork();
	if (pid < 0) {
		fprintf(stderr, "novi-panel: fork failed for \"%s\"\n", cmd);
		return;
	}
	if (pid == 0) {
		setsid();
		execl("/bin/sh", "/bin/sh", "-c", cmd, (void *)NULL);
		_exit(127);
	}
}

/* Single source of truth for the apps button's rect, used by both
 * render() (to draw it) and the pointer handlers (to hit-test it) --
 * computing it in two places would risk them drifting apart. */
static void apps_button_rect(const struct novi_panel *panel,
		int *x, int *y, int *w, int *h) {
	*x = PANEL_EDGE_PADDING;
	*y = BUTTON_V_MARGIN;
	*w = panel->apps_button_w;
	*h = (int)panel->height - 2 * BUTTON_V_MARGIN;
}

static bool point_in_apps_button(const struct novi_panel *panel,
		double px, double py) {
	int x, y, w, h;
	apps_button_rect(panel, &x, &y, &w, &h);
	return px >= x && px < x + w && py >= y && py < y + h;
}

static void surface_draw_frame(struct novi_panel *panel);

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

/* Signed distance from (px,py), relative to a rounded box's own
 * center, to that box's boundary: negative inside, positive outside,
 * magnitude is the distance to the nearest edge (corner arc included).
 * Inigo Quilez's widely-used 2D rounded-box SDF formula (public
 * domain) -- the same one novi-shell's drop-shadow code uses, applied
 * here rather than shared, since these are separate client binaries
 * with no shared geometry module yet. */
static double rounded_box_sdf(double px, double py, double half_w,
		double half_h, double radius) {
	double qx = fabs(px) - half_w + radius;
	double qy = fabs(py) - half_h + radius;
	double outside_x = qx > 0.0 ? qx : 0.0;
	double outside_y = qy > 0.0 ? qy : 0.0;
	double outside = sqrt(outside_x * outside_x + outside_y * outside_y);
	double inside = qx > qy ? qx : qy;
	if (inside > 0.0) {
		inside = 0.0;
	}
	return outside + inside - radius;
}

/* Per-pixel coverage [0,1] of the apps-grid icon at icon-local
 * coordinates (x,y) -- see APPS_ICON_* for where the icon's exact
 * geometry (Lucide's layout-grid.svg) comes from. A "stroke" (the
 * icon is a line icon, not filled, per GUI-DESIGN-LANGUAGE.md §5) is
 * just "distance to the shape's boundary is within half the stroke
 * width," directly expressible from the same signed-distance value a
 * filled shape's own edge-antialiasing would use -- keeping a band
 * around zero instead of everything <= 0. Checks all four squares and
 * takes the strongest hit; they never overlap (there's a real gap
 * between them), so at most one is ever non-zero per pixel, but max()
 * is the correct combine for a union of independent shapes regardless. */
static double apps_icon_coverage(double x, double y) {
	static const double square_pos[4][2] = {
		{0, 0},
		{APPS_ICON_SQUARE + APPS_ICON_GAP, 0},
		{APPS_ICON_SQUARE + APPS_ICON_GAP, APPS_ICON_SQUARE + APPS_ICON_GAP},
		{0, APPS_ICON_SQUARE + APPS_ICON_GAP},
	};
	double half = APPS_ICON_SQUARE / 2.0;
	double half_stroke = APPS_ICON_STROKE / 2.0;
	double best = 0.0;
	for (int i = 0; i < 4; i++) {
		double cx = square_pos[i][0] + half;
		double cy = square_pos[i][1] + half;
		double d = rounded_box_sdf(x - cx, y - cy, half, half, APPS_ICON_RADIUS);
		double dist_from_stroke_center = fabs(d) - half_stroke;
		double coverage = 0.5 - dist_from_stroke_center;
		if (coverage > 1.0) {
			coverage = 1.0;
		} else if (coverage < 0.0) {
			coverage = 0.0;
		}
		if (coverage > best) {
			best = coverage;
		}
	}
	return best;
}

/* Composites the icon onto the (already-opaque) button background at
 * (icon_x, icon_y) -- a plain linear blend toward tint_color per pixel
 * coverage, written back as another opaque pixel, since this buffer is
 * XRGB8888 throughout (novi-panel has no real alpha channel anywhere,
 * unlike novi-launcher; the button background under the icon is
 * already fully painted by the time this runs). */
static void draw_apps_icon(uint32_t *px, uint32_t stride_px, uint32_t buf_w,
		uint32_t buf_h, int icon_x, int icon_y, uint32_t tint_color) {
	uint8_t tint_r = (tint_color >> 16) & 0xff;
	uint8_t tint_g = (tint_color >> 8) & 0xff;
	uint8_t tint_b = tint_color & 0xff;
	for (int y = 0; y < APPS_ICON_SIZE; y++) {
		int py = icon_y + y;
		if (py < 0 || py >= (int)buf_h) {
			continue;
		}
		for (int x = 0; x < APPS_ICON_SIZE; x++) {
			int pxc = icon_x + x;
			if (pxc < 0 || pxc >= (int)buf_w) {
				continue;
			}
			double coverage = apps_icon_coverage(x + 0.5, y + 0.5);
			if (coverage <= 0.0) {
				continue;
			}
			uint32_t *p = &px[py * (int)stride_px + pxc];
			uint32_t bg = *p;
			uint8_t bg_r = (bg >> 16) & 0xff;
			uint8_t bg_g = (bg >> 8) & 0xff;
			uint8_t bg_b = bg & 0xff;
			uint8_t out_r = (uint8_t)(tint_r * coverage + bg_r * (1.0 - coverage) + 0.5);
			uint8_t out_g = (uint8_t)(tint_g * coverage + bg_g * (1.0 - coverage) + 0.5);
			uint8_t out_b = (uint8_t)(tint_b * coverage + bg_b * (1.0 - coverage) + 0.5);
			*p = 0xff000000u | ((uint32_t)out_r << 16) | ((uint32_t)out_g << 8) | out_b;
		}
	}
}

static void render(struct novi_panel *panel, uint32_t *px, uint32_t stride_px) {
	uint32_t w = panel->width, h = panel->height;
	draw_rect(px, stride_px, w, h, 0, 0, (int)w, (int)h, BG_COLOR);
	draw_rect(px, stride_px, w, h, 0, (int)h - 1, (int)w, 1, BORDER_COLOR);

	int btn_x, btn_y, btn_w, btn_h;
	apps_button_rect(panel, &btn_x, &btn_y, &btn_w, &btn_h);
	draw_rect(px, stride_px, w, h, btn_x, btn_y, btn_w, btn_h,
		panel->apps_button_hover ? BUTTON_HOVER_BG_COLOR : BUTTON_BG_COLOR);

	int icon_x = btn_x + BUTTON_H_PADDING;
	int icon_y = btn_y + (btn_h - APPS_ICON_SIZE) / 2;
	draw_apps_icon(px, stride_px, w, h, icon_x, icon_y,
		panel->apps_button_hover ? APPS_ICON_HOVER_COLOR : APPS_ICON_COLOR);

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

	/* text-secondary at rest, accent on hover -- GUI-DESIGN-LANGUAGE.md
	 * §7's stated hover treatment for the apps button. */
	static const pixman_color_t apps_label_color = {
		.red = 0xa300, .green = 0xa700, .blue = 0xb700, .alpha = 0xffff,
	};
	static const pixman_color_t apps_label_hover_color = {
		.red = 0x2d00, .green = 0xd400, .blue = 0xbf00, .alpha = 0xffff,
	};
	int label_x = icon_x + APPS_ICON_SIZE + APPS_ICON_TEXT_GAP;
	novi_text_draw(dest, panel->font, label_x, baseline_y, "Apps",
		panel->apps_button_hover ? apps_label_hover_color : apps_label_color);

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

/* enter/motion share the same "update local coords, recompute hover,
 * redraw only if hover actually changed" logic -- wl_pointer.enter
 * carries the entry coordinates itself, so it's exactly a motion event
 * for hit-testing purposes, not a separate case. */
static void update_pointer_position(struct novi_panel *panel,
		wl_fixed_t surface_x, wl_fixed_t surface_y) {
	panel->pointer_x = wl_fixed_to_double(surface_x);
	panel->pointer_y = wl_fixed_to_double(surface_y);
	bool hover = point_in_apps_button(panel, panel->pointer_x, panel->pointer_y);
	if (hover != panel->apps_button_hover) {
		panel->apps_button_hover = hover;
		surface_draw_frame(panel);
	}
}

static void pointer_enter(void *data, struct wl_pointer *pointer,
		uint32_t serial, struct wl_surface *surface,
		wl_fixed_t surface_x, wl_fixed_t surface_y) {
	(void)pointer; (void)serial; (void)surface;
	update_pointer_position(data, surface_x, surface_y);
}

static void pointer_leave(void *data, struct wl_pointer *pointer,
		uint32_t serial, struct wl_surface *surface) {
	(void)pointer; (void)serial; (void)surface;
	struct novi_panel *panel = data;
	panel->apps_button_pressed = false;
	if (panel->apps_button_hover) {
		panel->apps_button_hover = false;
		surface_draw_frame(panel);
	}
}

static void pointer_motion(void *data, struct wl_pointer *pointer,
		uint32_t time, wl_fixed_t surface_x, wl_fixed_t surface_y) {
	(void)pointer; (void)time;
	update_pointer_position(data, surface_x, surface_y);
}

static void pointer_button(void *data, struct wl_pointer *pointer,
		uint32_t serial, uint32_t time, uint32_t button, uint32_t state) {
	(void)pointer; (void)serial; (void)time;
	struct novi_panel *panel = data;
	if (button != BTN_LEFT) {
		return;
	}
	if (state == WL_POINTER_BUTTON_STATE_PRESSED) {
		/* Only arm the click if the press itself landed on the button --
		 * standard press-then-release-in-bounds click semantics, not
		 * "any release while hovering fires," so a press that started
		 * elsewhere and drags onto the button doesn't trigger it. */
		panel->apps_button_pressed =
			point_in_apps_button(panel, panel->pointer_x, panel->pointer_y);
		return;
	}
	/* Released. */
	bool was_pressed = panel->apps_button_pressed;
	panel->apps_button_pressed = false;
	if (was_pressed &&
			point_in_apps_button(panel, panel->pointer_x, panel->pointer_y)) {
		spawn(getenv("NOVI_LAUNCHER") ?
			getenv("NOVI_LAUNCHER") : NOVI_DEFAULT_LAUNCHER);
	}
}

static void pointer_axis(void *data, struct wl_pointer *pointer,
		uint32_t time, uint32_t axis, wl_fixed_t value) {
	(void)data; (void)pointer; (void)time; (void)axis; (void)value;
	/* Nothing in the panel scrolls yet. */
}

static const struct wl_pointer_listener pointer_listener = {
	.enter = pointer_enter,
	.leave = pointer_leave,
	.motion = pointer_motion,
	.button = pointer_button,
	.axis = pointer_axis,
};

static void seat_capabilities(void *data, struct wl_seat *seat,
		uint32_t capabilities) {
	struct novi_panel *panel = data;
	bool has_pointer = capabilities & WL_SEAT_CAPABILITY_POINTER;
	if (has_pointer && panel->pointer == NULL) {
		panel->pointer = wl_seat_get_pointer(seat);
		wl_pointer_add_listener(panel->pointer, &pointer_listener, panel);
	} else if (!has_pointer && panel->pointer != NULL) {
		wl_pointer_destroy(panel->pointer);
		panel->pointer = NULL;
	}
}

static void seat_name(void *data, struct wl_seat *seat, const char *name) {
	(void)data; (void)seat; (void)name;
}

static const struct wl_seat_listener seat_listener = {
	.capabilities = seat_capabilities,
	.name = seat_name,
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
	} else if (strcmp(interface, wl_seat_interface.name) == 0) {
		/* Version 1: only the `capabilities` event is used (`name` was
		 * added in v2 and isn't needed here), so there's no reason to
		 * negotiate a higher version. */
		panel->seat = wl_registry_bind(registry, name, &wl_seat_interface, 1);
		wl_seat_add_listener(panel->seat, &seat_listener, panel);
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
			panel.layer_shell == NULL || panel.seat == NULL) {
		fprintf(stderr, "novi-panel: compositor is missing a required "
			"global (wl_compositor/wl_shm/zwlr_layer_shell_v1/wl_seat)\n");
		return 1;
	}

	panel.font = novi_text_load_font("JetBrains Mono:size=11");
	if (panel.font == NULL) {
		fprintf(stderr, "novi-panel: failed to load JetBrains Mono\n");
		return 1;
	}
	/* Computed once: the button's own text never changes, so neither
	 * does its width. apps_button_rect() reads this every render/hit-
	 * test instead of recomputing novi_text_width() each time.
	 * Left-to-right: left padding, icon, icon-text gap, "Apps" text,
	 * right padding. */
	panel.apps_button_w = 2 * BUTTON_H_PADDING + APPS_ICON_SIZE +
		APPS_ICON_TEXT_GAP + novi_text_width(panel.font, "Apps");

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
	if (panel.pointer != NULL) {
		wl_pointer_destroy(panel.pointer);
	}
	if (panel.seat != NULL) {
		wl_seat_destroy(panel.seat);
	}
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
