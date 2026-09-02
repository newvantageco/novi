/* novi-settings — first-party Settings app: Account / change password.
 *
 * This is this repo's first first-party GUI app that is a normal
 * xdg-shell window, not a layer-shell overlay (novi-launcher,
 * novi-panel, novi-lockscreen all are). It's a real, resizable,
 * closable app window, decorated by novi-shell's own server-side
 * decorations exactly like `foot` -- the only difference from foot is
 * that foot is a third-party binary this repo bakes in, while this is
 * this project's own first application built on xdg-shell rather than
 * layer-shell. novi-shell decorates every xdg_toplevel unconditionally
 * regardless of what the client requests (see novi-shell/main.c's own
 * xdg_decoration_manager comment), so this client doesn't need to
 * negotiate decoration mode via zxdg_decoration_manager_v1 at all --
 * that would matter for portability to some other compositor, and this
 * app only ever runs under this one.
 *
 * v1 scope is deliberately just one real, useful thing, not a shallow
 * multi-section panel with nothing behind most of it: changing root's
 * password. This system has no password-setup flow with a GUI at all
 * today (novi-lockscreen's own header comment notes the stock
 * /etc/shadow ships an empty hash -- "no `passwd` flow has ever run"),
 * so this is a real, previously-missing capability, not a demo. Root
 * changing its own password doesn't need the OLD one first (standard
 * Unix semantics -- only a non-root user changing their own password
 * needs to prove the old one; root can always set any password), so
 * the form is just two fields: New and Confirm, not three. Salting and
 * hashing uses the same real crypt(3) family novi-lockscreen already
 * verifies against and passwd/login already rely on -- SHA-512
 * ("$6$"), a real random salt from /dev/urandom, not a placeholder.
 *
 * Keyboard-only interaction (Tab/Shift+Tab between fields, Enter to
 * advance or submit) -- no wl_pointer/click-to-focus in this pass, a
 * real, documented v1 limit like every other new client here, not an
 * oversight.
 */
#include <crypt.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>

#include "xdg-shell-client-protocol.h"
#include "../common/text.h"

#define WINDOW_WIDTH 480
#define WINDOW_HEIGHT 300
#define FIELD_MAX 127
#define FIELD_COUNT 2 /* 0 = new password, 1 = confirm */

#define BG_COLOR 0xff14141cu
#define TEXT_COLOR 0xffe0e0f0u
#define LABEL_COLOR 0xff8a8aa0u
#define HINT_COLOR 0xff8a8aa0u
#define ERROR_COLOR 0xffe08a8au
#define SUCCESS_COLOR 0xff8ae0a0u
#define FIELD_BG_COLOR 0xff1e1e28u
#define FIELD_BORDER_COLOR 0xff3a3a4au
#define FIELD_BORDER_FOCUS_COLOR 0xff8ab4f8u
#define DOT_COLOR 0xffe0e0f0u
#define DOT_SIZE 8
#define DOT_GAP 6

#define FIELD_X 24
#define FIELD_WIDTH (WINDOW_WIDTH - 2 * FIELD_X)
#define FIELD_HEIGHT 36

struct novi_settings {
	struct wl_display *display;
	struct wl_registry *registry;
	struct wl_compositor *compositor;
	struct wl_shm *shm;
	struct wl_seat *seat;
	struct wl_keyboard *keyboard;
	struct xdg_wm_base *wm_base;

	struct wl_surface *surface;
	struct xdg_surface *xdg_surface;
	struct xdg_toplevel *xdg_toplevel;

	struct xkb_context *xkb_context;
	struct xkb_keymap *xkb_keymap;
	struct xkb_state *xkb_state;

	struct fcft_font *font;
	struct fcft_font *font_small;

	uint32_t width, height;
	bool configured;
	bool running;

	int focus_field;
	char field[FIELD_COUNT][FIELD_MAX + 1];
	size_t field_len[FIELD_COUNT];

	const char *status;
	bool status_is_error;
};

/* ── Password change: real crypt(3)/shadow logic, shared reasoning
 * with novi-lockscreen's own verify_password()/hash_is_usable() (see
 * that file for the shadow(5) field-format background) ── */

