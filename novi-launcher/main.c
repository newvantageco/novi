/* novi-launcher — Alt+Space search/launcher overlay (RFC 0001 decision 7).
 *
 * A separate Wayland client, not compositor code: it anchors itself as
 * an overlay-layer, keyboard-exclusive wlr-layer-shell-v1 surface,
 * matching the "novi-shell UI is a layer-shell client" split any future
 * panel will follow too. novi-shell spawns a fresh instance on
 * Alt+Space; this process exits itself on Escape or Enter.
 *
 * v1 scope: RFC 0001 describes Alt+Space as "apps, files by name, and
 * a calculator/unit-conversion fallback." App search now covers real
 * GUI apps -- packages/pkg-format.md's "GUI Application Registration"
 * convention has each launchable app ship a small usr/share/novi/
 * apps/<name>.app descriptor (plain name=/exec= text), which
 * load_apps() scans at startup and find_app_match() searches against
 * typed input. `pkg` doesn't install anything through this path yet
 * (no real GUI apps are packaged), but foot -- baked into the base
 * rootfs directly by build/09-foot.sh, not pkg-installed -- registers
 * itself the same way a real package would, so this is exercised by a
 * real launchable app, not just plumbing with nothing to search.
 * File search (indexed filesystem lookup) still doesn't exist and
 * isn't attempted here. The calculator fallback is unchanged -- live
 * arithmetic evaluation as you type, shown below the input line
 * whenever no app matches.
 *
 * Rendering uses real, anti-aliased text via fcft+pixman (see
 * common/text.h) -- the same font-rendering pipeline foot itself uses
 * for terminal glyphs, and JetBrains Mono, the same font
 * build/09-foot.sh already installs. This replaces an earlier
 * hand-drawn 3x5 bitmap font placeholder, which existed only because
 * nothing else in this repo needed real font rendering before foot.
 *
 * The card also has real rounded corners and a soft drop shadow (see
 * apply_rounded_corners()/draw_drop_shadow()) via a real ARGB8888
 * buffer with actual alpha, not a placeholder square -- the wl_shm
 * surface is deliberately larger than the visible card to leave room
 * for the shadow to extend past its edges without clipping.
 *
 * A second mode, `novi-launcher --symbols` (spawned by novi-shell on
 * Super+.), reuses this entire client -- same overlay, same card
 * chrome, same font -- for RFC 0001 decision 7's other overlay binding:
 * the symbol half of "emoji/symbol picker" (see the SYMBOLS[] table's
 * own comment for why not emoji). Enter copies the matched symbol to
 * the clipboard via the standard core-Wayland wl_data_device_manager
 * instead of launching anything.
 */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
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
#include "../shared/icons/icon_blit.h"
#include "../shared/icons/icons.h"

/* The visible card's own size -- unchanged from before the shadow was
 * added. The wl_shm buffer/layer-shell surface are now larger than
 * this (see BUFFER_WIDTH/BUFFER_HEIGHT) to leave room for the shadow
 * to extend past the card's edges; every draw call that used to be
 * card-relative now adds SHADOW_MARGIN to land in the same place
 * within the bigger buffer. */
#define CARD_WIDTH 560
#define CARD_HEIGHT 120
/* These are still plain 0xAARRGGBB literals with A=0xff -- a fully
 * opaque premultiplied-alpha pixel is numerically identical to a
 * straight-alpha one (premultiplying by 255/255 is a no-op), so
 * switching the buffer format to real ARGB8888 (see surface_draw_
 * frame()) needed no change here. Only the corner pixels
 * apply_rounded_corners() touches actually carry alpha < 0xff. */
#define BG_COLOR 0xff202030u
#define BORDER_COLOR 0xff4a4a6au
#define INPUT_COLOR 0xffe0e0f0u
#define RESULT_COLOR 0xff8ab4f8u
#define CURSOR_COLOR 0xffe0e0f0u
/* Real app-grid icon (shared/icons/, ICON-PIPELINE.md Stage 1/2), drawn
 * next to a matched app's result text when its .app descriptor names one
 * (pkg-format.md's icon= field). 24px is the app-grid size the generated
 * bitmaps were rasterized at (shared/icons/tools/svg2icon's JOBS[]) --
 * not a resize, an exact match. Same visual color as the result text
 * itself (RESULT_COLOR), just opaque: an icon glyph reads better solid
 * than at the text's own slightly-muted tone. */
#define RESULT_ICON_SIZE 24
#define RESULT_ICON_GAP 8
#define RESULT_ICON_COLOR 0xff8ab4f8u
/* GUI-DESIGN-LANGUAGE.md §3's radius-lg token: "Floating cards, the
 * launcher panel, notification toasts, window corners." */
#define CORNER_RADIUS 12

/* GUI-DESIGN-LANGUAGE.md §4's elevation-1 spec for floating cards:
 * "y-offset: 4px, feather: 16px, alpha: 0.35, color: #000000". */
