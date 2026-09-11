/* ============================================================
 * notifications-test.c — the record format, checked without a desktop
 *
 * RFC 0034. Built and run by `make -C common check`, which
 * scripts/lint.sh runs. It links the REAL notifications.c rather than
 * reimplementing the format, for the reason common/theme-test.c links
 * the real loader: a test with its own copy tests the copy.
 *
 * The cases here are the ones a running desktop cannot produce. Every
 * notification a person sends by hand has no tab in it, arrives in
 * order, and is well formed -- so the interesting half of this format
 * (a tab inside a summary shifting every field after it, a truncated
 * line, a file written by an older build) is exactly the half that
 * only a test will ever exercise. The same argument novi-panel's icon
 * geometry test makes about a radio that only ever reports one signal
 * strength.
 * ============================================================ */
#include "notifications.h"

#include <stdio.h>
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

static struct novi_hist_entry mk(const char *summary, const char *body,
		int urgency, const char *icon, int64_t when) {
	struct novi_hist_entry e;
	memset(&e, 0, sizeof(e));
	e.when = when;
	e.urgency = urgency;
	novi_hist_sanitise(e.icon, NOVI_HIST_ICON, icon);
	novi_hist_sanitise(e.summary, NOVI_HIST_SUMMARY, summary);
	novi_hist_sanitise(e.body, NOVI_HIST_BODY, body);
	return e;
}

static int count_tabs(const char *s) {
	int n = 0;
	for (size_t i = 0; s[i] != '\0'; i++) {
		if (s[i] == '\t') {
			n++;
		}
	}
	return n;
}

int main(void) {
	char line[512];
	struct novi_hist_entry e, back;

	/* ── 1. a record survives the round trip ──────────────────── */
	e = mk("Volume mounted", "MYSTICK at /run/media/MYSTICK", 1, "drive",
		1700000000);
	novi_hist_format(line, sizeof(line), &e);
	ok(novi_hist_parse(line, &back), "a formatted record must parse back");
	ok(strcmp(back.summary, e.summary) == 0, "summary survives the round trip");
	ok(strcmp(back.body, e.body) == 0, "body survives the round trip");
	ok(strcmp(back.icon, e.icon) == 0, "icon survives the round trip");
	ok(back.when == e.when, "timestamp survives the round trip");
	ok(back.urgency == e.urgency, "urgency survives the round trip");

	/* ── 2. THE TAB. This is why the format is safe ───────────── */
	e = mk("a\tb", "c\td\ne", 1, "drive", 1700000000);
	ok(strcmp(e.summary, "ab") == 0, "sanitise must drop a tab in the summary");
	ok(strcmp(e.body, "cde") == 0, "sanitise must drop tabs and newlines in the body");
	novi_hist_format(line, sizeof(line), &e);
	ok(count_tabs(line) == 4, "a record has exactly four separators, whatever the sender sent");
	ok(novi_hist_parse(line, &back), "a record built from hostile text still parses");
	ok(strcmp(back.summary, "ab") == 0, "the field after a would-be tab is not shifted");

	/* ── 3. the urgency is a WORD, not an enum's number ───────── */
	e = mk("Device removed", "", 2, "eject", 1700000000);
	novi_hist_format(line, sizeof(line), &e);
	ok(strstr(line, "\tcritical\t") != NULL, "urgency is written as a name");
	ok(novi_hist_parse(line, &back) && back.urgency == 2, "and read back as one");
	/* A name this build does not know is normal, not a parse failure:
	 * a file in /run may have been written by a different version. */
	ok(novi_hist_parse("1700000000\tscreaming\t\tHello\t", &back) &&
		back.urgency == 1, "an unknown urgency reads as normal, not as a refusal");

	/* ── 4. lines that are not records ────────────────────────── */
	ok(!novi_hist_parse("", &back), "an empty line is not a record");
	ok(!novi_hist_parse("\n", &back), "a blank line is not a record");
	ok(!novi_hist_parse("garbage", &back), "a line with no separators is not a record");
	ok(!novi_hist_parse("1700000000\tnormal\tdrive\t", &back),
		"a record with no body FIELD is refused");
	ok(!novi_hist_parse("1700000000\tnormal\tdrive\t\t", &back),
		"a record with an empty summary is refused");
	ok(novi_hist_parse("1700000000\tnormal\t\tHello\t", &back),
		"an empty icon and an empty body are both fine");
	ok(novi_hist_parse("notanumber\tnormal\t\tHello\t", &back) && back.when == 0,
		"an unparseable timestamp reads as unknown rather than as garbage");

	/* ── 5. the ring drops the OLDEST ─────────────────────────── */
	struct novi_history h;
	memset(&h, 0, sizeof(h));
	for (int i = 0; i < NOVI_HIST_MAX + 10; i++) {
		char s[32];
		snprintf(s, sizeof(s), "msg%d", i);
		e = mk(s, "", 1, "", 1700000000 + i);
		novi_hist_push(&h, &e);
	}
	ok(h.n == NOVI_HIST_MAX, "the ring is bounded");
	ok(strcmp(h.e[h.n - 1].summary, "msg59") == 0, "the newest is last");
	ok(strcmp(h.e[0].summary, "msg10") == 0, "the oldest fell off");

	/* ── 6. ages, including a clock that misbehaves ───────────── */
	char age[16];
	novi_hist_age(age, sizeof(age), 1000, 1030);
	ok(strcmp(age, "now") == 0, "under a minute reads as now");
	novi_hist_age(age, sizeof(age), 1000, 1000 + 180);
	ok(strcmp(age, "3m") == 0, "minutes");
	novi_hist_age(age, sizeof(age), 1000, 1000 + 7200);
	ok(strcmp(age, "2h") == 0, "hours");
	novi_hist_age(age, sizeof(age), 1000, 1000 + 86400 * 5);
	ok(strcmp(age, "5d") == 0, "days");
	/* A notification from the future is a clock that changed, not a
	 * negative age to render. */
	novi_hist_age(age, sizeof(age), 2000, 1000);
	ok(strcmp(age, "now") == 0, "a timestamp in the future reads as now, never as a negative");
	novi_hist_age(age, sizeof(age), 0, 1000);
	ok(age[0] == '\0', "no timestamp means no age field, not a wrong one");

	/* ── 7. truncation cannot produce a record with a false field ─ */
	char longsum[NOVI_HIST_SUMMARY * 3];
	memset(longsum, 'x', sizeof(longsum) - 1);
	longsum[sizeof(longsum) - 1] = '\0';
	e = mk(longsum, longsum, 1, "drive", 1700000000);
	ok(strlen(e.summary) == NOVI_HIST_SUMMARY, "an over-long summary is capped");
	novi_hist_format(line, sizeof(line), &e);
	ok(count_tabs(line) == 4, "a capped record still has four separators");
	ok(novi_hist_parse(line, &back), "a capped record still parses");

	if (failures > 0) {
		fprintf(stderr, "notifications: %d of %d checks FAILED\n", failures, checks);
		return 1;
	}
	printf("notifications: %d checks passed\n", checks);
	return 0;
}