#define SALT_ALPHABET "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
#define SALT_LEN 16

/* Fills salt_out (must be at least SALT_LEN+1 bytes) with SALT_LEN
 * real random characters from the crypt salt alphabet, read from
 * /dev/urandom -- not rand()/time()-seeded pseudo-randomness, since
 * this feeds directly into a password hash's own security. */
static bool generate_salt(char *salt_out) {
	unsigned char raw[SALT_LEN];
	FILE *f = fopen("/dev/urandom", "rb");
	if (f == NULL) {
		return false;
	}
	size_t n = fread(raw, 1, SALT_LEN, f);
	fclose(f);
	if (n != SALT_LEN) {
		return false;
	}
	for (int i = 0; i < SALT_LEN; i++) {
		salt_out[i] = SALT_ALPHABET[raw[i] % 64];
	}
	salt_out[SALT_LEN] = '\0';
	return true;
}

/* Rewrites /etc/shadow with root's hash field replaced by `new_hash`,
 * every other field (last-change day, min/max age, warn, inactive,
 * expire -- shadow(5)'s remaining seven colon-separated fields) and
 * every other user's line left byte-for-byte untouched. Writes to a
 * temp file first and rename()s over the original -- an atomic
 * replace, so a crash or power loss mid-write can never leave
 * /etc/shadow half-written or missing. */
static bool write_new_shadow_hash(const char *new_hash) {
	FILE *in = fopen("/etc/shadow", "r");
	if (in == NULL) {
		return false;
	}
	FILE *out = fopen("/etc/shadow.tmp", "w");
	if (out == NULL) {
		fclose(in);
		return false;
	}
	if (fchmod(fileno(out), 0600) != 0) {
		fclose(in);
		fclose(out);
		unlink("/etc/shadow.tmp");
		return false;
	}

	bool found = false;
	bool ok = true;
	char line[512];
	while (fgets(line, sizeof(line), in) != NULL) {
		if (!found && strncmp(line, "root:", 5) == 0) {
			found = true;
			char *rest = line + 5;
			char *colon = strchr(rest, ':');
			const char *after_hash = colon != NULL ? colon : "";
			if (fprintf(out, "root:%s%s", new_hash, after_hash) < 0) {
				ok = false;
			}
			/* after_hash already includes its own trailing content
			 * (the remaining fields plus the line's own '\n'), copied
			 * verbatim from `rest` -- nothing else to append here. */
		} else {
			if (fputs(line, out) < 0) {
				ok = false;
			}
		}
	}
	fclose(in);
	if (fclose(out) != 0) {
		ok = false;
	}
	if (!found || !ok) {
		unlink("/etc/shadow.tmp");
		return false;
	}
	if (rename("/etc/shadow.tmp", "/etc/shadow") != 0) {
		unlink("/etc/shadow.tmp");
		return false;
	}
	return true;
}

/* Returns a heap-free()-able... no -- crypt()'s return is a pointer
 * into its own static buffer (POSIX crypt(3) semantics, same as
 * novi-lockscreen relies on), so the hash is copied out into a
 * caller-owned buffer immediately, before any other crypt() call
 * (there is only the one call here) could overwrite it. */
static bool change_root_password(const char *new_password) {
	char salt[SALT_LEN + 1];
	if (!generate_salt(salt)) {
		return false;
	}
	char salt_string[3 + SALT_LEN + 1 + 1]; /* "$6$" + salt + "$" + NUL */
	snprintf(salt_string, sizeof(salt_string), "$6$%s$", salt);

	char *result = crypt(new_password, salt_string);
	if (result == NULL) {
		return false;
	}
	char hash_copy[256];
	snprintf(hash_copy, sizeof(hash_copy), "%s", result);
	return write_new_shadow_hash(hash_copy);
}

static void wipe_fields(struct novi_settings *state) {
	for (int i = 0; i < FIELD_COUNT; i++) {
		explicit_bzero(state->field[i], sizeof(state->field[i]));
		state->field_len[i] = 0;
	}
}

/* ── Shared-memory buffer allocation (same pattern as every other
 * client here -- see novi-launcher's identical helper for why). ── */
