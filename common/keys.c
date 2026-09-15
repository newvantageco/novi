/* keys.c — see keys.h. Parsing and rendering a binding, once. */
#include "keys.h"

#include <ctype.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>

#include <xkbcommon/xkbcommon.h>

/* Modifier words, and the aliases people actually type. "Meta" is Alt
 * on every layout this desktop will meet, and "Win"/"Cmd" are what the
 * key is labelled on the two keyboards most people own -- refusing
 * them would be pedantry aimed at the exact person this file is for. */
static const struct {
	const char *word;
	unsigned bit;
} MODS[] = {
	{ "super", NOVI_MOD_LOGO },
	{ "logo",  NOVI_MOD_LOGO },
	{ "win",   NOVI_MOD_LOGO },
	{ "cmd",   NOVI_MOD_LOGO },
	{ "alt",   NOVI_MOD_ALT },
	{ "meta",  NOVI_MOD_ALT },
	{ "shift", NOVI_MOD_SHIFT },
};

/* Punctuation and the friendlier spellings. xkb_keysym_from_name()
 * knows "period" and not ".", and a person writing a config file types
 * the character -- so these come first and everything else goes to
 * xkbcommon, which already knows every keysym there is. */
static const struct {
	const char *word;
	xkb_keysym_t sym;
} KEY_ALIASES[] = {
	{ ".",           XKB_KEY_period },
	{ ",",           XKB_KEY_comma },
	{ "/",           XKB_KEY_slash },
	{ "\\",          XKB_KEY_backslash },
	{ "-",           XKB_KEY_minus },
	{ "=",           XKB_KEY_equal },
	{ ";",           XKB_KEY_semicolon },
	{ "'",           XKB_KEY_apostrophe },
	{ "`",           XKB_KEY_grave },
	{ "[",           XKB_KEY_bracketleft },
	{ "]",           XKB_KEY_bracketright },
	{ "enter",       XKB_KEY_Return },
	{ "esc",         XKB_KEY_Escape },
	{ "spacebar",    XKB_KEY_space },
	{ "printscreen", XKB_KEY_Print },
	{ "prtsc",       XKB_KEY_Print },
	{ "volumeup",    XKB_KEY_XF86AudioRaiseVolume },
	{ "volumedown",  XKB_KEY_XF86AudioLowerVolume },
	{ "mute",        XKB_KEY_XF86AudioMute },
};

/* How a keysym is SPELLED on the sheet. Everything not here falls back
 * to xkbcommon's own name, which is right for a letter and ugly for a
 * media key -- "XF86AudioRaiseVolume" is a correct answer to a
 * question nobody asked. */
static const struct {
	xkb_keysym_t sym;
	const char *text;
} KEY_NAMES[] = {
	{ XKB_KEY_Return,                "Return" },
	{ XKB_KEY_Escape,                "Escape" },
	{ XKB_KEY_space,                 "Space" },
	{ XKB_KEY_Tab,                   "Tab" },
	{ XKB_KEY_ISO_Left_Tab,          "Shift + Tab" },
	{ XKB_KEY_period,                "." },
	{ XKB_KEY_comma,                 "," },
	{ XKB_KEY_slash,                 "/" },
	{ XKB_KEY_backslash,             "\\" },
	{ XKB_KEY_minus,                 "-" },
	{ XKB_KEY_equal,                 "=" },
	{ XKB_KEY_semicolon,             ";" },
	{ XKB_KEY_apostrophe,            "'" },
	{ XKB_KEY_grave,                 "`" },
	{ XKB_KEY_bracketleft,           "[" },
	{ XKB_KEY_bracketright,          "]" },
	{ XKB_KEY_Print,                 "Print Screen" },
	{ XKB_KEY_XF86AudioRaiseVolume,  "Volume Up" },
	{ XKB_KEY_XF86AudioLowerVolume,  "Volume Down" },
	{ XKB_KEY_XF86AudioMute,         "Mute" },
};

static void trim(char *s) {
	size_t n = strlen(s);
	while (n > 0 && isspace((unsigned char)s[n - 1])) {
		s[--n] = '\0';
	}
	size_t lead = 0;
	while (s[lead] != '\0' && isspace((unsigned char)s[lead])) {
		lead++;
	}
	if (lead > 0) {
		memmove(s, s + lead, n - lead + 1);
	}
}

/* Forward: defaults() renders every row, and rewrite_text() is how a
 * row is rendered. */
