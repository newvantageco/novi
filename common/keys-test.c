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
#include <errno.h>
#include <string.h>
#include <unistd.h>

static int checks = 0;
static int failures = 0;

static void write_file(const char *path, const char *text) {
	FILE *f = fopen(path, "w");
	if (f != NULL) {
		fputs(text, f);
		fclose(f);
	}
}

/* Reads the whole file so a check can assert on what is NOT in it --
 * which is most of what a surgical edit is for. */
static char *read_file(const char *path) {
	FILE *f = fopen(path, "r");
	if (f == NULL) {
		return NULL;
	}
	static char buf[8192];
	size_t n = fread(buf, 1, sizeof buf - 1, f);
	fclose(f);
	buf[n] = '\0';
	char *copy = strdup(buf);
	return copy;
}

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

	/* NO TWO COMPILED ROWS SHARE A BINDING. The collision rule below
	 * only runs when there is a file to read, so a pair of defaults
	 * that landed on one key would not be caught there -- and would
	 * ship as a shortcut that silently never fires on every machine,
	 * with no config file involved at all. */
	novi_keys_defaults(&k);
	for (size_t i = 0; i < NOVI_BINDINGS_COUNT; i++) {
		for (size_t j = i + 1; j < NOVI_BINDINGS_COUNT; j++) {
			bool same = k.v[i].sym == k.v[j].sym && k.v[i].mods == k.v[j].mods;
			if (same) {
				fprintf(stderr, "       (%s and %s both want %s)\n",
					k.v[i].name, k.v[j].name, k.text[i]);
			}
			ok(!same, "no two compiled bindings collide");
		}
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

	/* ── 8b. the way back out ────────────────────────────────────
	 * A file read at startup can lock somebody out of their own
	 * desktop, so `novi.keys=off` on the kernel command line ignores
	 * it -- novi.state=off's argument, applied to the other file a
	 * machine reads before anybody can type. Matched as a WHOLE WORD,
	 * because a substring match would be switched off by a kernel
	 * parameter that merely contains it. */
	ok(novi_keys_cmdline_off("ro quiet novi.keys=off console=ttyS0"),
		"the escape hatch is recognised among other parameters");
	ok(novi_keys_cmdline_off("novi.keys=off"), "on its own");
	ok(novi_keys_cmdline_off("quiet novi.keys=off"), "at the end");
	ok(!novi_keys_cmdline_off("ro quiet console=ttyS0"), "absent");
	ok(!novi_keys_cmdline_off("xnovi.keys=off"),
		"not a suffix of another parameter");
	ok(!novi_keys_cmdline_off("novi.keys=office"),
		"not a prefix of another value");
	ok(!novi_keys_cmdline_off("novi.keys=on"), "and not the opposite");

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

	/* ── Writing a binding back (RFC 0037 roadmap 1) ──────────────────
	 *
	 * The edit is surgical, and every property worth having is about
	 * what it does NOT touch. A rewrite from the parsed table would
	 * pass a test that only checked the new value was there.
	 */
	{
		char dir[] = "/tmp/novi-keys-XXXXXX";
		if (mkdtemp(dir) == NULL) {
			ok(false, "a temp directory for the writer checks");
		} else {
			char path[256];
			snprintf(path, sizeof path, "%s/keys.conf", dir);

			/* A file shaped like the shipped one: prose, commented
			 * examples, one live line, and indentation somebody
			 * chose. */
			const char *ORIGINAL =
				"# ============================================\n"
				"#  Novi - keyboard shortcuts\n"
				"# ============================================\n"
				"#\n"
				"#  ── Session ──────────────────────────────\n"
				"# session.lock        = Super+L\n"
				"# session.quit        = Alt+Escape\n"
				"\n"
				"  window.close = Super+Q\n"
				"find.themes = Super+T\n";
			write_file(path, ORIGINAL);

			ok(novi_keys_write(path, "window.terminal", "Super+Shift+T") == 0,
				"writing an action with no live line succeeds");
			char *got = read_file(path);
			ok(got != NULL && strstr(got, "window.terminal = Super+Shift+T\n") != NULL,
				"and the new line is in the file");
			/* THE COMMENTED EXAMPLES SURVIVE. The shipped keys.conf is
			 * 87 lines and every one is a comment, so a writer that
			 * matched through the `#` would rewrite an example in
			 * place and uncomment it -- a line of documentation
			 * becoming a setting without being asked. */
			ok(got != NULL && strstr(got, "# session.lock        = Super+L\n") != NULL,
				"a commented example is not matched and not disturbed");
			free(got);

			/* The case that actually bites, and the one the shipped
			 * file is made of: an action that exists ONLY as a
			 * commented example. A matcher that skipped the `#` would
			 * rewrite that line in place -- uncommenting it, in the
			 * middle of a prose block -- instead of appending. */
			ok(novi_keys_write(path, "session.lock", "Super+Escape") == 0,
				"writing an action that exists only as a comment succeeds");
			got = read_file(path);
			ok(got != NULL && strstr(got, "# session.lock        = Super+L\n") != NULL,
				"and leaves the commented example commented");
			ok(got != NULL && strstr(got, "\nsession.lock = Super+Escape\n") != NULL,
				"putting the real line at the end instead");
			ok(got != NULL && strstr(got, "#  ── Session ──────────────────────────────\n") != NULL,
				"the prose survives");
			ok(got != NULL && strstr(got, "\n\n") != NULL,
				"and so does the blank line");
			free(got);

			/* Replacing a live line keeps its indentation, the way
			 * state_set keeps a key's. */
			ok(novi_keys_write(path, "window.close", "Super+W") == 0,
				"replacing a live line succeeds");
			got = read_file(path);
			ok(got != NULL && strstr(got, "  window.close = Super+W\n") != NULL,
				"and keeps the indentation the line had");
			ok(got != NULL && strstr(got, "Super+Q") == NULL,
				"with the old binding gone");
			free(got);

			/* The whole point: what the loader reads back is what was
			 * written. A writer that produced a file the parser reads
			 * differently would pass every string check above. */
			struct novi_keys k;
			novi_keys_defaults(&k);
			novi_keys_load(&k, path);
			ok(k.unreadable == 0, "the file it wrote parses with no bad lines");
			for (size_t i = 0; i < NOVI_BINDINGS_COUNT; i++) {
				if (strcmp(k.v[i].name, "window.close") == 0) {
					ok(k.v[i].sym == XKB_KEY_w && k.v[i].mods == NOVI_MOD_LOGO,
						"and the loader reads back the binding that was written");
				}
			}

			ok(novi_keys_is_set(path, "window.close"),
				"is_set sees a live line");
			/* session.quit, because session.lock has a live line by
			 * now -- the block above put one there. An is_set check
			 * against an action this test has written is a check that
			 * cannot tell the two cases apart. */
			ok(!novi_keys_is_set(path, "session.quit"),
				"and does NOT see a commented one");
			ok(!novi_keys_is_set(path, "session.power-menu"),
				"nor an action the file never mentions");

			/* Removing is a delete, not a comment-out: a commented
			 * line is documentation and this has no business
			 * inventing any. */
			ok(novi_keys_write(path, "window.close", NULL) == 0,
				"removing a line succeeds");
			got = read_file(path);
			ok(got != NULL && strstr(got, "window.close") == NULL,
				"and the line is gone rather than commented out");
			ok(got != NULL && strstr(got, "# session.lock        = Super+L\n") != NULL,
				"with the commented examples still untouched");
			free(got);

			/* A DUPLICATE live line is resolved, because the loader
			 * resolves it last-wins: writing above a stale line that
			 * still overrides would leave the file saying one thing
			 * and the desktop doing another. */
			write_file(path, "find.themes = Super+T\nfind.themes = Super+Y\n");
			ok(novi_keys_write(path, "find.themes", "Super+Z") == 0,
				"writing over a duplicated action succeeds");
			got = read_file(path);
			ok(got != NULL && strstr(got, "Super+Y") == NULL,
				"and the second, still-winning line is removed");
			free(got);

			/* Refusals. Writing a line that does something other than
			 * what it says is worse than writing nothing -- the same
			 * argument the loader makes about an unknown modifier. */
			write_file(path, "find.themes = Super+T\n");
			ok(novi_keys_write(path, "no.such.action", "Super+X") == EINVAL,
				"an action this build does not have is refused");
			ok(novi_keys_write(path, "find.themes", "Ctrl+Q") == EINVAL,
				"a modifier this compositor does not have is refused");
			/* These two are refused by novi_keys_parse() before the
			 * writer's own guard ever sees them -- confirmed by
			 * deleting that guard and watching both still pass. They
			 * assert the BEHAVIOUR, which is what matters, and the
			 * guard stays so that a future parser accepting more
			 * cannot silently make one call write two lines. Said
			 * here because a check whose stated subject is not what
			 * makes it pass is the probe-that-cannot-fail mistake
			 * wearing a different hat. */
			ok(novi_keys_write(path, "find.themes", "Super+T\nfind.launcher = Super+X")
					== EINVAL,
				"a spec carrying a newline is refused, not written as two lines");
			ok(novi_keys_write(path, "find.themes", "Super+T # and this") == EINVAL,
				"and one carrying a comment character is refused");
			got = read_file(path);
			ok(got != NULL && strcmp(got, "find.themes = Super+T\n") == 0,
				"a refused write leaves the file byte for byte as it was");
			free(got);

			/* `off` is a binding, not an absence: it means this
			 * shortcut does nothing, which is different from
			 * inheriting the default. */
			ok(novi_keys_write(path, "session.quit", "off") == 0,
				"`off` is a writable binding");
			novi_keys_defaults(&k);
			novi_keys_load(&k, path);
			for (size_t i = 0; i < NOVI_BINDINGS_COUNT; i++) {
				if (strcmp(k.v[i].name, "session.quit") == 0) {
					ok(k.v[i].sym == XKB_KEY_NoSymbol,
						"and reads back as unbound");
				}
			}

			unlink(path);
			rmdir(dir);
		}
	}

	if (failures > 0) {
		fprintf(stderr, "keys: %d of %d checks FAILED\n", failures, checks);
		return 1;
	}
	printf("keys: %d checks passed\n", checks);
	return 0;
}
