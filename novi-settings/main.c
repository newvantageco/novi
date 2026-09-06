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
 * Three panels, each of which does one real thing rather than being a
 * section with nothing behind it: Account changes root's password,
 * Network joins WiFi (RFC 0017), System is a front-end to
 * /etc/novi/system.conf (RFC 0002). Every one of them is a capability
 * this system did not previously have from a desktop.
 *
 * Account came first. This system had no password-setup flow with a
 * GUI at all (novi-lockscreen's own header comment notes the stock
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
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
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
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>

#include "xdg-shell-client-protocol.h"
#include "../common/text.h"

#define WINDOW_WIDTH 640
#define WINDOW_HEIGHT 400
#define FIELD_MAX 127
#define FIELD_COUNT 2 /* 0 = new password, 1 = confirm */

#define BG_COLOR 0xff14141cu
#define SIDEBAR_BG_COLOR 0xff101018u
#define TEXT_COLOR 0xffe0e0f0u
#define LABEL_COLOR 0xff8a8aa0u
#define HINT_COLOR 0xff8a8aa0u
#define ERROR_COLOR 0xffe08a8au
#define SUCCESS_COLOR 0xff8ae0a0u
#define FIELD_BG_COLOR 0xff1e1e28u
#define FIELD_BORDER_COLOR 0xff3a3a4au
#define FIELD_BORDER_FOCUS_COLOR 0xff8ab4f8u
#define ROW_SELECTED_COLOR 0xff232334u
#define ACCENT_COLOR 0xff8ab4f8u
#define DOT_COLOR 0xffe0e0f0u
#define DOT_SIZE 8
#define DOT_GAP 6

#define SIDEBAR_WIDTH 160
#define CONTENT_X (SIDEBAR_WIDTH + 24)
#define FIELD_X CONTENT_X
#define FIELD_WIDTH (WINDOW_WIDTH - CONTENT_X - 24)
#define FIELD_HEIGHT 36

/* ── The System panel: the GUI as a front-end to the document ───────
 *
 * RFC 0002's whole claim is that clicking a toggle and editing a text
 * file are the same operation on the same document. This panel is what
 * makes that true rather than asserted: it reads
 * /etc/novi/system.conf, and every change it makes goes back out
 * through `novi-state set` -- never by writing the file itself.
 *
 * That indirection is deliberate and worth not "optimizing" away.
 * novi-state's state_set() does a surgical in-place edit that
 * preserves every comment and the file's ordering (CLAUDE.md names it
 * an invariant). A second implementation here, in C, would be a second
 * thing that can drift from it -- and the first time the GUI clobbered
 * a user's comments, the document would stop being something anyone
 * wants to hand-edit, which is the entire proposition. One writer,
 * one behavior. */
#define STATE_FILE "/etc/novi/system.conf"
#define NOVI_STATE_BIN "/usr/bin/novi-state"
#define STATE_MAX_ENTRIES 32
#define STATE_KEY_MAX 63
#define STATE_VAL_MAX 31
#define ROW_HEIGHT 26

enum novi_panel {
	PANEL_ACCOUNT = 0,
	PANEL_NETWORK,
	PANEL_SYSTEM,
	PANEL_COUNT,
};

static const char *PANEL_NAMES[PANEL_COUNT] = { "Account", "Network", "System" };

/* ── The Network panel: WiFi without a terminal ─────────────────────
 *
 * RFC 0017. Everything here is a front-end to `novi-wifi` and
 * `novi-state`, for the same reason the System panel shells out to
 * novi-state: the rules about what a wireless device is, where a
 * passphrase may be stored, and how a PSK is derived should exist
 * once. This panel does not open /etc/novi/wifi.conf, does not walk
 * /sys/class/net, and does not run wpa_cli.
 *
 * The passphrase goes to `novi-wifi add <ssid> --stdin` down a pipe,
 * never as an argument: /proc/<pid>/cmdline is world-readable.
 *
 * And a scan is SLOW -- seconds, because it is a radio doing physics.
 * Every other subprocess this app runs is a fork and a few
 * milliseconds, and the file's own comment above already warns that
 * blocking the Wayland event loop stops being acceptable the moment
 * something slow shows up. A scan is that moment, so this panel
 * brought a job runner with it (job_start/job_pump below) and the
 * main loop polls the child's pipe alongside the Wayland fd. */
#define NOVI_WIFI_BIN "/usr/bin/novi-wifi"
#define NET_MAX 24
#define SSID_MAX 47
#define PASS_MAX 63          /* WPA-PSK's own upper bound */
#define JOB_BUF 8192

struct net_entry {
	char ssid[SSID_MAX + 1];
	/* dBm, negative. Only meaningful when `seen` -- a saved network
	 * that is not on the air right now has no signal, which is
	 * different from a signal of zero. */
	int signal;
	bool seen;
	bool saved;
	bool connected;
};

/* One job at a time, deliberately. Two concurrent scans have no
 * meaning, and a second `add` while the first is in flight would race
 * on wifi.conf -- a queue here would be machinery in service of a
 * situation a person cannot create by pressing keys. */
enum job_kind {
	JOB_NONE = 0,
	JOB_SCAN,
	JOB_ADD,
	JOB_FORGET,
	JOB_APPLY,
};

struct state_entry {
	char key[STATE_KEY_MAX + 1];
	char value[STATE_VAL_MAX + 1];
	/* True when novi-state's own `diff` reports this key as drifted --
	 * i.e. the running system does not currently match what the
	 * document declares. Nothing else in any desktop shows this,
	 * because nothing else has a declared state to compare against. */
	bool drifted;
};

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

	int panel;

	int focus_field;
	char field[FIELD_COUNT][FIELD_MAX + 1];
	size_t field_len[FIELD_COUNT];

	struct state_entry entries[STATE_MAX_ENTRIES];
	int entry_count;
	int selected;

	/* ── Network panel ── */
	char wifi_iface[32];             /* "" = no wireless device */
	char wifi_state[32];             /* wpa_supplicant's wpa_state */
	char wifi_ssid[SSID_MAX + 1];    /* what it is associated with */
	char wifi_ip[48];
	bool wifi_declared_on;
	struct net_entry nets[NET_MAX];
	int net_count;
	int net_selected;

	bool pass_prompt;
	char pass_ssid[SSID_MAX + 1];
	char pass[PASS_MAX + 1];
	size_t pass_len;

	enum job_kind job;
	pid_t job_pid;
	int job_fd;
	char job_ssid[SSID_MAX + 1];
	char job_out[JOB_BUF];
	size_t job_len;

	/* A status line that is a copy, not a pointer to a literal.
	 * Everything the Account and System panels report is a fixed
	 * string; the Network panel reports things like the last line a
	 * child process printed, which has to live somewhere. */
	char status_buf[160];
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

/* ── Talking to novi-state ─────────────────────────────────────────
 *
 * Every one of these shells out rather than reimplementing novi-state's
 * logic in C. See the STATE_FILE comment above for why that is a
 * deliberate constraint and not laziness.
 *
 * These calls block the Wayland event loop for as long as the child
 * runs. That is fine at this scale -- a `set` is a single awk pass over
 * a ~40-line file, and an `apply` is a couple of s6-rc transitions --
 * but it would not stay fine if a domain ever converged something slow
 * (a package install). At that point this needs to move off the event
 * loop; noting it here so the next person hits a comment rather than a
 * frozen window. */

static int run_novi_state(char *const argv[]) {
	pid_t pid = fork();
	if (pid < 0) {
		return -1;
	}
	if (pid == 0) {
		execv(NOVI_STATE_BIN, argv);
		_exit(127);
	}
	int status = 0;
	if (waitpid(pid, &status, 0) < 0) {
		return -1;
	}
	return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

/* Parse /etc/novi/system.conf into the entry table. Deliberately reads
 * the file directly (reading is not writing -- no invariant to
 * violate, and no reason to fork once per key), using the same shape
 * novi-state's own state_normalize() accepts: `key = value`, `#`
 * comments, blank lines and indentation allowed. */
static void load_state_file(struct novi_settings *state) {
	state->entry_count = 0;
	FILE *f = fopen(STATE_FILE, "r");
	if (f == NULL) {
		return;
	}
	char line[512];
	while (fgets(line, sizeof(line), f) != NULL &&
			state->entry_count < STATE_MAX_ENTRIES) {
		char *hash = strchr(line, '#');
		if (hash != NULL) {
			*hash = '\0';
		}
		char *eq = strchr(line, '=');
		if (eq == NULL) {
			continue;
		}
		*eq = '\0';
		char *key = line;
		char *value = eq + 1;

		/* Trim both fields. */
		while (*key == ' ' || *key == '\t') {
			key++;
		}
		char *end = key + strlen(key);
		while (end > key && (end[-1] == ' ' || end[-1] == '\t')) {
			*--end = '\0';
		}
		while (*value == ' ' || *value == '\t') {
			value++;
		}
		end = value + strlen(value);
		while (end > value && (end[-1] == ' ' || end[-1] == '\t' ||
				end[-1] == '\n' || end[-1] == '\r')) {
			*--end = '\0';
		}
		if (*key == '\0' || *value == '\0') {
			continue;
		}
		/* Skip rather than truncate. A truncated key would still
		 * display, but could never compare equal to what
		 * `novi-state diff` reports, so it would silently render as
		 * "never drifted" -- a wrong answer shown confidently, which
		 * is worse than omitting the row. */
		size_t key_len = strlen(key), value_len = strlen(value);
		if (key_len > STATE_KEY_MAX || value_len > STATE_VAL_MAX) {
			continue;
		}

		/* memcpy, not snprintf: the lengths are already proven to fit
		 * by the check above, and saying so with an explicit copy both
		 * states that intent and avoids -Wformat-truncation warning
		 * about a truncation that can no longer happen. */
		struct state_entry *e = &state->entries[state->entry_count++];
		memcpy(e->key, key, key_len + 1);
		memcpy(e->value, value, value_len + 1);
		e->drifted = false;
	}
	fclose(f);
}

/* Mark entries the running system doesn't currently match, by asking
 * novi-state itself rather than observing anything here -- the
 * observers live in one place on purpose (a second, C copy of "is this
 * service up" would be exactly the kind of parallel truth this whole
 * feature exists to abolish).
 *
 * `novi-state diff` prints drift to stdout as paired lines:
 *     - services.novi-shell = off   (actual)
 *     + services.novi-shell = on    (declared)
 * and its human-facing "matches declared state" message to stderr, so
 * capturing stdout alone yields exactly the machine-readable half. */
static void mark_drift(struct novi_settings *state) {
	int fds[2];
	if (pipe(fds) < 0) {
		return;
	}
	pid_t pid = fork();
	if (pid < 0) {
		close(fds[0]);
		close(fds[1]);
		return;
	}
	if (pid == 0) {
		close(fds[0]);
		dup2(fds[1], STDOUT_FILENO);
		close(fds[1]);
		char *const argv[] = { (char *)"novi-state", (char *)"diff", NULL };
		execv(NOVI_STATE_BIN, argv);
		_exit(127);
	}
	close(fds[1]);

	char buf[4096];
	size_t used = 0;
	ssize_t n;
	while (used < sizeof(buf) - 1 &&
			(n = read(fds[0], buf + used, sizeof(buf) - 1 - used)) > 0) {
		used += (size_t)n;
	}
	buf[used] = '\0';
	close(fds[0]);
	waitpid(pid, NULL, 0);

	for (char *line = strtok(buf, "\n"); line != NULL; line = strtok(NULL, "\n")) {
		if (line[0] != '-' || line[1] != ' ') {
			continue;
		}
		char *key = line + 2;
		char *sp = strchr(key, ' ');
		if (sp == NULL) {
			continue;
		}
		*sp = '\0';
		for (int i = 0; i < state->entry_count; i++) {
			if (strcmp(state->entries[i].key, key) == 0) {
				state->entries[i].drifted = true;
			}
		}
	}
}

static void refresh_system(struct novi_settings *state) {
	load_state_file(state);
	mark_drift(state);
	if (state->selected >= state->entry_count) {
		state->selected = state->entry_count > 0 ? state->entry_count - 1 : 0;
	}
}

static bool entry_is_toggleable(const struct state_entry *e) {
	return strcmp(e->value, "on") == 0 || strcmp(e->value, "off") == 0;
}

static void set_status(struct novi_settings *state, const char *msg, bool is_error);

static void toggle_selected(struct novi_settings *state) {
	if (state->entry_count == 0) {
		return;
	}
	struct state_entry *e = &state->entries[state->selected];
	if (!entry_is_toggleable(e)) {
		set_status(state, "Not a toggle -- edit it in the file", true);
		return;
	}
	const char *next = strcmp(e->value, "on") == 0 ? "off" : "on";
	char *const argv[] = {
		(char *)"novi-state", (char *)"set", e->key, (char *)next, NULL,
	};
	if (run_novi_state(argv) != 0) {
		set_status(state, "Failed to write system.conf", true);
		return;
	}
	/* Re-read rather than trusting our own in-memory edit: the file is
	 * the truth, and this is also the cheapest way to notice if
	 * something else changed it underneath us. */
	refresh_system(state);
	set_status(state, "Declared -- press Enter to apply", false);
}

static void apply_state(struct novi_settings *state) {
	char *const argv[] = { (char *)"novi-state", (char *)"apply", NULL };
	int rc = run_novi_state(argv);
	refresh_system(state);
	if (rc != 0) {
		set_status(state, "Apply failed", true);
		return;
	}
	set_status(state, "Applied -- system matches the document", false);
}

/* ── The Network panel ─────────────────────────────────────────────
 *
 * Reading is synchronous; anything that touches the radio is not. See
 * the enum job_kind comment above for the split.
 */

/* Run a command and capture its stdout into `out`. Synchronous, and
 * only ever used for the instant ones: `novi-wifi iface` reads one
 * sysfs directory, `list` reads a file, `status` talks to a local
 * socket. A scan does not come through here. */
static bool capture(const char *path, char *const argv[], char *out, size_t outsz) {
	int fds[2];
	out[0] = '\0';
	if (pipe(fds) < 0) {
		return false;
	}
	pid_t pid = fork();
	if (pid < 0) {
		close(fds[0]);
		close(fds[1]);
		return false;
	}
	if (pid == 0) {
		close(fds[0]);
		dup2(fds[1], STDOUT_FILENO);
		close(fds[1]);
		/* stderr to /dev/null: novi-wifi's `info`/`die` lines all go
		 * there, and mixing them into parsed output would turn an
		 * explanatory sentence into a network named after it. */
		int devnull = open("/dev/null", O_WRONLY);
		if (devnull >= 0) {
			dup2(devnull, STDERR_FILENO);
			close(devnull);
		}
		execv(path, argv);
		_exit(127);
	}
	close(fds[1]);
	size_t used = 0;
	ssize_t n;
	while (used < outsz - 1 &&
			(n = read(fds[0], out + used, outsz - 1 - used)) > 0) {
		used += (size_t)n;
	}
	out[used] = '\0';
	close(fds[0]);
	int status = 0;
	waitpid(pid, &status, 0);
	return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

static void chomp(char *s) {
	size_t n = strlen(s);
	while (n > 0 && (s[n - 1] == '\n' || s[n - 1] == '\r')) {
		s[--n] = '\0';
	}
}

static struct net_entry *net_find(struct novi_settings *state, const char *ssid) {
	for (int i = 0; i < state->net_count; i++) {
		if (strcmp(state->nets[i].ssid, ssid) == 0) {
			return &state->nets[i];
		}
	}
	return NULL;
}

/* Adds `ssid` if it is not already listed, and returns the row either
 * way. Saved networks and scanned networks are ONE list on purpose: a
 * person thinks about "networks", not about which of two tables a name
 * came from, and a saved network that is also in range is one thing,
 * not two rows that happen to share a name. */
static struct net_entry *net_intern(struct novi_settings *state, const char *ssid) {
	struct net_entry *e = net_find(state, ssid);
	if (e != NULL) {
		return e;
	}
	if (state->net_count >= NET_MAX || ssid[0] == '\0') {
		return NULL;
	}
	e = &state->nets[state->net_count++];
	memset(e, 0, sizeof(*e));
	snprintf(e->ssid, sizeof(e->ssid), "%s", ssid);
	return e;
}

/* What the supplicant is doing right now. `novi-wifi status` is
 * wpa_cli's own key=value output, so this parses that rather than
 * running wpa_cli itself -- one place knows the control socket's
 * path. */
static void refresh_wifi_status(struct novi_settings *state) {
	state->wifi_state[0] = '\0';
	state->wifi_ssid[0] = '\0';
	state->wifi_ip[0] = '\0';

	char buf[4096];
	char *const argv[] = { (char *)"novi-wifi", (char *)"status", NULL };
	if (!capture(NOVI_WIFI_BIN, argv, buf, sizeof(buf))) {
		return;   /* not running: no state, which is the honest answer */
	}
	for (char *line = strtok(buf, "\n"); line != NULL; line = strtok(NULL, "\n")) {
		char *eq = strchr(line, '=');
		if (eq == NULL) {
			continue;
		}
		*eq = '\0';
		const char *k = line, *v = eq + 1;
		if (strcmp(k, "wpa_state") == 0) {
			snprintf(state->wifi_state, sizeof(state->wifi_state), "%s", v);
		} else if (strcmp(k, "ssid") == 0) {
			snprintf(state->wifi_ssid, sizeof(state->wifi_ssid), "%s", v);
		} else if (strcmp(k, "ip_address") == 0) {
			snprintf(state->wifi_ip, sizeof(state->wifi_ip), "%s", v);
		}
	}
}

/* Re-read everything cheap: the interface, the declared key, the saved
 * list and the live association. The scan results already in
 * state->nets are kept -- they are the only thing here that costs
 * seconds to obtain, and throwing them away on every status refresh
 * would make the list flicker between "eight networks" and "the two
 * you have saved". */
static void refresh_network(struct novi_settings *state) {
	char buf[8192];

	char *const iface_argv[] = { (char *)"novi-wifi", (char *)"iface", NULL };
	if (capture(NOVI_WIFI_BIN, iface_argv, buf, sizeof(buf))) {
		chomp(buf);
		snprintf(state->wifi_iface, sizeof(state->wifi_iface), "%s", buf);
	} else {
		state->wifi_iface[0] = '\0';
	}

	char *const get_argv[] = {
		(char *)"novi-state", (char *)"get", (char *)"network.wifi", NULL,
	};
	state->wifi_declared_on = false;
	if (capture(NOVI_STATE_BIN, get_argv, buf, sizeof(buf))) {
		chomp(buf);
		state->wifi_declared_on = strcmp(buf, "on") == 0;
	}

	for (int i = 0; i < state->net_count; i++) {
		state->nets[i].saved = false;
		state->nets[i].connected = false;
	}

	char *const list_argv[] = { (char *)"novi-wifi", (char *)"list", NULL };
	if (capture(NOVI_WIFI_BIN, list_argv, buf, sizeof(buf))) {
		for (char *line = strtok(buf, "\n"); line != NULL;
				line = strtok(NULL, "\n")) {
			chomp(line);
			if (line[0] == '\0') {
				continue;
			}
			struct net_entry *e = net_intern(state, line);
			if (e != NULL) {
				e->saved = true;
			}
		}
	}

	refresh_wifi_status(state);
	if (state->wifi_ssid[0] != '\0' &&
			strcmp(state->wifi_state, "COMPLETED") == 0) {
		struct net_entry *e = net_intern(state, state->wifi_ssid);
		if (e != NULL) {
			e->connected = true;
		}
	}

	/* Drop rows that are neither saved nor currently on the air: a
	 * network that was in a scan two scans ago and is gone now is not
	 * information, it is a stale row a person might try to join. */
	int keep = 0;
	for (int i = 0; i < state->net_count; i++) {
		if (state->nets[i].saved || state->nets[i].seen ||
				state->nets[i].connected) {
			state->nets[keep++] = state->nets[i];
		}
	}
	state->net_count = keep;

	if (state->net_selected >= state->net_count) {
		state->net_selected = state->net_count > 0 ? state->net_count - 1 : 0;
	}
}

/* ── The job runner ────────────────────────────────────────────────
 *
 * fork, read the child's output through a pipe the main loop polls,
 * dispatch on EOF. `stdin_data` is written to the child before its
 * output is read; that ordering is safe only because the payload is a
 * passphrase -- 63 bytes at most, far inside a pipe buffer -- and
 * would deadlock on anything that could fill one. */
static void job_finish(struct novi_settings *state, int exit_code);

static bool job_start(struct novi_settings *state, enum job_kind kind,
		const char *path, char *const argv[], const char *stdin_data,
		const char *ssid) {
	if (state->job != JOB_NONE) {
		set_status(state, "Busy -- one thing at a time", true);
		return false;
	}
	int out_fds[2], in_fds[2] = { -1, -1 };
	if (pipe(out_fds) < 0) {
		return false;
	}
	if (stdin_data != NULL && pipe(in_fds) < 0) {
		close(out_fds[0]);
		close(out_fds[1]);
		return false;
	}

	pid_t pid = fork();
	if (pid < 0) {
		close(out_fds[0]);
		close(out_fds[1]);
		if (in_fds[0] >= 0) {
			close(in_fds[0]);
			close(in_fds[1]);
		}
		return false;
	}
	if (pid == 0) {
		close(out_fds[0]);
		dup2(out_fds[1], STDOUT_FILENO);
		/* stderr into the SAME pipe here, unlike capture(): a job's
		 * output is shown to the user, and novi-wifi says why it
		 * refused on stderr. Losing that would leave a failed join
		 * with no reason on screen. */
		dup2(out_fds[1], STDERR_FILENO);
		close(out_fds[1]);
		if (in_fds[0] >= 0) {
			close(in_fds[1]);
			dup2(in_fds[0], STDIN_FILENO);
			close(in_fds[0]);
		}
		execv(path, argv);
		_exit(127);
	}

	close(out_fds[1]);
	if (in_fds[0] >= 0) {
		close(in_fds[0]);
		size_t len = strlen(stdin_data), written = 0;
		while (written < len) {
			ssize_t n = write(in_fds[1], stdin_data + written, len - written);
			if (n < 0 && errno == EINTR) {
				continue;
			}
			if (n <= 0) {
				break;
			}
			written += (size_t)n;
		}
		(void)!write(in_fds[1], "\n", 1);
		close(in_fds[1]);
	}

	/* Non-blocking, and this matters: job_pump() drains in a loop until
	 * it sees EOF, and on a blocking fd the second read would sleep
	 * until the child produced more -- freezing the window for exactly
	 * as long as the scan it was supposed to be running alongside. */
	int fl = fcntl(out_fds[0], F_GETFL, 0);
	if (fl >= 0) {
		fcntl(out_fds[0], F_SETFL, fl | O_NONBLOCK);
	}

	state->job = kind;
	state->job_pid = pid;
	state->job_fd = out_fds[0];
	state->job_len = 0;
	state->job_out[0] = '\0';
	snprintf(state->job_ssid, sizeof(state->job_ssid), "%s", ssid ? ssid : "");
	return true;
}

/* Called when the job's pipe is readable. Returns true if the job
 * ended, which is the main loop's cue to redraw. */
static bool job_pump(struct novi_settings *state) {
	if (state->job == JOB_NONE) {
		return false;
	}
	for (;;) {
		if (state->job_len >= sizeof(state->job_out) - 1) {
			/* Full. Keep draining so the child is never blocked on a
			 * write we stopped reading -- discarding the tail is
			 * correct here (a scan of 24 networks is under 2 KB) and
			 * hanging the child would not be. */
			char sink[1024];
			ssize_t n = read(state->job_fd, sink, sizeof(sink));
			if (n > 0) {
				continue;
			}
			if (n < 0 && errno == EINTR) {
				continue;
			}
			if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
				return false;
			}
			break;
		}
		ssize_t n = read(state->job_fd, state->job_out + state->job_len,
			sizeof(state->job_out) - 1 - state->job_len);
		if (n > 0) {
			state->job_len += (size_t)n;
			state->job_out[state->job_len] = '\0';
			continue;
		}
		if (n < 0 && errno == EINTR) {
			continue;
		}
		if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
			return false;
		}
		break;   /* EOF, or a read error we cannot do anything about */
	}

	close(state->job_fd);
	state->job_fd = -1;
	int status = 0;
	waitpid(state->job_pid, &status, 0);
	job_finish(state, WIFEXITED(status) ? WEXITSTATUS(status) : -1);
	return true;
}

/* novi-wifi's own error lines are `ERROR: ...`; its progress lines are
 * `  -> ...` and `==> ...`. Show the last thing it said, preferring an
 * error, so a failure reads as a sentence rather than "exit 1". */
static void status_from_job(struct novi_settings *state, bool failed,
		const char *fallback) {
	char *best = NULL;
	char copy[JOB_BUF];
	snprintf(copy, sizeof(copy), "%s", state->job_out);
	for (char *line = strtok(copy, "\n"); line != NULL; line = strtok(NULL, "\n")) {
		if (strncmp(line, "ERROR: ", 7) == 0) {
			best = line + 7;
			break;
		}
	}
	if (best == NULL && failed) {
		best = (char *)fallback;
	}
	set_status(state, best != NULL ? best : fallback, failed);
}

static void job_finish(struct novi_settings *state, int exit_code) {
	enum job_kind kind = state->job;
	bool failed = exit_code != 0;
	state->job = JOB_NONE;

	switch (kind) {
	case JOB_SCAN:
		if (!failed) {
			/* A fresh scan replaces the airwaves, not the saved list:
			 * clear `seen` on everything, then mark what came back. */
			for (int i = 0; i < state->net_count; i++) {
				state->nets[i].seen = false;
			}
			char copy[JOB_BUF];
			snprintf(copy, sizeof(copy), "%s", state->job_out);
			for (char *line = strtok(copy, "\n"); line != NULL;
					line = strtok(NULL, "\n")) {
				char *tab = strchr(line, '\t');
				if (tab == NULL) {
					continue;
				}
				*tab = '\0';
				struct net_entry *e = net_intern(state, tab + 1);
				if (e == NULL) {
					continue;
				}
				e->seen = true;
				e->signal = atoi(line);
			}
		}
		refresh_network(state);
		if (failed) {
			status_from_job(state, true, "Scan failed");
		} else {
			char msg[64];
			snprintf(msg, sizeof(msg), "%d network(s) in range", state->net_count);
			set_status(state, msg, false);
		}
		break;
	case JOB_ADD:
		refresh_network(state);
		if (failed) {
			status_from_job(state, true, "Could not add that network");
		} else {
			char msg[128];
			snprintf(msg, sizeof(msg), "Saved \"%s\"%s", state->job_ssid,
				state->wifi_declared_on ? " -- joining" :
					" -- turn WiFi on with w");
			set_status(state, msg, false);
		}
		break;
	case JOB_FORGET:
		refresh_network(state);
		status_from_job(state, failed, failed ? "Could not forget that" :
			"Forgotten");
		break;
	case JOB_APPLY:
		refresh_network(state);
		refresh_system(state);
		status_from_job(state, failed, failed ? "Apply failed" :
			"Applied");
		break;
	case JOB_NONE:
		break;
	}
}

static void net_scan(struct novi_settings *state) {
	if (state->wifi_iface[0] == '\0') {
		set_status(state, "No wireless interface on this machine", true);
		return;
	}
	char *const argv[] = {
		(char *)"novi-wifi", (char *)"scan", (char *)"--tsv", NULL,
	};
	if (job_start(state, JOB_SCAN, NOVI_WIFI_BIN, argv, NULL, NULL)) {
		set_status(state, "Scanning...", false);
	}
}

static void net_toggle_wifi(struct novi_settings *state) {
	const char *next = state->wifi_declared_on ? "off" : "on";
	char *const set_argv[] = {
		(char *)"novi-state", (char *)"set", (char *)"network.wifi",
		(char *)next, NULL,
	};
	if (run_novi_state(set_argv) != 0) {
		set_status(state, "Could not write system.conf", true);
		return;
	}
	/* Applying it restarts the supplicant, which takes long enough to
	 * be worth not freezing the window for. */
	char *const apply_argv[] = { (char *)"novi-state", (char *)"apply", NULL };
	if (job_start(state, JOB_APPLY, NOVI_STATE_BIN, apply_argv, NULL, NULL)) {
		set_status(state, state->wifi_declared_on ?
			"Turning WiFi off..." : "Turning WiFi on...", false);
	}
}

static void net_forget(struct novi_settings *state) {
	if (state->net_count == 0) {
		return;
	}
	struct net_entry *e = &state->nets[state->net_selected];
	if (!e->saved) {
		set_status(state, "Nothing saved for that network", true);
		return;
	}
	char ssid[SSID_MAX + 1];
	snprintf(ssid, sizeof(ssid), "%s", e->ssid);
	char *const argv[] = {
		(char *)"novi-wifi", (char *)"forget", ssid, NULL,
	};
	job_start(state, JOB_FORGET, NOVI_WIFI_BIN, argv, NULL, ssid);
}

static void pass_clear(struct novi_settings *state) {
	explicit_bzero(state->pass, sizeof(state->pass));
	state->pass_len = 0;
	state->pass_prompt = false;
	state->pass_ssid[0] = '\0';
}

static void net_activate(struct novi_settings *state) {
	if (state->net_count == 0) {
		set_status(state, "Nothing here yet -- press s to scan", false);
		return;
	}
	struct net_entry *e = &state->nets[state->net_selected];
	if (e->connected) {
		set_status(state, "Already connected to this one", false);
		return;
	}
	if (e->saved) {
		/* The supplicant chooses among the networks it knows; there is
		 * no "connect to this one" to issue that would not be a second
		 * opinion about which network the machine should be on. Say
		 * that rather than pretending to do something. */
		set_status(state, state->wifi_declared_on ?
			"Saved -- the supplicant joins it when it is in range" :
			"Saved -- turn WiFi on with w", false);
		return;
	}
	state->pass_prompt = true;
	snprintf(state->pass_ssid, sizeof(state->pass_ssid), "%s", e->ssid);
	explicit_bzero(state->pass, sizeof(state->pass));
	state->pass_len = 0;
	set_status(state, NULL, false);
}

static void net_submit_pass(struct novi_settings *state) {
	if (state->pass_len < 8) {
		set_status(state, "A WPA passphrase is at least 8 characters", true);
		return;
	}
	char ssid[SSID_MAX + 1];
	snprintf(ssid, sizeof(ssid), "%s", state->pass_ssid);
	char *const argv[] = {
		(char *)"novi-wifi", (char *)"add", ssid, (char *)"--stdin", NULL,
	};
	if (job_start(state, JOB_ADD, NOVI_WIFI_BIN, argv, state->pass, ssid)) {
		set_status(state, "Saving...", false);
	}
	/* Wiped whether or not the job started: it is already down the
	 * pipe if it did, and there is no reason for it to stay here if it
	 * did not. */
	pass_clear(state);
}

static const char *FIELD_LABELS[FIELD_COUNT] = {
	"New password", "Confirm new password",
};

static const pixman_color_t TEXT_PIX = {
	.red = 0xe000, .green = 0xe000, .blue = 0xf000, .alpha = 0xffff,
};
static const pixman_color_t LABEL_PIX = {
	.red = 0x8a00, .green = 0x8a00, .blue = 0xa000, .alpha = 0xffff,
};
static const pixman_color_t ERROR_PIX = {
	.red = 0xe000, .green = 0x8a00, .blue = 0x8a00, .alpha = 0xffff,
};
static const pixman_color_t SUCCESS_PIX = {
	.red = 0x8a00, .green = 0xe000, .blue = 0xa000, .alpha = 0xffff,
};
static const pixman_color_t ACCENT_PIX = {
	.red = 0x8a00, .green = 0xb400, .blue = 0xf800, .alpha = 0xffff,
};

static void render_sidebar(struct novi_settings *state, uint32_t *px,
		uint32_t stride_px, pixman_image_t *dest) {
	uint32_t w = state->width, h = state->height;
	draw_rect(px, stride_px, w, h, 0, 0, SIDEBAR_WIDTH, (int)h, SIDEBAR_BG_COLOR);
	draw_rect(px, stride_px, w, h, SIDEBAR_WIDTH - 1, 0, 1, (int)h,
		FIELD_BORDER_COLOR);

	for (int i = 0; i < PANEL_COUNT; i++) {
		int y = 56 + i * 38;
		if (i == state->panel) {
			draw_rect(px, stride_px, w, h, 0, y - 6, SIDEBAR_WIDTH - 1,
				32, ROW_SELECTED_COLOR);
			/* A 3px accent rail on the active entry -- the same
			 * "one accent, used sparingly" rule GUI-DESIGN-LANGUAGE.md
			 * sets for the rest of this desktop. */
			draw_rect(px, stride_px, w, h, 0, y - 6, 3, 32, ACCENT_COLOR);
		}
		novi_text_draw(dest, state->font_small, 24,
			y + state->font_small->ascent, PANEL_NAMES[i],
			i == state->panel ? TEXT_PIX : LABEL_PIX);
	}
}

static void render_account(struct novi_settings *state, uint32_t *px,
		uint32_t stride_px, pixman_image_t *dest) {
	uint32_t w = state->width, h = state->height;

	novi_text_draw(dest, state->font, CONTENT_X, 24 + state->font->ascent,
		"Account", TEXT_PIX);

	int field_y[FIELD_COUNT] = {80, 160};
	for (int i = 0; i < FIELD_COUNT; i++) {
		novi_text_draw(dest, state->font_small, FIELD_X,
			field_y[i] + state->font_small->ascent, FIELD_LABELS[i], LABEL_PIX);
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
		novi_text_draw(dest, state->font_small, FIELD_X,
			252 + state->font_small->ascent, state->status,
			state->status_is_error ? ERROR_PIX : SUCCESS_PIX);
	} else {
		novi_text_draw(dest, state->font_small, FIELD_X,
			252 + state->font_small->ascent,
			"Tab to switch fields, Enter to save", LABEL_PIX);
	}

	/* Said on screen, not just in a code comment: a password hash does
	 * not belong in a world-readable, git-committable document, so this
	 * one panel deliberately does NOT write system.conf. Leaving that
	 * unexplained would look like the System panel simply hadn't gotten
	 * to it yet. */
	novi_text_draw(dest, state->font_small, FIELD_X,
		(int)h - 40 + state->font_small->ascent,
		"Stored in /etc/shadow, not system.conf (secrets stay 0600)",
		LABEL_PIX);
}

static void render_network(struct novi_settings *state, uint32_t *px,
		uint32_t stride_px, pixman_image_t *dest) {
	uint32_t w = state->width, h = state->height;

	novi_text_draw(dest, state->font, CONTENT_X, 24 + state->font->ascent,
		"Network", TEXT_PIX);

	/* The subtitle is the machine's actual situation in one line:
	 * which radio, and what it is doing. "no wireless interface" is a
	 * real and common answer on the machines this boots on, and saying
	 * it is better than an empty list that looks broken. */
	char sub[192];
	if (state->wifi_iface[0] == '\0') {
		snprintf(sub, sizeof(sub), "no wireless interface on this machine");
	} else if (state->wifi_ssid[0] != '\0' &&
			strcmp(state->wifi_state, "COMPLETED") == 0) {
		snprintf(sub, sizeof(sub), "%s  connected to \"%s\"%s%s",
			state->wifi_iface, state->wifi_ssid,
			state->wifi_ip[0] != '\0' ? "  " : "", state->wifi_ip);
	} else if (state->wifi_state[0] != '\0') {
		snprintf(sub, sizeof(sub), "%s  %s", state->wifi_iface, state->wifi_state);
	} else {
		snprintf(sub, sizeof(sub), "%s  supplicant not running",
			state->wifi_iface);
	}
	novi_text_draw(dest, state->font_small, CONTENT_X,
		52 + state->font_small->ascent, sub, LABEL_PIX);

	int y = 84;

	/* The declared key, shown here as well as in System. Two views of
	 * one value, never two values: this reads network.wifi through
	 * novi-state and writes it through novi-state set, exactly as the
	 * System panel does. */
	novi_text_draw(dest, state->font_small, CONTENT_X,
		y + state->font_small->ascent, "network.wifi", LABEL_PIX);
	const char *declared = state->wifi_declared_on ? "on" : "off";
	int dw = novi_text_width(state->font_small, declared);
	novi_text_draw(dest, state->font_small,
		CONTENT_X + FIELD_WIDTH - dw - 8, y + state->font_small->ascent,
		declared, state->wifi_declared_on ? ACCENT_PIX : LABEL_PIX);
	y += ROW_HEIGHT + 4;
	draw_rect(px, stride_px, w, h, CONTENT_X, y, FIELD_WIDTH, 1,
		FIELD_BORDER_COLOR);
	y += 10;

	if (state->pass_prompt) {
		char prompt[128];
		snprintf(prompt, sizeof(prompt), "Passphrase for \"%s\"",
			state->pass_ssid);
		novi_text_draw(dest, state->font_small, CONTENT_X,
			y + state->font_small->ascent, prompt, TEXT_PIX);
		int box_y = y + 24;
		draw_rect(px, stride_px, w, h, CONTENT_X, box_y, FIELD_WIDTH,
			FIELD_HEIGHT, FIELD_BG_COLOR);
		draw_rect_border(px, stride_px, w, h, CONTENT_X, box_y, FIELD_WIDTH,
			FIELD_HEIGHT, FIELD_BORDER_FOCUS_COLOR);
		int dots_x = CONTENT_X + 12;
		int dots_y = box_y + (FIELD_HEIGHT - DOT_SIZE) / 2;
		/* Same fixed-per-character dots as the Account panel, and
		 * clamped to the box: a 63-character passphrase would
		 * otherwise draw straight through the window's edge. */
		int max_dots = (FIELD_WIDTH - 24) / (DOT_SIZE + DOT_GAP);
		for (size_t d = 0; d < state->pass_len && (int)d < max_dots; d++) {
			draw_rect(px, stride_px, w, h,
				dots_x + (int)d * (DOT_SIZE + DOT_GAP), dots_y,
				DOT_SIZE, DOT_SIZE, DOT_COLOR);
		}
		novi_text_draw(dest, state->font_small, CONTENT_X,
			box_y + FIELD_HEIGHT + 14 + state->font_small->ascent,
			"Enter joins, Esc cancels", LABEL_PIX);
	} else {
		for (int i = 0; i < state->net_count; i++) {
			struct net_entry *e = &state->nets[i];
			int ry = y + i * ROW_HEIGHT;
			if (ry + ROW_HEIGHT > (int)h - 46) {
				break;
			}
			if (i == state->net_selected) {
				draw_rect(px, stride_px, w, h, CONTENT_X - 8, ry - 3,
					FIELD_WIDTH + 16, ROW_HEIGHT, ROW_SELECTED_COLOR);
			}
			novi_text_draw(dest, state->font_small, CONTENT_X,
				ry + state->font_small->ascent, e->ssid,
				i == state->net_selected ? TEXT_PIX : LABEL_PIX);

			/* Right-hand column, right-aligned: signal if it is on the
			 * air, and the word that says what this row IS -- saved,
			 * or the one we are on. */
			char right[48];
			if (e->connected) {
				snprintf(right, sizeof(right), "connected");
			} else if (e->seen && e->saved) {
				snprintf(right, sizeof(right), "saved  %d dBm", e->signal);
			} else if (e->seen) {
				snprintf(right, sizeof(right), "%d dBm", e->signal);
			} else {
				snprintf(right, sizeof(right), "saved");
			}
			int rw = novi_text_width(state->font_small, right);
			novi_text_draw(dest, state->font_small,
				CONTENT_X + FIELD_WIDTH - rw - 8, ry + state->font_small->ascent,
				right, e->connected ? SUCCESS_PIX :
					(i == state->net_selected ? TEXT_PIX : LABEL_PIX));
		}
		if (state->net_count == 0) {
			novi_text_draw(dest, state->font_small, CONTENT_X,
				y + state->font_small->ascent,
				state->wifi_iface[0] != '\0' ?
					"No networks yet -- press s to scan" :
					"Nothing to show without a radio", LABEL_PIX);
		}
	}

	int footer_y = (int)h - 40;
	if (state->status != NULL) {
		novi_text_draw(dest, state->font_small, CONTENT_X,
			footer_y + state->font_small->ascent, state->status,
			state->status_is_error ? ERROR_PIX : SUCCESS_PIX);
	} else {
		novi_text_draw(dest, state->font_small, CONTENT_X,
			footer_y + state->font_small->ascent,
			"s scans, Enter joins, d forgets, w toggles WiFi", LABEL_PIX);
	}
}

static void render_system(struct novi_settings *state, uint32_t *px,
		uint32_t stride_px, pixman_image_t *dest) {
	uint32_t w = state->width, h = state->height;

	novi_text_draw(dest, state->font, CONTENT_X, 24 + state->font->ascent,
		"System", TEXT_PIX);
	/* Naming the file on screen is the point, not decoration: the user
	 * should be able to see that this panel and `$EDITOR` are aimed at
	 * the same place. */
	novi_text_draw(dest, state->font_small, CONTENT_X,
		52 + state->font_small->ascent, STATE_FILE, LABEL_PIX);

	int list_y = 84;
	int drifted = 0;
	for (int i = 0; i < state->entry_count; i++) {
		struct state_entry *e = &state->entries[i];
		int y = list_y + i * ROW_HEIGHT;
		if (y + ROW_HEIGHT > (int)h - 46) {
			break;
		}
		if (i == state->selected) {
			draw_rect(px, stride_px, w, h, CONTENT_X - 8, y - 3,
				FIELD_WIDTH + 16, ROW_HEIGHT, ROW_SELECTED_COLOR);
		}
		novi_text_draw(dest, state->font_small, CONTENT_X,
			y + state->font_small->ascent, e->key,
			i == state->selected ? TEXT_PIX : LABEL_PIX);

		/* Value right-aligned, drifted values in the accent colour with
		 * a marker -- "declared X, actually something else" is
		 * information no other desktop's settings app can show at all,
		 * so it gets the emphasis. */
		int val_w = novi_text_width(state->font_small, e->value);
		int val_x = CONTENT_X + FIELD_WIDTH - val_w - 8;
		novi_text_draw(dest, state->font_small, val_x,
			y + state->font_small->ascent, e->value,
			e->drifted ? ACCENT_PIX : (i == state->selected ? TEXT_PIX : LABEL_PIX));
		if (e->drifted) {
			drifted++;
			novi_text_draw(dest, state->font_small, val_x - 18,
				y + state->font_small->ascent, "*", ACCENT_PIX);
		}
	}

	int footer_y = (int)h - 40;
	if (state->status != NULL) {
		novi_text_draw(dest, state->font_small, CONTENT_X,
			footer_y + state->font_small->ascent, state->status,
			state->status_is_error ? ERROR_PIX : SUCCESS_PIX);
	} else if (drifted > 0) {
		char buf[96];
		snprintf(buf, sizeof(buf),
			"* %d pending -- Enter applies them", drifted);
		novi_text_draw(dest, state->font_small, CONTENT_X,
			footer_y + state->font_small->ascent, buf, ACCENT_PIX);
	} else {
		novi_text_draw(dest, state->font_small, CONTENT_X,
			footer_y + state->font_small->ascent,
			"Space toggles, Enter applies", LABEL_PIX);
	}
}

static void render(struct novi_settings *state, uint32_t *px, uint32_t stride_px) {
	uint32_t w = state->width, h = state->height;
	draw_rect(px, stride_px, w, h, 0, 0, (int)w, (int)h, BG_COLOR);

	pixman_image_t *dest = pixman_image_create_bits_no_clear(
		PIXMAN_a8r8g8b8, (int)w, (int)h, px, (int)stride_px * 4);

	render_sidebar(state, px, stride_px, dest);
	switch (state->panel) {
	case PANEL_NETWORK: render_network(state, px, stride_px, dest); break;
	case PANEL_SYSTEM:  render_system(state, px, stride_px, dest);  break;
	default:            render_account(state, px, stride_px, dest); break;
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

/* Copies rather than storing the pointer. Every caller in the Account
 * and System panels passes a string literal, which would have been
 * fine forever; the Network panel reports what a child process just
 * said, and that lives in a buffer the next job overwrites. One
 * function, one lifetime rule. NULL clears it. */
static void set_status(struct novi_settings *state, const char *msg, bool is_error) {
	if (msg == NULL) {
		state->status = NULL;
		state->status_is_error = false;
		return;
	}
	snprintf(state->status_buf, sizeof(state->status_buf), "%s", msg);
	state->status = state->status_buf;
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
	(void)kb; (void)serial; (void)surface; (void)keys;
	/* Regaining focus is the moment the user is most likely to have
	 * just edited system.conf somewhere else -- alt-tab to a terminal,
	 * change a line, come back. Re-reading here is what makes "the GUI
	 * and the editor are looking at one document" true in practice
	 * rather than only after someone discovers the reload key. */
	struct novi_settings *state = data;
	if (state->panel == PANEL_SYSTEM) {
		refresh_system(state);
		surface_draw_frame(state);
	} else if (state->panel == PANEL_NETWORK) {
		refresh_network(state);
		surface_draw_frame(state);
	}
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

	/* Left/Right switch panels from anywhere. Tab is already spoken for
	 * inside the Account form, so the sidebar needs its own key rather
	 * than overloading that one. */
	if (sym == XKB_KEY_Left || sym == XKB_KEY_Right) {
		state->panel = sym == XKB_KEY_Right ?
			(state->panel + 1) % PANEL_COUNT :
			(state->panel + PANEL_COUNT - 1) % PANEL_COUNT;
		set_status(state, NULL, false);
		if (state->panel == PANEL_SYSTEM) {
			/* Re-read on every entry to the panel: the file may have
			 * been edited in a terminal since it was last shown, and
			 * showing a stale view would quietly recreate exactly the
			 * two-sources-of-truth problem this panel exists to end. */
			refresh_system(state);
		} else if (state->panel == PANEL_NETWORK) {
			pass_clear(state);
			refresh_network(state);
		}
		surface_draw_frame(state);
		return;
	}

	if (state->panel == PANEL_NETWORK) {
		if (state->pass_prompt) {
			/* A modal prompt, so it eats every key it can use before
			 * the list bindings below get a look -- otherwise `s` in a
			 * passphrase would start a scan. */
			if (sym == XKB_KEY_Escape) {
				pass_clear(state);
				set_status(state, NULL, false);
			} else if (sym == XKB_KEY_Return || sym == XKB_KEY_KP_Enter) {
				net_submit_pass(state);
			} else if (sym == XKB_KEY_BackSpace) {
				if (state->pass_len > 0) {
					state->pass[--state->pass_len] = '\0';
				}
			} else if (sym >= 32 && sym < 127) {
				if (state->pass_len < PASS_MAX) {
					state->pass[state->pass_len++] = (char)sym;
					state->pass[state->pass_len] = '\0';
				}
			}
			surface_draw_frame(state);
			return;
		}
		switch (sym) {
		case XKB_KEY_Up:
			if (state->net_selected > 0) {
				state->net_selected--;
			}
			set_status(state, NULL, false);
			break;
		case XKB_KEY_Down:
			if (state->net_selected + 1 < state->net_count) {
				state->net_selected++;
			}
			set_status(state, NULL, false);
			break;
		case XKB_KEY_s:
		case XKB_KEY_S:
			net_scan(state);
			break;
		case XKB_KEY_w:
		case XKB_KEY_W:
			net_toggle_wifi(state);
			break;
		case XKB_KEY_d:
		case XKB_KEY_D:
		case XKB_KEY_Delete:
			net_forget(state);
			break;
		case XKB_KEY_r:
		case XKB_KEY_R:
			refresh_network(state);
			set_status(state, "Refreshed", false);
			break;
		case XKB_KEY_Return:
		case XKB_KEY_KP_Enter:
			net_activate(state);
			break;
		default:
			break;
		}
		surface_draw_frame(state);
		return;
	}

	if (state->panel == PANEL_SYSTEM) {
		switch (sym) {
		case XKB_KEY_Up:
			if (state->selected > 0) {
				state->selected--;
			}
			set_status(state, NULL, false);
			break;
		case XKB_KEY_Down:
			if (state->selected + 1 < state->entry_count) {
				state->selected++;
			}
			set_status(state, NULL, false);
			break;
		case XKB_KEY_space:
			toggle_selected(state);
			break;
		case XKB_KEY_Return:
		case XKB_KEY_KP_Enter:
			apply_state(state);
			break;
		case XKB_KEY_r:
		case XKB_KEY_R:
			refresh_system(state);
			set_status(state, "Reloaded from disk", false);
			break;
		default:
			break;
		}
		surface_draw_frame(state);
		return;
	}

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
	state.job_fd = -1;   /* 0 is stdin, and a zeroed struct would poll it */
	state.width = WINDOW_WIDTH;
	/* Load the document up front so the System panel is correct the
	 * first time it's shown, not one keystroke later. */
	refresh_system(&state);
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

	/* The event loop polls two things, and that is the whole reason it
	 * is written out rather than being wl_display_dispatch() in a
	 * while: a WiFi scan is a radio doing physics for several seconds,
	 * and the window must keep drawing while it happens. Every other
	 * subprocess this app runs is instant and still runs synchronously.
	 *
	 * The prepare_read / read_events dance is libwayland's own
	 * protocol for waiting on the display fd yourself. Getting it wrong
	 * is a hang, so: prepare_read until it succeeds (dispatching what
	 * is already queued in between), flush, poll, then either read the
	 * events or cancel the read -- cancel on EVERY path that does not
	 * read, including a poll error, or the next prepare_read blocks
	 * forever. */
	while (state.running) {
		while (wl_display_prepare_read(state.display) != 0) {
			if (wl_display_dispatch_pending(state.display) < 0) {
				state.running = false;
				break;
			}
		}
		if (!state.running) {
			break;
		}
		if (wl_display_flush(state.display) < 0 && errno != EAGAIN) {
			wl_display_cancel_read(state.display);
			break;
		}

		struct pollfd pfds[2];
		nfds_t n = 1;
		pfds[0].fd = wl_display_get_fd(state.display);
		pfds[0].events = POLLIN;
		pfds[0].revents = 0;
		if (state.job != JOB_NONE && state.job_fd >= 0) {
			pfds[1].fd = state.job_fd;
			pfds[1].events = POLLIN;
			pfds[1].revents = 0;
			n = 2;
		}

		int pr = poll(pfds, n, -1);
		if (pr < 0) {
			wl_display_cancel_read(state.display);
			if (errno == EINTR) {
				continue;
			}
			break;
		}

		if (pfds[0].revents & (POLLIN | POLLHUP | POLLERR)) {
			if (wl_display_read_events(state.display) < 0) {
				break;
			}
		} else {
			wl_display_cancel_read(state.display);
		}
		if (wl_display_dispatch_pending(state.display) < 0) {
			break;
		}

		/* POLLHUP as well as POLLIN: the child exiting closes the pipe,
		 * and on a job that printed nothing that is the only event
		 * there will ever be. Waiting for POLLIN alone would leave the
		 * job hanging and the window saying "Scanning..." forever. */
		if (n == 2 && (pfds[1].revents & (POLLIN | POLLHUP | POLLERR))) {
			if (job_pump(&state)) {
				surface_draw_frame(&state);
			}
		}
	}

	if (state.job_fd >= 0) {
		close(state.job_fd);
	}
	explicit_bzero(state.pass, sizeof(state.pass));
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