static void rewrite_text(struct novi_keys *k, size_t i);

void novi_keys_defaults(struct novi_keys *k) {
	memset(k, 0, sizeof(*k));
	for (size_t i = 0; i < NOVI_BINDINGS_COUNT; i++) {
		k->v[i] = NOVI_BINDINGS[i];
		rewrite_text(k, i);
	}
}

bool novi_keys_parse(const char *spec, unsigned *mods, xkb_keysym_t *sym) {
	char buf[NOVI_KEYS_TEXT_MAX];
	snprintf(buf, sizeof(buf), "%s", spec);
	trim(buf);
	if (buf[0] == '\0') {
		return false;
	}
	if (strcasecmp(buf, "off") == 0 || strcasecmp(buf, "none") == 0 ||
			strcasecmp(buf, "disabled") == 0) {
		*mods = NOVI_MOD_NONE;
		*sym = XKB_KEY_NoSymbol;
		return true;
	}

	unsigned m = NOVI_MOD_NONE;
	char *rest = buf;
	char *tok;
	char *last = NULL;
	/* Split on '+', last token is the key. Done by hand rather than
	 * with strtok so that a trailing '+' -- "Super+" -- is a refusal
	 * rather than a binding on Super alone, which cannot be pressed
	 * as a shortcut and would swallow every other Super binding. */
	while ((tok = strsep(&rest, "+")) != NULL) {
		trim(tok);
		if (tok[0] == '\0') {
			return false;
		}
		if (last != NULL) {
			unsigned bit = 0;
			for (size_t i = 0; i < sizeof(MODS) / sizeof(MODS[0]); i++) {
				if (strcasecmp(last, MODS[i].word) == 0) {
					bit = MODS[i].bit;
					break;
				}
			}
			if (bit == 0) {
				/* A word before a '+' that is not a modifier: the
				 * person meant something this cannot express, and
				 * guessing which half they meant is worse than
				 * saying so. */
				return false;
			}
			m |= bit;
		}
		last = tok;
	}
	if (last == NULL) {
		return false;
	}

	for (size_t i = 0; i < sizeof(KEY_ALIASES) / sizeof(KEY_ALIASES[0]); i++) {
		if (strcasecmp(last, KEY_ALIASES[i].word) == 0) {
			*mods = m;
			*sym = KEY_ALIASES[i].sym;
			return true;
		}
	}
	/* CASE_INSENSITIVE so `Super+Q` and `Super+q` are one binding --
	 * which they are: novi-shell compares through
	 * xkb_keysym_to_lower(), so a config that could express the
	 * difference would be expressing something that cannot happen. */
	xkb_keysym_t s = xkb_keysym_from_name(last, XKB_KEYSYM_CASE_INSENSITIVE);
	if (s == XKB_KEY_NoSymbol) {
		return false;
	}
	*mods = m;
	*sym = s;
	return true;
}

void novi_keys_format(unsigned mods, xkb_keysym_t sym, unsigned flags,
		char *out, size_t cap) {
	char buf[NOVI_KEYS_TEXT_MAX];
	size_t used = 0;
	buf[0] = '\0';
	/* Super, Alt, Shift, in that order whatever order they were
	 * written in: a sheet where one row says "Shift + Super + Q" and
	 * the next says "Super + Shift + 1…9" reads as two different kinds
	 * of thing. */
	static const struct { unsigned bit; const char *word; } ORDER[] = {
		{ NOVI_MOD_LOGO,  "Super" },
		{ NOVI_MOD_ALT,   "Alt" },
		{ NOVI_MOD_SHIFT, "Shift" },
	};
	for (size_t i = 0; i < sizeof(ORDER) / sizeof(ORDER[0]); i++) {
		if ((mods & ORDER[i].bit) == 0) {
			continue;
		}
		int n = snprintf(buf + used, sizeof(buf) - used, "%s%s",
			used > 0 ? " + " : "", ORDER[i].word);
		if (n < 0 || (size_t)n >= sizeof(buf) - used) {
			used = sizeof(buf) - 1;
			break;
		}
		used += (size_t)n;
	}

	const char *key = NULL;
	char fallback[64];
	if (sym == XKB_KEY_NoSymbol) {
		key = "(unbound)";
	} else if ((flags & NOVI_BIND_DIGIT_RANGE) != 0) {
		/* Nine keys, one row. Rendering the base keysym would say
		 * "Super + 1" for a binding that answers to all nine. */
		key = "1…9";
	} else {
		for (size_t i = 0; i < sizeof(KEY_NAMES) / sizeof(KEY_NAMES[0]); i++) {
			if (KEY_NAMES[i].sym == sym) {
				key = KEY_NAMES[i].text;
				break;
			}
		}
		if (key == NULL) {
			xkb_keysym_get_name(sym, fallback, sizeof(fallback));
			/* A single letter is upper-cased, because a key is
			 * labelled Q and not q. */
			if (fallback[0] != '\0' && fallback[1] == '\0') {
				fallback[0] = (char)toupper((unsigned char)fallback[0]);
			}
			key = fallback;
		}
	}
	snprintf(out, cap, "%s%s%s", buf, used > 0 ? " + " : "", key);
}

