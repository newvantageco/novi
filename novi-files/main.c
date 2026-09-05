/* ============================================================
 * novi-files — a file manager for the Novi desktop
 *
 * The second first-party application, and it exists because the first
 * one made it possible: novi-edit opens anything, so this can hand it
 * any file it does not understand and always have somewhere to go.
 * That ordering was the whole reason the editor came first.
 *
 * A raw xdg-shell client drawing with pixman and fcft, like every
 * other GUI program here. Keyboard-driven, because that is what the
 * rest of this desktop is and a file manager that needs the mouse
 * while the launcher, the editor and the terminal do not would be the
 * odd one out.
 *
 * What it does: list a directory, walk into it, walk back out, and
 * open a file with novi-edit. Directories first, then files, both
 * alphabetically. Sizes in human units. Hidden entries off by default,
 * ^H to show them.
 *
 * What it does NOT do, stated rather than left to be discovered:
 *
 *   - No copy, move, rename or delete. Destructive operations need a
 *     confirmation flow, an undo story, and a progress indicator for
 *     anything larger than instant -- and a file manager that deletes
 *     without any of those is worse than one that cannot delete. It is
 *     the next piece of work here, not an oversight.
 *   - No multi-select, no drag and drop, no mouse at all yet.
 *   - No "open with" choice: a directory is navigated, and everything
 *     else goes to novi-edit. When there is an image viewer, this is
 *     where the dispatch table goes.
 *   - No file watching. The listing is read when you enter a directory
 *     and refreshed on ^R, not when something changes underneath you.
 * ============================================================ */

#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <pixman.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>

#include "icons.h"
#include "icon_blit.h"
#include "text.h"
#include "xdg-shell-client-protocol.h"

#define WINDOW_WIDTH  860
#define WINDOW_HEIGHT 600

#define PAD        14
#define ROW_H      26
#define ICON_SIZE  16
#define ICON_GAP   10
#define HEADER_H   40
#define STATUS_H   28

/* A directory with more entries than this lists the first MAX_ENTRIES
 * and says so in the status bar. The cap exists so that pointing this
 * at something pathological cannot exhaust memory; it is reported
 * rather than silently truncating, same rule as novi-edit's. */
#define MAX_ENTRIES 20000
#define NAME_MAX_LEN 255

#define BG_COLOR      0xff16161eu
#define HEADER_BG     0xff1b1b26u
#define STATUS_BG     0xff232430u
#define SEL_BG        0xff23303cu
#define SEL_BAR       0xff2dd4bfu

#define ICON_DIR_COLOR  0xff7aa2f7u
#define ICON_FILE_COLOR 0xff8b8fa3u

static const pixman_color_t NAME_PIX    = {0xc8c8, 0xcccc, 0xd8d8, 0xffff};
static const pixman_color_t DIR_PIX     = {0x7a7a, 0xa2a2, 0xf7f7, 0xffff};
static const pixman_color_t SIZE_PIX    = {0x6a6a, 0x6e6e, 0x8080, 0xffff};
static const pixman_color_t PATH_PIX    = {0xa3a3, 0xa7a7, 0xb7b7, 0xffff};
static const pixman_color_t STATUS_PIX  = {0x8b8b, 0x8f8f, 0xa3a3, 0xffff};
static const pixman_color_t ERROR_PIX   = {0xf0f0, 0x7a7a, 0x7a7a, 0xffff};

struct entry {
	char name[NAME_MAX_LEN + 1];
	bool is_dir;
	off_t size;
};

struct novi_files {
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

	struct fcft_font *font;
	struct fcft_font *font_small;

	uint32_t width, height;
	bool configured;
	bool running;

	char cwd[PATH_MAX];
	struct entry *entries;
	int nentries;
	int entries_cap;
	int sel;
	int top;
	bool show_hidden;
	bool truncated;

	char status[256];
	bool status_is_error;
};

static void set_status(struct novi_files *s, bool err, const char *fmt, ...)
	__attribute__((format(printf, 3, 4)));

static void set_status(struct novi_files *s, bool err, const char *fmt, ...) {
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(s->status, sizeof(s->status), fmt, ap);
	va_end(ap);
	s->status_is_error = err;
}

/* ── Listing ───────────────────────────────────────────────────── */

