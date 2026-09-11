/* ============================================================
 * notifications.c — the record format, and nothing else
 *
 * RFC 0034. No Wayland, no pixman, no fcft: this file is string
 * handling, which is why it can be compiled by the host compiler and
 * asserted without a desktop (see history-test.c).
 * ============================================================ */
#include "notifications.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

void novi_hist_sanitise(char *dst, size_t cap, const char *src) {
	size_t o = 0;
	if (cap == 0) {
		return;
	}
	for (size_t i = 0; src != NULL && src[i] != '\0' && o < cap; i++) {
		unsigned char c = (unsigned char)src[i];
		if (c < 0x20 || c == 0x7f) {
			continue;
		}
		dst[o++] = (char)c;
	}
	dst[o] = '\0';
}

void novi_hist_push(struct novi_history *h, const struct novi_hist_entry *e) {
	if (h->n == NOVI_HIST_MAX) {
		memmove(&h->e[0], &h->e[1], sizeof(h->e[0]) * (NOVI_HIST_MAX - 1));
		h->n = NOVI_HIST_MAX - 1;
	}
	h->e[h->n++] = *e;
}

/* <epoch>\t<urgency>\t<icon>\t<summary>\t<body>
 *
 * Tab separated with NO escaping, and that is safe because
 * novi_hist_sanitise() has already dropped every control character
 * from every field that came from outside -- a tab cannot reach here.
 * The alternative, an escaping scheme in a format parsed by a hand
 * written splitter, is the thing RFC 0006 refused for the package
 * index for the same reason.
 *
 * The urgency is a WORD, not the enum's number. A file in /run is
 * read by a different program, possibly a different version of it,
 * and a number that means "critical" only because both sides happen
 * to agree on an enum's order is a format that breaks silently when
 * somebody inserts a value. */
static const char *URGENCY_NAMES[] = { "low", "normal", "critical" };

int novi_hist_format(char *out, size_t cap, const struct novi_hist_entry *e) {
	int u = e->urgency;
	if (u < 0 || u > 2) {
		u = 1;
	}
	return snprintf(out, cap, "%lld\t%s\t%s\t%s\t%s\n",
		(long long)e->when, URGENCY_NAMES[u],
		e->icon, e->summary, e->body);
}

/* Copies up to the next tab (or end of string) into a fixed field,
 * and advances the cursor past the tab. Returns NULL when the line
 * ran out before this field existed, which is what tells the parser
 * the record is short. */
static const char *take_field(const char *p, char *dst, size_t cap,
		bool last) {
	if (p == NULL) {
		return NULL;
	}
	const char *tab = strchr(p, '\t');
	size_t len = tab != NULL ? (size_t)(tab - p) : strlen(p);
	if (len >= cap) {
		len = cap - 1;
	}
	memcpy(dst, p, len);
	dst[len] = '\0';
	if (last) {
		/* The final field takes the rest of the line, tabs and all --
		 * except there can be none, so this only ever matters if a
		 * writer that is not us produced the file. */
		return p + strlen(p);
	}
	return tab != NULL ? tab + 1 : NULL;
}

bool novi_hist_parse(const char *line, struct novi_hist_entry *out) {
	if (line == NULL || *line == '\0' || *line == '\n') {
		return false;
	}
	memset(out, 0, sizeof(*out));

	char when[24] = "", urg[16] = "";
	const char *p = line;
	p = take_field(p, when, sizeof(when), false);
	p = take_field(p, urg, sizeof(urg), false);
	p = take_field(p, out->icon, sizeof(out->icon), false);
	p = take_field(p, out->summary, sizeof(out->summary), false);
	if (p == NULL) {
		return false;
	}
	/* The body is the last field and is allowed to be empty; what is
	 * NOT allowed is the field being absent, which take_field reports
	 * by having returned NULL above. */
	take_field(p, out->body, sizeof(out->body), true);

	/* A summary is the one field with no useful empty value: a row
	 * with nothing to say is a row that should not be drawn. The
	 * toast path already refuses one; so does this. */
	if (out->summary[0] == '\0') {
		return false;
	}

	/* Trailing newline off the last field, since a caller reading
	 * lines with fgets() keeps it. */
	size_t bl = strlen(out->body);
	while (bl > 0 && (out->body[bl - 1] == '\n' || out->body[bl - 1] == '\r')) {
		out->body[--bl] = '\0';
	}

	char *end = NULL;
	long long v = strtoll(when, &end, 10);
	out->when = (end != NULL && *end == '\0' && v > 0) ? (int64_t)v : 0;

	out->urgency = 1;
	for (int i = 0; i < 3; i++) {
		if (strcmp(urg, URGENCY_NAMES[i]) == 0) {
			out->urgency = i;
			break;
		}
	}
	return true;
}

bool novi_hist_publish(const struct novi_history *h, const char *path) {
	char tmp[512];
	/* Create the directory rather than assume it. /run/novi happens to
	 * exist on a booted machine because the network service makes it,
	 * but a desktop daemon depending on a network service having
	 * started is a coupling nobody would think to look for -- and the
	 * symptom would be a history that is silently always empty. */
	const char *slash = strrchr(path, '/');
	if (slash != NULL && slash != path) {
		char dir[512];
		size_t dlen = (size_t)(slash - path);
		if (dlen < sizeof(dir)) {
			memcpy(dir, path, dlen);
			dir[dlen] = '\0';
			(void)mkdir(dir, 0755); /* EEXIST is the expected case */
		}
	}
	if ((size_t)snprintf(tmp, sizeof(tmp), "%s.new", path) >= sizeof(tmp)) {
		return false;
	}
	FILE *f = fopen(tmp, "w");
	if (f == NULL) {
		return false;
	}
	/* NEWEST FIRST. The ring holds oldest-first because that is what
	 * makes the drop cheap; the file is written the way a person
	 * reads a list of things that just happened. */
	for (size_t i = h->n; i > 0; i--) {
		char line[NOVI_HIST_SUMMARY + NOVI_HIST_BODY + 96];
		novi_hist_format(line, sizeof(line), &h->e[i - 1]);
		fputs(line, f);
	}
	if (fclose(f) != 0) {
		unlink(tmp);
		return false;
	}
	if (rename(tmp, path) != 0) {
		unlink(tmp);
		return false;
	}
	return true;
}

void novi_hist_age(char *out, size_t cap, int64_t when, int64_t now) {
	if (when <= 0 || now < when) {
		/* A clock that went backwards, or an entry with no timestamp.
		 * "now" is wrong in a way nobody can act on; an empty field
		 * says nothing, which is the truth. */
		snprintf(out, cap, "%s", when <= 0 ? "" : "now");
		return;
	}
	int64_t d = now - when;
	if (d < 60) {
		snprintf(out, cap, "now");
	} else if (d < 3600) {
		snprintf(out, cap, "%lldm", (long long)(d / 60));
	} else if (d < 86400) {
		snprintf(out, cap, "%lldh", (long long)(d / 3600));
	} else {
		snprintf(out, cap, "%lldd", (long long)(d / 86400));
	}
}
