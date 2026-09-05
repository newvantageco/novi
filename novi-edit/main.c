/* ============================================================
 * novi-edit — a text editor for the Novi desktop
 *
 * The desktop had six GUI programs and none of them could open a file.
 * You could take a screenshot and not look at it; you could reach
 * /etc/novi/system.conf from Settings' System panel but not from
 * anywhere else, and every other file on the machine was reachable
 * only through `vi` in a terminal.
 *
 * This is the first of the first-party applications, and it is
 * deliberately the *first* one because it opens anything. A file
 * manager needs somewhere to send a file it cannot preview; an image
 * viewer handles images and nothing else; a text editor is the
 * fallback for every file on the system, so it is the one that makes
 * the others worth writing.
 *
 * Written as a raw xdg-shell client, drawing with pixman and fcft,
 * exactly like novi-settings and for the same reason: there is no GUI
 * toolkit on this system. That is not a gap to be embarrassed about
 * here -- it is why the desktop looks like one piece of software
 * instead of six programs from four different decades.
 *
 * What this is NOT, stated so nobody has to discover it:
 *
 *   - No undo. The single most-missed feature, and it wants a proper
 *     edit-history structure rather than a bolted-on last-action
 *     stash. Next.
 *   - No selection, no clipboard, no search-and-replace.
 *   - No horizontal scrolling. A line wider than the window is
 *     clipped at the right edge (pixman clips the composite), and the
 *     cursor can still move into the clipped region -- you just
 *     cannot see it there.
 *   - No syntax highlighting, no line wrapping, no tabs-vs-spaces
 *     policy (a Tab inserts a literal tab byte and renders as one
 *     glyph-width, which is wrong-looking for indented code and fine
 *     for the config files this exists to edit).
 *
 * It saves atomically -- write a temp file beside the target, fsync,
 * rename -- because an editor that truncates your file and then dies
 * is worse than no editor.
 * ============================================================ */

#define _GNU_SOURCE
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
#include <time.h>
#include <unistd.h>

#include <pixman.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>

#include "text.h"
#include "xdg-shell-client-protocol.h"

#define WINDOW_WIDTH  900
#define WINDOW_HEIGHT 620

/* Chrome. The gutter holds line numbers; the status bar is one line of
 * text at the bottom with the filename, position and modified flag. */
#define PAD           12
#define GUTTER_W      64
#define STATUS_H      28

/* Hard limits, chosen so a runaway file cannot exhaust memory on a
 * machine with no swap. They are generous for what this is for and
 * they are *reported* rather than silently truncating: a file over the
 * limit opens read-only with the reason in the status bar, which is
 * the honest failure. */
#define MAX_LINES     200000
#define MAX_LINE_LEN  8192

/* Palette: the panel's, so the desktop reads as one system. */
#define BG_COLOR        0xff16161eu
#define GUTTER_BG_COLOR 0xff1b1b26u
#define STATUS_BG_COLOR 0xff232430u
#define CURSOR_COLOR    0xff2dd4bfu
#define CURLINE_COLOR   0xff1e1e2au

static const pixman_color_t TEXT_PIX      = {0xc8c8, 0xcccc, 0xd8d8, 0xffff};
static const pixman_color_t GUTTER_PIX    = {0x5555, 0x5858, 0x6a6a, 0xffff};
static const pixman_color_t GUTTER_CUR_PIX= {0x9a9a, 0xa0a0, 0xb4b4, 0xffff};
static const pixman_color_t STATUS_PIX    = {0xa3a3, 0xa7a7, 0xb7b7, 0xffff};
static const pixman_color_t MODIFIED_PIX  = {0xf0f0, 0xc0c0, 0x6a6a, 0xffff};
static const pixman_color_t ERROR_PIX     = {0xf0f0, 0x7a7a, 0x7a7a, 0xffff};

/* One whole-document state, held so undo can put it back. */
struct snapshot {
	char **lines;
	int nlines;
	int cy, cx;
	bool modified;
	size_t bytes;   /* what this costs, for the history budget */
};

struct novi_edit {
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

	/* The document. lines[i] is a NUL-terminated, malloc'd string with
	 * no trailing newline; the newlines are implied by the array and
	 * re-added on save. A completely empty file is one empty line, not
	 * zero lines, so the cursor always has somewhere to be. */
	char **lines;
	int nlines;
	int lines_cap;

	int cy;        /* cursor line */
	int cx;        /* cursor column, a BYTE offset into lines[cy] */
	int top;       /* first visible line */
	bool modified;
	bool read_only;

	/* Undo/redo. See the block comment above snapshot_capture(). */
	struct snapshot *undo;
	int nundo, undo_cap;
	struct snapshot *redo;
	int nredo, redo_cap;
	size_t history_bytes;
	bool coalescing;   /* an open typing run already has its snapshot */
	bool quit_armed;   /* ^Q pressed once with unsaved changes */

	char path[PATH_MAX];
	char status[256];
	bool status_is_error;
};

/* ── Document ──────────────────────────────────────────────────── */

static void set_status(struct novi_edit *e, bool is_error, const char *fmt, ...)
	__attribute__((format(printf, 3, 4)));

