/* novi-lockscreen — Super+L session lock (RFC 0001 decision 7).
 *
 * Unlike novi-launcher/novi-panel, this isn't a convenience overlay --
 * it's meant to be a real security boundary, so it's built to the
 * standard a lock screen actually needs, not just "a layer-shell
 * surface that happens to cover the screen":
 *
 *  - Anchored to all four edges with exclusive_zone=-1 at the OVERLAY
 *    layer, so it covers the entire output including novi-panel's own
 *    top bar, not just the area below it.
 *  - novi-shell recognizes this surface by its zwlr_layer_surface_v1
 *    namespace (NOVI_LOCK_NAMESPACE, matching the identical constant
 *    in novi-shell/main.c) and sets novi_server.locked while it's
 *    mapped. That flag -- not this client's own existence -- is what
 *    actually disables every compositor keybinding and refuses every
 *    focus-stealing path (see novi-shell/main.c's keyboard_handle_key()
 *    and focus_toplevel() for the two guards). Without that half,
 *    Super+Q or another Alt+Space would still run underneath a merely
 *    visual lock screen, exactly the class of bug that makes a fake
 *    lock worse than no lock: it looks secure and isn't.
 *  - Real authentication, not a placeholder: reads /etc/shadow's own
 *    "root" entry (the only interactive user this system has today --
 *    there's no multi-user session model yet, matching the plain
 *    "root login on ttyS0" reality of how this system actually boots)
 *    and checks a typed password against it with musl's real crypt(3),
 *    the same primitive passwd/login already rely on. If root has no
 *    password set (this repo's stock /etc/shadow ships an empty hash
 *    field -- no `passwd` flow has ever run), this refuses to lock at
 *    all rather than either accepting any input as correct or locking
 *    the user out with nothing that could ever unlock it: checked
 *    before ever opening a Wayland connection or mapping a surface, so
 *    Super+L with no password set is a silent no-op (logged to
 *    stderr), never a fake or a lockout.
 *  - Escape does NOT dismiss this overlay (unlike every other one in
 *    this repo) -- that would defeat the entire point. It only clears
 *    whatever's currently typed, a plain "clear the field" convenience.
 *    The only way out is a correct password.
 *
 * v1 scope: no rate-limiting/backoff on repeated wrong attempts (a
 * real follow-up -- this is a local single-user system with no network
 * exposure to brute-force, but it's still a gap worth tracking rather
 * than silently deciding it doesn't matter), and no "no /etc/shadow at
 * all" recovery UI beyond the stderr message above.
 */
#include <crypt.h>
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

/* Must match novi-shell/main.c's identical NOVI_LOCK_NAMESPACE -- see
 * that file's comment on why a plain string match, not a new protocol,
 * is how the compositor tells this surface apart from any other
 * layer-shell client. */
#define LOCK_NAMESPACE "novi-lockscreen"

#define PASSWORD_MAX 127
#define BG_COLOR 0xff14141cu
#define TEXT_COLOR 0xffe0e0f0u
#define HINT_COLOR 0xff8a8aa0u
#define ERROR_COLOR 0xffe08a8au
#define DOT_COLOR 0xffe0e0f0u
#define DOT_SIZE 10
#define DOT_GAP 8

struct novi_lockscreen {
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
	struct fcft_font *font_small;

	uint32_t width, height;
	bool configured;
	bool running;

	char password[PASSWORD_MAX + 1];
	size_t password_len;
	char shadow_hash[256];

	/* Set after a wrong password, cleared on the next keystroke --
	 * drives the "Incorrect password" line in render(). */
	bool show_error;
};

/* ── Password verification ──────────────────────────────────────────
 *
 * /etc/shadow's format is "user:hash:...six more colon-separated
 * fields..." (see shadow(5)) -- only the first two fields matter here.
 * Returns false (and leaves *hash untouched) if `user` has no entry at
 * all, which read_shadow_hash()'s caller treats identically to "no
 * password set": either way, there is nothing this lock screen could
 * ever check a typed password against. */