static void rewrite_text(struct novi_keys *k, size_t i) {
	novi_keys_format(k->v[i].mods, k->v[i].sym, k->v[i].flags,
		k->text[i], sizeof(k->text[i]));
}

int novi_keys_load(struct novi_keys *k, const char *path) {
	FILE *f = fopen(path, "r");
	if (f == NULL) {
		/* No file is not an error and never has been: the compiled
		 * defaults are a complete answer, and a desktop that refused
		 * to bind anything because /etc had no opinion would be a
		 * desktop with no keys. */
		return 0;
	}

	char line[256];
	while (fgets(line, sizeof(line), f) != NULL) {
		char *hash = strchr(line, '#');
		if (hash != NULL) {
			*hash = '\0';
		}
		trim(line);
		if (line[0] == '\0') {
			continue;
		}
		char *eq = strchr(line, '=');
		if (eq == NULL) {
			k->unreadable++;
			continue;
		}
		*eq = '\0';
		char *name = line;
		char *spec = eq + 1;
		trim(name);
		trim(spec);

		size_t idx = NOVI_BINDINGS_COUNT;
		for (size_t i = 0; i < NOVI_BINDINGS_COUNT; i++) {
			if (strcmp(k->v[i].name, name) == 0) {
				idx = i;
				break;
			}
		}
		if (idx == NOVI_BINDINGS_COUNT) {
			/* An action this build does not have. Counted, not fatal:
			 * one file is read by whatever novi-shell is installed,
			 * and a line for a shortcut that arrived in a later
			 * version must not take the rest of the file with it. */
			k->unreadable++;
			continue;
		}

		unsigned mods = 0;
		xkb_keysym_t sym = XKB_KEY_NoSymbol;
		if (!novi_keys_parse(spec, &mods, &sym)) {
			k->unreadable++;
			continue;
		}
		/* A row that matches nine digits can only be moved by its
		 * modifiers -- so the key has to be one of the nine, and
		 * anything else is a line that would not do what it says. */
		if ((k->v[idx].flags & NOVI_BIND_DIGIT_RANGE) != 0 &&
				sym != XKB_KEY_NoSymbol) {
			if (sym < XKB_KEY_1 || sym > XKB_KEY_9) {
				k->unreadable++;
				continue;
			}
			sym = XKB_KEY_1;
		}

		if (k->v[idx].mods == mods && k->v[idx].sym == sym) {
			continue;  /* the default, written out longhand */
		}
		k->v[idx].mods = mods;
		k->v[idx].sym = sym;
		k->overridden++;
		rewrite_text(k, idx);
	}
	fclose(f);

	/* Collisions are resolved by DISABLING the later row, not by
	 * letting the earlier one quietly win. Dispatch stops at its first
	 * match, so "first wins" is what the loop does on its own -- and
	 * the cost of leaving it there is a sheet that lists a key for a
	 * row that can never fire, which is the wrong-key document this
	 * table exists to prevent. Unbound at least SAYS so. */
	for (size_t i = 0; i < NOVI_BINDINGS_COUNT; i++) {
		bool clash = false;
		for (size_t j = 0; j < i; j++) {
			if (k->v[j].sym == XKB_KEY_NoSymbol) {
				continue;
			}
			if (k->v[j].sym == k->v[i].sym && k->v[j].mods == k->v[i].mods &&
					k->v[i].sym != XKB_KEY_NoSymbol) {
				clash = true;
				break;
			}
		}
		if (!clash) {
			continue;
		}
		k->v[i].mods = NOVI_MOD_NONE;
		k->v[i].sym = XKB_KEY_NoSymbol;
		k->conflicts++;
		rewrite_text(k, i);
	}
	return k->unreadable;
}