static void set_status(struct novi_edit *e, bool is_error, const char *fmt, ...) {
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(e->status, sizeof(e->status), fmt, ap);
	va_end(ap);
	e->status_is_error = is_error;
}

static bool lines_reserve(struct novi_edit *e, int want) {
	if (want <= e->lines_cap) {
		return true;
	}
	int cap = e->lines_cap ? e->lines_cap * 2 : 256;
	while (cap < want) {
		cap *= 2;
	}
	char **grown = realloc(e->lines, (size_t)cap * sizeof(*grown));
	if (grown == NULL) {
		return false;
	}
	e->lines = grown;
	e->lines_cap = cap;
	return true;
}

static bool line_insert(struct novi_edit *e, int at, char *text) {
	if (e->nlines >= MAX_LINES || !lines_reserve(e, e->nlines + 1)) {
		return false;
	}
	memmove(&e->lines[at + 1], &e->lines[at],
		(size_t)(e->nlines - at) * sizeof(*e->lines));
	e->lines[at] = text;
	e->nlines++;
	return true;
}

static void line_remove(struct novi_edit *e, int at) {
	free(e->lines[at]);
	memmove(&e->lines[at], &e->lines[at + 1],
		(size_t)(e->nlines - at - 1) * sizeof(*e->lines));
	e->nlines--;
}

static void doc_free(struct novi_edit *e) {
	for (int i = 0; i < e->nlines; i++) {
		free(e->lines[i]);
	}
	free(e->lines);
	e->lines = NULL;
	e->nlines = 0;
	e->lines_cap = 0;
}

/* An empty document is one empty line. */
static bool doc_init_empty(struct novi_edit *e) {
	char *first = calloc(1, 1);
	return first != NULL && line_insert(e, 0, first);
}

static bool doc_load(struct novi_edit *e, const char *path) {
	FILE *f = fopen(path, "r");
	if (f == NULL) {
		/* A path that does not exist is a new file, not an error --
		 * the same thing every editor does, and the reason `novi-edit
		 * notes.txt` is a useful thing to type. A path that exists and
		 * cannot be read IS an error and says so. */
		if (errno == ENOENT) {
			set_status(e, false, "new file");
			return doc_init_empty(e);
		}
		set_status(e, true, "cannot open: %s", strerror(errno));
		e->read_only = true;
		return doc_init_empty(e);
	}

	char buf[MAX_LINE_LEN + 2];
	bool truncated = false;
	while (fgets(buf, (int)sizeof(buf), f) != NULL) {
		size_t n = strlen(buf);
		if (n > 0 && buf[n - 1] == '\n') {
			buf[--n] = '\0';
		} else if (n == MAX_LINE_LEN + 1) {
			truncated = true;
		}
		if (e->nlines >= MAX_LINES) {
			truncated = true;
			break;
		}
		char *copy = strdup(buf);
		if (copy == NULL || !line_insert(e, e->nlines, copy)) {
			free(copy);
			truncated = true;
			break;
		}
	}
	fclose(f);

	if (e->nlines == 0 && !doc_init_empty(e)) {
		return false;
	}
	if (truncated) {
		/* Read-only rather than silently editing a truncated copy:
		 * saving would destroy the part that did not fit. */
		e->read_only = true;
		set_status(e, true, "file too large -- opened READ-ONLY");
	}
	return true;
}

/* Atomic save: temp file beside the target, fsync, rename. An editor
 * that truncates your file and then dies is worse than no editor, and
 * open(O_TRUNC) followed by a failed write is exactly that. */
static bool doc_save(struct novi_edit *e) {
	if (e->read_only) {
		set_status(e, true, "read-only");
		return false;
	}
	if (e->path[0] == '\0') {
		set_status(e, true, "no filename");
		return false;
	}

	char tmp[PATH_MAX];
	int n = snprintf(tmp, sizeof(tmp), "%s.novi-edit.tmp", e->path);
	if (n < 0 || (size_t)n >= sizeof(tmp)) {
		set_status(e, true, "path too long to save safely");
		return false;
	}

	/* Preserve the original's mode where there is one. A config file
	 * at 0600 must not come back 0644 because it was edited. */
	mode_t mode = 0644;
	struct stat st;
	if (stat(e->path, &st) == 0) {
		mode = st.st_mode & 07777;
	}

	int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, mode);
	if (fd < 0) {
		set_status(e, true, "cannot write: %s", strerror(errno));
		return false;
	}
	FILE *f = fdopen(fd, "w");
	if (f == NULL) {
		close(fd);
		unlink(tmp);
		set_status(e, true, "cannot write: %s", strerror(errno));
		return false;
	}
	for (int i = 0; i < e->nlines; i++) {
		if (fputs(e->lines[i], f) == EOF || fputc('\n', f) == EOF) {
			fclose(f);
			unlink(tmp);
			set_status(e, true, "write failed: %s", strerror(errno));
			return false;
		}
	}
	if (fflush(f) != 0 || fsync(fileno(f)) != 0) {
		fclose(f);
		unlink(tmp);
		set_status(e, true, "flush failed: %s", strerror(errno));
		return false;
	}
	fclose(f);

	if (rename(tmp, e->path) != 0) {
		unlink(tmp);
		set_status(e, true, "rename failed: %s", strerror(errno));
		return false;
	}
	e->modified = false;
	e->coalescing = false;

	/* Every state in the history now differs from what is on disk, so
	 * undoing back to one of them leaves an unsaved buffer -- including
	 * the state the file was loaded in, which is no longer what the
	 * file contains. Without this the asterisk vanishes on an undo past
	 * a save and the editor quietly says "nothing to lose here". */
	for (int i = 0; i < e->nundo; i++) {
		e->undo[i].modified = true;
	}
	for (int i = 0; i < e->nredo; i++) {
		e->redo[i].modified = true;
	}

	set_status(e, false, "saved %d line%s", e->nlines, e->nlines == 1 ? "" : "s");
	return true;
}