static bool read_shadow_hash(const char *user, char *hash, size_t hash_size) {
	FILE *f = fopen("/etc/shadow", "r");
	if (f == NULL) {
		return false;
	}
	char line[512];
	bool found = false;
	size_t user_len = strlen(user);
	while (fgets(line, sizeof(line), f) != NULL) {
		if (strncmp(line, user, user_len) != 0 || line[user_len] != ':') {
			continue;
		}
		char *hash_start = line + user_len + 1;
		char *colon = strchr(hash_start, ':');
		size_t hash_len = colon != NULL ?
			(size_t)(colon - hash_start) : strlen(hash_start);
		while (hash_len > 0 &&
				(hash_start[hash_len - 1] == '\n' || hash_start[hash_len - 1] == '\r')) {
			hash_len--;
		}
		if (hash_len >= hash_size) {
			hash_len = hash_size - 1;
		}
		memcpy(hash, hash_start, hash_len);
		hash[hash_len] = '\0';
		found = true;
		break;
	}
	fclose(f);
	return found;
}

/* A hash field that can never successfully verify anything, per
 * standard shadow(5) convention: empty (no password ever set), "*" or
 * "!" alone (password auth explicitly disabled), or "!"-prefixed (a
 * real hash administratively locked -- passwd -l's convention). Any of
 * these means "this lock screen has nothing real to check a typed
 * password against", not "accept anything". */
static bool hash_is_usable(const char *hash) {
	return hash[0] != '\0' && strcmp(hash, "*") != 0 &&
		strcmp(hash, "!") != 0 && hash[0] != '!';
}

/* Fixed-time comparison of two equal-purpose strings -- crypt()'s
 * own output is already the dominant cost here by orders of magnitude,
 * so this isn't closing a realistic timing side-channel on a
 * single-user local machine with no network exposure, but comparing
 * secrets with plain strcmp() (which returns the instant it finds a
 * mismatching byte) is a bad habit worth not forming even here. */
static bool constant_time_equal(const char *a, const char *b) {
	size_t len_a = strlen(a), len_b = strlen(b);
	if (len_a != len_b) {
		return false;
	}
	unsigned char diff = 0;
	for (size_t i = 0; i < len_a; i++) {
		diff |= (unsigned char)(a[i] ^ b[i]);
	}
	return diff == 0;
}

static bool verify_password(struct novi_lockscreen *state) {
	char *result = crypt(state->password, state->shadow_hash);
	if (result == NULL) {
		return false;
	}
	return constant_time_equal(result, state->shadow_hash);
}

/* ── Shared-memory buffer allocation (identical pattern to
 * novi-launcher/novi-panel/novi-screenshot -- see any of theirs for
 * why: shm_open+O_EXCL retry loop instead of mkstemp, matching
 * wlroots' own util/shm.c). ── */
