/* common/theme.c — the live palette, and reading a theme file.
 *
 * RFC 0030. Every colour in this desktop was a compile-time constant
 * in common/theme.h, which made the palette correct and unchangeable:
 * altering one hex digit meant rebuilding ten binaries and reflashing
 * an image. This file is the smallest change that makes `display.theme
 * = <name>` a thing a person can set, without giving a theme file the
 * power to break a layout.
 *
 * WHAT A THEME MAY CHANGE IS COLOUR, AND ONLY COLOUR. Type, spacing
 * and radius stay compile-time in theme.h. §3 of the design language
 * exists to stop ad hoc numbers; a theme that can move a 12px gap to
 * 11 reintroduces exactly what it forbids, one file at a time, in a
 * place no reviewer looks.
 *
 * THE DEFAULTS ARE COMPILED IN. `novi_theme` below is the design
 * language's own palette, so a client that never calls
 * novi_theme_load(), or one whose theme file is missing, unreadable,
 * empty or garbage, draws exactly what it drew before this file
 * existed. There is no state in which this desktop has no colours --
 * which matters because the alternative failure is a black window with
 * black text and nothing to say why.
 */

#include "theme.h"

#include <ctype.h>
#include <stddef.h>
#include <sys/stat.h>
#include <stdio.h>
#include <stdbool.h>
#include <string.h>

struct novi_palette novi_theme = {
	.bg_base        = 0xff0a0a0fu,
	.bg_panel       = 0xff15161du,
	.bg_card        = 0xff1b1c26u,
	.bg_card_raised = 0xff232430u,

	.accent         = 0xff2dd4bfu,
	.accent_hover   = 0xff5eead4u,
	.accent_active  = 0xff14b8a6u,
	.accent_subtle  = 0xff17302cu,
	.text_on_accent = 0xff071310u,

	.text_primary   = 0xfff2f3f7u,
	.text_secondary = 0xffa3a7b7u,
	.text_muted     = 0xff6b6f80u,

	.border_subtle  = 0xff292b35u,
	.border_strong  = 0xff3a3d4au,

	.status_success = 0xff22c55eu,
	.status_warning = 0xfff59e0bu,
	.status_error    = 0xffef4444u,
};

/* Key name to field. A table rather than a twenty-branch `if` chain
 * for the usual reason, and one specific to this file: the theme
 * FORMAT is this list, so the parser and the documentation cannot
 * disagree about what a valid key is. */
static const struct {
	const char *key;
	size_t offset;
} FIELDS[] = {
	{ "bg.base",        offsetof(struct novi_palette, bg_base) },
	{ "bg.panel",       offsetof(struct novi_palette, bg_panel) },
	{ "bg.card",        offsetof(struct novi_palette, bg_card) },
	{ "bg.card-raised", offsetof(struct novi_palette, bg_card_raised) },
	{ "accent",         offsetof(struct novi_palette, accent) },
	{ "accent.hover",   offsetof(struct novi_palette, accent_hover) },
	{ "accent.active",  offsetof(struct novi_palette, accent_active) },
	{ "accent.subtle",  offsetof(struct novi_palette, accent_subtle) },
	{ "text.on-accent", offsetof(struct novi_palette, text_on_accent) },
	{ "text.primary",   offsetof(struct novi_palette, text_primary) },
	{ "text.secondary", offsetof(struct novi_palette, text_secondary) },
	{ "text.muted",     offsetof(struct novi_palette, text_muted) },
	{ "border.subtle",  offsetof(struct novi_palette, border_subtle) },
	{ "border.strong",  offsetof(struct novi_palette, border_strong) },
	{ "status.success", offsetof(struct novi_palette, status_success) },
	{ "status.warning", offsetof(struct novi_palette, status_warning) },
	{ "status.error",   offsetof(struct novi_palette, status_error) },
};
#define FIELD_COUNT ((int)(sizeof FIELDS / sizeof FIELDS[0]))

