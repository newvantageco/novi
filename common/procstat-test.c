/* ============================================================
 * procstat-test.c — the /proc/<pid>/stat parse, without a /proc
 *
 * RFC 0038. Built and run by `make -C common check`, which
 * scripts/lint.sh runs. It links the real procstat.c, for the reason
 * every other test here links the real thing: a test with its own copy
 * of the parser tests the copy.
 *
 * The cases that matter are the ones a real machine will not hand you
 * on the day you write the code. Every process on a booted desktop has
 * a boring comm, so the field-counting bug this parser exists to avoid
 * is invisible until somebody's program calls prctl(PR_SET_NAME) with
 * a space in it -- and the one class of program this watchdog is for
 * is the one running somebody else's content. Same argument
 * novi-panel's icon geometry test makes about a radio that only ever
 * reports one signal strength.
 * ============================================================ */
#include "procstat.h"

#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int checks = 0;
static int failures = 0;

static void ok(bool cond, const char *what) {
	checks++;
	if (!cond) {
		failures++;
		fprintf(stderr, "FAIL: %s\n", what);
	}
}

/* A stat line with a chosen comm and chosen utime/stime, every other
 * field filled with a value that is NOT the one being read -- so a
 * parse that lands one field off reports a wrong number rather than
 * accidentally the right one. Fields 3..13 are the eleven before
 * utime; 16.. are what follows. */
static void mk(char *out, size_t n, const char *comm,
		unsigned long u, unsigned long s) {
	snprintf(out, n,
		"4242 (%s) R 1 1 1 0 -1 4194560 7 7 7 7 %lu %lu 9 9 20 0 1 0 "
		"123456 45056000 1024 18446744073709551615 1 1 0 0 0 0 0 0 0\n",
		comm, u, s);
}