/* ── Cursor movement ───────────────────────────────────────────── */

/* UTF-8: a continuation byte is 10xxxxxx. Moving by bytes would land
 * the cursor in the middle of a multi-byte character and the next
 * insert would corrupt it, so left/right skip whole characters. This
 * is the same class of bug common/text.c already had once, where a
 * byte-per-codepoint loop mojibake'd every non-ASCII glyph. */
static bool is_utf8_cont(unsigned char c) {
	return (c & 0xC0) == 0x80;
}

static int prev_char(const char *s, int i) {
	if (i <= 0) {
		return 0;
	}
	i--;
	while (i > 0 && is_utf8_cont((unsigned char)s[i])) {
		i--;
	}
	return i;
}

static int next_char(const char *s, int i) {
	int len = (int)strlen(s);
	if (i >= len) {
		return len;
	}
	i++;
	while (i < len && is_utf8_cont((unsigned char)s[i])) {
		i++;
	}
	return i;
}

static void clamp_cx(struct novi_edit *e) {
	int len = (int)strlen(e->lines[e->cy]);
	if (e->cx > len) {
		e->cx = len;
	}
	/* If a vertical move landed us mid-character, step back to the
	 * start of it. */
	while (e->cx > 0 && is_utf8_cont((unsigned char)e->lines[e->cy][e->cx])) {
		e->cx--;
	}
}

static int visible_rows(const struct novi_edit *e) {
	int h = (int)e->height - STATUS_H - PAD;
	int lh = e->font->height;
	return lh > 0 ? h / lh : 1;
}

static void scroll_to_cursor(struct novi_edit *e) {
	int rows = visible_rows(e);
	if (rows < 1) {
		rows = 1;
	}
	if (e->cy < e->top) {
		e->top = e->cy;
	} else if (e->cy >= e->top + rows) {
		e->top = e->cy - rows + 1;
	}
	if (e->top < 0) {
		e->top = 0;
	}
}

/* ── Undo ──────────────────────────────────────────────────────── */

/* Whole-document snapshots, not an operation log.
 *
 * An op log (record each insert/delete and apply its inverse) is the
 * memory-efficient answer and the one a big editor uses. It is also
 * four hand-written inverse operations that must each be exactly
 * right, and the failure mode when one is not is silent corruption of
 * a file somebody asked this program to look after. A snapshot puts
 * back precisely what was there, by construction rather than by
 * argument, and this is a small editor for config files.
 *
 * What that costs is bounded on purpose rather than hoped about: the
 * document may be 200000 lines, so the history carries a byte budget
 * and drops its OLDEST entries when it is exceeded. Editing a huge
 * file gives you fewer undo steps; it never gives you an editor that
 * exhausts memory keeping them.
 *
 * Consecutive typing is one step, not one per keystroke: `coalescing`
 * says the current run already pushed its snapshot, and anything that
 * is not more typing -- a cursor move, a newline, a delete, a save --
 * closes the run.
 */
#define HISTORY_MAX_BYTES (8u * 1024u * 1024u)
#define HISTORY_MAX_STEPS 256

static void snapshot_free(struct snapshot *s) {
	for (int i = 0; i < s->nlines; i++) {
		free(s->lines[i]);
	}
	free(s->lines);
	s->lines = NULL;
	s->nlines = 0;
	s->bytes = 0;
}

static bool snapshot_capture(const struct novi_edit *e, struct snapshot *out) {
	int n = e->nlines > 0 ? e->nlines : 1;
	out->lines = calloc((size_t)n, sizeof(*out->lines));
	if (out->lines == NULL) {
		return false;
	}
	out->nlines = 0;
	out->bytes = (size_t)n * sizeof(*out->lines);
	for (int i = 0; i < e->nlines; i++) {
		out->lines[i] = strdup(e->lines[i]);
		if (out->lines[i] == NULL) {
			out->nlines = i;   /* so snapshot_free frees only what exists */
			snapshot_free(out);
			return false;
		}
		out->bytes += strlen(e->lines[i]) + 1;
	}
	out->nlines = e->nlines;
	out->cy = e->cy;
	out->cx = e->cx;
	out->modified = e->modified;
	return true;
}

static bool stack_push(struct snapshot **arr, int *n, int *cap,
		const struct snapshot *s) {
	if (*n == *cap) {
		int grown = *cap ? *cap * 2 : 16;
		struct snapshot *p = realloc(*arr, (size_t)grown * sizeof(*p));
		if (p == NULL) {
			return false;
		}
		*arr = p;
		*cap = grown;
	}
	(*arr)[(*n)++] = *s;
	return true;
}