/* Directories before files, then case-insensitive by name. This is the
 * ordering every file manager uses and the reason is not aesthetic:
 * directories are the navigable things, so they are what the eye is
 * looking for when the list is long. */
static int entry_cmp(const void *a, const void *b) {
	const struct entry *x = a, *y = b;
	if (x->is_dir != y->is_dir) {
		return x->is_dir ? -1 : 1;
	}
	return strcasecmp(x->name, y->name);
}

static bool entries_reserve(struct novi_files *s, int want) {
	if (want <= s->entries_cap) {
		return true;
	}
	int cap = s->entries_cap ? s->entries_cap * 2 : 128;
	while (cap < want) {
		cap *= 2;
	}
	struct entry *grown = realloc(s->entries, (size_t)cap * sizeof(*grown));
	if (grown == NULL) {
		return false;
	}
	s->entries = grown;
	s->entries_cap = cap;
	return true;
}

static void read_dir(struct novi_files *s) {
	s->nentries = 0;
	s->truncated = false;

	DIR *d = opendir(s->cwd);
	if (d == NULL) {
		set_status(s, true, "cannot open: %s", strerror(errno));
		return;
	}

	struct dirent *de;
	while ((de = readdir(d)) != NULL) {
		if (strcmp(de->d_name, ".") == 0 || strcmp(de->d_name, "..") == 0) {
			continue;
		}
		if (!s->show_hidden && de->d_name[0] == '.') {
			continue;
		}
		if (s->nentries >= MAX_ENTRIES) {
			s->truncated = true;
			break;
		}
		if (!entries_reserve(s, s->nentries + 1)) {
			s->truncated = true;
			break;
		}

		struct entry *e = &s->entries[s->nentries];
		snprintf(e->name, sizeof(e->name), "%s", de->d_name);

		/* stat() rather than trusting d_type: it is not portable
		 * across filesystems (some return DT_UNKNOWN for everything),
		 * and a symlink to a directory should navigate like a
		 * directory, which means following it -- which d_type does
		 * not do. A stat that fails leaves the entry listed as a file
		 * rather than hiding it; a broken symlink is still something
		 * you want to see. */
		char full[PATH_MAX];
		int n = snprintf(full, sizeof(full), "%s/%s", s->cwd, de->d_name);
		struct stat st;
		if (n > 0 && (size_t)n < sizeof(full) && stat(full, &st) == 0) {
			e->is_dir = S_ISDIR(st.st_mode);
			e->size = st.st_size;
		} else {
			e->is_dir = false;
			e->size = 0;
		}
		s->nentries++;
	}
	closedir(d);

	qsort(s->entries, (size_t)s->nentries, sizeof(*s->entries), entry_cmp);
	s->sel = 0;
	s->top = 0;
	if (s->truncated) {
		set_status(s, true, "listing truncated at %d entries", MAX_ENTRIES);
	}
}

static void human_size(off_t n, char *out, size_t outlen) {
	const char *unit[] = {"B", "K", "M", "G", "T"};
	int i = 0;
	double v = (double)n;
	while (v >= 1024.0 && i < 4) {
		v /= 1024.0;
		i++;
	}
	if (i == 0) {
		snprintf(out, outlen, "%lld B", (long long)n);
	} else {
		snprintf(out, outlen, "%.1f %s", v, unit[i]);
	}
}

/* ── Navigation ────────────────────────────────────────────────── */

static void go_to(struct novi_files *s, const char *path) {
	char resolved[PATH_MAX];
	if (realpath(path, resolved) == NULL) {
		set_status(s, true, "cannot enter: %s", strerror(errno));
		return;
	}
	/* Confirm it is a directory we can actually list before committing
	 * to it -- otherwise a permission error leaves the view showing one
	 * path and the title showing another. */
	DIR *probe = opendir(resolved);
	if (probe == NULL) {
		set_status(s, true, "cannot enter: %s", strerror(errno));
		return;
	}
	closedir(probe);

	snprintf(s->cwd, sizeof(s->cwd), "%s", resolved);
	s->status[0] = '\0';
	read_dir(s);
}

