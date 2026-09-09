/* novi-notifyd — the desktop end of RFC 0024.
 *
 * Listens on a UNIX datagram socket and draws what arrives as toasts
 * in the top-right corner, stacked, expiring on a timer.
 *
 * A SEPARATE CLIENT, not a second surface inside novi-panel, and that
 * is a failure-domain decision rather than tidiness. The panel is the
 * always-visible chrome: the clock, the taskbar, the network
 * indicator. A bug in socket handling that takes down this process
 * costs a toast; the same bug inside novi-panel costs the user their
 * taskbar and their clock. Two jobs with very different blast radii
 * do not belong in one process.
 *
 * Spawned by novi-shell beside novi-panel, not run as an s6 service,
 * because that is the arrangement novi-shell already documents for
 * "its own UI pieces" -- and because a notification daemon with no
 * compositor to draw on has nothing to do.
 *
 * EVERYTHING THAT ARRIVES ON THAT SOCKET IS UNTRUSTED TEXT. The
 * largest single source of notifications is novi-mount announcing a
 * volume by its filesystem LABEL, which is a string off a stranger's
 * USB stick (RFC 0023 filters it for use as a directory name; here it
 * is being rendered). The socket is world-writable, so any process on
 * the machine can also send one. sanitise() is therefore not
 * defensive-programming garnish: it is the contract. Control
 * characters go, lengths are capped, and urgency and icon are matched
 * against fixed lists rather than believed.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/timerfd.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include <wayland-client.h>
#include <linux/input-event-codes.h>

#include "wlr-layer-shell-unstable-v1-protocol.h"
#include "../common/text.h"
#include "../common/theme.h"
#include "icons.h"
#include "icon_blit.h"

#define SOCK_PATH "/run/novi/notify.sock"
#define MSG_MAX 4096

/* Geometry. One column of cards down the right-hand edge, below the
 * panel -- MARGIN_TOP clears PANEL_HEIGHT (32) plus a gap, so a toast
 * never sits on top of the clock. */
#define TOAST_W       360
#define TOAST_MIN_H   56
#define TOAST_GAP     NOVI_SP_SM
#define MARGIN_TOP    44
#define MARGIN_RIGHT  NOVI_SP_MD
#define PAD           NOVI_SP_LG
#define ICON_SIZE     24
#define ICON_GAP      NOVI_SP_MD
#define ACCENT_W      3

#define MAX_TOASTS 4
#define SUMMARY_MAX 200
#define BODY_MAX 400

#define CARD_RADIUS   NOVI_RADIUS_LG
#define BG_COLOR      NOVI_BG_CARD
#define BG_HOVER      NOVI_BG_CARD_RAISED
#define BORDER_COLOR  NOVI_BORDER_SUBTLE
#define ACCENT_LOW    NOVI_TEXT_MUTED
#define ACCENT_NORMAL NOVI_ACCENT
#define ACCENT_CRIT   NOVI_STATUS_ERROR
#define ICON_COLOR    NOVI_TEXT_SECONDARY
#define SUMMARY_PIX NOVI_PIX(NOVI_TEXT_PRIMARY)
#define BODY_PIX NOVI_PIX(NOVI_TEXT_SECONDARY)

enum urgency { URG_LOW = 0, URG_NORMAL, URG_CRITICAL };

/* How long each urgency stays up. Critical does not expire: something
 * that matters enough to be called critical should not vanish while
 * the person is looking away from the screen. It goes when clicked. */
static const int TTL_MS[] = { 3000, 5000, 0 };

struct toast {
	bool used;
	enum urgency urgency;
	enum novi_icon_id icon;
	bool has_icon;
	char summary[SUMMARY_MAX + 1];
	char body[BODY_MAX + 1];
	int64_t expires_ms; /* 0 = never */
	int y, h;           /* laid out per frame; also the hit-test */
};

struct notifyd {
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
	struct fcft_font *font_small;

	uint32_t width, height;
	bool configured;
	bool running;
	bool mapped; /* a surface with content committed on it */

	struct toast toasts[MAX_TOASTS];
	double ptr_x, ptr_y;
	bool ptr_in;
	int hover;
	int press;