/* Drop the oldest entries until the whole history fits the budget.
 * Undo first: losing the far past costs less than losing a redo the
 * user can still see themselves needing. */
static void history_trim(struct novi_edit *e) {
	while ((e->history_bytes > HISTORY_MAX_BYTES || e->nundo > HISTORY_MAX_STEPS)
			&& e->nundo > 0) {
		e->history_bytes -= e->undo[0].bytes;
		snapshot_free(&e->undo[0]);
		memmove(&e->undo[0], &e->undo[1],
			(size_t)(--e->nundo) * sizeof(*e->undo));
	}
	while (e->history_bytes > HISTORY_MAX_BYTES && e->nredo > 0) {
		e->history_bytes -= e->redo[0].bytes;
		snapshot_free(&e->redo[0]);
		memmove(&e->redo[0], &e->redo[1],
			(size_t)(--e->nredo) * sizeof(*e->redo));
	}
}

static void redo_clear(struct novi_edit *e) {
	for (int i = 0; i < e->nredo; i++) {
		e->history_bytes -= e->redo[i].bytes;
		snapshot_free(&e->redo[i]);
	}
	e->nredo = 0;
}

static void history_free(struct novi_edit *e) {
	for (int i = 0; i < e->nundo; i++) {
		snapshot_free(&e->undo[i]);
	}
	for (int i = 0; i < e->nredo; i++) {
		snapshot_free(&e->redo[i]);
	}
	free(e->undo);
	free(e->redo);
	e->undo = NULL; e->redo = NULL;
	e->nundo = e->nredo = e->undo_cap = e->redo_cap = 0;
	e->history_bytes = 0;
}

/* Record the state an edit is about to replace. Call it AFTER the
 * cheap guards that can refuse the edit outright and BEFORE the first
 * byte changes; on a later failure, undo_discard() takes it back off
 * so undo never offers a step that changes nothing. */
static void undo_push(struct novi_edit *e, bool coalescable) {
	redo_clear(e);
	if (coalescable && e->coalescing && e->nundo > 0) {
		return;   /* this typing run's snapshot is already on the stack */
	}
	struct snapshot s;
	if (!snapshot_capture(e, &s)) {
		/* Losing the ability to undo is bad; refusing the edit is
		 * worse, and silently pretending is worst. Say so and let the
		 * edit through. */
		set_status(e, true, "out of memory -- this edit cannot be undone");
		e->coalescing = false;
		return;
	}
	if (!stack_push(&e->undo, &e->nundo, &e->undo_cap, &s)) {
		snapshot_free(&s);
		set_status(e, true, "out of memory -- this edit cannot be undone");
		e->coalescing = false;
		return;
	}
	e->history_bytes += s.bytes;
	e->coalescing = coalescable;
	history_trim(e);
}

static void undo_discard(struct novi_edit *e) {
	if (e->nundo == 0) {
		return;
	}
	e->history_bytes -= e->undo[e->nundo - 1].bytes;
	snapshot_free(&e->undo[--e->nundo]);
	e->coalescing = false;
}

/* Swap the live document with the top of one stack, pushing what was
 * live onto the other. Undo and redo are the same operation in
 * opposite directions, so they are one function. */
static void history_step(struct novi_edit *e, bool forward) {
	struct snapshot **src  = forward ? &e->redo : &e->undo;
	int *nsrc              = forward ? &e->nredo : &e->nundo;
	struct snapshot **dst  = forward ? &e->undo : &e->redo;
	int *ndst              = forward ? &e->nundo : &e->nredo;
	int *dstcap            = forward ? &e->undo_cap : &e->redo_cap;

	e->coalescing = false;
	if (*nsrc == 0) {
		set_status(e, false, forward ? "nothing to redo" : "nothing to undo");
		return;
	}

	struct snapshot live;
	if (!snapshot_capture(e, &live)) {
		set_status(e, true, "out of memory");
		return;
	}
	if (!stack_push(dst, ndst, dstcap, &live)) {
		snapshot_free(&live);
		set_status(e, true, "out of memory");
		return;
	}
	e->history_bytes += live.bytes;

	struct snapshot want = (*src)[--(*nsrc)];
	e->history_bytes -= want.bytes;

	doc_free(e);
	e->lines     = want.lines;
	e->nlines    = want.nlines;
	e->lines_cap = want.nlines > 0 ? want.nlines : 1;
	e->cy        = want.cy;
	e->cx        = want.cx;
	e->modified  = want.modified;
	/* want.lines now belongs to the document; do not snapshot_free it. */

	scroll_to_cursor(e);
	set_status(e, false, forward ? "redone" : "undone");
	history_trim(e);
}

/* ── Editing ───────────────────────────────────────────────────── */