#define SHADOW_OFFSET_Y 4
#define SHADOW_FEATHER 16
#define SHADOW_ALPHA_MAX 89 /* 0.35 * 255, rounded */
/* How far past the card's own edges the buffer needs to extend to fit
 * the shadow without clipping it -- feather (16) plus the vertical
 * offset (4) covers the shadow's farthest reach (below the card);
 * using the same margin on all four sides is simpler than four
 * different numbers and costs nothing (a few extra always-transparent
 * pixels on the shorter sides). */
#define SHADOW_MARGIN (SHADOW_FEATHER + SHADOW_OFFSET_Y)
#define BUFFER_WIDTH (CARD_WIDTH + 2 * SHADOW_MARGIN)
#define BUFFER_HEIGHT (CARD_HEIGHT + 2 * SHADOW_MARGIN)

#define INPUT_MAX 127

/* GUI app registry -- packages/pkg-format.md's "GUI Application
 * Registration" convention. APP_MAX is a fixed small cap, not a real
 * limit design: matches this doc's own reasoning for the icon set
 * being "small, fixed, and known entirely at build time" -- there's
 * no dynamic app installation happening at runtime here to size for. */
#define APPS_DIR "/usr/share/novi/apps"
#define APP_NAME_MAX 63
#define APP_EXEC_MAX 255
#define APP_MAX 64

struct app_entry {
	char id[APP_NAME_MAX + 1];   /* descriptor filename stem, e.g. "foot" */
	char name[APP_NAME_MAX + 1]; /* display name, e.g. "Terminal" */
	char exec[APP_EXEC_MAX + 1];
	int icon_id; /* enum novi_icon_id, or -1 if unset/unrecognized (see
	              * resolve_icon_name()) -- pkg-format.md's icon= field
	              * is optional, and "no icon" just means the result row
	              * shows text only, not a broken-icon placeholder. */
};

/* icon= in a .app descriptor names one of shared/icons/icons.h's
 * app-grid icons by its plain SVG-source name (pkg-format.md's own
 * table) -- a closed, fixed set matching ICON-PIPELINE.md's own
 * reasoning, not an arbitrary path novi-launcher would have to load at
 * runtime (there's still zero image-loading capability anywhere in
 * this repo; see that doc). */
static int resolve_icon_name(const char *name) {
	static const struct { const char *name; enum novi_icon_id id; } NAMES[] = {
		{"terminal", ICON_TERMINAL},
		{"folder", ICON_FOLDER},
		{"globe", ICON_GLOBE},
		{"pencil", ICON_PENCIL},
		{"package", ICON_PACKAGE},
		{"settings", ICON_SETTINGS},
		{"shield", ICON_SHIELD},
	};
	for (size_t i = 0; i < sizeof(NAMES) / sizeof(NAMES[0]); i++) {
		if (strcmp(NAMES[i].name, name) == 0) {
			return (int)NAMES[i].id;
		}
	}
	return -1;
}

struct novi_launcher {
	struct wl_display *display;
	struct wl_registry *registry;
	struct wl_compositor *compositor;
	struct wl_shm *shm;
	struct wl_seat *seat;
	struct wl_keyboard *keyboard;
	struct zwlr_layer_shell_v1 *layer_shell;
	struct wl_data_device_manager *data_device_manager;

	struct wl_surface *surface;
	struct zwlr_layer_surface_v1 *layer_surface;

	struct xkb_context *xkb_context;
	struct xkb_keymap *xkb_keymap;
	struct xkb_state *xkb_state;

	struct fcft_font *font;

	uint32_t width, height;
	bool configured;
	bool running;

	/* --symbols mode (see main()): the visible overlay closes the
	 * instant a symbol is copied, but the process itself has to keep
	 * dispatching until the clipboard data source is superseded --
	 * standard Wayland clipboard-source lifetime (the same reason
	 * wl-copy stays resident), not specific to this client. */
	bool symbol_mode;
	bool clipboard_serving;
	uint32_t last_key_serial;

	char input[INPUT_MAX + 1];
	size_t input_len;

	struct app_entry apps[APP_MAX];
	size_t app_count;
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

/* ── GUI app registry (Alt+Space app search) ───────────────────────── */

/* Parses one usr/share/novi/apps/<name>.app descriptor
 * (packages/pkg-format.md's "GUI Application Registration" format:
 * plain name=/exec= key=value lines, same style as MANIFEST) into
 * *out. Returns false if the file is missing either required field --
 * a package shipping a malformed descriptor shouldn't crash the
 * launcher or silently become an unnamed/unlaunchable entry, so it's
 * just skipped, matching evaluate()'s own "not parseable means not
 * shown" discipline rather than inventing a partial-entry fallback. */
static bool parse_app_file(const char *path, struct app_entry *out) {
	FILE *f = fopen(path, "r");
	if (f == NULL) {
		return false;
	}
	out->name[0] = '\0';
	out->exec[0] = '\0';
	out->icon_id = -1;
	char line[512];
	while (fgets(line, sizeof(line), f) != NULL) {
		size_t len = strlen(line);
		while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r')) {
			line[--len] = '\0';
		}
		if (strncmp(line, "name=", 5) == 0) {
			snprintf(out->name, sizeof(out->name), "%s", line + 5);
		} else if (strncmp(line, "exec=", 5) == 0) {
			snprintf(out->exec, sizeof(out->exec), "%s", line + 5);
		} else if (strncmp(line, "icon=", 5) == 0) {
			out->icon_id = resolve_icon_name(line + 5);
		}
	}
	fclose(f);
	return out->name[0] != '\0' && out->exec[0] != '\0';
}