	int sock_fd;
	int timer_fd;
};

static int64_t now_ms(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* ── Parsing what arrives ──────────────────────────────────────────
 *
 * The wire format is newline-separated key=value (see novi-notify).
 * Nothing here believes any of it.
 */

/* Copies at most `cap` bytes of `src` into `dst`, dropping every
 * control character on the way. Not "escapes" -- drops: there is
 * nothing a control character in a notification summary can mean
 * except that somebody is trying to draw outside their box, and the
 * same argument this project already made about tabs in an SSID
 * applies verbatim. */
static void sanitise(char *dst, size_t cap, const char *src) {
	size_t o = 0;
	for (size_t i = 0; src[i] != '\0' && o < cap; i++) {
		unsigned char c = (unsigned char)src[i];
		if (c < 0x20 || c == 0x7f) {
			continue;
		}
		dst[o++] = (char)c;
	}
	dst[o] = '\0';
}

/* Icon names are matched against a fixed list, never used to index
 * anything. An unknown name is not an error and not a fallback glyph
 * -- it is no icon, because a notification whose sender asked for
 * something this build does not have should still be readable. */
static bool icon_by_name(const char *name, enum novi_icon_id *out) {
	static const struct { const char *name; enum novi_icon_id id; } TABLE[] = {
		{ "drive",   ICON_HARD_DRIVE },
		{ "eject",   ICON_EJECT },
		{ "package", ICON_PACKAGE },
		{ "wifi",    ICON_WIFI },
		{ "shield",  ICON_SHIELD },
		{ "power",   ICON_POWER },
		{ "file",    ICON_FILE },
		{ "folder",  ICON_FOLDER },
		{ "settings", ICON_SETTINGS },
	};
	for (size_t i = 0; i < sizeof(TABLE) / sizeof(TABLE[0]); i++) {
		if (strcmp(TABLE[i].name, name) == 0) {
			*out = TABLE[i].id;
			return true;
		}
	}
	return false;
}

static void surface_draw_frame(struct notifyd *n);
static void relayout(struct notifyd *n);
static void set_input_region(struct notifyd *n);

/* Oldest first, so a burst of notifications reads top-to-bottom in the
 * order it happened. When the stack is full the OLDEST goes, not the
 * newest: the thing that just happened is the thing somebody is
 * waiting to see. */
static void toast_add(struct notifyd *n, const struct toast *t) {
	int slot = -1;
	for (int i = 0; i < MAX_TOASTS; i++) {
		if (!n->toasts[i].used) {
			slot = i;
			break;
		}
	}
	if (slot < 0) {
		memmove(&n->toasts[0], &n->toasts[1],
			sizeof(n->toasts[0]) * (MAX_TOASTS - 1));
		slot = MAX_TOASTS - 1;
	}
	n->toasts[slot] = *t;
	n->toasts[slot].used = true;
}

static void toast_remove(struct notifyd *n, int i) {
	if (i < 0 || i >= MAX_TOASTS || !n->toasts[i].used) {
		return;
	}
	memmove(&n->toasts[i], &n->toasts[i + 1],
		sizeof(n->toasts[0]) * (MAX_TOASTS - 1 - i));
	n->toasts[MAX_TOASTS - 1].used = false;
	if (n->hover == i) {
		n->hover = -1;
	}
}


static void handle_message(struct notifyd *n, const char *msg) {
	struct toast t;
	memset(&t, 0, sizeof(t));
	t.urgency = URG_NORMAL;

	char raw_summary[MSG_MAX] = "";
	char raw_body[MSG_MAX] = "";
	char raw_icon[64] = "";

	const char *p = msg;
	while (*p != '\0') {
		const char *nl = strchr(p, '\n');
		size_t linelen = nl != NULL ? (size_t)(nl - p) : strlen(p);
		char line[MSG_MAX];
		if (linelen >= sizeof(line)) {
			linelen = sizeof(line) - 1;
		}
		memcpy(line, p, linelen);
		line[linelen] = '\0';

		char *eq = strchr(line, '=');
		if (eq != NULL) {
			*eq = '\0';
			const char *key = line, *val = eq + 1;
			if (strcmp(key, "summary") == 0) {
				snprintf(raw_summary, sizeof(raw_summary), "%s", val);
			} else if (strcmp(key, "body") == 0) {
				snprintf(raw_body, sizeof(raw_body), "%s", val);
			} else if (strcmp(key, "icon") == 0) {
				snprintf(raw_icon, sizeof(raw_icon), "%s", val);
			} else if (strcmp(key, "urgency") == 0) {
				if (strcmp(val, "low") == 0) {
					t.urgency = URG_LOW;
				} else if (strcmp(val, "critical") == 0) {
					t.urgency = URG_CRITICAL;
				}
				/* anything else stays normal -- an unrecognised
				 * urgency is a sender bug, not a reason to drop a
				 * message somebody wanted seen */
			}
		}
		if (nl == NULL) {
			break;
		}
		p = nl + 1;
	}

	sanitise(t.summary, SUMMARY_MAX, raw_summary);
	sanitise(t.body, BODY_MAX, raw_body);
	if (t.summary[0] == '\0') {
		return; /* nothing to show */
	}
	char icon_name[64];
	sanitise(icon_name, sizeof(icon_name) - 1, raw_icon);
	t.has_icon = icon_by_name(icon_name, &t.icon);

	int ttl = TTL_MS[t.urgency];
	t.expires_ms = ttl > 0 ? now_ms() + ttl : 0;

	toast_add(n, &t);
	relayout(n);
	surface_draw_frame(n);
}

static void drain_socket(struct notifyd *n) {
	/* Every datagram queued, not one per wake: the socket is level-
	 * triggered in poll(), but reading one message per wake would let
	 * a burst -- two partitions on one stick, which RFC 0023 says is
	 * the normal case -- arrive one frame apart for no reason. */
	for (;;) {
		char buf[MSG_MAX];
		ssize_t r = recv(n->sock_fd, buf, sizeof(buf) - 1, MSG_DONTWAIT);
		if (r <= 0) {
			return;
		}
		buf[r] = '\0';
		handle_message(n, buf);
	}
}

/* ── Layout and rendering ──────────────────────────────────────────
 *
 * The layer surface is sized to exactly the stack it is showing, and
 * resized every time that changes. A full-screen surface would be
 * simpler and would also swallow every click on the desktop behind it
 * -- an empty notification area that eats mouse input is worse than no
 * notification area.
 */

static int toast_height(struct notifyd *n, const struct toast *t) {
	int h = PAD * 2 + n->font->height;
	if (t->body[0] != '\0') {
		h += n->font_small->height + 4;
	}
	return h < TOAST_MIN_H ? TOAST_MIN_H : h;
}

static void relayout(struct notifyd *n) {
	int y = 0;
	for (int i = 0; i < MAX_TOASTS; i++) {
		if (!n->toasts[i].used) {
			continue;
		}
		n->toasts[i].h = toast_height(n, &n->toasts[i]);
		n->toasts[i].y = y;
		y += n->toasts[i].h + TOAST_GAP;
	}
	/* Never zero: the surface stays mapped for its whole life.
	 *
	 * The first version unmapped it when the stack emptied, by
	 * attaching a NULL buffer -- which is the documented way to stop
	 * occupying a rectangle, and which does not come back. A
	 * layer surface that has been unmapped needs another configure
	 * round before the compositor will accept a buffer again, so the
	 * next toast attached one to a surface that was not ready for it
	 * and wlroots dropped it. Nothing drew, ever, and nothing said so:
	 * the daemon was running, the socket was bound, syslog had every
	 * message. Same shape as this repo's own note about configuring an
	 * xdg_surface before its initial commit -- the protocol has an
	 * order and silently ignores you when you get it wrong.
	 *
	 * So the surface is always mapped, and CLICK-THROUGH is done the
	 * way Wayland actually provides for it: an input region covering
	 * exactly the cards. That is strictly better than unmapping ever
	 * was, because it also makes the gaps BETWEEN cards transparent to
	 * the pointer, which unmapping could never do. */
	int want_h = y > 0 ? y - TOAST_GAP : 1;

	if ((int)n->height != want_h) {
		zwlr_layer_surface_v1_set_size(n->layer_surface, TOAST_W, want_h);
		/* The configure answering this carries the size and draws the
		 * frame; callers draw too, for the case where the size did not
		 * change and no configure is coming. */
		wl_surface_commit(n->surface);
	}
}

/* The pointer only exists where a card is. Everything else in this
 * surface -- the gaps, and the whole thing when it is empty -- is
 * transparent to clicks, so the desktop behind it stays usable. */
static void set_input_region(struct notifyd *n) {
	struct wl_region *region = wl_compositor_create_region(n->compositor);
	if (region == NULL) {
		return;
	}
	for (int i = 0; i < MAX_TOASTS; i++) {
		if (n->toasts[i].used) {
			wl_region_add(region, 0, n->toasts[i].y,
				(int)n->width, n->toasts[i].h);
		}
	}
	wl_surface_set_input_region(n->surface, region);
	wl_region_destroy(region);
}

/* Inigo Quilez's rounded-box SDF, the same one novi-shell's shadows and
 * novi-panel's icons use. Here it buys actual rounded corners rather
 * than an approximation, because this surface is ARGB8888 with a
 * genuinely transparent background -- a card can be antialiased
 * against the desktop instead of against an assumed backdrop colour,
 * which is the thing that makes a corner look cut rather than drawn. */
static double rounded_box_sdf(double px, double py, double half_w,
		double half_h, double radius) {
	double qx = fabs(px) - half_w + radius;
	double qy = fabs(py) - half_h + radius;
	double ox = qx > 0.0 ? qx : 0.0;
	double oy = qy > 0.0 ? qy : 0.0;
	double outside = sqrt(ox * ox + oy * oy);
	double inside = qx > qy ? qx : qy;
	if (inside > 0.0) {
		inside = 0.0;
	}
	return outside + inside - radius;
}

/* One card: a rounded fill, a hairline border a shade lighter, and the
 * urgency stripe down the left clipped to the same shape. Written
 * straight into the ARGB buffer with per-pixel coverage as alpha. */
static void draw_card(uint32_t *px, uint32_t stride_px, uint32_t buf_w,
		uint32_t buf_h, int x, int y, int w, int h,
		uint32_t fill, uint32_t border, uint32_t accent) {
	double hw = w / 2.0, hh = h / 2.0;
	for (int row = 0; row < h; row++) {
		int py = y + row;
		if (py < 0 || py >= (int)buf_h) {
			continue;
		}
		for (int col = 0; col < w; col++) {
			int pxc = x + col;
			if (pxc < 0 || pxc >= (int)buf_w) {
				continue;
			}
			double d = rounded_box_sdf(col + 0.5 - hw, row + 0.5 - hh,
				hw, hh, CARD_RADIUS);
			/* Inside coverage: 1 well inside, 0 well outside, one
			 * pixel of linear falloff across the edge. */
			double cov = 0.5 - d;
			if (cov <= 0.0) {
				continue;
			}
			if (cov > 1.0) {
				cov = 1.0;
			}
			/* The border is a band just inside the boundary; the
			 * accent stripe is the same band's job on the left edge,
			 * so both are clipped to the rounded shape for free. */
			uint32_t rgb = fill;
			if (col < ACCENT_W) {
				rgb = accent;
			} else if (d > -1.5) {
				rgb = border;
			}
			uint8_t a = (uint8_t)(cov * 255.0 + 0.5);
			px[py * (int)stride_px + pxc] =
				((uint32_t)a << 24) | (rgb & 0x00ffffffu);
		}
	}
}


static uint32_t accent_of(enum urgency u) {
	switch (u) {
	case URG_LOW: return ACCENT_LOW;
	case URG_CRITICAL: return ACCENT_CRIT;
	default: return ACCENT_NORMAL;
	}
}

static void render(struct notifyd *n, uint32_t *px, uint32_t stride_px) {
	uint32_t w = n->width, h = n->height;
	/* ARGB8888 with a zero alpha everywhere first: the gaps between
	 * cards have to be genuinely transparent, or the stack reads as
	 * one tall slab with lines drawn on it. */
	for (uint32_t i = 0; i < stride_px * h; i++) {
		px[i] = 0;
	}
	pixman_image_t *dest = pixman_image_create_bits_no_clear(
		PIXMAN_a8r8g8b8, (int)w, (int)h, px, (int)stride_px * 4);

	for (int i = 0; i < MAX_TOASTS; i++) {
		struct toast *t = &n->toasts[i];
		if (!t->used) {
			continue;
		}
		int y = t->y;
		draw_card(px, stride_px, w, h, 0, y, (int)w, t->h,
			i == n->hover ? BG_HOVER : BG_COLOR, BORDER_COLOR,
			accent_of(t->urgency));

		int text_x = ACCENT_W + PAD;
		if (t->has_icon) {
			draw_icon(px, stride_px, w, h, text_x,
				y + (t->h - ICON_SIZE) / 2, t->icon, ICON_COLOR);
			text_x += ICON_SIZE + ICON_GAP;
		}
		int avail = (int)w - text_x - PAD;

		int base = y + PAD + n->font->ascent;
		char line[SUMMARY_MAX + 8];
		novi_text_truncate(n->font, t->summary, avail, line, sizeof(line));
		novi_text_draw(dest, n->font, text_x, base, line, SUMMARY_PIX);

		if (t->body[0] != '\0') {
			char bline[BODY_MAX + 8];
			novi_text_truncate(n->font_small, t->body, avail,
				bline, sizeof(bline));
			novi_text_draw(dest, n->font_small, text_x,
				base + n->font_small->height + 2, bline, BODY_PIX);
		}
	}
	pixman_image_unref(dest);
}

static int allocate_shm_file(size_t size) {
	char name[] = "/novi-notifyd-XXXXXX";
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

static void surface_draw_frame(struct notifyd *n) {
	if (!n->configured || n->width == 0 || n->height == 0) {
		return;
	}
	uint32_t stride = n->width * 4;
	size_t size = (size_t)stride * n->height;

	int fd = allocate_shm_file(size);
	if (fd < 0) {
		return;
	}
	uint32_t *px = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (px == MAP_FAILED) {
		close(fd);
		return;
	}
	struct wl_shm_pool *pool = wl_shm_create_pool(n->shm, fd, (int32_t)size);
	struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0,
		(int32_t)n->width, (int32_t)n->height, (int32_t)stride,
		WL_SHM_FORMAT_ARGB8888);
	wl_shm_pool_destroy(pool);
	close(fd);

	render(n, px, n->width);
	munmap(px, size);

	set_input_region(n);
	wl_surface_attach(n->surface, buffer, 0, 0);
	wl_surface_damage_buffer(n->surface, 0, 0, (int32_t)n->width,
		(int32_t)n->height);
	wl_surface_commit(n->surface);
	wl_buffer_destroy(buffer);
	n->mapped = true;
}

/* ── Wayland ───────────────────────────────────────────────────── */

static void layer_surface_configure(void *data,
		struct zwlr_layer_surface_v1 *surface, uint32_t serial,
		uint32_t w, uint32_t h) {
	struct notifyd *n = data;
	zwlr_layer_surface_v1_ack_configure(surface, serial);
	n->width = w;
	n->height = h;
	n->configured = true;
	surface_draw_frame(n);
}

static void layer_surface_closed(void *data,
		struct zwlr_layer_surface_v1 *surface) {
	struct notifyd *n = data;
	(void)surface;
	n->running = false;
}

static const struct zwlr_layer_surface_v1_listener layer_surface_listener = {
	.configure = layer_surface_configure,
	.closed = layer_surface_closed,
};

static int toast_at(const struct notifyd *n, double x, double y) {
	if (x < 0 || x >= (double)n->width) {
		return -1;
	}
	for (int i = 0; i < MAX_TOASTS; i++) {
		if (!n->toasts[i].used) {
			continue;
		}
		if (y >= n->toasts[i].y && y < n->toasts[i].y + n->toasts[i].h) {
			return i;
		}
	}
	return -1; /* a gap between cards is not a card */
}

static void update_hover(struct notifyd *n) {
	int h = n->ptr_in ? toast_at(n, n->ptr_x, n->ptr_y) : -1;
	if (h == n->hover) {
		return;
	}
	n->hover = h;
	surface_draw_frame(n);
}

static void pointer_enter(void *data, struct wl_pointer *p, uint32_t serial,
		struct wl_surface *surface, wl_fixed_t sx, wl_fixed_t sy) {
	(void)p; (void)serial; (void)surface;
	struct notifyd *n = data;
	n->ptr_in = true;
	n->ptr_x = wl_fixed_to_double(sx);
	n->ptr_y = wl_fixed_to_double(sy);
	update_hover(n);
}

static void pointer_leave(void *data, struct wl_pointer *p, uint32_t serial,
		struct wl_surface *surface) {
	(void)p; (void)serial; (void)surface;
	struct notifyd *n = data;
	n->ptr_in = false;
	n->press = -1;
	update_hover(n);
}

static void pointer_motion(void *data, struct wl_pointer *p, uint32_t time,
		wl_fixed_t sx, wl_fixed_t sy) {
	(void)p; (void)time;
	struct notifyd *n = data;
	n->ptr_x = wl_fixed_to_double(sx);
	n->ptr_y = wl_fixed_to_double(sy);
	update_hover(n);
}

static void pointer_button(void *data, struct wl_pointer *p, uint32_t serial,
		uint32_t time, uint32_t button, uint32_t state) {
	(void)p; (void)serial; (void)time;
	struct notifyd *n = data;
	if (button != BTN_LEFT) {
		return;
	}
	if (state == WL_POINTER_BUTTON_STATE_PRESSED) {
		n->press = toast_at(n, n->ptr_x, n->ptr_y);
		return;
	}
	int was = n->press;
	n->press = -1;
	if (was >= 0 && toast_at(n, n->ptr_x, n->ptr_y) == was) {
		toast_remove(n, was);
		relayout(n);
		surface_draw_frame(n);
	}
}

static void pointer_axis(void *data, struct wl_pointer *p, uint32_t time,
		uint32_t axis, wl_fixed_t value) {
	(void)data; (void)p; (void)time; (void)axis; (void)value;
}

static const struct wl_pointer_listener pointer_listener = {
	.enter = pointer_enter,
	.leave = pointer_leave,
	.motion = pointer_motion,
	.button = pointer_button,
	.axis = pointer_axis,
};

static void seat_capabilities(void *data, struct wl_seat *seat, uint32_t caps) {
	struct notifyd *n = data;
	if ((caps & WL_SEAT_CAPABILITY_POINTER) && n->pointer == NULL) {
		n->pointer = wl_seat_get_pointer(seat);
		wl_pointer_add_listener(n->pointer, &pointer_listener, n);
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
	struct notifyd *n = data;
	if (strcmp(interface, wl_compositor_interface.name) == 0) {
		n->compositor = wl_registry_bind(registry, name,
			&wl_compositor_interface, 4);
	} else if (strcmp(interface, wl_shm_interface.name) == 0) {
		n->shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
	} else if (strcmp(interface, zwlr_layer_shell_v1_interface.name) == 0) {
		n->layer_shell = wl_registry_bind(registry, name,
			&zwlr_layer_shell_v1_interface, 1);
	} else if (strcmp(interface, wl_seat_interface.name) == 0) {
		/* Version 1, so wl_pointer is version 1 and needs exactly the
		 * five handlers above. Binding 5 here would demand frame/
		 * axis_source/axis_stop/axis_discrete as well, and libwayland
		 * aborts the client on a NULL listener slot rather than
		 * ignoring the event -- which is how novi-files died on its
		 * first mouse move. There is no keyboard here, so there is no
		 * reason to ask for a later version. */
		n->seat = wl_registry_bind(registry, name, &wl_seat_interface, 1);
		wl_seat_add_listener(n->seat, &seat_listener, n);
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

/* ── The socket ────────────────────────────────────────────────── */

static int listen_socket(void) {
	int fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
	if (fd < 0) {
		return -1;
	}
	struct sockaddr_un addr;
	memset(&addr, 0, sizeof(addr));
	addr.sun_family = AF_UNIX;
	snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", SOCK_PATH);

	/* Unlink first. A daemon killed with SIGKILL leaves the socket
	 * file behind, and bind() on an existing path fails with
	 * EADDRINUSE -- so without this, one hard kill means no
	 * notifications until somebody deletes a file by hand. The race
	 * this opens (two daemons starting together) is not one that can
	 * happen: novi-shell spawns exactly one. */
	unlink(SOCK_PATH);
	if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		close(fd);
		return -1;
	}
	/* World-writable on purpose: an unprivileged program has as much
	 * business saying "your download finished" as root has saying "a
	 * disk is full", and this system has no session bus to arbitrate
	 * between them. The security position is not access control on the
	 * socket, it is that EVERY message is treated as untrusted text --
	 * see sanitise() and the header. */
	chmod(SOCK_PATH, 0666);
	return fd;
}

/* ── main ──────────────────────────────────────────────────────── */

/* When the next toast expires, as a timerfd delay. Recomputed after
 * every change rather than polled on a fixed tick: an idle desktop
 * should wake this process zero times, not once a second forever. */
static void arm_timer(struct notifyd *n) {
	int64_t soonest = 0;
	for (int i = 0; i < MAX_TOASTS; i++) {
		if (!n->toasts[i].used || n->toasts[i].expires_ms == 0) {
			continue;
		}
		if (soonest == 0 || n->toasts[i].expires_ms < soonest) {
			soonest = n->toasts[i].expires_ms;
		}
	}
	struct itimerspec its;
	memset(&its, 0, sizeof(its));
	if (soonest != 0) {
		int64_t delay = soonest - now_ms();
		if (delay < 1) {
			delay = 1;
		}
		its.it_value.tv_sec = delay / 1000;
		its.it_value.tv_nsec = (delay % 1000) * 1000000;
	}
	/* An all-zero itimerspec DISARMS the timer, which is exactly what
	 * is wanted when nothing is pending -- and is also the classic way
	 * to arm a timer that never fires by accident. Here it is
	 * deliberate. */
	timerfd_settime(n->timer_fd, 0, &its, NULL);
}

static void expire_toasts(struct notifyd *n) {
	int64_t t = now_ms();
	bool changed = false;
	for (int i = 0; i < MAX_TOASTS; ) {
		if (n->toasts[i].used && n->toasts[i].expires_ms != 0 &&
				n->toasts[i].expires_ms <= t) {
			toast_remove(n, i);
			changed = true;
			continue; /* the list shifted; re-check this index */
		}
		i++;
	}
	if (changed) {
		relayout(n);
		/* Unconditionally, including when that was the last one: the
		 * surface is always mapped now, so "nothing left" still has to
		 * be drawn -- as an empty frame -- or the toast that just
		 * expired stays on screen for good. */
		surface_draw_frame(n);
	}
}

int main(void) {
	/* Colours are a runtime table now (RFC 0030). Load the active
	 * theme BEFORE anything computes a colour; on failure the
	 * compiled-in defaults stay in force, so this cannot leave the
	 * client worse off than it was. */
	novi_theme_load();
	struct notifyd n;
	memset(&n, 0, sizeof(n));
	n.running = true;
	n.hover = -1;
	n.press = -1;

	n.display = wl_display_connect(NULL);
	if (n.display == NULL) {
		fprintf(stderr, "novi-notifyd: no Wayland display\n");
		return 1;
	}
	n.registry = wl_display_get_registry(n.display);
	wl_registry_add_listener(n.registry, &registry_listener, &n);
	wl_display_roundtrip(n.display);

	if (n.compositor == NULL || n.shm == NULL || n.layer_shell == NULL) {
		fprintf(stderr, "novi-notifyd: compositor is missing a required "
			"global (wl_compositor/wl_shm/zwlr_layer_shell_v1)\n");
		return 1;
	}

	n.font = novi_text_load_font(NOVI_FONT_TITLE);
	n.font_small = novi_text_load_font(NOVI_FONT_CAPTION);
	if (n.font == NULL || n.font_small == NULL) {
		fprintf(stderr, "novi-notifyd: failed to load Inter\n");
		return 1;
	}

	n.sock_fd = listen_socket();
	if (n.sock_fd < 0) {
		fprintf(stderr, "novi-notifyd: cannot bind %s: %s\n",
			SOCK_PATH, strerror(errno));
		return 1;
	}
	n.timer_fd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
	if (n.timer_fd < 0) {
		fprintf(stderr, "novi-notifyd: timerfd_create failed\n");
		return 1;
	}

	n.surface = wl_compositor_create_surface(n.compositor);
	n.layer_surface = zwlr_layer_shell_v1_get_layer_surface(
		n.layer_shell, n.surface, NULL,
		ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, "novi-notifyd");
	zwlr_layer_surface_v1_set_size(n.layer_surface, TOAST_W, TOAST_MIN_H);
	zwlr_layer_surface_v1_set_anchor(n.layer_surface,
		ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP |
		ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT);
	zwlr_layer_surface_v1_set_margin(n.layer_surface,
		MARGIN_TOP, MARGIN_RIGHT, 0, 0);
	/* -1, not 0: 0 means "let the compositor decide whether other
	 * surfaces' exclusive zones push me around", and a toast that
	 * moved when the panel appeared would be jarring. -1 says this
	 * surface ignores exclusive zones entirely and is positioned from
	 * the raw output edge, which is why MARGIN_TOP has to clear the
	 * panel itself. */
	zwlr_layer_surface_v1_set_exclusive_zone(n.layer_surface, -1);
	zwlr_layer_surface_v1_set_keyboard_interactivity(n.layer_surface,
		ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE);
	zwlr_layer_surface_v1_add_listener(n.layer_surface,
		&layer_surface_listener, &n);
	wl_surface_commit(n.surface);

	/* Start unmapped: the surface exists so a configure can arrive,
	 * but nothing is drawn until there is something to say. */
	wl_display_roundtrip(n.display);
	relayout(&n);

	while (n.running) {
		while (wl_display_prepare_read(n.display) != 0) {
			if (wl_display_dispatch_pending(n.display) < 0) {
				n.running = false;
				break;
			}
		}
		if (!n.running) {
			wl_display_cancel_read(n.display);
			break;
		}
		arm_timer(&n);
		wl_display_flush(n.display);

		struct pollfd fds[3] = {
			{.fd = wl_display_get_fd(n.display), .events = POLLIN},
			{.fd = n.sock_fd, .events = POLLIN},
			{.fd = n.timer_fd, .events = POLLIN},
		};
		if (poll(fds, 3, -1) < 0) {
			/* cancel_read on EVERY path that does not read, poll
			 * errors included, or the next prepare_read blocks
			 * forever. RFC 0017 learned this one the hard way. */
			wl_display_cancel_read(n.display);
			if (errno == EINTR) {
				continue;
			}
			break;
		}

		if (fds[0].revents & POLLIN) {
			wl_display_read_events(n.display);
		} else {
			wl_display_cancel_read(n.display);
		}
		if (wl_display_dispatch_pending(n.display) < 0) {
			break;
		}

		if (fds[1].revents & POLLIN) {
			drain_socket(&n);
		}
		if (fds[2].revents & POLLIN) {
			uint64_t ticks;
			if (read(n.timer_fd, &ticks, sizeof(ticks)) > 0) {
				expire_toasts(&n);
			}
		}
	}

	unlink(SOCK_PATH);
	close(n.sock_fd);
	close(n.timer_fd);
	if (n.pointer != NULL) {
		wl_pointer_destroy(n.pointer);
	}
	if (n.font != NULL) {
		fcft_destroy(n.font);
	}
	if (n.font_small != NULL) {
		fcft_destroy(n.font_small);
	}
	wl_display_disconnect(n.display);
	return 0;
}