static int allocate_shm_file(size_t size) {
	char name[] = "/novi-settings-XXXXXX";
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

/* 1px rectangle outline -- four draw_rect() strips rather than a
 * dedicated routine, the same "simple enough not to need its own
 * primitive" judgment as everything else drawn here. */
static void draw_rect_border(uint32_t *px, uint32_t stride_px, uint32_t buf_w,
		uint32_t buf_h, int x, int y, int w, int h, uint32_t color) {
	draw_rect(px, stride_px, buf_w, buf_h, x, y, w, 1, color);
	draw_rect(px, stride_px, buf_w, buf_h, x, y + h - 1, w, 1, color);
	draw_rect(px, stride_px, buf_w, buf_h, x, y, 1, h, color);
	draw_rect(px, stride_px, buf_w, buf_h, x + w - 1, y, 1, h, color);
}

static const char *FIELD_LABELS[FIELD_COUNT] = {
	"New password", "Confirm new password",
};

static void render(struct novi_settings *state, uint32_t *px, uint32_t stride_px) {
	uint32_t w = state->width, h = state->height;
	draw_rect(px, stride_px, w, h, 0, 0, (int)w, (int)h, BG_COLOR);

	pixman_image_t *dest = pixman_image_create_bits_no_clear(
		PIXMAN_a8r8g8b8, (int)w, (int)h, px, (int)stride_px * 4);

	static const pixman_color_t text_color = {
		.red = 0xe000, .green = 0xe000, .blue = 0xf000, .alpha = 0xffff,
	};
	static const pixman_color_t label_color = {
		.red = 0x8a00, .green = 0x8a00, .blue = 0xa000, .alpha = 0xffff,
	};
	static const pixman_color_t error_color = {
		.red = 0xe000, .green = 0x8a00, .blue = 0x8a00, .alpha = 0xffff,
	};
	static const pixman_color_t success_color = {
		.red = 0x8a00, .green = 0xe000, .blue = 0xa000, .alpha = 0xffff,
	};

	novi_text_draw(dest, state->font, FIELD_X, 24 + state->font->ascent,
		"Account", text_color);

	int field_y[FIELD_COUNT] = {70, 150};
	for (int i = 0; i < FIELD_COUNT; i++) {
		novi_text_draw(dest, state->font_small, FIELD_X,
			field_y[i] + state->font_small->ascent, FIELD_LABELS[i], label_color);
		int box_y = field_y[i] + 20;
		uint32_t border = i == state->focus_field ?
			FIELD_BORDER_FOCUS_COLOR : FIELD_BORDER_COLOR;
		draw_rect(px, stride_px, w, h, FIELD_X, box_y, FIELD_WIDTH, FIELD_HEIGHT,
			FIELD_BG_COLOR);
		draw_rect_border(px, stride_px, w, h, FIELD_X, box_y, FIELD_WIDTH,
			FIELD_HEIGHT, border);

		/* Password dots -- same fixed-per-character convention
		 * novi-lockscreen's own render() already uses. */
		size_t len = state->field_len[i];
		int dots_x = FIELD_X + 12;
		int dots_y = box_y + (FIELD_HEIGHT - DOT_SIZE) / 2;
		for (size_t d = 0; d < len; d++) {
			draw_rect(px, stride_px, w, h,
				dots_x + (int)d * (DOT_SIZE + DOT_GAP), dots_y, DOT_SIZE, DOT_SIZE,
				DOT_COLOR);
		}
	}

	if (state->status != NULL) {
		pixman_color_t status_color = state->status_is_error ? error_color : success_color;
		novi_text_draw(dest, state->font_small, FIELD_X,
			230 + state->font_small->ascent, state->status, status_color);
	} else {
		novi_text_draw(dest, state->font_small, FIELD_X,
			230 + state->font_small->ascent,
			"Tab to switch fields, Enter to save", label_color);
	}

	pixman_image_unref(dest);
}

static void surface_draw_frame(struct novi_settings *state) {
	if (!state->configured) {
		return;
	}
	uint32_t stride = state->width * 4;
	size_t size = (size_t)stride * state->height;

	int fd = allocate_shm_file(size);
	if (fd < 0) {
		fprintf(stderr, "novi-settings: failed to allocate shm buffer\n");
		return;
	}
	uint32_t *data = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (data == MAP_FAILED) {
		fprintf(stderr, "novi-settings: mmap failed\n");
		close(fd);
		return;
	}

	struct wl_shm_pool *pool = wl_shm_create_pool(state->shm, fd, (int32_t)size);
	struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0,
		(int32_t)state->width, (int32_t)state->height, (int32_t)stride,
		WL_SHM_FORMAT_XRGB8888);
	wl_shm_pool_destroy(pool);
	wl_display_flush(state->display); /* see novi-launcher's identical note on why */
	close(fd);

	render(state, data, state->width);
	munmap(data, size);

	wl_surface_attach(state->surface, buffer, 0, 0);
	wl_surface_damage_buffer(state->surface, 0, 0,
		(int32_t)state->width, (int32_t)state->height);
	wl_surface_commit(state->surface);
}