/* Scans APPS_DIR for *.app descriptors at startup -- the set of
 * installed GUI apps is fixed for the life of this short-lived overlay
 * process (it exits on every Escape/Enter and novi-shell spawns a
 * fresh one next time), so there's no need to re-scan or watch the
 * directory for changes while running. Missing directory (no GUI apps
 * registered at all yet) is not an error -- the launcher still works
 * as a pure calculator, exactly like before this feature existed. */
static void load_apps(struct novi_launcher *state) {
	DIR *dir = opendir(APPS_DIR);
	if (dir == NULL) {
		return;
	}
	struct dirent *entry;
	while (state->app_count < APP_MAX && (entry = readdir(dir)) != NULL) {
		size_t name_len = strlen(entry->d_name);
		if (name_len < 5 || strcmp(entry->d_name + name_len - 4, ".app") != 0) {
			continue;
		}
		char path[PATH_MAX];
		snprintf(path, sizeof(path), "%s/%s", APPS_DIR, entry->d_name);
		struct app_entry *slot = &state->apps[state->app_count];
		if (parse_app_file(path, slot)) {
			/* id is the filename stem (up to the ".app" suffix
			 * load_apps() already matched), not part of the file's
			 * own key=value content -- it's how a real package name
			 * ("foot") stays searchable even when the display name
			 * ("Terminal") reads nothing like it. */
			size_t id_len = name_len - 4;
			if (id_len > APP_NAME_MAX) {
				id_len = APP_NAME_MAX;
			}
			memcpy(slot->id, entry->d_name, id_len);
			slot->id[id_len] = '\0';
			state->app_count++;
		}
	}
	closedir(dir);
}

/* Case-insensitive substring search, hand-rolled rather than
 * strcasestr(): this repo's musl cross-toolchain only declares
 * strcasestr() under _GNU_SOURCE (confirmed by reading
 * sysroot/usr/include/string.h and features.h -- plain -std=gnu11
 * doesn't imply it under musl the way it effectively does under
 * glibc), and this is little enough logic that hand-rolling it avoids
 * the feature-test-macro question entirely. */
static bool app_name_matches(const char *name, const char *query) {
	size_t name_len = strlen(name);
	size_t query_len = strlen(query);
	if (query_len == 0 || query_len > name_len) {
		return false;
	}
	for (size_t i = 0; i + query_len <= name_len; i++) {
		size_t j = 0;
		for (; j < query_len; j++) {
			char a = name[i + j];
			char b = query[j];
			if (a >= 'A' && a <= 'Z') {
				a = (char)(a + 32);
			}
			if (b >= 'A' && b <= 'Z') {
				b = (char)(b + 32);
			}
			if (a != b) {
				break;
			}
		}
		if (j == query_len) {
			return true;
		}
	}
	return false;
}

/* First registered app whose id (the descriptor's filename stem, e.g.
 * "foot") or display name (e.g. "Terminal") contains the typed input,
 * or NULL if input is empty or nothing matches. Checking id as well as
 * name matters whenever the two don't read alike -- a user typing the
 * binary/package name they already know ("foot") should find it even
 * though its display name doesn't contain that substring at all. Only
 * the first match is used (v1: no result list, no up/down selection)
 * -- matches this launcher's existing one-result-at-a-time calculator
 * display instead of adding new UI plumbing for a feature with, right
 * now, exactly one real app (foot) to ever produce more than one match
 * against. */
static struct app_entry *find_app_match(struct novi_launcher *state) {
	if (state->input_len == 0) {
		return NULL;
	}
	for (size_t i = 0; i < state->app_count; i++) {
		if (app_name_matches(state->apps[i].id, state->input) ||
				app_name_matches(state->apps[i].name, state->input)) {
			return &state->apps[i];
		}
	}
	return NULL;
}

/* Splits app->exec on spaces into an execvp() argv (no shell -- see
 * pkg-format.md's field table: no quoting/globbing/$VAR support in
 * v1, a path containing a space isn't representable), forks, and
 * execs in the child. The parent doesn't wait(): this overlay sets
 * state->running = false right after calling this and exits within
 * the same event-loop iteration, so the launched process is reparented
 * to PID 1 (s6) immediately after, the same as any other orphaned
 * process on this system -- there is no long-running parent here to
 * reap it instead. */
static void launch_app(const struct app_entry *app) {
	char exec_copy[APP_EXEC_MAX + 1];
	snprintf(exec_copy, sizeof(exec_copy), "%s", app->exec);

	char *argv[16];
	int argc = 0;
	char *tok = strtok(exec_copy, " ");
	while (tok != NULL && argc < 15) {
		argv[argc++] = tok;
		tok = strtok(NULL, " ");
	}
	argv[argc] = NULL;
	if (argc == 0) {
		return;
	}

	pid_t pid = fork();
	if (pid < 0) {
		fprintf(stderr, "novi-launcher: fork failed: %s\n", strerror(errno));
		return;
	}
	if (pid == 0) {
		execvp(argv[0], argv);
		fprintf(stderr, "novi-launcher: exec %s failed: %s\n", argv[0],
			strerror(errno));
		_exit(127);
	}
}

