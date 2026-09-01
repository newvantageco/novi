/* novi-launcher — Alt+Space search/launcher overlay (RFC 0001 decision 7).
 *
 * A separate Wayland client, not compositor code: it anchors itself as
 * an overlay-layer, keyboard-exclusive wlr-layer-shell-v1 surface,
 * matching the "novi-shell UI is a layer-shell client" split any future
 * panel will follow too. novi-shell spawns a fresh instance on
 * Alt+Space; this process exits itself on Escape or Enter.
 *
 * v1 scope is deliberately narrow: RFC 0001 describes Alt+Space as
 * "apps, files by name, and a calculator/unit-conversion fallback."
 * There is no application registry or indexed filesystem to search yet
 * (this is a fresh install with no packages/desktop entries installed),
 * so this implements only the calculator fallback -- live arithmetic
 * evaluation as you type, shown live below the input line. App/file
 * search is a tracked follow-up once there's something real to search.
 *
 * Rendering uses real, anti-aliased text via fcft+pixman (see
 * common/text.h) -- the same font-rendering pipeline foot itself uses
 * for terminal glyphs, and JetBrains Mono, the same font
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
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>

#include "wlr-layer-shell-unstable-v1-protocol.h"
#include "../common/text.h"

#define WIN_WIDTH 560
#define WIN_HEIGHT 120
#define BG_COLOR 0xff202030u /* opaque dark blue-gray, XRGB8888 */
#define BORDER_COLOR 0xff4a4a6au
#define INPUT_COLOR 0xffe0e0f0u
#define RESULT_COLOR 0xff8ab4f8u
#define CURSOR_COLOR 0xffe0e0f0u

#define INPUT_MAX 127

struct novi_launcher {
	struct wl_display *display;
	struct wl_registry *registry;
	struct wl_compositor *compositor;
	struct wl_shm *shm;
	struct wl_seat *seat;
	struct wl_keyboard *keyboard;
	struct zwlr_layer_shell_v1 *layer_shell;

	struct wl_surface *surface;
	struct zwlr_layer_surface_v1 *layer_surface;

	struct xkb_context *xkb_context;
	struct xkb_keymap *xkb_keymap;
	struct xkb_state *xkb_state;

	struct fcft_font *font;

	uint32_t width, height;
	bool configured;
	bool running;

	char input[INPUT_MAX + 1];
	size_t input_len;
};

/* ── Shared-memory buffer allocation ────────────────────────────── */