static void insert_text(struct novi_edit *e, const char *s) {
	if (e->read_only) {
		set_status(e, true, "read-only");
		return;
	}
	size_t add = strlen(s);
	char *line = e->lines[e->cy];
	size_t len = strlen(line);
	if (len + add > MAX_LINE_LEN) {
		set_status(e, true, "line too long");
		return;
	}
	/* Coalescable: a run of typed characters is one undo step. */
	undo_push(e, true);
	char *grown = realloc(line, len + add + 1);
	if (grown == NULL) {
		undo_discard(e);
		set_status(e, true, "out of memory");
		return;
	}
	memmove(grown + e->cx + add, grown + e->cx, len - (size_t)e->cx + 1);
	memcpy(grown + e->cx, s, add);
	e->lines[e->cy] = grown;
	e->cx += (int)add;
	e->modified = true;
}

static void split_line(struct novi_edit *e) {
	if (e->read_only) {
		set_status(e, true, "read-only");
		return;
	}
	undo_push(e, false);
	char *line = e->lines[e->cy];
	char *tail = strdup(line + e->cx);
	if (tail == NULL || !line_insert(e, e->cy + 1, tail)) {
		free(tail);
		undo_discard(e);
		set_status(e, true, "out of memory");
		return;
	}
	line[e->cx] = '\0';
	e->cy++;
	e->cx = 0;
	e->modified = true;
}

/* The mutation with no read-only check and no undo record:
 * delete_forward()'s join case is exactly "backspace at column 0 one
 * line down", and doing that through delete_back() would push a second
 * snapshot for one keypress -- so undo would need two presses to put
 * back one Delete. */
static bool do_delete_back(struct novi_edit *e) {
	if (e->cx > 0) {
		char *line = e->lines[e->cy];
		int start = prev_char(line, e->cx);
		size_t len = strlen(line);
		memmove(line + start, line + e->cx, len - (size_t)e->cx + 1);
		e->cx = start;
		e->modified = true;
	} else if (e->cy > 0) {
		/* Join with the previous line. */
		char *prev = e->lines[e->cy - 1];
		char *cur = e->lines[e->cy];
		size_t plen = strlen(prev), clen = strlen(cur);
		if (plen + clen > MAX_LINE_LEN) {
			set_status(e, true, "joined line would be too long");
			return false;
		}
		char *joined = realloc(prev, plen + clen + 1);
		if (joined == NULL) {
			set_status(e, true, "out of memory");
			return false;
		}
		memcpy(joined + plen, cur, clen + 1);
		e->lines[e->cy - 1] = joined;
		line_remove(e, e->cy);
		e->cy--;
		e->cx = (int)plen;
		e->modified = true;
	}
	return true;
}

static void delete_back(struct novi_edit *e) {
	if (e->read_only) {
		set_status(e, true, "read-only");
		return;
	}
	if (e->cx == 0 && e->cy == 0) {
		return;   /* nothing behind the cursor; do not record a no-op */
	}
	undo_push(e, false);
	if (!do_delete_back(e)) {
		undo_discard(e);
	}
}