/* ── Symbol picker (Super+., novi-launcher --symbols) ──────────────
 *
 * RFC 0001 decision 7 calls this binding "emoji/symbol picker". Only
 * the symbol half is implemented: this repo ships no color-emoji font
 * (JetBrainsMono-Regular.ttf's own cmap was checked directly, not
 * assumed -- it has zero glyphs anywhere in the U+1F300+ emoji block),
 * and rendering real emoji would mean silently showing tofu/missing-
 * glyph boxes instead. Every codepoint below was checked against that
 * same cmap and does have a real JetBrains Mono glyph, so what's typed
 * and copied is always exactly what was seen on screen -- no
 * placeholder characters. Full emoji support is future work gated on
 * adding an actual (color or monochrome) emoji font. */
struct symbol_entry {
	const char *name;
	uint32_t codepoint;
};

static const struct symbol_entry SYMBOLS[] = {
	{"arrow right", 0x2192}, {"arrow left", 0x2190},
	{"arrow up", 0x2191}, {"arrow down", 0x2193},
	{"arrow left right", 0x2194}, {"arrow up down", 0x2195},
	{"double arrow right", 0x21D2}, {"double arrow left", 0x21D0},
	{"check mark", 0x2713}, {"cross mark", 0x2717},
	{"warning sign", 0x26A0}, {"lightning bolt", 0x26A1},
	{"plus minus", 0xB1}, {"multiply", 0xD7}, {"divide", 0xF7},
	{"approx equal", 0x2248}, {"not equal", 0x2260},
	{"less equal", 0x2264}, {"greater equal", 0x2265},
	{"infinity", 0x221E}, {"sum", 0x2211}, {"sqrt", 0x221A},
	{"delta", 0x2206}, {"pi", 0x3C0}, {"lambda", 0x3BB}, {"micro", 0xB5},
	{"euro", 0x20AC}, {"pound", 0xA3}, {"yen", 0xA5}, {"cent", 0xA2},
	{"copyright", 0xA9}, {"registered", 0xAE}, {"trademark", 0x2122},
	{"degree", 0xB0}, {"section", 0xA7}, {"paragraph", 0xB6},
	{"en dash", 0x2013}, {"em dash", 0x2014}, {"ellipsis", 0x2026},
	{"bullet", 0x2022}, {"middle dot", 0xB7}, {"not sign", 0xAC},
	{"left double quote", 0x201C}, {"right double quote", 0x201D},
	{"left single quote", 0x2018}, {"right single quote", 0x2019},
	{"box top left", 0x250C}, {"box top right", 0x2510},
	{"box bottom left", 0x2514}, {"box bottom right", 0x2518},
	{"box horizontal", 0x2500}, {"box vertical", 0x2502},
	{"square empty", 0x25A1}, {"square filled", 0x25A0},
	{"circle empty", 0x25CB}, {"circle filled", 0x25CF},
};

/* Encodes one Unicode codepoint as UTF-8 into out (caller-owned, must be
 * at least 5 bytes), NUL-terminated. Every SYMBOLS[] entry is in the
 * Basic Multilingual Plane (<= 3 UTF-8 bytes), but this handles the
 * full range correctly rather than assuming that stays true forever. */