static void go_up(struct novi_files *s) {
	if (strcmp(s->cwd, "/") == 0) {
		return;
	}
	char parent[PATH_MAX];
	snprintf(parent, sizeof(parent), "%s/..", s->cwd);
	/* Remember where we came from so the cursor lands on it, which is
	 * what makes walking back out of a tree feel like undo rather than
	 * like starting over. */
	const char *leaf = strrchr(s->cwd, '/');
	char was[NAME_MAX_LEN + 1] = {0};
	if (leaf != NULL && leaf[1] != '\0') {
		snprintf(was, sizeof(was), "%s", leaf + 1);
	}
	go_to(s, parent);
	if (was[0] != '\0') {
		for (int i = 0; i < s->nentries; i++) {
			if (strcmp(s->entries[i].name, was) == 0) {
				s->sel = i;
				break;
			}
		}
	}
}

/* Everything that is not a directory goes to novi-edit. When there is
 * an image viewer this is where the dispatch table goes; one target is
 * not a table yet, and pretending otherwise would be scaffolding for a
 * decision not taken. */
static void open_selected(struct novi_files *s) {
	if (s->nentries == 0) {
		return;
	}
	struct entry *e = &s->entries[s->sel];
	char full[PATH_MAX];
	int n = snprintf(full, sizeof(full), "%s/%s", s->cwd, e->name);
	if (n < 0 || (size_t)n >= sizeof(full)) {
		set_status(s, true, "path too long");
		return;
	}

	if (e->is_dir) {
		go_to(s, full);
		return;
	}

	pid_t pid = fork();
	if (pid < 0) {
		set_status(s, true, "fork failed: %s", strerror(errno));
		return;
	}
	if (pid == 0) {
		/* Its own session, so it outlives this window being closed --
		 * the same reasoning novi-shell's spawn() documents. */
		setsid();
		execlp("novi-edit", "novi-edit", full, (char *)NULL);
		_exit(127);
	}
	set_status(s, false, "opened %s", e->name);
}

/* ── Rendering ─────────────────────────────────────────────────── */

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

static int visible_rows(const struct novi_files *s) {
	int h = (int)s->height - HEADER_H - STATUS_H;
	return h > 0 ? h / ROW_H : 1;
}

static void scroll_to_sel(struct novi_files *s) {
	int rows = visible_rows(s);
	if (rows < 1) {
		rows = 1;
	}
	if (s->sel < s->top) {
		s->top = s->sel;
	} else if (s->sel >= s->top + rows) {
		s->top = s->sel - rows + 1;
	}
	if (s->top < 0) {
		s->top = 0;
	}
}