static int allocate_shm_file(size_t size) {
	char name[] = "/novi-launcher-XXXXXX";
	/* mkstemp-style unique suffix without pulling in mkstemp itself --
	 * shm_open with O_EXCL retries on collision, same pattern wlroots'
	 * own util/shm.c uses for exactly this purpose. */
	struct timespec ts;
	int fd = -1;
	for (int tries = 0; tries < 100 && fd < 0; tries++) {
		clock_gettime(CLOCK_REALTIME, &ts);
		long r = ts.tv_nsec + tries;
		for (int i = 0; i < 6; i++) {
			name[15 + i] = 'A' + (r & 15) + (r & 16) * 2;
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

/* ── Tiny arithmetic evaluator (+ - * / parens, decimals, unary -) ─ */

struct parser {
	const char *p;
	bool error;
};

static void skip_ws(struct parser *ps) {
	while (*ps->p == ' ') {
		ps->p++;
	}
}

static double parse_expr(struct parser *ps);

static double parse_primary(struct parser *ps) {
	skip_ws(ps);
	if (*ps->p == '(') {
		ps->p++;
		double v = parse_expr(ps);
		skip_ws(ps);
		if (*ps->p != ')') {
			ps->error = true;
			return 0;
		}
		ps->p++;
		return v;
	}
	if (*ps->p == '-') {
		ps->p++;
		return -parse_primary(ps);
	}
	if (*ps->p == '+') {
		ps->p++;
		return parse_primary(ps);
	}
	char *end;
	double v = strtod(ps->p, &end);
	if (end == ps->p) {
		ps->error = true;
		return 0;
	}
	ps->p = end;
	return v;
}

static double parse_term(struct parser *ps) {
	double v = parse_primary(ps);
	for (;;) {
		skip_ws(ps);
		if (*ps->p == '*') {
			ps->p++;
			v *= parse_primary(ps);
		} else if (*ps->p == '/') {
			ps->p++;
			double rhs = parse_primary(ps);
			if (rhs == 0) {
				ps->error = true;
				return 0;
			}
			v /= rhs;
		} else {
			return v;
		}
	}
}

static double parse_expr(struct parser *ps) {
	double v = parse_term(ps);
	for (;;) {
		skip_ws(ps);
		if (*ps->p == '+') {
			ps->p++;
			v += parse_term(ps);
		} else if (*ps->p == '-') {
			ps->p++;
			v -= parse_term(ps);
		} else {
			return v;
		}
	}
}

/* Returns true and fills *out if `input` parses as a complete
 * expression (trailing garbage or a parse error means "not a valid
 * calculation", not shown as a result). */
static bool evaluate(const char *input, double *out) {
	struct parser ps = {.p = input, .error = false};
	if (*ps.p == '\0') {
		return false;
	}
	double v = parse_expr(&ps);
	skip_ws(&ps);
	if (ps.error || *ps.p != '\0') {
		return false;
	}
	*out = v;
	return true;
}

/* ── Rendering ───────────────────────────────────────────────────── */

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

/* Restricts typed input to characters the calculator grammar actually
 * understands. fcft can render any printable ASCII glyph now (unlike
 * the old bitmap font, which only had digits/operators at all), but
 * accepting a character evaluate() can't parse would just display
 * text that can never produce a result -- not a rendering limit
 * anymore, a grammar one, so this check stays. */
static bool is_input_char(char ch) {
	return (ch >= '0' && ch <= '9') || strchr("+-*/. ()=", ch) != NULL;
}

static void render(struct novi_launcher *state, uint32_t *px,
		uint32_t stride_px) {
	uint32_t w = state->width, h = state->height;

	draw_rect(px, stride_px, w, h, 0, 0, (int)w, (int)h, BORDER_COLOR);
	draw_rect(px, stride_px, w, h, 3, 3, (int)w - 6, (int)h - 6, BG_COLOR);

	/* Wraps the same buffer draw_rect() already filled above -- both
	 * write into the identical memory in place, no double buffering. */
	pixman_image_t *dest = pixman_image_create_bits_no_clear(
		PIXMAN_x8r8g8b8, (int)w, (int)h, px, (int)stride_px * 4);

	static const pixman_color_t input_color = {
		.red = 0xe000, .green = 0xe000, .blue = 0xf000, .alpha = 0xffff,
	};
	static const pixman_color_t result_color = {
		.red = 0x8a00, .green = 0xb400, .blue = 0xf800, .alpha = 0xffff,
	};

	int text_x = 16;
	int line_height = state->font->height;
	int input_y = 16;
	int baseline_y = input_y + state->font->ascent;
	int cursor_w = 3;

	if (state->input_len == 0) {
		/* Empty input: just a blinking-style cursor block -- pure
		 * geometry, no glyph needed. */
		draw_rect(px, stride_px, w, h, text_x, input_y, cursor_w,
			line_height, CURSOR_COLOR);
	} else {
		int end_x = novi_text_draw(dest, state->font, text_x, baseline_y,
			state->input, input_color);
		draw_rect(px, stride_px, w, h, end_x, input_y, cursor_w,
			line_height, CURSOR_COLOR);
	}

	double result;
	if (evaluate(state->input, &result)) {
		char buf[64];
		snprintf(buf, sizeof(buf), "= %.6g", result);
		novi_text_draw(dest, state->font, text_x,
			input_y + line_height + 16 + state->font->ascent, buf, result_color);
	}

	pixman_image_unref(dest);
}

static void surface_draw_frame(struct novi_launcher *state) {
	if (!state->configured) {
		return;
	}
	uint32_t stride = state->width * 4;
	size_t size = (size_t)stride * state->height;

	int fd = allocate_shm_file(size);
	if (fd < 0) {
		fprintf(stderr, "novi-launcher: failed to allocate shm buffer\n");
		return;
	}
	uint32_t *data = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (data == MAP_FAILED) {
		fprintf(stderr, "novi-launcher: mmap failed\n");
		close(fd);
		return;
	}

	struct wl_shm_pool *pool = wl_shm_create_pool(state->shm, fd, (int32_t)size);
	struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0,
		(int32_t)state->width, (int32_t)state->height, (int32_t)stride,
		WL_SHM_FORMAT_XRGB8888);
	wl_shm_pool_destroy(pool);
	/* Flush before closing: wl_shm_create_pool's fd is only actually
	 * written to the socket (as SCM_RIGHTS ancillary data) at the next
	 * real flush, not at the moment this call returns. This client's
	 * own redraws happen to always run inside wl_display_dispatch()'s
	 * own timing, which never exposed the gap -- but novi-panel's
	 * near-identical code, redrawing from a hand-rolled poll loop
	 * instead, hit it for real ("file descriptor expected... message
	 * create_pool(nhi)"). Same latent risk here, fixed the same way,
	 * rather than leave a pattern that only worked by scheduling luck. */
	wl_display_flush(state->display);
	close(fd);

	render(state, data, state->width);
	munmap(data, size);

	wl_surface_attach(state->surface, buffer, 0, 0);
	wl_surface_damage_buffer(state->surface, 0, 0,
		(int32_t)state->width, (int32_t)state->height);
	wl_surface_commit(state->surface);
	/* buffer is destroyed once the compositor releases it (wl_buffer's
	 * release event) -- not tracked here; leaking one buffer per
	 * keystroke for a short-lived overlay process that exits on
	 * Escape/Enter is an acceptable v1 simplification, not something a
	 * long-running daemon could get away with. */
}

/* ── wl_keyboard ─────────────────────────────────────────────────── */

static void keyboard_keymap(void *data, struct wl_keyboard *kb,
		uint32_t format, int32_t fd, uint32_t size) {
	(void)kb;
	struct novi_launcher *state = data;
	if (format != WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) {
		close(fd);
		return;
	}
	char *map_str = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
	close(fd);
	if (map_str == MAP_FAILED) {
		return;
	}
	struct xkb_keymap *keymap = xkb_keymap_new_from_string(state->xkb_context,
		map_str, XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS);
	munmap(map_str, size);
	if (keymap == NULL) {
		return;
	}
	struct xkb_state *xkb_state = xkb_state_new(keymap);
	if (state->xkb_state != NULL) {
		xkb_state_unref(state->xkb_state);
	}
	if (state->xkb_keymap != NULL) {
		xkb_keymap_unref(state->xkb_keymap);
	}
	state->xkb_keymap = keymap;
	state->xkb_state = xkb_state;
}

static void keyboard_enter(void *data, struct wl_keyboard *kb, uint32_t serial,
		struct wl_surface *surface, struct wl_array *keys) {
	(void)data; (void)kb; (void)serial; (void)surface; (void)keys;
}

static void keyboard_leave(void *data, struct wl_keyboard *kb, uint32_t serial,
		struct wl_surface *surface) {
	(void)kb; (void)serial; (void)surface;
	/* Losing keyboard focus means the compositor gave it to something
	 * else -- this overlay has nothing useful left to do. */
	struct novi_launcher *state = data;
	state->running = false;
}

static void keyboard_key(void *data, struct wl_keyboard *kb, uint32_t serial,
		uint32_t time, uint32_t key, uint32_t key_state) {
	(void)kb; (void)serial; (void)time;
	struct novi_launcher *state = data;
	if (key_state != WL_KEYBOARD_KEY_STATE_PRESSED || state->xkb_state == NULL) {
		return;
	}
	xkb_keysym_t sym = xkb_state_key_get_one_sym(state->xkb_state, key + 8);

	if (sym == XKB_KEY_Escape) {
		state->running = false;
		return;
	}
	if (sym == XKB_KEY_Return || sym == XKB_KEY_KP_Enter) {
		/* No app/file search yet (see file header) -- there's nothing
		 * further to "launch," so Enter just dismisses the overlay
		 * the same as Escape. */
		state->running = false;
		return;
	}
	if (sym == XKB_KEY_BackSpace) {
		if (state->input_len > 0) {
			state->input[--state->input_len] = '\0';
			surface_draw_frame(state);
		}
		return;
	}

	/* Only accept characters the calculator grammar understands
	 * (digits, operators, space) -- anything else is silently ignored
	 * rather than accepted and shown as text that can never evaluate. */
	if (sym >= 32 && sym < 127 && is_input_char((char)sym)) {
		if (state->input_len < INPUT_MAX) {
			state->input[state->input_len++] = (char)sym;
			state->input[state->input_len] = '\0';
			surface_draw_frame(state);
		}
	}
}

static void keyboard_modifiers(void *data, struct wl_keyboard *kb,
		uint32_t serial, uint32_t mods_depressed, uint32_t mods_latched,
		uint32_t mods_locked, uint32_t group) {
	(void)kb; (void)serial;
	struct novi_launcher *state = data;
	if (state->xkb_state != NULL) {
		xkb_state_update_mask(state->xkb_state, mods_depressed, mods_latched,
			mods_locked, 0, 0, group);
	}
}

static void keyboard_repeat_info(void *data, struct wl_keyboard *kb,
		int32_t rate, int32_t delay) {
	(void)data; (void)kb; (void)rate; (void)delay;
	/* Key repeat isn't implemented -- a short calculator input string
	 * doesn't need it, and adding a repeat timer is unjustified
	 * complexity for this milestone. */
}

static const struct wl_keyboard_listener keyboard_listener = {
	.keymap = keyboard_keymap,
	.enter = keyboard_enter,
	.leave = keyboard_leave,
	.key = keyboard_key,
	.modifiers = keyboard_modifiers,
	.repeat_info = keyboard_repeat_info,
};

/* ── wl_seat ─────────────────────────────────────────────────────── */

static void seat_capabilities(void *data, struct wl_seat *seat,
		uint32_t caps) {
	struct novi_launcher *state = data;
	bool has_keyboard = caps & WL_SEAT_CAPABILITY_KEYBOARD;
	if (has_keyboard && state->keyboard == NULL) {
		state->keyboard = wl_seat_get_keyboard(seat);
		wl_keyboard_add_listener(state->keyboard, &keyboard_listener, state);
	} else if (!has_keyboard && state->keyboard != NULL) {
		wl_keyboard_destroy(state->keyboard);
		state->keyboard = NULL;
	}
}

static void seat_name(void *data, struct wl_seat *seat, const char *name) {
	(void)data; (void)seat; (void)name;
}

static const struct wl_seat_listener seat_listener = {
	.capabilities = seat_capabilities,
	.name = seat_name,
};

/* ── zwlr_layer_surface_v1 ───────────────────────────────────────── */

static void layer_surface_configure(void *data,
		struct zwlr_layer_surface_v1 *layer_surface, uint32_t serial,
		uint32_t width, uint32_t height) {
	struct novi_launcher *state = data;
	zwlr_layer_surface_v1_ack_configure(layer_surface, serial);
	state->width = width > 0 ? width : WIN_WIDTH;
	state->height = height > 0 ? height : WIN_HEIGHT;
	state->configured = true;
	surface_draw_frame(state);
}

static void layer_surface_closed(void *data,
		struct zwlr_layer_surface_v1 *layer_surface) {
	(void)layer_surface;
	struct novi_launcher *state = data;
	state->running = false;
}

static const struct zwlr_layer_surface_v1_listener layer_surface_listener = {
	.configure = layer_surface_configure,
	.closed = layer_surface_closed,
};

/* ── wl_registry ─────────────────────────────────────────────────── */

static void registry_global(void *data, struct wl_registry *registry,
		uint32_t name, const char *interface, uint32_t version) {
	(void)version;
	struct novi_launcher *state = data;
	if (strcmp(interface, wl_compositor_interface.name) == 0) {
		state->compositor = wl_registry_bind(registry, name,
			&wl_compositor_interface, 4);
	} else if (strcmp(interface, wl_shm_interface.name) == 0) {
		state->shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
	} else if (strcmp(interface, wl_seat_interface.name) == 0) {
		state->seat = wl_registry_bind(registry, name, &wl_seat_interface, 5);
		wl_seat_add_listener(state->seat, &seat_listener, state);
	} else if (strcmp(interface, zwlr_layer_shell_v1_interface.name) == 0) {
		state->layer_shell = wl_registry_bind(registry, name,
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
	struct novi_launcher state = {0};
	state.running = true;

	state.display = wl_display_connect(NULL);
	if (state.display == NULL) {
		fprintf(stderr, "novi-launcher: failed to connect to Wayland display "
			"(is WAYLAND_DISPLAY set?)\n");
		return 1;
	}

	state.xkb_context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);

	state.registry = wl_display_get_registry(state.display);
	wl_registry_add_listener(state.registry, &registry_listener, &state);
	wl_display_roundtrip(state.display);

	if (state.compositor == NULL || state.shm == NULL ||
			state.layer_shell == NULL) {
		fprintf(stderr, "novi-launcher: compositor is missing a required "
			"global (wl_compositor/wl_shm/zwlr_layer_shell_v1)\n");
		return 1;
	}

	state.font = novi_text_load_font("JetBrains Mono:size=16");
	if (state.font == NULL) {
		fprintf(stderr, "novi-launcher: failed to load JetBrains Mono\n");
		return 1;
	}

	state.surface = wl_compositor_create_surface(state.compositor);
	state.layer_surface = zwlr_layer_shell_v1_get_layer_surface(
		state.layer_shell, state.surface, NULL,
		ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, "novi-launcher");
	zwlr_layer_surface_v1_set_size(state.layer_surface, WIN_WIDTH, WIN_HEIGHT);
	zwlr_layer_surface_v1_set_anchor(state.layer_surface, 0);
	zwlr_layer_surface_v1_set_exclusive_zone(state.layer_surface, -1);
	zwlr_layer_surface_v1_set_keyboard_interactivity(state.layer_surface,
		ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE);
	zwlr_layer_surface_v1_add_listener(state.layer_surface,
		&layer_surface_listener, &state);

	/* Initial commit with no buffer attached -- required before the
	 * compositor will send the first configure event (protocol XML,
	 * zwlr_layer_surface_v1 description). */
	wl_surface_commit(state.surface);

	while (state.running && wl_display_dispatch(state.display) != -1) {
		/* All the real work happens in the listener callbacks above. */
	}

	if (state.layer_surface != NULL) {
		zwlr_layer_surface_v1_destroy(state.layer_surface);
	}
	if (state.surface != NULL) {
		wl_surface_destroy(state.surface);
	}
	if (state.xkb_state != NULL) {
		xkb_state_unref(state.xkb_state);
	}
	if (state.xkb_keymap != NULL) {
		xkb_keymap_unref(state.xkb_keymap);
	}
	if (state.xkb_context != NULL) {
		xkb_context_unref(state.xkb_context);
	}
	if (state.font != NULL) {
		fcft_destroy(state.font);
	}
	wl_display_disconnect(state.display);
	return 0;
}