static void utf8_encode(uint32_t cp, char out[5]) {
	if (cp < 0x80) {
		out[0] = (char)cp;
		out[1] = '\0';
	} else if (cp < 0x800) {
		out[0] = (char)(0xC0 | (cp >> 6));
		out[1] = (char)(0x80 | (cp & 0x3F));
		out[2] = '\0';
	} else if (cp < 0x10000) {
		out[0] = (char)(0xE0 | (cp >> 12));
		out[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
		out[2] = (char)(0x80 | (cp & 0x3F));
		out[3] = '\0';
	} else {
		out[0] = (char)(0xF0 | (cp >> 18));
		out[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
		out[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
		out[3] = (char)(0x80 | (cp & 0x3F));
		out[4] = '\0';
	}
}

/* Same one-result convention as find_app_match(): the first name match,
 * no ranked/multi-result list. */
static const struct symbol_entry *find_symbol_match(
		const struct novi_launcher *state) {
	if (state->input_len == 0) {
		return NULL;
	}
	for (size_t i = 0; i < sizeof(SYMBOLS) / sizeof(SYMBOLS[0]); i++) {
		if (app_name_matches(SYMBOLS[i].name, state->input)) {
			return &SYMBOLS[i];
		}
	}
	return NULL;
}

static const struct wl_data_source_listener clipboard_source_listener;

/* Bundles what the data-source callbacks need -- there's only ever one
 * clipboard source alive per process (this client copies exactly once,
 * on Enter), so static storage is simpler than heap-allocating a
 * per-source context. */
static struct {
	struct novi_launcher *state;
	char utf8[5];
} clipboard_ctx;

/* Sets a copy of `utf8` as the clipboard selection via the standard
 * core-Wayland wl_data_device_manager (novi-shell already creates one --
 * wlr_data_device_manager_create() in novi-shell/main.c -- for exactly
 * this, not a new protocol). */
static void copy_to_clipboard(struct novi_launcher *state, const char *utf8) {
	if (state->data_device_manager == NULL || state->seat == NULL) {
		fprintf(stderr, "novi-launcher: no clipboard support "
			"(wl_data_device_manager or wl_seat missing)\n");
		return;
	}
	clipboard_ctx.state = state;
	snprintf(clipboard_ctx.utf8, sizeof(clipboard_ctx.utf8), "%s", utf8);

	struct wl_data_source *source =
		wl_data_device_manager_create_data_source(state->data_device_manager);
	wl_data_source_offer(source, "text/plain;charset=utf-8");
	wl_data_source_offer(source, "UTF8_STRING");
	wl_data_source_offer(source, "text/plain");
	wl_data_source_add_listener(source, &clipboard_source_listener, NULL);

	struct wl_data_device *device =
		wl_data_device_manager_get_data_device(state->data_device_manager,
			state->seat);
	/* set_selection needs the serial of the input event that justifies
	 * claiming the selection -- the Enter keypress that triggered this
	 * copy, captured in keyboard_key() below. */
	wl_data_device_set_selection(device, source, state->last_key_serial);
	state->clipboard_serving = true;
}

static void clipboard_source_target(void *data, struct wl_data_source *source,
		const char *mime_type) {
	(void)data; (void)source; (void)mime_type;
}

static void clipboard_source_send(void *data, struct wl_data_source *source,
		const char *mime_type, int32_t fd) {
	(void)data; (void)source; (void)mime_type;
	const char *utf8 = clipboard_ctx.utf8;
	size_t len = strlen(utf8);
	size_t written = 0;
	while (written < len) {
		ssize_t n = write(fd, utf8 + written, len - written);
		if (n <= 0) {
			break;
		}
		written += (size_t)n;
	}
	close(fd);
}

static void clipboard_source_cancelled(void *data,
		struct wl_data_source *source) {
	(void)data;
	/* Another client took the selection (or novi-launcher itself is
	 * being torn down) -- this source's job is done, and nothing else
	 * keeps this process alive once clipboard_serving drops. */
	wl_data_source_destroy(source);
	clipboard_ctx.state->clipboard_serving = false;
}

static void clipboard_source_dnd_drop_performed(void *data,
		struct wl_data_source *source) {
	(void)data; (void)source;
}

static void clipboard_source_dnd_finished(void *data,
		struct wl_data_source *source) {
	(void)data; (void)source;
}

static void clipboard_source_action(void *data, struct wl_data_source *source,
		uint32_t dnd_action) {
	(void)data; (void)source; (void)dnd_action;
}

static const struct wl_data_source_listener clipboard_source_listener = {
	.target = clipboard_source_target,
	.send = clipboard_source_send,
	.cancelled = clipboard_source_cancelled,
	.dnd_drop_performed = clipboard_source_dnd_drop_performed,
	.dnd_finished = clipboard_source_dnd_finished,
	.action = clipboard_source_action,
};

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

/* Punches real transparency into each of the buffer's four corners so
 * a rounded-rect shape drawn into it reads as genuinely rounded
 * against whatever's behind it, instead of a rounded shape drawn ON an
 * opaque square (which would still show hard square corners). Per
 * GUI-DESIGN-LANGUAGE.md §4's "precomputed rounded-corner alpha mask"
 * approach, but computed directly here via each pixel's distance to
 * the corner's circle center rather than pixman's trapezoid
 * rasterizer -- geometrically the same result (a real, anti-aliased
 * A8 coverage boundary, not a hard cutoff), simpler to read, and cheap
 * enough (4 * radius^2 pixels) to redo on every redraw rather than
 * cache: this client only redraws on keystrokes, not every frame, so
 * there's no per-frame cost to amortize the way a compositor-lifetime
 * daemon would need to.
 *
 * Operates on whatever buffer it's given -- render() runs it on a
 * small card-local buffer (background+border only, not yet composited
 * onto the main surface), not the main output buffer directly. That
 * matters once there's a drop shadow underneath: punching transparency
 * via a RAW overwrite into the final, already-composited surface
 * buffer would erase the shadow value sitting there along with the
 * card's own color, showing a hole through to the desktop at each
 * corner instead of the shadow peeking through. Corner-masking the
 * card in its own small buffer FIRST, then alpha-compositing that
 * (via PIXMAN_OP_OVER, not a raw write) onto the shadow already in the
 * main buffer, lets the corners' partial transparency correctly blend
 * with whatever's underneath instead of replacing it. */
static void apply_rounded_corners(uint32_t *px, uint32_t stride_px,
		uint32_t w, uint32_t h, int radius) {
	for (int cy = 0; cy < radius; cy++) {
		for (int cx = 0; cx < radius; cx++) {
			double dx = radius - cx - 0.5;
			double dy = radius - cy - 0.5;
			double dist = sqrt(dx * dx + dy * dy);
			/* 1.0 = fully inside the rounded boundary (opaque,
			 * untouched in effect), 0.0 = fully outside (fully
			 * transparent), the ~1px band between is the
			 * anti-aliased edge. */
			double coverage = radius - dist;
			if (coverage > 1.0) {
				coverage = 1.0;
			} else if (coverage < 0.0) {
				coverage = 0.0;
			}
			uint8_t alpha = (uint8_t)(coverage * 255.0 + 0.5);

			int positions[4][2] = {
				{cx, cy},                             /* top-left */
				{(int)w - 1 - cx, cy},                 /* top-right */
				{cx, (int)h - 1 - cy},                 /* bottom-left */
				{(int)w - 1 - cx, (int)h - 1 - cy},     /* bottom-right */
			};
			for (int i = 0; i < 4; i++) {
				int x = positions[i][0], y = positions[i][1];
				if (x < 0 || x >= (int)w || y < 0 || y >= (int)h) {
					continue;
				}
				uint32_t *p = &px[y * (int)stride_px + x];
				uint32_t orig = *p;
				uint8_t r = (orig >> 16) & 0xff;
				uint8_t g = (orig >> 8) & 0xff;
				uint8_t b = orig & 0xff;
				/* wl_shm ARGB8888 is premultiplied alpha -- scale
				 * the color channels down to match the new alpha
				 * rather than just zeroing the alpha byte and
				 * leaving stale full-brightness RGB behind it. */
				r = (uint8_t)(r * alpha / 255);
				g = (uint8_t)(g * alpha / 255);
				b = (uint8_t)(b * alpha / 255);
				*p = ((uint32_t)alpha << 24) | ((uint32_t)r << 16) |
					((uint32_t)g << 8) | b;
			}
		}
	}
}

/* Signed distance from point (px,py), relative to a rounded box's own
 * center, to that box's boundary: negative inside, positive outside,
 * magnitude is the distance to the nearest edge (corner arc included).
 * This is Inigo Quilez's widely-used 2D rounded-box SDF formula
 * (public domain, from his signed-distance-functions reference) --
 * not derived here, just applied: it's the standard, correct way to
 * get a smoothly-feathered soft edge around a rounded rectangle
 * without rasterizing per-corner special cases by hand. */
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

/* Draws the card's drop shadow directly into `px`, which must start
 * fully transparent -- true here without any explicit clear, because
 * allocate_shm_file() ftruncate()s a brand new POSIX shm object every
 * redraw, and the kernel zero-fills those (same guarantee as a fresh
 * anonymous mmap). Must run FIRST, before the card itself is
 * composited on top (see render()): the shadow is the same rounded-
 * rect shape as the card, offset down by SHADOW_OFFSET_Y and feathered
 * outward by SHADOW_FEATHER using the SDF above, so most of it ends up
 * hidden directly under the opaque card -- only the sliver that peeks
 * out past the card's own edges (mainly below, since the offset is
 * purely vertical) is ever visible, which is exactly the intended
 * "elevated card" look. */
static void draw_drop_shadow(uint32_t *px, uint32_t stride_px,
		uint32_t buf_w, uint32_t buf_h) {
	double half_w = CARD_WIDTH / 2.0;
	double half_h = CARD_HEIGHT / 2.0;
	double center_x = SHADOW_MARGIN + half_w;
	double center_y = SHADOW_MARGIN + SHADOW_OFFSET_Y + half_h;

	for (int y = 0; y < (int)buf_h; y++) {
		for (int x = 0; x < (int)buf_w; x++) {
			double d = rounded_box_sdf(x + 0.5 - center_x, y + 0.5 - center_y,
				half_w, half_h, CORNER_RADIUS);
			double coverage;
			if (d <= 0.0) {
				coverage = 1.0;
			} else if (d >= SHADOW_FEATHER) {
				coverage = 0.0;
			} else {
				coverage = 1.0 - d / SHADOW_FEATHER;
			}
			if (coverage <= 0.0) {
				continue;
			}
			uint8_t alpha = (uint8_t)(coverage * SHADOW_ALPHA_MAX + 0.5);
			/* Shadow color is pure black -- at any alpha, premultiplied
			 * RGB is always 0,0,0, so the alpha byte alone is the
			 * entire pixel value. (Verified live with a temporary bright
			 * magenta swap-in, since a real black-on-black shadow is
			 * mathematically invisible in a screendump against this
			 * environment's plain black desktop, no matter how correct
			 * it is -- a pixel-exact scan of that debug render confirmed
			 * the SDF shape, the 4px offset sliver below the card, and
			 * the 16px linear feather all landing exactly on the values
			 * SHADOW_OFFSET_Y/SHADOW_FEATHER specify.) */
			px[y * (int)stride_px + x] = (uint32_t)alpha << 24;
		}
	}
}

static void render(struct novi_launcher *state, uint32_t *px,
		uint32_t stride_px) {
	uint32_t w = state->width, h = state->height;

	/* Shadow first, directly into the (freshly zero-filled, so already
	 * fully transparent) output buffer -- see draw_drop_shadow()'s own
	 * comment for why this has to happen before the card, not after. */
	draw_drop_shadow(px, stride_px, w, h);

	/* The card itself is built in its own small, card-sized buffer --
	 * background/border opaque, corners punched transparent -- then
	 * alpha-composited onto the shadow already sitting in `px`, rather
	 * than drawn directly into `px` with raw overwrites. A raw overwrite
	 * would blow away the shadow pixels wherever the card is opaque
	 * (fine, that's supposed to happen) but ALSO wherever the card's own
	 * corners are transparent (not fine -- see apply_rounded_corners()'s
	 * comment: that would erase the shadow there too, showing a hole
	 * through to the desktop instead of the shadow peeking through). A
	 * static buffer, not a stack one: CARD_WIDTH*CARD_HEIGHT*4 is ~262KB,
	 * too large for a stack frame, and this function is only ever called
	 * from the single-threaded main loop, so reusing one buffer across
	 * calls is safe. */
	static uint32_t card_buf[CARD_WIDTH * CARD_HEIGHT];
	draw_rect(card_buf, CARD_WIDTH, CARD_WIDTH, CARD_HEIGHT,
		0, 0, CARD_WIDTH, CARD_HEIGHT, BORDER_COLOR);
	draw_rect(card_buf, CARD_WIDTH, CARD_WIDTH, CARD_HEIGHT,
		3, 3, CARD_WIDTH - 6, CARD_HEIGHT - 6, BG_COLOR);
	apply_rounded_corners(card_buf, CARD_WIDTH, CARD_WIDTH, CARD_HEIGHT,
		CORNER_RADIUS);

	pixman_image_t *dest = pixman_image_create_bits_no_clear(
		PIXMAN_a8r8g8b8, (int)w, (int)h, px, (int)stride_px * 4);
	pixman_image_t *card_src = pixman_image_create_bits_no_clear(
		PIXMAN_a8r8g8b8, CARD_WIDTH, CARD_HEIGHT, card_buf, CARD_WIDTH * 4);
	pixman_image_composite32(PIXMAN_OP_OVER, card_src, NULL, dest,
		0, 0, 0, 0, SHADOW_MARGIN, SHADOW_MARGIN, CARD_WIDTH, CARD_HEIGHT);
	pixman_image_unref(card_src);

	static const pixman_color_t input_color = {
		.red = 0xe000, .green = 0xe000, .blue = 0xf000, .alpha = 0xffff,
	};
	static const pixman_color_t result_color = {
		.red = 0x8a00, .green = 0xb400, .blue = 0xf800, .alpha = 0xffff,
	};

	/* All card-relative coordinates from here on need the same
	 * SHADOW_MARGIN offset the card itself was composited at -- the
	 * card's interior is now fully opaque at this point (just painted
	 * above), so a raw draw_rect() for the cursor bar is exactly
	 * equivalent to a blend there and doesn't need its own pixman call. */
	int text_x = SHADOW_MARGIN + 16;
	int line_height = state->font->height;
	int input_y = SHADOW_MARGIN + 16;
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

	if (state->symbol_mode) {
		const struct symbol_entry *sym_match = find_symbol_match(state);
		if (sym_match != NULL) {
			/* Glyph first (exactly what Enter would copy), then its
			 * name -- no "-> " prefix here, unlike app search: the
			 * rendered glyph itself already IS the preview of what
			 * gets copied, "-> " would just be visual noise in front
			 * of it. */
			char glyph_utf8[5];
			utf8_encode(sym_match->codepoint, glyph_utf8);
			int result_top = input_y + line_height + 16;
			int end_x = novi_text_draw(dest, state->font, text_x,
				result_top + state->font->ascent, glyph_utf8, result_color);
			novi_text_draw(dest, state->font, end_x + RESULT_ICON_GAP,
				result_top + state->font->ascent, sym_match->name, result_color);
		}
		pixman_image_unref(dest);
		return;
	}

	/* App match takes priority over the calculator result when both
	 * would otherwise show something -- typing a name like "foot"
	 * never parses as an expression anyway (evaluate() would reject it
	 * at the first non-digit/operator character), so in practice these
	 * two never actually compete for the same input, but checking the
	 * app match first keeps that priority explicit rather than
	 * incidental. */
	struct app_entry *app = find_app_match(state);
	if (app != NULL) {
		int result_top = input_y + line_height + 16;
		int result_text_x = text_x;
		/* Real ICON-PIPELINE.md Stage 2 icon, not a placeholder: only
		 * drawn when the descriptor named a recognized icon= (see
		 * resolve_icon_name()) -- an app with no icon set, or an
		 * unrecognized name, still shows its text-only result exactly
		 * as before this feature existed. */
		if (app->icon_id >= 0) {
			int icon_y = result_top + (line_height - RESULT_ICON_SIZE) / 2;
			draw_icon(px, stride_px, w, h, text_x, icon_y,
				(enum novi_icon_id)app->icon_id, RESULT_ICON_COLOR);
			result_text_x = text_x + RESULT_ICON_SIZE + RESULT_ICON_GAP;
		}
		char buf[APP_NAME_MAX + 16];
		snprintf(buf, sizeof(buf), "-> %s", app->name);
		novi_text_draw(dest, state->font, result_text_x,
			result_top + state->font->ascent, buf, result_color);
	} else {
		double result;
		if (evaluate(state->input, &result)) {
			char buf[64];
			snprintf(buf, sizeof(buf), "= %.6g", result);
			novi_text_draw(dest, state->font, text_x,
				input_y + line_height + 16 + state->font->ascent, buf, result_color);
		}
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
	/* ARGB8888, not XRGB8888: apply_rounded_corners() needs a real
	 * alpha channel to punch actual transparency into the four corners
	 * -- an opaque XRGB buffer has nowhere to put that, so the corners
	 * would just stay whatever solid color was drawn under them. Every
	 * wl_shm-capable compositor is required to support both formats
	 * (core Wayland protocol, wl_shm's two mandatory formats), so this
	 * needs no capability check. */
	struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0,
		(int32_t)state->width, (int32_t)state->height, (int32_t)stride,
		WL_SHM_FORMAT_ARGB8888);
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
	(void)kb; (void)time;
	struct novi_launcher *state = data;
	state->last_key_serial = serial;
	if (key_state != WL_KEYBOARD_KEY_STATE_PRESSED || state->xkb_state == NULL) {
		return;
	}
	xkb_keysym_t sym = xkb_state_key_get_one_sym(state->xkb_state, key + 8);

	if (sym == XKB_KEY_Escape) {
		state->running = false;
		return;
	}
	if (sym == XKB_KEY_Return || sym == XKB_KEY_KP_Enter) {
		if (state->symbol_mode) {
			const struct symbol_entry *sym_match = find_symbol_match(state);
			if (sym_match != NULL) {
				char utf8[5];
				utf8_encode(sym_match->codepoint, utf8);
				copy_to_clipboard(state, utf8);
			}
			/* Hide the overlay immediately -- copy_to_clipboard() (if
			 * it ran) already armed clipboard_serving, which is what
			 * actually keeps the process alive past this point, not
			 * the surface staying mapped. */
			if (state->layer_surface != NULL) {
				zwlr_layer_surface_v1_destroy(state->layer_surface);
				state->layer_surface = NULL;
			}
			if (state->surface != NULL) {
				wl_surface_destroy(state->surface);
				state->surface = NULL;
			}
			state->running = false;
			return;
		}
		struct app_entry *app = find_app_match(state);
		if (app != NULL) {
			launch_app(app);
		}
		/* No result to "launch" for a bare calculator expression (see
		 * evaluate()) or file search (doesn't exist yet) -- Enter just
		 * dismisses the overlay in those cases, same as Escape. */
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

	/* Any printable ASCII is now valid input -- app names need letters
	 * that the calculator grammar alone never did (see file header:
	 * input is either a calculator expression or an app-name search
	 * query, and there's no calculator character class to filter
	 * against that wouldn't also reject e.g. "foot"). fcft renders any
	 * printable glyph fine (unlike the old bitmap font this replaced). */
	if (sym >= 32 && sym < 127) {
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
	state->width = width > 0 ? width : BUFFER_WIDTH;
	state->height = height > 0 ? height : BUFFER_HEIGHT;
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
	} else if (strcmp(interface, wl_data_device_manager_interface.name) == 0) {
		state->data_device_manager = wl_registry_bind(registry, name,
			&wl_data_device_manager_interface, 3);
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

int main(int argc, char *argv[]) {
	struct novi_launcher state = {0};
	state.running = true;
	/* --symbols: the symbol-picker half of RFC 0001 decision 7's
	 * Super+. binding (see the SYMBOLS[] table above for why not full
	 * emoji), spawned by novi-shell's own Super+. handler. Plain
	 * invocation (Alt+Space) stays app search + calculator, unchanged. */
	state.symbol_mode = argc > 1 && strcmp(argv[1], "--symbols") == 0;

	if (!state.symbol_mode) {
		load_apps(&state);
	}

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
	/* Requesting BUFFER_WIDTH/HEIGHT, not CARD_WIDTH/HEIGHT: the surface
	 * itself has to be big enough to hold the shadow's full reach around
	 * the card, not just the card. With anchor=0 (centered, unchanged
	 * below), the extra margin is symmetric, so the card still ends up
	 * centered on screen -- only the invisible (mostly-transparent)
	 * padding around it grew. */
	zwlr_layer_surface_v1_set_size(state.layer_surface, BUFFER_WIDTH, BUFFER_HEIGHT);
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

	while ((state.running || state.clipboard_serving) &&
			wl_display_dispatch(state.display) != -1) {
		/* All the real work happens in the listener callbacks above.
		 * clipboard_serving keeps this alive after the overlay itself
		 * is gone (see keyboard_key()'s Enter/--symbols handling) so a
		 * copied symbol can still actually be pasted somewhere. */
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