static void set_status(struct novi_settings *state, const char *msg, bool is_error) {
	state->status = msg;
	state->status_is_error = is_error;
}

static void try_submit(struct novi_settings *state) {
	if (state->field_len[0] == 0) {
		set_status(state, "Password can't be empty", true);
		wipe_fields(state);
		state->focus_field = 0;
		return;
	}
	if (strcmp(state->field[0], state->field[1]) != 0) {
		set_status(state, "Passwords don't match", true);
		wipe_fields(state);
		state->focus_field = 0;
		return;
	}
	if (change_root_password(state->field[0])) {
		set_status(state, "Password changed", false);
	} else {
		set_status(state, "Failed to change password", true);
	}
	wipe_fields(state);
	state->focus_field = 0;
}

/* ── wl_keyboard ─────────────────────────────────────────────────── */

static void keyboard_keymap(void *data, struct wl_keyboard *kb,
		uint32_t format, int32_t fd, uint32_t size) {
	(void)kb;
	struct novi_settings *state = data;
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
	(void)data; (void)kb; (void)serial; (void)surface;
	/* Unlike novi-lockscreen, losing focus here is completely normal
	 * (Alt+Tab away, click another window -- this is a regular app
	 * window, not a security boundary) and not something to react to;
	 * the typed-so-far fields just stay as they are until it regains
	 * focus, like any real app. */
}

static void keyboard_key(void *data, struct wl_keyboard *kb, uint32_t serial,
		uint32_t time, uint32_t key, uint32_t key_state) {
	(void)kb; (void)serial; (void)time;
	struct novi_settings *state = data;
	if (key_state != WL_KEYBOARD_KEY_STATE_PRESSED || state->xkb_state == NULL) {
		return;
	}
	xkb_keysym_t sym = xkb_state_key_get_one_sym(state->xkb_state, key + 8);
	bool shift = xkb_state_mod_name_is_active(state->xkb_state, XKB_MOD_NAME_SHIFT,
		XKB_STATE_MODS_EFFECTIVE) > 0;

	if (sym == XKB_KEY_Tab || sym == XKB_KEY_ISO_Left_Tab) {
		/* Shift+Tab reports XKB_KEY_ISO_Left_Tab on most layouts, not
		 * Tab-with-Shift-set -- the same keysym-after-modifiers
		 * behavior novi-shell's own Alt+Tab/Shift+Tab handling and
		 * Super+Shift+[1-9]'s bugfix both already document. Checking
		 * the modifier explicitly here (rather than branching on which
		 * keysym arrived) handles both real-world reportings the same
		 * way. */
		state->focus_field = shift ?
			(state->focus_field + FIELD_COUNT - 1) % FIELD_COUNT :
			(state->focus_field + 1) % FIELD_COUNT;
		set_status(state, NULL, false);
		surface_draw_frame(state);
		return;
	}
	if (sym == XKB_KEY_Return || sym == XKB_KEY_KP_Enter) {
		if (state->focus_field < FIELD_COUNT - 1) {
			state->focus_field++;
		} else {
			try_submit(state);
		}
		surface_draw_frame(state);
		return;
	}
	if (sym == XKB_KEY_Escape) {
		/* Not a security boundary (unlike novi-lockscreen) -- a plain
		 * "start over" convenience is fine here. */
		wipe_fields(state);
		state->focus_field = 0;
		set_status(state, NULL, false);
		surface_draw_frame(state);
		return;
	}
	if (sym == XKB_KEY_BackSpace) {
		size_t *len = &state->field_len[state->focus_field];
		if (*len > 0) {
			state->field[state->focus_field][--(*len)] = '\0';
		}
		set_status(state, NULL, false);
		surface_draw_frame(state);
		return;
	}

	if (sym >= 32 && sym < 127) {
		size_t *len = &state->field_len[state->focus_field];
		if (*len < FIELD_MAX) {
			state->field[state->focus_field][(*len)++] = (char)sym;
			state->field[state->focus_field][*len] = '\0';
		}
		set_status(state, NULL, false);
		surface_draw_frame(state);
	}
}