/* Parse `#rrggbb`, `rrggbb` or `#aarrggbb`.
 *
 * A six-digit value gets alpha 0xff, because that is what a person
 * writing a theme means and because the alternative -- a colour that
 * silently comes out fully transparent -- is a window that renders as
 * nothing at all with no error anywhere. Every token in this palette
 * except accent.subtle is opaque in practice; the eight-digit form is
 * there for the ones that are not.
 *
 * Returns 0 on anything it does not fully understand. Partial parses
 * are how "#2dd4b" becomes a colour nobody chose. */
static int parse_hex(const char *s, uint32_t *out)
{
	uint32_t v = 0;
	int n = 0;

	while (*s == '#' || isspace((unsigned char)*s))
		s++;
	for (; *s; s++, n++) {
		int d;
		if (*s >= '0' && *s <= '9')      d = *s - '0';
		else if (*s >= 'a' && *s <= 'f') d = *s - 'a' + 10;
		else if (*s >= 'A' && *s <= 'F') d = *s - 'A' + 10;
		else if (isspace((unsigned char)*s)) break;
		else return 0;
		if (n >= 8)
			return 0;
		v = (v << 4) | (uint32_t)d;
	}
	/* Trailing junk after whitespace is a typo, not a comment. */
	while (isspace((unsigned char)*s))
		s++;
	if (*s)
		return 0;

	if (n == 6)
		*out = 0xff000000u | v;
	else if (n == 8)
		*out = v;
	else
		return 0;
	return 1;
}

static void strip(char *s)
{
	char *e;
	while (*s && isspace((unsigned char)*s))
		memmove(s, s + 1, strlen(s));
	e = s + strlen(s);
	while (e > s && isspace((unsigned char)e[-1]))
		*--e = '\0';
}

/* Read one theme file into `p`. Returns 1 if the file was readable.
 *
 * An unknown key is IGNORED rather than refused, and a bad value
 * leaves that one token at its default. A theme file written against a
 * newer palette must not make an older client refuse to draw, and a
 * single mistyped colour must not cost you the other sixteen. */
static int load_file(const char *path, struct novi_palette *p)
{
	FILE *f = fopen(path, "re");
	char line[256];

	if (!f)
		return 0;
	while (fgets(line, sizeof line, f)) {
		char *eq, *key, *val;
		uint32_t v;
		int i;

		/* `#` starts a comment ONLY at the start of the trimmed
		 * line: it is also the first character of every colour
		 * value, so cutting at the first `#` anywhere would
		 * delete every value in the file. */
		key = line;
		strip(key);
		if (!*key || *key == '#')
			continue;

		eq = strchr(key, '=');
		if (!eq)
			continue;
		*eq = '\0';
		val = eq + 1;
		strip(key);
		strip(val);

		for (i = 0; i < FIELD_COUNT; i++) {
			if (strcmp(key, FIELDS[i].key) != 0)
				continue;
			if (parse_hex(val, &v))
				*(uint32_t *)((char *)p + FIELDS[i].offset) = v;
			break;
		}
	}
	fclose(f);
	return 1;
}

/* The name of the theme actually in force, or NULL. Static because the
 * only caller that wants it wants to print it, and handing out a
 * pointer into a heap allocation nobody frees is worse than 64 bytes
 * of bss. */
static char active_name[64];

/* A theme name becomes a path, so it is checked rather than trusted.
 * `..` survives a plain character filter because dots are legal in a
 * name -- the trap novi-mount's safe_name() records from the other
 * direction (RFC 0023). */
static bool name_ok(const char *name)
{
	size_t i;

	if (name == NULL || name[0] == '\0' || name[0] == '.' ||
	    strchr(name, '/') != NULL) {
		return false;
	}
	for (i = 0; name[i] != '\0'; i++) {
		if (!isalnum((unsigned char)name[i]) &&
		    name[i] != '-' && name[i] != '_' && name[i] != '.') {
			return false;
		}
	}
	return i < 64;
}

