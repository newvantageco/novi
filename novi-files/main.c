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

/* A prompt takes over the status bar and the keyboard until it is
 * answered. There is exactly one at a time and it is never nested. */
enum prompt_kind {
	PROMPT_NONE = 0,
	PROMPT_DELETE,   /* y/n */
	PROMPT_RENAME,   /* text */
	PROMPT_MKDIR,    /* text */
};

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

	/* The one modal thing this program has. See the comment above
	 * prompt_open(). */
	enum prompt_kind prompt;
	char prompt_target[NAME_MAX_LEN + 1];  /* what the prompt acts on */
	char prompt_text[NAME_MAX_LEN + 1];    /* what has been typed */
	int prompt_len;

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
	/* Cut the last component off rather than appending "/..": the
	 * append can only ever get longer, and at a PATH_MAX cwd it
	 * truncates -- which does not fail, it just silently names a
	 * different directory to go to. Cutting can only get shorter.
	 * (This is also the -Wformat-truncation the build had been
	 * printing, correctly, and which had been read as noise.) */
	char parent[PATH_MAX];
	snprintf(parent, sizeof(parent), "%s", s->cwd);
	char *cut = strrchr(parent, '/');
	if (cut == parent) {
		parent[1] = '\0';        /* "/foo" -> "/" */
	} else if (cut != NULL) {
		*cut = '\0';
	}
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

/* Dispatch. This was a single target (the editor) until novi-view
 * existed; now there are two, so there is a table.
 *
 * By extension, not by content. Sniffing the file's magic bytes would
 * be more correct and is what novi-view itself does -- but that means
 * opening and reading every file just to draw a list, and the list is
 * drawn far more often than anything is opened. The cost of being
 * wrong is bounded and cheap: novi-view decodes before it opens a
 * window, so a .png that is not one prints a line and exits rather
 * than flashing up an empty window. The editor is the fallback for
 * everything else, which is why it had to be written first. */
static const char *EXT_IMAGE[] = {".png", ".bmp", ".ppm", ".pgm", ".pnm", NULL};

static bool has_ext(const char *name, const char *const *exts) {
	const char *dot = strrchr(name, '.');
	if (dot == NULL) {
		return false;
	}
	for (int i = 0; exts[i] != NULL; i++) {
		if (strcasecmp(dot, exts[i]) == 0) {
			return true;
		}
	}
	return false;
}

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
	const char *app = has_ext(e->name, EXT_IMAGE) ? "novi-view" : "novi-edit";
	if (pid == 0) {
		/* Its own session, so it outlives this window being closed --
		 * the same reasoning novi-shell's spawn() documents. */
		setsid();
		execlp(app, app, full, (char *)NULL);
		_exit(127);
	}
	set_status(s, false, "opened %s in %s", e->name, app);
}

/* ── File operations ───────────────────────────────────────────── */

/* Defined with the rest of the view code below; an operation has to put
 * the cursor somewhere sensible when it finishes. */
static void scroll_to_sel(struct novi_files *s);


/* This program can now destroy things, so what it will and will not do
 * is worth stating plainly:
 *
 *   - It deletes a file, and it deletes an EMPTY directory. It refuses
 *     a directory with anything in it and says so. There is no trash on
 *     this system and no undo in this program, so a recursive delete
 *     behind a single keypress is one mis-aimed cursor away from
 *     unrecoverable -- and a terminal is one keystroke away for anyone
 *     who means it. Recursive delete needs a confirmation that shows
 *     what is about to go, which is real work and is not this change.
 *   - It renames within the current directory only, and refuses a name
 *     that already exists rather than silently replacing it -- which is
 *     what a bare rename(2) would do.
 *   - Every one of them asks first, or types first. Nothing here
 *     happens on a single keypress.
 *
 * Same argument as novi-gpt writing exactly one partition layout: a
 * tool that can express every operation is a tool that can express the
 * wrong one.
 */

static bool child_path(struct novi_files *s, const char *name,
		char *out, size_t outlen) {
	int n = snprintf(out, outlen, "%s/%s", s->cwd, name);
	if (n < 0 || (size_t)n >= outlen) {
		set_status(s, true, "path too long");
		return false;
	}
	return true;
}

/* A name typed into a prompt names something in THIS directory and
 * nothing else -- no traversal, no re-pointing at the parent. */
