/* procstat.c -- see procstat.h. */
#include "procstat.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Fields, 1-indexed as proc(5) numbers them: 1 pid, 2 comm, 3 state,
 * ... 14 utime, 15 stime. The scan below starts after comm's closing
 * ')', so its first token is field 3 and utime is the twelfth. */
#define FIELD_STATE 3
#define FIELD_UTIME 14
#define FIELD_STIME 15
#define FIELD_STARTTIME 22

/* The one scan every reader here goes through: walk from the last ')'
 * to field `want` and parse it. Two of them (utime, stime) are
 * adjacent and read twice rather than in one pass, because a stat line
 * is a few hundred bytes and one source of truth about where a field
 * is beats saving a scan. */
bool novi_procstat_field(const char *line, int want, unsigned long long *out) {
	if (line == NULL || out == NULL || want < FIELD_STATE) {
		return false;
	}
	/* The LAST ')', not the first: comm may contain one. */
	const char *p = strrchr(line, ')');
	if (p == NULL) {
		return false;
	}
	p++;
	for (int field = FIELD_STATE; field <= want; field++) {
		while (*p == ' ') {
			p++;
		}
		if (*p == '\0' || *p == '\n') {
			return false;
		}
		if (field == want) {
			char *end = NULL;
			unsigned long long v = strtoull(p, &end, 10);
			/* A field that is not a number at all -- which is what a
			 * short line or a misaligned parse looks like -- must fail
			 * rather than contribute 0, or a truncated /proc read
			 * reports a process that has used no CPU. */
			if (end == p || (*end != ' ' && *end != '\0' && *end != '\n')) {
				return false;
			}
			*out = v;
			return true;
		}
		/* Advance past this field. */
		while (*p != ' ' && *p != '\0' && *p != '\n') {
			p++;
		}
	}
	return false;
}

bool novi_procstat_cpu_ticks(const char *line, unsigned long long *out) {
	unsigned long long utime = 0, stime = 0;
	if (out == NULL ||
			!novi_procstat_field(line, FIELD_UTIME, &utime) ||
			!novi_procstat_field(line, FIELD_STIME, &stime)) {
		return false;
	}
	*out = utime + stime;
	return true;
}

bool novi_procstat_starttime(const char *line, unsigned long long *out) {
	return novi_procstat_field(line, FIELD_STARTTIME, out);
}

bool novi_procstat_read(int pid, unsigned long long *cpu,
		unsigned long long *starttime) {
	if (pid <= 0) {
		return false;
	}
	char path[64];
	snprintf(path, sizeof(path), "/proc/%d/stat", pid);
	FILE *f = fopen(path, "r");
	if (f == NULL) {
		return false;
	}
	/* comm is capped at 16 bytes by the kernel, so the whole line is
	 * small; 512 is several times what it can be. */
	char line[512];
	char *got = fgets(line, sizeof(line), f);
	fclose(f);
	if (got == NULL) {
		return false;
	}
	if (cpu != NULL && !novi_procstat_cpu_ticks(line, cpu)) {
		return false;
	}
	if (starttime != NULL && !novi_procstat_starttime(line, starttime)) {
		return false;
	}
	return true;
}

int novi_procstat_cpu_percent(unsigned long long delta, int window_ms,
		long clk_tck) {
	if (clk_tck <= 0 || window_ms <= 0) {
		return -1;
	}
	/* delta ticks is delta*1000/clk_tck milliseconds of CPU; as a
	 * percentage of the window that is delta*100000/(clk_tck*window).
	 * Done in one expression in 64-bit so a long sample cannot
	 * overflow the intermediate, and integer-divided last so it
	 * truncates rather than accumulating rounding. */
	unsigned long long num = delta * 100000ULL;
	unsigned long long den = (unsigned long long)clk_tck *
		(unsigned long long)window_ms;
	unsigned long long pct = num / den;
	/* A process that has been running for weeks on a machine whose
	 * clock rate we misread could produce an absurd number; there is
	 * nothing useful past "several cores saturated" and an int is what
	 * the caller compares. */
	if (pct > 100000ULL) {
		pct = 100000ULL;
	}
	return (int)pct;
}
