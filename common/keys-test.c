/* ============================================================
 * keys-test.c — the config file, checked without a desktop
 *
 * RFC 0037. Built and run by `make -C common check`, which
 * scripts/lint.sh runs. It links the REAL loader, for the reason
 * theme-test.c and notifications-test.c do: a test with its own copy
 * of the parser tests the copy.
 *
 * Everything interesting here is a thing a running desktop cannot
 * show you. A machine with a well-formed keys.conf exercises one path;
 * the paths that matter are the misspelled modifier, the action this
 * build has never heard of, the line that rebinds one shortcut onto
 * another's key, and the file that is not there at all -- and each of
 * those has a wrong answer that looks exactly like a working desktop
 * until the moment somebody presses the key.
 * ============================================================ */
#include "keys.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int checks = 0;
static int failures = 0;

static void ok(bool cond, const char *what) {
	checks++;
	if (!cond) {
		failures++;
		fprintf(stderr, "FAIL: %s\n", what);
	}
}

static const struct novi_binding *row(const struct novi_keys *k,
		const char *name) {
	for (size_t i = 0; i < NOVI_BINDINGS_COUNT; i++) {
		if (strcmp(k->v[i].name, name) == 0) {
			return &k->v[i];
		}
	}
	return NULL;
}

static const char *row_text(const struct novi_keys *k, const char *name) {
	for (size_t i = 0; i < NOVI_BINDINGS_COUNT; i++) {
		if (strcmp(k->v[i].name, name) == 0) {
			return k->text[i];
		}
	}
	return "";
}

static const char *PATH = "/tmp/novi-keys-test.conf";

static void write_conf(const char *body) {
	FILE *f = fopen(PATH, "w");
	if (f == NULL) {
		fprintf(stderr, "cannot write %s\n", PATH);
		exit(1);
	}
	fputs(body, f);
	fclose(f);
}

static void load(struct novi_keys *k, const char *body) {
	write_conf(body);
	novi_keys_defaults(k);
	novi_keys_load(k, PATH);
}