static bool name_is_sane(struct novi_files *s, const char *n) {
	if (n[0] == '\0') {
		set_status(s, true, "no name given");
		return false;
	}
	if (strchr(n, '/') != NULL) {
		set_status(s, true, "a name cannot contain '/'");
		return false;
	}
	if (strcmp(n, ".") == 0 || strcmp(n, "..") == 0) {
		set_status(s, true, "'%s' is not a name", n);
		return false;
	}
	return true;
}

/* Re-read the directory and put the cursor back on `name` if it is
 * still there, else on `fallback`. read_dir() resets the selection to
 * the top, which is right when you navigate somewhere and wrong after
 * you rename something: the thing you just acted on is where you were
 * looking. */
static void reload_selecting(struct novi_files *s, const char *name, int fallback) {
	read_dir(s);
	int want = -1;
	if (name != NULL) {
		for (int i = 0; i < s->nentries; i++) {
			if (strcmp(s->entries[i].name, name) == 0) {
				want = i;
				break;
			}
		}
	}
	if (want < 0) {
		want = fallback;
	}
	if (want >= s->nentries) {
		want = s->nentries - 1;
	}
	s->sel = want > 0 ? want : 0;
	scroll_to_sel(s);
}

static void do_delete(struct novi_files *s, const char *name) {
	char full[PATH_MAX];
	if (!child_path(s, name, full, sizeof(full))) {
		return;
	}

	/* lstat, not stat: a symlink pointing at a directory is a link, and
	 * deleting it means unlink(2) on the link -- never rmdir(2) on
	 * whatever it happens to point at. */
	struct stat st;
	if (lstat(full, &st) != 0) {
		set_status(s, true, "cannot delete: %s", strerror(errno));
		return;
	}

	int keep = s->sel;
	if (S_ISDIR(st.st_mode)) {
		if (rmdir(full) != 0) {
			if (errno == ENOTEMPTY || errno == EEXIST) {
				set_status(s, true, "'%s' is not empty -- only empty directories are removed here", name);
			} else {
				set_status(s, true, "cannot delete: %s", strerror(errno));
			}
			return;
		}
	} else if (unlink(full) != 0) {
		set_status(s, true, "cannot delete: %s", strerror(errno));
		return;
	}

	reload_selecting(s, NULL, keep);
	set_status(s, false, "deleted %s", name);
}

static void do_rename(struct novi_files *s, const char *from, const char *to) {
	if (!name_is_sane(s, to)) {
		return;
	}
	if (strcmp(from, to) == 0) {
		set_status(s, false, "unchanged");
		return;
	}

	char src[PATH_MAX], dst[PATH_MAX];
	if (!child_path(s, from, src, sizeof(src)) ||
	    !child_path(s, to, dst, sizeof(dst))) {
		return;
	}

	/* rename(2) replaces an existing target without a word. Refuse
	 * instead. This is a check-then-act and something could appear in
	 * the gap; on a single-user file manager that race is not worth
	 * renameat2(RENAME_NOREPLACE), which is Linux-specific and which
	 * musl only wraps on new-enough kernels. Losing a file to a silent
	 * clobber is the failure that actually happens. */
	struct stat st;
	if (lstat(dst, &st) == 0) {
		set_status(s, true, "'%s' already exists", to);
		return;
	}

	if (rename(src, dst) != 0) {
		set_status(s, true, "cannot rename: %s", strerror(errno));
		return;
	}
	reload_selecting(s, to, s->sel);
	set_status(s, false, "renamed to %s", to);
}

static void do_mkdir(struct novi_files *s, const char *name) {
	if (!name_is_sane(s, name)) {
		return;
	}
	char full[PATH_MAX];
	if (!child_path(s, name, full, sizeof(full))) {
		return;
	}
	/* 0777 and let the process umask decide, the way mkdir(1) does --
	 * hardcoding 0755 here would ignore a umask someone set on purpose. */
	if (mkdir(full, 0777) != 0) {
		set_status(s, true, "cannot create: %s", strerror(errno));
		return;
	}
	reload_selecting(s, name, s->sel);
	set_status(s, false, "created %s", name);
}

/* ── Prompts ───────────────────────────────────────────────────── */

static void prompt_close(struct novi_files *s) {
	s->prompt = PROMPT_NONE;
	s->prompt_len = 0;
	s->prompt_text[0] = '\0';
	s->prompt_target[0] = '\0';
}

