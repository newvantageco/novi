/* ============================================================
 * notifications.h — what was said, after the toast has gone
 *
 * RFC 0034. A toast is up for three or five seconds and then it is
 * gone; before this there was NO WAY to find out what one said. A
 * notification you were not looking at was a notification that never
 * happened, which makes the whole mechanism unreliable for exactly
 * the thing it is for -- telling you something while you are busy.
 *
 * novi-notifyd keeps the last NOVI_HIST_MAX and republishes the whole
 * list to /run/novi/notifications on every message;
 * `novi-launcher --notifications` (Super+N) renders it.
 *
 * A PUBLISHED FILE, not a second socket or a D-Bus method, for the
 * same reason /run/novi/health, /run/novi/theme and
 * /run/novi/network.device are files: a reader that starts later has
 * to be able to find out, and a file is the whole of that. The list
 * is rewritten entire rather than appended to, which gets the bound
 * and the atomicity in one move -- fifty short lines is nothing, and
 * an appender would need a separate trimmer that could disagree with
 * it.
 *
 * IT DOES NOT SURVIVE A RESTART, and that is honest rather than
 * unfortunate: /run is a tmpfs, the history is what this daemon has
 * seen, and a daemon that has just started has seen nothing. Making
 * it durable would mean a file under /var that outlives the session
 * it describes.
 *
 * It lives in common/ rather than in novi-notifyd because TWO
 * clients need it -- the daemon writes the file and novi-launcher
 * reads it -- and because it can then be tested with the HOST compiler
 * (`make -C common check`, run by scripts/lint.sh). The record
 * format is exactly the kind of thing that is wrong in ways a running
 * desktop never shows you: a tab inside a summary silently shifts
 * every field after it, and no notification anybody sends by hand
 * will contain one.
 * ============================================================ */
#ifndef NOVI_NOTIFYD_HISTORY_H
#define NOVI_NOTIFYD_HISTORY_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define NOVI_HIST_MAX      50
#define NOVI_HIST_SUMMARY  96
#define NOVI_HIST_BODY     160
#define NOVI_HIST_ICON     24

#define NOVI_HIST_PATH "/run/novi/notifications"

struct novi_hist_entry {
	int64_t when;      /* wall-clock seconds; 0 if unknown */
	int urgency;       /* 0 low, 1 normal, 2 critical */
	char icon[NOVI_HIST_ICON + 1];
	char summary[NOVI_HIST_SUMMARY + 1];
	char body[NOVI_HIST_BODY + 1];
};

struct novi_history {
	struct novi_hist_entry e[NOVI_HIST_MAX];
	size_t n;   /* entries in use; e[0] is the OLDEST */
};

/* Drops every control character, tab and newline included. This is
 * what makes the tab-separated record format safe by construction
 * rather than by escaping: there is nothing a control character in a
 * notification summary can mean except that somebody is drawing
 * outside their box. Shared with the toast path, which had its own
 * copy of exactly this and the same argument. */
void novi_hist_sanitise(char *dst, size_t cap, const char *src);

/* Newest goes on the end; the oldest falls off when full. */
void novi_hist_push(struct novi_history *h, const struct novi_hist_entry *e);

/* One record, NEWEST FIRST order being the caller's job. Returns the
 * number of bytes it wanted to write, snprintf-style. */
int novi_hist_format(char *out, size_t cap, const struct novi_hist_entry *e);

/* Parses one record back. Returns false for a line that is not one --
 * a reader of a file in /run is reading something another program
 * wrote, and "it must be well formed because we wrote it" is how a
 * parser learns to trust its input. */
bool novi_hist_parse(const char *line, struct novi_hist_entry *out);

/* Writes the whole list newest-first to `path`, via a temp file and a
 * rename: a reader on its own schedule must never see half a list.
 * Returns false if it could not. */
bool novi_hist_publish(const struct novi_history *h, const char *path);

/* "now", "3m", "2h", "5d" -- the age of an entry in one short field,
 * which is what a list wants where a timestamp would take the width
 * of the summary. `now` is the current wall clock in seconds. */
void novi_hist_age(char *out, size_t cap, int64_t when, int64_t now);

#endif /* NOVI_NOTIFYD_HISTORY_H */