int main(void) {
	struct novi_keys k;
	char buf[NOVI_KEYS_TEXT_MAX];

	/* ── 1. the defaults stand on their own ──────────────────────── */
	novi_keys_defaults(&k);
	ok(row(&k, "window.terminal")->sym == XKB_KEY_Return,
		"the compiled default is there before any file is read");
	novi_keys_defaults(&k);
	ok(novi_keys_load(&k, "/tmp/novi-keys-does-not-exist") == 0 &&
		k.overridden == 0 && k.unreadable == 0,
		"a missing file is not an error and changes nothing");
	ok(strcmp(row_text(&k, "window.terminal"), "Super + Return") == 0,
		"every row is rendered by the formatter, defaults included");

	/* EVERY row renders, and none of them renders as a keysym name.
	 * The hand-written strings this replaced were deleted only because
	 * the formatter reproduced all of them; nothing would catch it
	 * silently regressing to "XF86AudioRaiseVolume" but this. */
	for (size_t i = 0; i < NOVI_BINDINGS_COUNT; i++) {
		ok(k.text[i][0] != '\0', "a row renders to something");
		ok(strstr(k.text[i], "XF86") == NULL,
			"no row renders as a raw keysym name");
		ok(strstr(k.text[i], "_") == NULL,
			"no row renders with an underscore in it");
	}

	/* ── 2. an override moves the binding AND the text ───────────── */
	load(&k, "window.terminal = Super+Shift+T\n");
	ok(k.overridden == 1, "one line, one override");
	ok(row(&k, "window.terminal")->sym == XKB_KEY_t &&
		row(&k, "window.terminal")->mods == (NOVI_MOD_LOGO | NOVI_MOD_SHIFT),
		"the binding moved");
	ok(strcmp(row_text(&k, "window.terminal"), "Super + Shift + T") == 0,
		"and so did the text the sheet shows -- a sheet that still said "
		"Super + Return would be the drift this whole feature is built to "
		"avoid");
	ok(row(&k, "window.close")->sym == XKB_KEY_q,
		"a row the file does not mention is untouched (the document is "
		"additive)");

	/* ── 3. `off` is a binding too ───────────────────────────────── */
	load(&k, "session.quit = off\n");
	ok(row(&k, "session.quit")->sym == XKB_KEY_NoSymbol,
		"off unbinds the row");
	ok(strcmp(row_text(&k, "session.quit"), "(unbound)") == 0,
		"and the sheet says so rather than showing a key that does nothing");
	ok(k.unreadable == 0, "off is not a parse failure");

	/* ── 4. lines this build cannot use ──────────────────────────── */
	load(&k,
		"# a comment\n"
		"\n"
		"window.terminal = Supper+Return\n"     /* misspelled modifier */
		"window.close = Super+Nonesuchkey\n"    /* no such keysym */
		"window.teleport = Super+T\n"           /* no such action */
		"this line has no equals sign\n"
		"window.cycle-next = Super+\n"          /* modifier, no key */
	);
	ok(k.unreadable == 5, "five lines, none of them usable");
	ok(k.overridden == 0, "and not one of them changed a binding");
	ok(row(&k, "window.terminal")->sym == XKB_KEY_Return &&
		row(&k, "window.close")->sym == XKB_KEY_q,
		"a line that cannot be parsed leaves ITS row alone -- refusing the "
		"whole file would take nineteen working shortcuts away over one typo");

	/* ── 5. two rows, one key ────────────────────────────────────── */
	/* The later row is DISABLED rather than left listed on a key it
	 * can never win: dispatch stops at its first match, so "first
	 * wins" is what the loop does anyway, and a sheet that goes on
	 * advertising the shadowed binding is a document that lies. */
	load(&k, "session.lock = Super+Q\n");
	ok(k.conflicts == 1, "the collision is counted");
	ok(row(&k, "window.close")->sym == XKB_KEY_q,
		"the row that was there first keeps the key");
	ok(row(&k, "session.lock")->sym == XKB_KEY_NoSymbol,
		"and the one that landed on it is unbound, not silently shadowed");
	ok(strcmp(row_text(&k, "session.lock"), "(unbound)") == 0,
		"which the sheet says");

	/* Two rows unbound do NOT collide with each other. */
	load(&k, "session.quit = off\nsession.lock = off\n");
	ok(k.conflicts == 0, "unbound rows do not collide with one another");

	/* ── 6. the nine-digit rows ──────────────────────────────────── */
	load(&k, "workspace.switch = Alt+1\n");
	ok(row(&k, "workspace.switch")->mods == NOVI_MOD_ALT &&
		row(&k, "workspace.switch")->sym == XKB_KEY_1,
		"a digit-range row can be moved by its modifiers");
	ok(strcmp(row_text(&k, "workspace.switch"), "Alt + 1…9") == 0,
		"and still renders as the nine keys it matches");
	load(&k, "workspace.switch = Alt+K\n");
	ok(k.unreadable == 1 && row(&k, "workspace.switch")->mods == NOVI_MOD_LOGO,
		"a digit-range row bound to a letter is refused -- it would match "
		"nine digits while claiming to be K");

	/* ── 7. spellings a person actually types ────────────────────── */
	unsigned m = 0;
	xkb_keysym_t sym = XKB_KEY_NoSymbol;
	ok(novi_keys_parse("super+q", &m, &sym) && m == NOVI_MOD_LOGO &&
		sym == XKB_KEY_q, "lowercase");
	ok(novi_keys_parse("SUPER+Q", &m, &sym) && sym == XKB_KEY_q,
		"uppercase gives the same keysym -- novi-shell compares through "
		"xkb_keysym_to_lower(), so a config that told them apart would be "
		"describing something that cannot happen");
	ok(novi_keys_parse("Win + Return", &m, &sym) && m == NOVI_MOD_LOGO &&
		sym == XKB_KEY_Return, "spaces around the plus, and Win for Super");
	ok(novi_keys_parse("Meta+Space", &m, &sym) && m == NOVI_MOD_ALT &&
		sym == XKB_KEY_space, "Meta is Alt");
	ok(novi_keys_parse("Super+.", &m, &sym) && sym == XKB_KEY_period,
		"the punctuation character, not its xkb name");
	ok(novi_keys_parse("Super+Enter", &m, &sym) && sym == XKB_KEY_Return,
		"Enter for Return");
	ok(novi_keys_parse("Print", &m, &sym) && m == NOVI_MOD_NONE &&
		sym == XKB_KEY_Print, "a key with no modifier at all");
	ok(!novi_keys_parse("", &m, &sym), "empty");
	ok(!novi_keys_parse("Super++Q", &m, &sym), "an empty component");
	ok(!novi_keys_parse("Ctrl+Q", &m, &sym),
		"Ctrl is refused rather than ignored: this compositor has no "
		"control modifier in its table, and accepting the word would bind "
		"the key to Q alone");

	/* ── 8. the formatter's own corners ──────────────────────────── */
	novi_keys_format(NOVI_MOD_SHIFT | NOVI_MOD_LOGO, XKB_KEY_1,
		NOVI_BIND_DIGIT_RANGE, buf, sizeof(buf));
	ok(strcmp(buf, "Super + Shift + 1…9") == 0,
		"modifiers render in one fixed order however they were written");
	novi_keys_format(NOVI_MOD_ALT, XKB_KEY_ISO_Left_Tab, 0, buf, sizeof(buf));
	ok(strcmp(buf, "Alt + Shift + Tab") == 0,
		"ISO_Left_Tab reads as Shift + Tab, which is the key people press");

	/* ── 9. the shipped file is a THIRD list ─────────────────────
	 *
	 * rootfs/etc/novi/keys.conf documents every action by name, with
	 * its default, all commented out. That is the only place a person
	 * learns what an action is called -- so a row added to the table
	 * without a line in that file is a shortcut nobody can rebind,
	 * and a line in that file for an action that no longer exists is
	 * a documented name that does nothing. Neither shows up anywhere
	 * else; novi-agent's VERBS learned this the same way.
	 */
	{
		FILE *f = fopen("rootfs/etc/novi/keys.conf", "r");
		ok(f != NULL, "the shipped keys.conf is where this expects it");
		if (f != NULL) {
			char body[16384];
			size_t n = fread(body, 1, sizeof(body) - 1, f);
			body[n] = '\0';
			fclose(f);
			for (size_t i = 0; i < NOVI_BINDINGS_COUNT; i++) {
				char needle[64];
				snprintf(needle, sizeof(needle), "# %s ", k.v[i].name);
				bool documented = strstr(body, needle) != NULL;
				if (!documented) {
					fprintf(stderr, "       (missing: %s)\n", k.v[i].name);
				}
				ok(documented, "every action is named in the shipped keys.conf");
			}
			/* And the other direction: every `# <word>.<word> =` line
			 * in the file names an action this build has. */
			int orphans = 0;
			for (char *p = body; (p = strstr(p, "# ")) != NULL; p += 2) {
				char name[64];
				size_t j = 0;
				char *q = p + 2;
				while (j + 1 < sizeof(name) && *q != '\0' &&
						(isalnum((unsigned char)*q) || *q == '.' || *q == '-')) {
					name[j++] = *q++;
				}
				name[j] = '\0';
				if (strchr(name, '.') == NULL) {
					continue;
				}
				while (*q == ' ') {
					q++;
				}
				if (*q != '=') {
					continue;  /* prose that happens to contain a dot */
				}
				if (row(&k, name) == NULL) {
					fprintf(stderr, "       (orphan: %s)\n", name);
					orphans++;
				}
			}
			ok(orphans == 0,
				"and every action the file names is one this build has");
		}
	}

	if (failures > 0) {
		fprintf(stderr, "keys: %d of %d checks FAILED\n", failures, checks);
		return 1;
	}
	printf("keys: %d checks passed\n", checks);
	return 0;
}