/* The compiled-in defaults as a value, so novi_theme_read() can start
 * from them without depending on what the caller is currently drawing
 * with. `novi_theme` itself is initialised from the same digits above;
 * they are the same palette written twice, which is the price of
 * having both a live global and a pure read. */
static const struct novi_palette BUILTIN = {
	.bg_base        = 0xff0a0a0fu,
	.bg_panel       = 0xff15161du,
	.bg_card        = 0xff1b1c26u,
	.bg_card_raised = 0xff232430u,
	.accent         = 0xff2dd4bfu,
	.accent_hover   = 0xff5eead4u,
	.accent_active  = 0xff14b8a6u,
	.accent_subtle  = 0xff17302cu,
	.text_on_accent = 0xff071310u,
	.text_primary   = 0xfff2f3f7u,
	.text_secondary = 0xffa3a7b7u,
	.text_muted     = 0xff6b6f80u,
	.border_subtle  = 0xff292b35u,
	.border_strong  = 0xff3a3d4au,
	.status_success = 0xff22c55eu,
	.status_warning = 0xfff59e0bu,
	.status_error   = 0xffef4444u,
};

bool novi_theme_read(const char *name, struct novi_palette *out)
{
	char path[256];

	/* Starts from the BUILT-IN palette, not the live one: reading
	 * theme X must give the same answer whichever theme happens to be
	 * running, or a picker's swatches would shift as you switched. */
	*out = BUILTIN;
	if (!name_ok(name)) {
		return false;
	}
	if ((size_t)snprintf(path, sizeof path, "%s/%s.theme",
			     NOVI_THEME_DIR, name) >= sizeof path) {
		return false;
	}
	return load_file(path, out) != 0;
}

const char *novi_theme_load(void)
{
	char name[64], path[256];
	struct novi_palette next = novi_theme;
	FILE *f;

	/* The name comes from the file novi-state's converger published,
	 * not from an environment variable: a client started later --
	 * from the launcher, from a terminal, by novi-shell -- has to be
	 * able to find out, and an exported variable only reaches
	 * children of whoever had it. Same argument as
	 * /run/novi/network.device (RFC 0009). */
	f = fopen(NOVI_THEME_ACTIVE, "re");
	if (!f)
		return NULL;
	if (!fgets(name, sizeof name, f)) {
		fclose(f);
		return NULL;
	}
	fclose(f);
	strip(name);

	if (!name_ok(name))
		return NULL;

	if ((size_t)snprintf(path, sizeof path, "%s/%s.theme",
			     NOVI_THEME_DIR, name) >= sizeof path)
		return NULL;

	/* Parse into a COPY and commit only on success. A half-applied
	 * theme -- new background, old text colour -- is the one outcome
	 * worse than not switching at all, because it can be
	 * unreadable. */
	if (!load_file(path, &next))
		return NULL;

	novi_theme = next;
	snprintf(active_name, sizeof active_name, "%s", name);
	return active_name;
}

/* mtime and size of the published name at the last successful load.
 * Two fields rather than one because a same-second rewrite is exactly
 * what `novi-state apply` does -- set, then apply, inside a second --
 * and mtime alone would miss it whenever the two names are the same
 * length. Size is not a strong check either; together they catch every
 * case that matters here, and the cost of a false negative is a stale
 * palette until the next change rather than anything worse. */
static struct timespec last_mtime;
static off_t last_size = -1;

bool novi_theme_reload(void)
{
	struct stat st;

	if (stat(NOVI_THEME_ACTIVE, &st) != 0) {
		return false;
	}
	if (last_size == st.st_size &&
	    last_mtime.tv_sec == st.st_mtim.tv_sec &&
	    last_mtime.tv_nsec == st.st_mtim.tv_nsec) {
		return false;
	}
	/* Record BEFORE loading, not after: a theme file that fails to
	 * parse would otherwise be retried on every single tick, which
	 * turns a typo into a busy loop opening a file 86,400 times a
	 * day. One attempt per change is the right number. */
	last_mtime = st.st_mtim;
	last_size = st.st_size;
	return novi_theme_load() != NULL;
}