static void delete_forward(struct novi_edit *e) {
	if (e->read_only) {
		set_status(e, true, "read-only");
		return;
	}
	char *line = e->lines[e->cy];
	int len = (int)strlen(line);
	if (e->cx >= len && e->cy >= e->nlines - 1) {
		return;   /* end of the document */
	}
	undo_push(e, false);
	if (e->cx < len) {
		int end = next_char(line, e->cx);
		memmove(line + e->cx, line + end, (size_t)(len - end) + 1);
		e->modified = true;
	} else {
		/* Deleting the newline at end-of-line is joining the next line
		 * onto this one -- the same operation as backspace-at-column-0
		 * one line down, so do exactly that rather than write it
		 * twice. */
		int was_cy = e->cy;
		e->cy++;
		e->cx = 0;
		if (!do_delete_back(e)) {
			/* Put the cursor back where the user left it: the refusal
			 * must not move it as a side effect. */
			e->cy = was_cy;
			e->cx = len;
			undo_discard(e);
		}
	}
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

static void render(struct novi_edit *e, uint32_t *px, uint32_t stride_px) {
	uint32_t w = e->width, h = e->height;
	pixman_image_t *dest = pixman_image_create_bits(PIXMAN_x8r8g8b8,
		(int)w, (int)h, px, (int)(stride_px * 4));

	draw_rect(px, stride_px, w, h, 0, 0, (int)w, (int)h, BG_COLOR);
	draw_rect(px, stride_px, w, h, 0, 0, GUTTER_W, (int)h - STATUS_H,
		GUTTER_BG_COLOR);

	int lh = e->font->height;
	int rows = visible_rows(e);
	int text_x = GUTTER_W + PAD;

	for (int r = 0; r < rows; r++) {
		int ln = e->top + r;
		if (ln >= e->nlines) {
			break;
		}
		int baseline = PAD + r * lh + e->font->ascent;
		bool is_cursor_line = (ln == e->cy);

		if (is_cursor_line) {
			draw_rect(px, stride_px, w, h, GUTTER_W, PAD + r * lh,
				(int)w - GUTTER_W, lh, CURLINE_COLOR);
		}

		char num[16];
		snprintf(num, sizeof(num), "%d", ln + 1);
		int nw = novi_text_width(e->font_small, num);
		novi_text_draw(dest, e->font_small, GUTTER_W - PAD - nw,
			baseline, num, is_cursor_line ? GUTTER_CUR_PIX : GUTTER_PIX);

		novi_text_draw(dest, e->font, text_x, baseline, e->lines[ln], TEXT_PIX);

		if (is_cursor_line) {
			/* Cursor x is the rendered width of the text before it --
			 * measured, not computed from a column count, because the
			 * font is not guaranteed monospace at every codepoint even
			 * when it is a monospace family. */
			char save = e->lines[ln][e->cx];
			e->lines[ln][e->cx] = '\0';
			int cw = novi_text_width(e->font, e->lines[ln]);
			e->lines[ln][e->cx] = save;
			draw_rect(px, stride_px, w, h, text_x + cw, PAD + r * lh,
				2, lh, CURSOR_COLOR);
		}
	}

	/* Status bar. */
	int sy = (int)h - STATUS_H;
	draw_rect(px, stride_px, w, h, 0, sy, (int)w, STATUS_H, STATUS_BG_COLOR);
	int sbase = sy + (STATUS_H - e->font_small->height) / 2 + e->font_small->ascent;

	/* Sized for the longest thing that can go in it: a PATH_MAX path
	 * plus both suffixes. snprintf would truncate safely either way,
	 * but a status line is exactly where truncation costs the most --
	 * it is the only channel this program has for telling you why a
	 * save failed. */
	const char *name = e->path[0] ? e->path : "(no file)";
	char left[PATH_MAX + 32];
	snprintf(left, sizeof(left), "%s%s%s", name,
		e->modified ? " *" : "", e->read_only ? " [read-only]" : "");
	novi_text_draw(dest, e->font_small, PAD, sbase, left,
		e->modified ? MODIFIED_PIX : STATUS_PIX);

	char right[sizeof(e->status) + 64];
	snprintf(right, sizeof(right), "%d:%d   %s",
		e->cy + 1, e->cx + 1,
		e->status[0] ? e->status : "^S save   ^Z undo   ^Y redo   ^Q quit");
	int rw = novi_text_width(e->font_small, right);
	novi_text_draw(dest, e->font_small, (int)w - PAD - rw, sbase, right,
		e->status_is_error ? ERROR_PIX : STATUS_PIX);

	pixman_image_unref(dest);
}

/* ── Wayland plumbing ──────────────────────────────────────────── */

static int allocate_shm_file(size_t size) {
	char name[] = "/novi-edit-XXXXXX";
	struct timespec ts;
	int fd = -1;
	for (int tries = 0; tries < 100 && fd < 0; tries++) {
		clock_gettime(CLOCK_REALTIME, &ts);
		long r = ts.tv_nsec + tries;
		for (int i = 0; i < 6; i++) {
			name[11 + i] = 'A' + (r & 15) + (r & 16) * 2;
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

static void surface_draw_frame(struct novi_edit *e) {
	if (!e->configured) {
		return;
	}
	uint32_t stride = e->width * 4;
	size_t size = (size_t)stride * e->height;

	int fd = allocate_shm_file(size);
	if (fd < 0) {
		fprintf(stderr, "novi-edit: failed to allocate shm buffer\n");
		return;
	}
	uint32_t *data = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (data == MAP_FAILED) {
		fprintf(stderr, "novi-edit: mmap failed\n");
		close(fd);
		return;
	}
	struct wl_shm_pool *pool = wl_shm_create_pool(e->shm, fd, (int32_t)size);
	struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0,
		(int32_t)e->width, (int32_t)e->height, (int32_t)stride,
		WL_SHM_FORMAT_XRGB8888);
	wl_shm_pool_destroy(pool);
	wl_display_flush(e->display);
	close(fd);

	render(e, data, e->width);
	munmap(data, size);

	wl_surface_attach(e->surface, buffer, 0, 0);
	wl_surface_damage_buffer(e->surface, 0, 0,
		(int32_t)e->width, (int32_t)e->height);
	wl_surface_commit(e->surface);
}

static void handle_key(struct novi_edit *e, xkb_keysym_t sym, bool ctrl) {
	e->status[0] = '\0';
	bool was_quit_armed = e->quit_armed;
	e->quit_armed = false;

	if (ctrl) {
		switch (sym) {
		case XKB_KEY_s: case XKB_KEY_S:
			doc_save(e);
			return;
		case XKB_KEY_z: case XKB_KEY_Z:
			history_step(e, false);
			return;
		case XKB_KEY_y: case XKB_KEY_Y:
			history_step(e, true);
			return;
		case XKB_KEY_q: case XKB_KEY_Q:
			/* An editor must not throw away work on one keypress. The
			 * second ^Q is the confirmation -- no modal dialog, which
			 * this program has no widget for and does not need. */
			if (e->modified && !was_quit_armed) {
				e->quit_armed = true;
				set_status(e, true, "unsaved changes -- ^Q again to discard, ^S to save");
				return;
			}
			e->running = false;
			return;
		default:
			return;
		}
	}

	switch (sym) {
	case XKB_KEY_Escape:
		if (e->modified && !was_quit_armed) {
			e->quit_armed = true;
			set_status(e, true, "unsaved changes -- Esc again to discard, ^S to save");
			return;
		}
		e->running = false;
		return;
	case XKB_KEY_Up:
		if (e->cy > 0) { e->cy--; clamp_cx(e); }
		break;
	case XKB_KEY_Down:
		if (e->cy < e->nlines - 1) { e->cy++; clamp_cx(e); }
		break;
	case XKB_KEY_Left:
		if (e->cx > 0) {
			e->cx = prev_char(e->lines[e->cy], e->cx);
		} else if (e->cy > 0) {
			e->cy--;
			e->cx = (int)strlen(e->lines[e->cy]);
		}
		break;
	case XKB_KEY_Right:
		if (e->cx < (int)strlen(e->lines[e->cy])) {
			e->cx = next_char(e->lines[e->cy], e->cx);
		} else if (e->cy < e->nlines - 1) {
			e->cy++;
			e->cx = 0;
		}
		break;
	case XKB_KEY_Home:
		e->cx = 0;
		break;
	case XKB_KEY_End:
		e->cx = (int)strlen(e->lines[e->cy]);
		break;
	case XKB_KEY_Page_Up: {
		int rows = visible_rows(e);
		e->cy = e->cy > rows ? e->cy - rows : 0;
		clamp_cx(e);
		break;
	}
	case XKB_KEY_Page_Down: {
		int rows = visible_rows(e);
		e->cy = e->cy + rows < e->nlines ? e->cy + rows : e->nlines - 1;
		clamp_cx(e);
		break;
	}
	case XKB_KEY_Return: case XKB_KEY_KP_Enter:
		split_line(e);
		break;
	case XKB_KEY_BackSpace:
		delete_back(e);
		break;
	case XKB_KEY_Delete:
		delete_forward(e);
		break;
	case XKB_KEY_Tab:
		insert_text(e, "\t");
		break;
	default:
		/* Printable text never reaches here: keyboard_key() handles it
		 * before calling this, from xkb_state_key_get_utf8(), which is
		 * the only correct source for it -- it applies the keymap, the
		 * modifiers and any compose state, so a keysym-to-ASCII table
		 * would get every non-US layout wrong. Anything left is a key
		 * with no text and no binding. */
		break;
	}

	/* A cursor move ends the run of typing that undo treats as one
	 * step. Without this, typing a word, arrowing away and typing
	 * another would collapse into a single undo that swallows both. */
	switch (sym) {
	case XKB_KEY_Up: case XKB_KEY_Down: case XKB_KEY_Left: case XKB_KEY_Right:
	case XKB_KEY_Home: case XKB_KEY_End:
	case XKB_KEY_Page_Up: case XKB_KEY_Page_Down:
		e->coalescing = false;
		break;
	default:
		break;
	}

	scroll_to_cursor(e);
}

static void keyboard_keymap(void *data, struct wl_keyboard *kb,
		uint32_t format, int fd, uint32_t size) {
	struct novi_edit *e = data;
	if (format != WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) {
		close(fd);
		return;
	}
	char *map = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
	if (map == MAP_FAILED) {
		close(fd);
		return;
	}
	struct xkb_keymap *keymap = xkb_keymap_new_from_string(e->xkb_context,
		map, XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS);
	munmap(map, size);
	close(fd);
	if (keymap == NULL) {
		return;
	}
	struct xkb_state *st = xkb_state_new(keymap);
	if (e->xkb_state != NULL) {
		xkb_state_unref(e->xkb_state);
	}
	if (e->xkb_keymap != NULL) {
		xkb_keymap_unref(e->xkb_keymap);
	}
	e->xkb_keymap = keymap;
	e->xkb_state = st;
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
	struct novi_edit *e = data;
	if (key_state != WL_KEYBOARD_KEY_STATE_PRESSED || e->xkb_state == NULL) {
		return;
	}
	xkb_keycode_t code = key + 8;
	xkb_keysym_t sym = xkb_state_key_get_one_sym(e->xkb_state, code);
	bool ctrl = xkb_state_mod_name_is_active(e->xkb_state, XKB_MOD_NAME_CTRL,
		XKB_STATE_MODS_EFFECTIVE) > 0;

	/* Text first: anything the keymap turns into printable UTF-8 and
	 * that is not a control chord is an insertion. Checking this before
	 * the keysym switch means a layout where, say, AltGr+something
	 * produces a character still types it. */
	if (!ctrl) {
		char buf[16];
		int n = xkb_state_key_get_utf8(e->xkb_state, code, buf, sizeof(buf));
		if (n > 0 && (unsigned char)buf[0] >= 0x20 && buf[0] != 0x7f) {
			e->status[0] = '\0';
			/* Typing after a ^Q that asked for confirmation is not
			 * confirmation of anything; the next ^Q must ask again. */
			e->quit_armed = false;
			insert_text(e, buf);
			scroll_to_cursor(e);
			surface_draw_frame(e);
			return;
		}
	}
	handle_key(e, sym, ctrl);
	surface_draw_frame(e);
}

static void keyboard_modifiers(void *data, struct wl_keyboard *kb,
		uint32_t serial, uint32_t depressed, uint32_t latched,
		uint32_t locked, uint32_t group) {
	struct novi_edit *e = data;
	if (e->xkb_state != NULL) {
		xkb_state_update_mask(e->xkb_state, depressed, latched, locked,
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
	struct novi_edit *e = data;
	if ((caps & WL_SEAT_CAPABILITY_KEYBOARD) && e->keyboard == NULL) {
		e->keyboard = wl_seat_get_keyboard(seat);
		wl_keyboard_add_listener(e->keyboard, &keyboard_listener, e);
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
	struct novi_edit *e = data;
	xdg_surface_ack_configure(xdg_surface, serial);
	e->configured = true;
	surface_draw_frame(e);
}

static const struct xdg_surface_listener xdg_surface_listener_impl = {
	.configure = xdg_surface_configure,
};

static void toplevel_configure(void *data, struct xdg_toplevel *toplevel,
		int32_t width, int32_t height, struct wl_array *states) {
	struct novi_edit *e = data;
	/* The compositor suggests a size (novi-shell asks for 70% of the
	 * usable area); zero means "you choose". Honouring it is what makes
	 * this window match every other one on the desktop. */
	if (width > 0 && height > 0) {
		e->width = (uint32_t)width;
		e->height = (uint32_t)height;
		scroll_to_cursor(e);
	}
}

static void toplevel_close(void *data, struct xdg_toplevel *toplevel) {
	struct novi_edit *e = data;
	e->running = false;
}

static const struct xdg_toplevel_listener toplevel_listener = {
	.configure = toplevel_configure,
	.close = toplevel_close,
};

static void registry_global(void *data, struct wl_registry *registry,
		uint32_t name, const char *interface, uint32_t version) {
	(void)version;
	struct novi_edit *e = data;
	if (strcmp(interface, wl_compositor_interface.name) == 0) {
		e->compositor = wl_registry_bind(registry, name,
			&wl_compositor_interface, 4);
	} else if (strcmp(interface, wl_shm_interface.name) == 0) {
		e->shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
	} else if (strcmp(interface, wl_seat_interface.name) == 0) {
		e->seat = wl_registry_bind(registry, name, &wl_seat_interface, 5);
		wl_seat_add_listener(e->seat, &seat_listener, e);
	} else if (strcmp(interface, xdg_wm_base_interface.name) == 0) {
		e->wm_base = wl_registry_bind(registry, name,
			&xdg_wm_base_interface, 1);
		xdg_wm_base_add_listener(e->wm_base, &wm_base_listener, e);
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
	struct novi_edit e = {0};
	e.running = true;
	e.width = WINDOW_WIDTH;
	e.height = WINDOW_HEIGHT;

	if (argc > 2) {
		fprintf(stderr, "usage: novi-edit [FILE]\n");
		return 2;
	}
	if (argc == 2) {
		snprintf(e.path, sizeof(e.path), "%s", argv[1]);
		if (!doc_load(&e, e.path)) {
			fprintf(stderr, "novi-edit: out of memory reading %s\n", e.path);
			return 1;
		}
	} else if (!doc_init_empty(&e)) {
		fprintf(stderr, "novi-edit: out of memory\n");
		return 1;
	}

	e.display = wl_display_connect(NULL);
	if (e.display == NULL) {
		fprintf(stderr, "novi-edit: failed to connect to Wayland display "
			"(is WAYLAND_DISPLAY set?)\n");
		return 1;
	}
	e.xkb_context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
	e.registry = wl_display_get_registry(e.display);
	wl_registry_add_listener(e.registry, &registry_listener, &e);
	wl_display_roundtrip(e.display);

	if (e.compositor == NULL || e.shm == NULL || e.wm_base == NULL) {
		fprintf(stderr, "novi-edit: compositor is missing a required global "
			"(wl_compositor/wl_shm/xdg_wm_base)\n");
		return 1;
	}

	e.font = novi_text_load_font("JetBrains Mono:size=15");
	e.font_small = novi_text_load_font("JetBrains Mono:size=12");
	if (e.font == NULL || e.font_small == NULL) {
		fprintf(stderr, "novi-edit: failed to load JetBrains Mono\n");
		return 1;
	}

	e.surface = wl_compositor_create_surface(e.compositor);
	e.xdg_surface = xdg_wm_base_get_xdg_surface(e.wm_base, e.surface);
	xdg_surface_add_listener(e.xdg_surface, &xdg_surface_listener_impl, &e);
	e.xdg_toplevel = xdg_surface_get_toplevel(e.xdg_surface);
	xdg_toplevel_add_listener(e.xdg_toplevel, &toplevel_listener, &e);

	char title[PATH_MAX + 16];
	snprintf(title, sizeof(title), "%s — Text Editor",
		e.path[0] ? e.path : "Untitled");
	xdg_toplevel_set_title(e.xdg_toplevel, title);
	xdg_toplevel_set_app_id(e.xdg_toplevel, "novi-edit");

	wl_surface_commit(e.surface);

	while (e.running && wl_display_dispatch(e.display) != -1) {
		;
	}

	history_free(&e);
	doc_free(&e);
	if (e.xkb_state != NULL) {
		xkb_state_unref(e.xkb_state);
	}
	if (e.xkb_keymap != NULL) {
		xkb_keymap_unref(e.xkb_keymap);
	}
	if (e.xkb_context != NULL) {
		xkb_context_unref(e.xkb_context);
	}
	wl_display_disconnect(e.display);
	return 0;
}