static void render(struct novi_files *s, uint32_t *px, uint32_t stride_px) {
	uint32_t w = s->width, h = s->height;
	pixman_image_t *dest = pixman_image_create_bits(PIXMAN_x8r8g8b8,
		(int)w, (int)h, px, (int)(stride_px * 4));

	draw_rect(px, stride_px, w, h, 0, 0, (int)w, (int)h, BG_COLOR);

	/* Header: the current path. */
	draw_rect(px, stride_px, w, h, 0, 0, (int)w, HEADER_H, HEADER_BG);
	int hbase = (HEADER_H - s->font->height) / 2 + s->font->ascent;
	novi_text_draw(dest, s->font, PAD, hbase, s->cwd, PATH_PIX);

	int rows = visible_rows(s);
	for (int r = 0; r < rows; r++) {
		int i = s->top + r;
		if (i >= s->nentries) {
			break;
		}
		struct entry *e = &s->entries[i];
		int y = HEADER_H + r * ROW_H;
		bool selected = (i == s->sel);

		if (selected) {
			draw_rect(px, stride_px, w, h, 0, y, (int)w, ROW_H, SEL_BG);
			draw_rect(px, stride_px, w, h, 0, y, 3, ROW_H, SEL_BAR);
		}

		/* ICON_PENCIL for a plain file is a compromise: the generated
		 * set (shared/icons) has no generic document glyph, and pencil
		 * is the least-wrong of what exists -- it at least says "this
		 * opens in the editor", which here is true. A `file` icon
		 * belongs in the next pass of tools/svg2icon, not in a
		 * hand-drawn one-off here. */
		draw_icon(px, stride_px, w, h, PAD, y + (ROW_H - ICON_SIZE) / 2,
			e->is_dir ? ICON_FOLDER : ICON_PENCIL,
			e->is_dir ? ICON_DIR_COLOR : ICON_FILE_COLOR);

		int baseline = y + (ROW_H - s->font->height) / 2 + s->font->ascent;
		novi_text_draw(dest, s->font, PAD + ICON_SIZE + ICON_GAP, baseline,
			e->name, e->is_dir ? DIR_PIX : NAME_PIX);

		if (!e->is_dir) {
			char sz[32];
			human_size(e->size, sz, sizeof(sz));
			int sw = novi_text_width(s->font_small, sz);
			novi_text_draw(dest, s->font_small, (int)w - PAD - sw,
				baseline, sz, SIZE_PIX);
		}
	}

	if (s->nentries == 0) {
		int baseline = HEADER_H + ROW_H + s->font->ascent;
		novi_text_draw(dest, s->font, PAD + ICON_SIZE + ICON_GAP, baseline,
			"(empty)", SIZE_PIX);
	}

	/* Status bar. */
	int sy = (int)h - STATUS_H;
	draw_rect(px, stride_px, w, h, 0, sy, (int)w, STATUS_H, STATUS_BG);
	int sbase = sy + (STATUS_H - s->font_small->height) / 2 + s->font_small->ascent;

	char left[128];
	snprintf(left, sizeof(left), "%d item%s%s", s->nentries,
		s->nentries == 1 ? "" : "s", s->show_hidden ? "   (hidden shown)" : "");
	novi_text_draw(dest, s->font_small, PAD, sbase, left, STATUS_PIX);

	char right[sizeof(s->status) + 64];
	snprintf(right, sizeof(right), "%s", s->status[0] ? s->status :
		"Enter open   Bksp up   ^H hidden   ^R refresh   ^Q quit");
	int rw = novi_text_width(s->font_small, right);
	novi_text_draw(dest, s->font_small, (int)w - PAD - rw, sbase, right,
		s->status_is_error ? ERROR_PIX : STATUS_PIX);

	pixman_image_unref(dest);
}

/* ── Wayland plumbing ──────────────────────────────────────────── */

static int allocate_shm_file(size_t size) {
	char name[] = "/novi-files-XXXXXX";
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

static void surface_draw_frame(struct novi_files *s) {
	if (!s->configured) {
		return;
	}
	uint32_t stride = s->width * 4;
	size_t size = (size_t)stride * s->height;

	int fd = allocate_shm_file(size);
	if (fd < 0) {
		fprintf(stderr, "novi-files: failed to allocate shm buffer\n");
		return;
	}
	uint32_t *data = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (data == MAP_FAILED) {
		fprintf(stderr, "novi-files: mmap failed\n");
		close(fd);
		return;
	}
	struct wl_shm_pool *pool = wl_shm_create_pool(s->shm, fd, (int32_t)size);
	struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0,
		(int32_t)s->width, (int32_t)s->height, (int32_t)stride,
		WL_SHM_FORMAT_XRGB8888);
	wl_shm_pool_destroy(pool);
	wl_display_flush(s->display);
	close(fd);

	render(s, data, s->width);
	munmap(data, size);

	wl_surface_attach(s->surface, buffer, 0, 0);
	wl_surface_damage_buffer(s->surface, 0, 0,
		(int32_t)s->width, (int32_t)s->height);
	wl_surface_commit(s->surface);
}

static void handle_key(struct novi_files *s, xkb_keysym_t sym, bool ctrl) {
	if (ctrl) {
		switch (sym) {
		case XKB_KEY_q: case XKB_KEY_Q:
			s->running = false;
			return;
		case XKB_KEY_h: case XKB_KEY_H:
			s->show_hidden = !s->show_hidden;
			s->status[0] = '\0';
			read_dir(s);
			return;
		case XKB_KEY_r: case XKB_KEY_R:
			s->status[0] = '\0';
			read_dir(s);
			set_status(s, false, "refreshed");
			return;
		default:
			return;
		}
	}

	switch (sym) {
	case XKB_KEY_Escape:
		s->running = false;
		return;
	case XKB_KEY_Up:
		if (s->sel > 0) { s->sel--; }
		break;
	case XKB_KEY_Down:
		if (s->sel < s->nentries - 1) { s->sel++; }
		break;
	case XKB_KEY_Home:
		s->sel = 0;
		break;
	case XKB_KEY_End:
		s->sel = s->nentries > 0 ? s->nentries - 1 : 0;
		break;
	case XKB_KEY_Page_Up: {
		int rows = visible_rows(s);
		s->sel = s->sel > rows ? s->sel - rows : 0;
		break;
	}
	case XKB_KEY_Page_Down: {
		int rows = visible_rows(s);
		s->sel = s->sel + rows < s->nentries ? s->sel + rows
			: (s->nentries > 0 ? s->nentries - 1 : 0);
		break;
	}
	case XKB_KEY_Return: case XKB_KEY_KP_Enter: case XKB_KEY_Right:
		open_selected(s);
		break;
	case XKB_KEY_BackSpace: case XKB_KEY_Left:
		go_up(s);
		break;
	default:
		break;
	}
	scroll_to_sel(s);
}