int main(void) {
	char line[1024];
	unsigned long long t = 0;

	/* ── 1. an ordinary line ──────────────────────────────────── */
	mk(line, sizeof(line), "netsurf-fb", 1200, 300);
	ok(novi_procstat_cpu_ticks(line, &t), "an ordinary line parses");
	ok(t == 1500, "utime and stime are summed, not just utime");

	/* ── 2. the trap: comm is arbitrary text ──────────────────── */
	/* A space in comm shifts every whitespace-counted field right. */
	t = 0;
	mk(line, sizeof(line), "my app", 1200, 300);
	ok(novi_procstat_cpu_ticks(line, &t) && t == 1500,
		"a space in comm does not move the fields");

	/* A ')' in comm: parsing from the FIRST one ends field 2 early. */
	/* The value matters: with utime 700 and stime 7 a parse that
	 * starts at the FIRST ')' also lands on 707, because the field it
	 * mistakes for utime happens to hold a 7. It passed that way once.
	 * A probe that cannot fail on the bug it names is worse than no
	 * probe, so stime is 11 and the two answers differ. */
	t = 0;
	mk(line, sizeof(line), "weird) name", 700, 11);
	ok(novi_procstat_cpu_ticks(line, &t) && t == 711,
		"a ')' in comm does not end the name early");

	/* The nastiest shape: a comm that looks like the rest of a stat
	 * line. A parser counting tokens from the left reads these
	 * numbers; one counting from the last ')' cannot see them. */
	t = 0;
	mk(line, sizeof(line), "R 1 1 1 1 1 1 1 1 1 1 999 888", 1200, 300);
	ok(novi_procstat_cpu_ticks(line, &t), "a comm shaped like a stat line parses");
	ok(t == 1500, "and the numbers inside it are not mistaken for utime/stime");

	/* ── 3. malformed input is refused, never silently zero ───── */
	t = 12345;
	ok(!novi_procstat_cpu_ticks("4242 netsurf R 1 1", &t),
		"a line with no ')' is refused");
	ok(t == 12345, "and *out is left alone");

	ok(!novi_procstat_cpu_ticks("4242 (sh) R 1 1 1 0 -1 4194560 7 7\n", &t),
		"a line that ends before utime is refused");
	ok(!novi_procstat_cpu_ticks("4242 (sh) R 1 1 1 0 -1 4194560 7 7 7 7 x 3 9\n", &t),
		"a utime that is not a number is refused");
	ok(!novi_procstat_cpu_ticks("4242 (sh) R 1 1 1 0 -1 4194560 7 7 7 7 12x 3 9\n", &t),
		"a utime with trailing rubbish is refused");
	ok(!novi_procstat_cpu_ticks(NULL, &t), "a NULL line is refused");
	ok(!novi_procstat_cpu_ticks("4242 (sh) R 1 1 1 0 -1 4194560 7 7 7 7 12 3 9\n", NULL),
		"a NULL out is refused");

	/* ── 4. the start time, and the field reader under both ───── */
	unsigned long long st = 0;
	mk(line, sizeof(line), "netsurf-fb", 1200, 300);
	ok(novi_procstat_starttime(line, &st) && st == 123456,
		"the start time comes from field 22");
	st = 0;
	mk(line, sizeof(line), "R 1 1 1 1 1 1 1 1 1 1 999 888", 1200, 300);
	ok(novi_procstat_starttime(line, &st) && st == 123456,
		"and a comm shaped like a stat line does not move it either");
	ok(novi_procstat_field(line, 14, &t) && t == 1200,
		"the field reader returns one field, not a sum");
	ok(!novi_procstat_field(line, 2, &t),
		"field 2 is refused -- it is the one this parse starts after");
	ok(!novi_procstat_field(line, 99, &t),
		"a field past the end of the line is refused");

	/* ── 5. a pid that is not there ───────────────────────────── */
	ok(!novi_procstat_read(0, &t, NULL), "pid 0 is refused rather than read");
	ok(!novi_procstat_read(-1, &t, NULL), "a negative pid is refused");
	/* This process exists, so the read half works against the real
	 * /proc rather than only against strings. */
	ok(novi_procstat_read((int)getpid(), &t, &st),
		"our own /proc/<pid>/stat reads");
	ok(st > 0, "and it carries a start time");

	/* ── 6. the percentage ────────────────────────────────────── */
	/* 100 Hz clock, a 2000 ms window: one core is 200 ticks. */
	ok(novi_procstat_cpu_percent(200, 2000, 100) == 100,
		"a saturated core is 100%");
	ok(novi_procstat_cpu_percent(100, 2000, 100) == 50, "half a core is 50%");
	ok(novi_procstat_cpu_percent(0, 2000, 100) == 0, "no CPU is 0%");
	/* Several busy threads exceed 100 and are NOT clamped to it: the
	 * threshold this feeds is a floor, and hiding the difference
	 * between one busy thread and four would lose the only clue a
	 * reader has about what the program is doing. */
	ok(novi_procstat_cpu_percent(800, 2000, 100) == 400,
		"four busy threads report 400%, not 100");
	/* A different clock rate, because CLK_TCK is not 100 everywhere
	 * and a hardcoded divisor would be wrong silently. */
	ok(novi_procstat_cpu_percent(2000, 2000, 1000) == 100,
		"a 1000 Hz clock gives the same answer for the same CPU");

	/* Unreadable is -1, and that is not 0: a caller that treated a
	 * failed sample as an idle one would kill a window on a bad read. */
	ok(novi_procstat_cpu_percent(200, 2000, 0) == -1,
		"a clock rate of zero says \"cannot tell\", not \"idle\"");
	ok(novi_procstat_cpu_percent(200, 2000, -1) == -1,
		"a negative clock rate says \"cannot tell\"");
	ok(novi_procstat_cpu_percent(200, 0, 100) == -1,
		"a zero-length window says \"cannot tell\"");
	ok(novi_procstat_cpu_percent(200, -5, 100) == -1,
		"a negative window says \"cannot tell\"");

	if (failures > 0) {
		fprintf(stderr, "procstat: %d of %d checks FAILED\n", failures, checks);
		return 1;
	}
	printf("procstat: %d checks passed\n", checks);
	return 0;
}
