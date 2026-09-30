/* procstat.h -- how much CPU a process has burned, read out of
 * /proc/<pid>/stat.
 *
 * RFC 0038. novi-shell's window watchdog needs one number per client:
 * the CPU time that client has accumulated, sampled twice and
 * subtracted. That is two fields of /proc/<pid>/stat, and reading them
 * has a trap sharp enough to deserve a file of its own with a host
 * test beside it -- see novi_procstat_cpu_ticks().
 *
 * Nothing here opens a Wayland connection or knows what a window is,
 * which is the point: the arithmetic and the parse are testable on a
 * build host, and the compositor keeps only the decision.
 */
#ifndef NOVI_PROCSTAT_H
#define NOVI_PROCSTAT_H

#include <stdbool.h>

/* Parse utime+stime (fields 14 and 15) out of one /proc/<pid>/stat
 * line and sum them into *out, in clock ticks.
 *
 * THE FIELDS CANNOT BE COUNTED FROM THE LEFT. Field 2 is the
 * executable name in parentheses, and the kernel neither escapes nor
 * rejects what is in it: a process whose comm contains a space, or a
 * ')', or the text "1 2 3 4 5", produces a line whose fourteenth
 * whitespace-separated token is not utime. That is not a hypothetical
 * -- comm is settable with prctl(PR_SET_NAME) by the process itself,
 * so it is attacker-chosen text in exactly the case this watchdog
 * exists for. The parse starts from the LAST ')' in the line, which is
 * the one field-2 ends at whatever is inside it.
 *
 * Returns false and leaves *out alone if the line is malformed.
 */
bool novi_procstat_cpu_ticks(const char *line, unsigned long long *out);

/* The process's start time (field 22), in clock ticks since boot. It
 * is what makes a pid safe to act on: a pid alone can be reused, and
 * the one thing the watchdog does with a pid is send it a signal. Read
 * once when a window appears and compared before the signal goes out,
 * a changed start time means this is a different process wearing the
 * same number. Same parse, same trap. */
bool novi_procstat_starttime(const char *line, unsigned long long *out);

/* One numbered field, as proc(5) numbers them -- 3 or higher, since
 * fields 1 and 2 are before the ')' this parse starts from. For
 * UNSIGNED fields only: field 8 (tpgid) is routinely -1 and would come
 * back as a very large number. */
bool novi_procstat_field(const char *line, int field, unsigned long long *out);

/* Both numbers from one read of /proc/<pid>/stat -- one open for the
 * two things a caller wants together. Either pointer may be NULL.
 * False if the process is gone (the common case -- it exited between
 * two samples) or unreadable. */
bool novi_procstat_read(int pid, unsigned long long *cpu,
	unsigned long long *starttime);

/* What share of one core `delta` ticks over `window_ms` milliseconds
 * is, as a percentage. 100 is one core saturated; a process with
 * several busy threads exceeds it, which is a floor worth keeping
 * rather than clamping away.
 *
 * Returns -1 when it cannot say (a clock rate or a window that is not
 * positive), which is deliberately NOT 0: "no reading" and "idle" are
 * different answers, and a caller that treats them alike would kill a
 * window on a failed sample. */
int novi_procstat_cpu_percent(unsigned long long delta, int window_ms,
	long clk_tck);

/* Is this process the init of a PID namespace nested inside ours?
 *
 * IT MATTERS BECAUSE SIGTERM DOES NOT REACH ONE. The kernel gives the
 * init of a PID namespace the same protection it gives the machine's
 * own init: a signal whose disposition is still SIG_DFL is DISCARDED
 * when it is sent from outside that namespace, and kill(2) returns 0
 * for it. Measured on a booted Novi against a process under
 * novi-sandbox (RFC 0039): `kill` succeeded, the process was still
 * there, `kill -9` ended it. SIGKILL and SIGSTOP are the exception the
 * kernel makes.
 *
 * So the polite stage of a force-quit is not merely unlikely to work
 * on a sandboxed window -- it cannot work, and it reports success. The
 * answer comes from `NSpid:` in /proc/<pid>/status, which lists the
 * process's pid at each namespace level outermost-first: two or more
 * fields with 1 last means it is pid 1 somewhere below us.
 *
 * Takes the file's text so the parse is host-testable; the _pid form
 * reads the file. Both answer FALSE when they cannot tell -- an
 * unreadable file or a kernel with no NSpid line leaves the caller on
 * its ordinary path, because the failure of an instrument must not be
 * what escalates a signal. */
bool novi_procstat_status_is_ns_init(const char *status_text);
bool novi_procstat_is_ns_init(int pid);

#endif /* NOVI_PROCSTAT_H */