static void keyboard_keymap(void *data, struct wl_keyboard *kb,
		uint32_t format, int fd, uint32_t size) {
	struct novi_files *s = data;
	if (format != WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) {
		close(fd);
		return;
	}
	char *map = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
	if (map == MAP_FAILED) {
		close(fd);
		return;
	}
	struct xkb_keymap *keymap = xkb_keymap_new_from_string(s->xkb_context,
		map, XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS);
	munmap(map, size);
	close(fd);
	if (keymap == NULL) {
		return;
	}
	struct xkb_state *st = xkb_state_new(keymap);
	if (s->xkb_state != NULL) {
		xkb_state_unref(s->xkb_state);
	}
	if (s->xkb_keymap != NULL) {
		xkb_keymap_unref(s->xkb_keymap);
	}
	s->xkb_keymap = keymap;
	s->xkb_state = st;
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
	struct novi_files *s = data;
	if (key_state != WL_KEYBOARD_KEY_STATE_PRESSED || s->xkb_state == NULL) {
		return;
	}
	xkb_keysym_t sym = xkb_state_key_get_one_sym(s->xkb_state, key + 8);
	bool ctrl = xkb_state_mod_name_is_active(s->xkb_state, XKB_MOD_NAME_CTRL,
		XKB_STATE_MODS_EFFECTIVE) > 0;
	handle_key(s, sym, ctrl);
	surface_draw_frame(s);
}

