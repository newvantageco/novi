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

/* ── Unread ───────────────────────────────────────────────────────
 *
 * A history nobody can see the SIZE of is a history nobody opens. The
 * panel draws a bell and a count; this is where "how many have I not
 * seen" is answered, once, for both ends of it.
 *
 * TWO FILES, ONE WRITER EACH. novi-notifyd owns the history and never
 * reads the marker; novi-launcher owns the marker and never writes
 * the history; the panel reads both and writes neither. A single file
 * with a "seen" column would need the daemon and the launcher to
 * write the same file, which is the arrangement every published-state
 * file in this system exists to avoid.
 *
 * The marker is the `when` of the newest entry the list has shown.
 * Unread is therefore "strictly newer than that", which has a
 * one-second blind spot: a notification arriving in the same second
 * as the newest one on screen is counted as seen. Stated rather than
 * papered over -- the entry is still in the list, and the alternative
 * (a marker that is a count as well as a time) is two numbers that can
 * disagree about the same moment.
 */
#define NOVI_HIST_SEEN_PATH "/run/novi/notifications.seen"

/* And where "I have dealt with everything up to here" is recorded.
 *
 * A SECOND MARKER RATHER THAN A VERB ON THE SOCKET, and that is the
 * whole design. Clearing could have been a control message to
 * novi-notifyd -- but that socket is world-writable by design (RFC
 * 0024: an unprivileged program has as much business notifying as root
 * does, and there is no session bus to arbitrate), so a clear verb
 * would let any process on the machine empty your notification list.
 * A marker file the reader owns costs one line, adds nothing to the
 * daemon, and cannot be reached by a sender at all.
 *
 * It is the same shape as the seen marker above, and it uses the same
 * two functions: this pair is "a timestamp in a file", not two
 * different mechanisms that happen to look alike.
 *
 * DISMISSING ONE is deliberately not built on this. A timestamp can
 * say "everything before here"; it cannot say "that one", and the
 * record format has no identity to name -- two notifications in the
 * same second share a `when`. Doing it properly means giving entries
 * ids, which is a change to the file two programs exchange; doing it
 * improperly means a dismiss that sometimes takes its neighbour with
 * it. */
#define NOVI_HIST_CLEARED_PATH "/run/novi/notifications.cleared"

/* The marker, or 0 when there is none -- which is the right answer for
 * a machine where the list has never been opened: everything is
 * unread. Used for both markers; `path` is which one. */
int64_t novi_hist_seen_read(const char *path);

/* Writes the marker, temp-and-rename like the history itself. */
bool novi_hist_seen_write(const char *path, int64_t when);

/* How many entries in `hist_path` are newer than the marker in
 * `seen_path`. The history is written newest first, so this stops at
 * the first entry that is not -- it costs the unread count, not the
 * file. */
size_t novi_hist_unread(const char *hist_path, const char *seen_path);

/* "now", "3m", "2h", "5d" -- the age of an entry in one short field,
 * which is what a list wants where a timestamp would take the width
 * of the summary. `now` is the current wall clock in seconds. */
void novi_hist_age(char *out, size_t cap, int64_t when, int64_t now);

#endif /* NOVI_NOTIFYD_HISTORY_H */