static void prompt_open(struct novi_files *s, enum prompt_kind kind) {
	if (kind != PROMPT_MKDIR && s->nentries == 0) {
		set_status(s, true, "nothing selected");
		return;
	}
	prompt_close(s);
	s->status[0] = '\0';
	s->prompt = kind;

	/* The target is captured now, by name. The prompt then acts on that
	 * name whatever the selection does in the meantime -- a confirmation
	 * that reads the selection back at commit time is a confirmation for
	 * the wrong file waiting to happen. */
	if (kind != PROMPT_MKDIR) {
		snprintf(s->prompt_target, sizeof(s->prompt_target), "%s",
			s->entries[s->sel].name);
	}
	if (kind == PROMPT_RENAME) {
		snprintf(s->prompt_text, sizeof(s->prompt_text), "%s", s->prompt_target);
		s->prompt_len = (int)strlen(s->prompt_text);
	}
}

/* The prompt's own text, for the status bar. */
static void prompt_line(const struct novi_files *s, char *out, size_t outlen) {
	switch (s->prompt) {
	case PROMPT_DELETE:
		snprintf(out, outlen, "delete '%s'?   y / n", s->prompt_target);
		break;
	case PROMPT_RENAME:
		snprintf(out, outlen, "rename '%s' to: %s", s->prompt_target, s->prompt_text);
		break;
	case PROMPT_MKDIR:
		snprintf(out, outlen, "new folder: %s", s->prompt_text);
		break;
	case PROMPT_NONE:
		out[0] = '\0';
		break;
	}
}

/* Backspace one whole UTF-8 character, not one byte -- a byte would
 * leave a truncated sequence in the name being typed. */
static void prompt_backspace(struct novi_files *s) {
	int i = s->prompt_len;
	while (i > 0) {
		i--;
		if (((unsigned char)s->prompt_text[i] & 0xc0) != 0x80) {
			break;
		}
	}
	s->prompt_len = i;
	s->prompt_text[i] = '\0';
}

static void prompt_insert(struct novi_files *s, const char *utf8) {
	size_t add = strlen(utf8);
	if ((size_t)s->prompt_len + add >= sizeof(s->prompt_text)) {
		return;
	}
	memcpy(s->prompt_text + s->prompt_len, utf8, add + 1);
	s->prompt_len += (int)add;
}

static void prompt_commit(struct novi_files *s) {
	enum prompt_kind kind = s->prompt;
	char target[NAME_MAX_LEN + 1], text[NAME_MAX_LEN + 1];
	snprintf(target, sizeof(target), "%s", s->prompt_target);
	snprintf(text, sizeof(text), "%s", s->prompt_text);
	prompt_close(s);

	switch (kind) {
	case PROMPT_DELETE: do_delete(s, target);        break;
	case PROMPT_RENAME: do_rename(s, target, text);  break;
	case PROMPT_MKDIR:  do_mkdir(s, text);           break;
	case PROMPT_NONE:                                break;
	}
}