static void keyboard_modifiers(void *data, struct wl_keyboard *kb,
		uint32_t serial, uint32_t depressed, uint32_t latched,
		uint32_t locked, uint32_t group) {
	struct novi_files *s = data;
	if (s->xkb_state != NULL) {
		xkb_state_update_mask(s->xkb_state, depressed, latched, locked,
			0, 0, group);
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
	struct novi_files *s = data;
	if ((caps & WL_SEAT_CAPABILITY_KEYBOARD) && s->keyboard == NULL) {
		s->keyboard = wl_seat_get_keyboard(seat);
		wl_keyboard_add_listener(s->keyboard, &keyboard_listener, s);
	}
}

static void seat_name(void *data, struct wl_seat *seat, const char *name) {
	(void)data; (void)seat; (void)name;
}

static const struct wl_seat_listener seat_listener = {
	.capabilities = seat_capabilities,
	.name = seat_name,
};

static void wm_base_ping(void *data, struct xdg_wm_base *wm_base,
		uint32_t serial) {
	(void)data;
	xdg_wm_base_pong(wm_base, serial);
}

static const struct xdg_wm_base_listener wm_base_listener = {
	.ping = wm_base_ping,
};

static void xdg_surface_configure(void *data, struct xdg_surface *xdg_surface,
		uint32_t serial) {
	struct novi_files *s = data;
	xdg_surface_ack_configure(xdg_surface, serial);
	s->configured = true;
	surface_draw_frame(s);
}

static const struct xdg_surface_listener xdg_surface_listener_impl = {
	.configure = xdg_surface_configure,
};

static void toplevel_configure(void *data, struct xdg_toplevel *toplevel,
		int32_t width, int32_t height, struct wl_array *states) {
	struct novi_files *s = data;
	if (width > 0 && height > 0) {
		s->width = (uint32_t)width;
		s->height = (uint32_t)height;
		scroll_to_sel(s);
	}
}

static void toplevel_close(void *data, struct xdg_toplevel *toplevel) {
	struct novi_files *s = data;
	s->running = false;
}

static const struct xdg_toplevel_listener toplevel_listener = {
	.configure = toplevel_configure,
	.close = toplevel_close,
};

static void registry_global(void *data, struct wl_registry *registry,
		uint32_t name, const char *interface, uint32_t version) {
	(void)version;
	struct novi_files *s = data;
	if (strcmp(interface, wl_compositor_interface.name) == 0) {
		s->compositor = wl_registry_bind(registry, name,
			&wl_compositor_interface, 4);
	} else if (strcmp(interface, wl_shm_interface.name) == 0) {
		s->shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
	} else if (strcmp(interface, wl_seat_interface.name) == 0) {
		s->seat = wl_registry_bind(registry, name, &wl_seat_interface, 5);
		wl_seat_add_listener(s->seat, &seat_listener, s);
	} else if (strcmp(interface, xdg_wm_base_interface.name) == 0) {
		s->wm_base = wl_registry_bind(registry, name,
			&xdg_wm_base_interface, 1);
		xdg_wm_base_add_listener(s->wm_base, &wm_base_listener, s);
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
	struct novi_files s = {0};
	s.running = true;
	s.width = WINDOW_WIDTH;
	s.height = WINDOW_HEIGHT;

	if (argc > 2) {
		fprintf(stderr, "usage: novi-files [DIRECTORY]\n");
		return 2;
	}
	const char *start = argc == 2 ? argv[1] : getenv("HOME");
	if (start == NULL || start[0] == '\0') {
		start = "/";
	}
	if (realpath(start, s.cwd) == NULL) {
		snprintf(s.cwd, sizeof(s.cwd), "/");
	}
	read_dir(&s);

	s.display = wl_display_connect(NULL);
	if (s.display == NULL) {
		fprintf(stderr, "novi-files: failed to connect to Wayland display "
			"(is WAYLAND_DISPLAY set?)\n");
		return 1;
	}
	s.xkb_context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
	s.registry = wl_display_get_registry(s.display);
	wl_registry_add_listener(s.registry, &registry_listener, &s);
	wl_display_roundtrip(s.display);

	if (s.compositor == NULL || s.shm == NULL || s.wm_base == NULL) {
		fprintf(stderr, "novi-files: compositor is missing a required global "
			"(wl_compositor/wl_shm/xdg_wm_base)\n");
		return 1;
	}

	s.font = novi_text_load_font("JetBrains Mono:size=14");
	s.font_small = novi_text_load_font("JetBrains Mono:size=12");
	if (s.font == NULL || s.font_small == NULL) {
		fprintf(stderr, "novi-files: failed to load JetBrains Mono\n");
		return 1;
	}

	s.surface = wl_compositor_create_surface(s.compositor);
	s.xdg_surface = xdg_wm_base_get_xdg_surface(s.wm_base, s.surface);
	xdg_surface_add_listener(s.xdg_surface, &xdg_surface_listener_impl, &s);
	s.xdg_toplevel = xdg_surface_get_toplevel(s.xdg_surface);
	xdg_toplevel_add_listener(s.xdg_toplevel, &toplevel_listener, &s);
	xdg_toplevel_set_title(s.xdg_toplevel, "Files");
	xdg_toplevel_set_app_id(s.xdg_toplevel, "novi-files");

	wl_surface_commit(s.surface);

	while (s.running && wl_display_dispatch(s.display) != -1) {
		/* Reap any editor we launched, so a long-lived Files window
		 * does not accumulate zombies. WNOHANG in the loop rather than
		 * a SIGCHLD handler: there is nothing to do with the status,
		 * and a handler would be a second thing touching state the
		 * event loop owns. */
		while (waitpid(-1, NULL, WNOHANG) > 0) {
			;
		}
	}

	free(s.entries);
	if (s.xkb_state != NULL) {
		xkb_state_unref(s.xkb_state);
	}
	if (s.xkb_keymap != NULL) {
		xkb_keymap_unref(s.xkb_keymap);
	}
	if (s.xkb_context != NULL) {
		xkb_context_unref(s.xkb_context);
	}
	wl_display_disconnect(s.display);
	return 0;
}