static int allocate_shm_file(size_t size) {
	char name[] = "/novi-lockscreen-XXXXXX";
	struct timespec ts;
	int fd = -1;
	for (int tries = 0; tries < 100 && fd < 0; tries++) {
		clock_gettime(CLOCK_REALTIME, &ts);
		long r = ts.tv_nsec + tries;
		for (int i = 0; i < 6; i++) {
			name[18 + i] = 'A' + (r & 15) + (r & 16) * 2;
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

static void render(struct novi_lockscreen *state, uint32_t *px,
		uint32_t stride_px) {
	uint32_t w = state->width, h = state->height;
	draw_rect(px, stride_px, w, h, 0, 0, (int)w, (int)h, BG_COLOR);

	pixman_image_t *dest = pixman_image_create_bits_no_clear(
		PIXMAN_a8r8g8b8, (int)w, (int)h, px, (int)stride_px * 4);

	static const pixman_color_t text_color = {
		.red = 0xe000, .green = 0xe000, .blue = 0xf000, .alpha = 0xffff,
	};
	static const pixman_color_t hint_color = {
		.red = 0x8a00, .green = 0x8a00, .blue = 0xa000, .alpha = 0xffff,
	};
	static const pixman_color_t error_color = {
		.red = 0xe000, .green = 0x8a00, .blue = 0x8a00, .alpha = 0xffff,
	};

	const char *label = "Locked";
	int label_w = novi_text_width(state->font, label);
	int label_x = ((int)w - label_w) / 2;
	int center_y = (int)h / 2;
	novi_text_draw(dest, state->font, label_x, center_y - 40, label, text_color);

	/* Password dots: one per typed character, matching the common
	 * (GNOME/macOS/most lock screens) convention of showing input
	 * length rather than hiding it entirely -- a well-understood,
	 * accepted tradeoff, not an oversight. */
	int dots_w = state->password_len > 0 ?
		(int)state->password_len * (DOT_SIZE + DOT_GAP) - DOT_GAP : 0;
	int dots_x = ((int)w - dots_w) / 2;
	int dots_y = center_y;
	for (size_t i = 0; i < state->password_len; i++) {
		draw_rect(px, stride_px, w, h,
			dots_x + (int)i * (DOT_SIZE + DOT_GAP), dots_y, DOT_SIZE, DOT_SIZE,
			DOT_COLOR);
	}

	const char *hint = state->show_error ?
		"Incorrect password" : "Type your password, then press Enter";
	pixman_color_t hint_draw_color = state->show_error ? error_color : hint_color;
	int hint_w = novi_text_width(state->font_small, hint);
	novi_text_draw(dest, state->font_small, ((int)w - hint_w) / 2,
		center_y + 40, hint, hint_draw_color);

	pixman_image_unref(dest);
}

static void surface_draw_frame(struct novi_lockscreen *state) {
	if (!state->configured) {
		return;
	}
	uint32_t stride = state->width * 4;
	size_t size = (size_t)stride * state->height;

	int fd = allocate_shm_file(size);
	if (fd < 0) {
		fprintf(stderr, "novi-lockscreen: failed to allocate shm buffer\n");
		return;
	}
	uint32_t *data = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (data == MAP_FAILED) {
		fprintf(stderr, "novi-lockscreen: mmap failed\n");
		close(fd);
		return;
	}

	struct wl_shm_pool *pool = wl_shm_create_pool(state->shm, fd, (int32_t)size);
	/* XRGB, not ARGB: this surface is a fully opaque solid background
	 * (that's the point -- it has to hide everything behind it), so
	 * there's no real alpha channel to punch, unlike novi-launcher's
	 * rounded card. */
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

/* ── wl_keyboard ─────────────────────────────────────────────────── */

static void keyboard_keymap(void *data, struct wl_keyboard *kb,
		uint32_t format, int32_t fd, uint32_t size) {
	(void)kb;
	struct novi_lockscreen *state = data;
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
	/* Deliberately NOT state->running = false here, unlike every other
	 * overlay in this repo: novi-shell's own focus_toplevel() guard
	 * (see novi-shell/main.c's novi_server.locked comment) refuses to
	 * move keyboard focus away from this surface while locked, so this
	 * should never legitimately fire before a correct password is
	 * entered -- and if it somehow did anyway, exiting here would be
	 * exactly the kind of silent bypass this whole feature exists to
	 * prevent. Staying mapped (and thus still covering the screen, with
	 * novi_server.locked still set) is the fail-safe behavior. */
}

static void wipe_password(struct novi_lockscreen *state) {
	explicit_bzero(state->password, sizeof(state->password));
	state->password_len = 0;
}

static void keyboard_key(void *data, struct wl_keyboard *kb, uint32_t serial,
		uint32_t time, uint32_t key, uint32_t key_state) {
	(void)kb; (void)serial; (void)time;
	struct novi_lockscreen *state = data;
	if (key_state != WL_KEYBOARD_KEY_STATE_PRESSED || state->xkb_state == NULL) {
		return;
	}
	xkb_keysym_t sym = xkb_state_key_get_one_sym(state->xkb_state, key + 8);

	if (sym == XKB_KEY_Return || sym == XKB_KEY_KP_Enter) {
		if (verify_password(state)) {
			wipe_password(state);
			state->running = false;
		} else {
			wipe_password(state);
			state->show_error = true;
			surface_draw_frame(state);
		}
		return;
	}
	if (sym == XKB_KEY_Escape) {
		/* Clears the field -- does NOT unlock. See file header. */
		wipe_password(state);
		state->show_error = false;
		surface_draw_frame(state);
		return;
	}
	if (sym == XKB_KEY_BackSpace) {
		if (state->password_len > 0) {
			state->password[--state->password_len] = '\0';
		}
		state->show_error = false;
		surface_draw_frame(state);
		return;
	}

	if (sym >= 32 && sym < 127) {
		if (state->password_len < PASSWORD_MAX) {
			state->password[state->password_len++] = (char)sym;
			state->password[state->password_len] = '\0';
		}
		state->show_error = false;
		surface_draw_frame(state);
	}
}

static void keyboard_modifiers(void *data, struct wl_keyboard *kb,
		uint32_t serial, uint32_t mods_depressed, uint32_t mods_latched,
		uint32_t mods_locked, uint32_t group) {
	(void)kb; (void)serial;
	struct novi_lockscreen *state = data;
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
	struct novi_lockscreen *state = data;
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
	struct novi_lockscreen *state = data;
	zwlr_layer_surface_v1_ack_configure(layer_surface, serial);
	state->width = width;
	state->height = height;
	state->configured = true;
	surface_draw_frame(state);
}

static void layer_surface_closed(void *data,
		struct zwlr_layer_surface_v1 *layer_surface) {
	(void)layer_surface;
	struct novi_lockscreen *state = data;
	/* The compositor asking this surface to close (e.g. output removed)
	 * is not "user entered the correct password" -- but there's nothing
	 * left to display against if wlroots is tearing the surface down
	 * regardless, so exit rather than spin forever with a surface
	 * that's already gone. */
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
	struct novi_lockscreen *state = data;
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
	struct novi_lockscreen state = {0};
	state.running = true;

	/* Real auth check FIRST, before even connecting to Wayland -- if
	 * there's nothing to verify a password against, this should be a
	 * silent no-op (logged, not a fake lock screen and not a lockout),
	 * and there's no point mapping a surface just to tear it down a
	 * moment later. See file header and hash_is_usable()'s own comment. */
	if (!read_shadow_hash("root", state.shadow_hash, sizeof(state.shadow_hash)) ||
			!hash_is_usable(state.shadow_hash)) {
		fprintf(stderr, "novi-lockscreen: root has no password set "
			"(run 'passwd' first) -- refusing to lock\n");
		return 1;
	}

	state.display = wl_display_connect(NULL);
	if (state.display == NULL) {
		fprintf(stderr, "novi-lockscreen: failed to connect to Wayland display "
			"(is WAYLAND_DISPLAY set?)\n");
		return 1;
	}

	state.xkb_context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);

	state.registry = wl_display_get_registry(state.display);
	wl_registry_add_listener(state.registry, &registry_listener, &state);
	wl_display_roundtrip(state.display);

	if (state.compositor == NULL || state.shm == NULL ||
			state.layer_shell == NULL) {
		fprintf(stderr, "novi-lockscreen: compositor is missing a required "
			"global (wl_compositor/wl_shm/zwlr_layer_shell_v1)\n");
		return 1;
	}

	state.font = novi_text_load_font("JetBrains Mono:size=24");
	state.font_small = novi_text_load_font("JetBrains Mono:size=14");
	if (state.font == NULL || state.font_small == NULL) {
		fprintf(stderr, "novi-lockscreen: failed to load JetBrains Mono\n");
		return 1;
	}

	state.surface = wl_compositor_create_surface(state.compositor);
	state.layer_surface = zwlr_layer_shell_v1_get_layer_surface(
		state.layer_shell, state.surface, NULL,
		ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, LOCK_NAMESPACE);
	/* Anchored to all four edges with size (0,0): the protocol's own
	 * convention for "give me the whole output, whatever size that
	 * turns out to be" -- the compositor reports the real dimensions in
	 * the configure event (layer_surface_configure() above) rather than
	 * this client hardcoding or querying an output size itself. */
	zwlr_layer_surface_v1_set_anchor(state.layer_surface,
		ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM |
		ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT);
	zwlr_layer_surface_v1_set_size(state.layer_surface, 0, 0);
	/* -1: cover the panel's own reserved space too, not just the area
	 * below it -- a lock screen that left the top bar visible/clickable
	 * would leak whatever the panel shows (the clock, at minimum) and
	 * defeat the "hide everything" point of locking at all. */
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

	/* Defense in depth: wipe the password buffer on every exit path,
	 * not just the successful-unlock one keyboard_key() already
	 * handles (e.g. layer_surface_closed() exiting mid-entry). */
	wipe_password(&state);

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
	if (state.font_small != NULL) {
		fcft_destroy(state.font_small);
	}
	wl_display_disconnect(state.display);
	return 0;
}