/* Returns true if the prompt consumed the key. */
static bool prompt_key(struct novi_files *s, xkb_keysym_t sym, const char *text) {
	if (s->prompt == PROMPT_NONE) {
		return false;
	}
	if (sym == XKB_KEY_Escape) {
		prompt_close(s);
		set_status(s, false, "cancelled");
		return true;
	}

	if (s->prompt == PROMPT_DELETE) {
		/* Deliberately not Enter: Enter is the key people press to make
		 * a dialog go away, and this one destroys something. Say yes on
		 * purpose or say nothing at all. */
		if (sym == XKB_KEY_y || sym == XKB_KEY_Y) {
			prompt_commit(s);
		} else if (sym == XKB_KEY_n || sym == XKB_KEY_N) {
			prompt_close(s);
			set_status(s, false, "cancelled");
		}
		return true;
	}

	switch (sym) {
	case XKB_KEY_Return: case XKB_KEY_KP_Enter:
		prompt_commit(s);
		return true;
	case XKB_KEY_BackSpace:
		prompt_backspace(s);
		return true;
	default:
		break;
	}
	if (text != NULL) {
		prompt_insert(s, text);
	}
	return true;
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

		/* The icon answers the same question Enter does, from the
		 * same has_ext() -- a row that shows the image glyph opens in
		 * novi-view, one that shows the file glyph opens in the
		 * editor. Two answers derived separately would eventually
		 * disagree, and a file manager whose icons lie about what
		 * Enter will do is worse than one with no icons.
		 *
		 * (Until novi-view existed this drew ICON_PENCIL for every
		 * plain file, because the generated set had no document glyph
		 * and "this opens in the editor" was true of everything. It
		 * stopped being true the moment a second app could be
		 * launched; `file` and `image` went through tools/svg2icon in
		 * the same change.) */
		enum novi_icon_id icon = ICON_FILE;
		if (e->is_dir) {
			icon = ICON_FOLDER;
		} else if (has_ext(e->name, EXT_IMAGE)) {
			icon = ICON_IMAGE;
		}
		draw_icon(px, stride_px, w, h, PAD, y + (ROW_H - ICON_SIZE) / 2,
			icon, e->is_dir ? ICON_DIR_COLOR : ICON_FILE_COLOR);

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

	if (s->prompt != PROMPT_NONE) {
		/* A prompt takes the whole bar, from the left, with a caret
		 * where the next character lands. It is the only modal state
		 * this program has, so it should be impossible to miss. */
		char line[PATH_MAX + 64];
		prompt_line(s, line, sizeof(line));
		novi_text_draw(dest, s->font_small, PAD, sbase, line,
			s->prompt == PROMPT_DELETE ? ERROR_PIX : NAME_PIX);
		if (s->prompt != PROMPT_DELETE) {
			int cw = novi_text_width(s->font_small, line);
			draw_rect(px, stride_px, w, h, PAD + cw + 1,
				sy + (STATUS_H - s->font_small->height) / 2,
				2, s->font_small->height, SEL_BAR);
		}
	} else {
		char left[128];
		snprintf(left, sizeof(left), "%d item%s%s", s->nentries,
			s->nentries == 1 ? "" : "s", s->show_hidden ? "   (hidden shown)" : "");
		novi_text_draw(dest, s->font_small, PAD, sbase, left, STATUS_PIX);

		char right[sizeof(s->status) + 96];
		snprintf(right, sizeof(right), "%s", s->status[0] ? s->status :
			"Enter open  Bksp up  F2 rename  Del delete  ^N folder  ^H hidden  ^Q quit");
		int rw = novi_text_width(s->font_small, right);
		novi_text_draw(dest, s->font_small, (int)w - PAD - rw, sbase, right,
			s->status_is_error ? ERROR_PIX : STATUS_PIX);
	}

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

static void handle_key(struct novi_files *s, xkb_keysym_t sym, bool ctrl,
		const char *text) {
	/* An open prompt owns the keyboard. Nothing below runs while one is
	 * up, so Delete cannot fire a second confirmation on top of the
	 * first and Backspace cannot navigate out of the directory being
	 * asked about. */
	if (prompt_key(s, sym, ctrl ? NULL : text)) {
		return;
	}

	if (ctrl) {
		switch (sym) {
		case XKB_KEY_q: case XKB_KEY_Q:
			s->running = false;
			return;
		case XKB_KEY_n: case XKB_KEY_N:
			prompt_open(s, PROMPT_MKDIR);
			return;
		case XKB_KEY_d: case XKB_KEY_D:
			prompt_open(s, PROMPT_DELETE);
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
	/* The two bindings every file manager has had for thirty years.
	 * ^D and ^N exist alongside them for keyboards and remote consoles
	 * where F2 and Delete do not survive the trip. */
	case XKB_KEY_F2:
		prompt_open(s, PROMPT_RENAME);
		break;
	case XKB_KEY_Delete:
		prompt_open(s, PROMPT_DELETE);
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
	xkb_keycode_t code = key + 8;
	xkb_keysym_t sym = xkb_state_key_get_one_sym(s->xkb_state, code);
	bool ctrl = xkb_state_mod_name_is_active(s->xkb_state, XKB_MOD_NAME_CTRL,
		XKB_STATE_MODS_EFFECTIVE) > 0;

	/* The typed character, for a prompt that is taking a name. From
	 * xkb_state_key_get_utf8() and nowhere else: it applies the keymap,
	 * the modifiers and any compose state, so a keysym-to-ASCII table
	 * would get every non-US layout wrong -- the same reason novi-edit
	 * reads its text here. */
	char utf8[16];
	int n = xkb_state_key_get_utf8(s->xkb_state, code, utf8, sizeof(utf8));
	bool printable = n > 0 && (unsigned char)utf8[0] >= 0x20 && utf8[0] != 0x7f;

	handle_key(s, sym, ctrl, printable ? utf8 : NULL);
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