static void keyboard_modifiers(void *data, struct wl_keyboard *kb,
		uint32_t serial, uint32_t mods_depressed, uint32_t mods_latched,
		uint32_t mods_locked, uint32_t group) {
	(void)kb; (void)serial;
	struct novi_settings *state = data;
	if (state->xkb_state != NULL) {
		xkb_state_update_mask(state->xkb_state, mods_depressed, mods_latched,
			mods_locked, 0, 0, group);
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

/* ── wl_seat ─────────────────────────────────────────────────────── */

static void seat_capabilities(void *data, struct wl_seat *seat, uint32_t caps) {
	struct novi_settings *state = data;
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

/* ── xdg_wm_base / xdg_surface / xdg_toplevel ───────────────────────
 *
 * This client's real difference from every other one in this repo:
 * layer-shell clients (novi-launcher, novi-panel, novi-lockscreen)
 * anchor themselves and never negotiate a size with the compositor.
 * A plain xdg_toplevel goes through the standard xdg-shell handshake
 * instead: the compositor pings periodically (must pong back or risk
 * being considered unresponsive), and configure is a two-part
 * sequence -- xdg_toplevel::configure suggests a size (0x0 meaning
 * "you choose"), then xdg_surface::configure marks that suggestion
 * final and must be ack_configure()'d before the next commit. */

static void xdg_wm_base_ping(void *data, struct xdg_wm_base *wm_base,
		uint32_t serial) {
	(void)data;
	xdg_wm_base_pong(wm_base, serial);
}

static const struct xdg_wm_base_listener wm_base_listener = {
	.ping = xdg_wm_base_ping,
};

static void xdg_toplevel_configure(void *data, struct xdg_toplevel *xdg_toplevel,
		int32_t width, int32_t height, struct wl_array *states) {
	(void)xdg_toplevel; (void)states;
	struct novi_settings *state = data;
	/* 0x0 means "you decide" (xdg-shell protocol XML, xdg_toplevel::
	 * configure) -- this is a fixed-size settings form, not a
	 * resizable content view, so the suggested size is honored only
	 * when the compositor actually names one different from our own
	 * default; novi-shell today never resizes an existing toplevel
	 * after mapping, so in practice this just keeps WINDOW_WIDTH/
	 * HEIGHT on the very first configure. */
	state->width = width > 0 ? (uint32_t)width : WINDOW_WIDTH;
	state->height = height > 0 ? (uint32_t)height : WINDOW_HEIGHT;
}

static void xdg_toplevel_close(void *data, struct xdg_toplevel *xdg_toplevel) {
	(void)xdg_toplevel;
	struct novi_settings *state = data;
	/* The decoration's close dot (or any other close request) sends
	 * this -- same as foot handling its own window's close button. */
	state->running = false;
}

static void xdg_toplevel_configure_bounds(void *data,
		struct xdg_toplevel *xdg_toplevel, int32_t width, int32_t height) {
	(void)data; (void)xdg_toplevel; (void)width; (void)height;
}

static void xdg_toplevel_wm_capabilities(void *data,
		struct xdg_toplevel *xdg_toplevel, struct wl_array *capabilities) {
	(void)data; (void)xdg_toplevel; (void)capabilities;
}

static const struct xdg_toplevel_listener toplevel_listener = {
	.configure = xdg_toplevel_configure,
	.close = xdg_toplevel_close,
	.configure_bounds = xdg_toplevel_configure_bounds,
	.wm_capabilities = xdg_toplevel_wm_capabilities,
};

static void xdg_surface_configure(void *data, struct xdg_surface *xdg_surface,
		uint32_t serial) {
	struct novi_settings *state = data;
	xdg_surface_ack_configure(xdg_surface, serial);
	state->configured = true;
	surface_draw_frame(state);
}

static const struct xdg_surface_listener xdg_surface_listener_impl = {
	.configure = xdg_surface_configure,
};

/* ── wl_registry ─────────────────────────────────────────────────── */

static void registry_global(void *data, struct wl_registry *registry,
		uint32_t name, const char *interface, uint32_t version) {
	(void)version;
	struct novi_settings *state = data;
	if (strcmp(interface, wl_compositor_interface.name) == 0) {
		state->compositor = wl_registry_bind(registry, name,
			&wl_compositor_interface, 4);
	} else if (strcmp(interface, wl_shm_interface.name) == 0) {
		state->shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
	} else if (strcmp(interface, wl_seat_interface.name) == 0) {
		state->seat = wl_registry_bind(registry, name, &wl_seat_interface, 5);
		wl_seat_add_listener(state->seat, &seat_listener, state);
	} else if (strcmp(interface, xdg_wm_base_interface.name) == 0) {
		state->wm_base = wl_registry_bind(registry, name,
			&xdg_wm_base_interface, 1);
		xdg_wm_base_add_listener(state->wm_base, &wm_base_listener, state);
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
	struct novi_settings state = {0};
	state.running = true;
	state.width = WINDOW_WIDTH;
	state.height = WINDOW_HEIGHT;

	state.display = wl_display_connect(NULL);
	if (state.display == NULL) {
		fprintf(stderr, "novi-settings: failed to connect to Wayland display "
			"(is WAYLAND_DISPLAY set?)\n");
		return 1;
	}

	state.xkb_context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);

	state.registry = wl_display_get_registry(state.display);
	wl_registry_add_listener(state.registry, &registry_listener, &state);
	wl_display_roundtrip(state.display);

	if (state.compositor == NULL || state.shm == NULL || state.wm_base == NULL) {
		fprintf(stderr, "novi-settings: compositor is missing a required "
			"global (wl_compositor/wl_shm/xdg_wm_base)\n");
		return 1;
	}

	state.font = novi_text_load_font("JetBrains Mono:size=16");
	state.font_small = novi_text_load_font("JetBrains Mono:size=13");
	if (state.font == NULL || state.font_small == NULL) {
		fprintf(stderr, "novi-settings: failed to load JetBrains Mono\n");
		return 1;
	}

	state.surface = wl_compositor_create_surface(state.compositor);
	state.xdg_surface = xdg_wm_base_get_xdg_surface(state.wm_base, state.surface);
	xdg_surface_add_listener(state.xdg_surface, &xdg_surface_listener_impl, &state);
	state.xdg_toplevel = xdg_surface_get_toplevel(state.xdg_surface);
	xdg_toplevel_add_listener(state.xdg_toplevel, &toplevel_listener, &state);
	xdg_toplevel_set_title(state.xdg_toplevel, "Settings");
	xdg_toplevel_set_app_id(state.xdg_toplevel, "novi-settings");

	/* Initial commit with no buffer attached -- required before the
	 * compositor sends the first configure (xdg-shell protocol XML,
	 * xdg_surface's own description; same requirement every layer-
	 * shell client here already follows for its own initial commit). */
	wl_surface_commit(state.surface);

	while (state.running && wl_display_dispatch(state.display) != -1) {
		/* All the real work happens in the listener callbacks above. */
	}

	wipe_fields(&state);

	if (state.xdg_toplevel != NULL) {
		xdg_toplevel_destroy(state.xdg_toplevel);
	}
	if (state.xdg_surface != NULL) {
		xdg_surface_destroy(state.xdg_surface);
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
	if (state.font_small != NULL) {
		fcft_destroy(state.font_small);
	}
	wl_display_disconnect(state.display);
	return 0;
}
