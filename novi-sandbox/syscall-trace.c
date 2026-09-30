/* novi-syscalls — which syscalls does this program actually make?
 *
 * RFC 0039 roadmap 3. An allowlist is only honest if it is DERIVED: a
 * hand-written list is somebody's reading of a program, and the cost of
 * being wrong is a tool that works everywhere it was tried and fails on
 * the path nobody exercised. So the list comes from the program.
 *
 * THIS IS A BUILD ARTIFACT AND IS NOT INSTALLED, like hostapd in
 * 25-wifi.sh and sshd in 35-devtools.sh. It lives in /build/sandbox-test
 * and exists to produce a list that is then committed as C. A tracer on
 * the target would be a second way to inspect a process on a system
 * whose whole argument is that there is one.
 *
 * WHY NOT SECCOMP_RET_LOG, which is the obvious answer. It needs
 * `audit_seccomp()`, which without `CONFIG_AUDIT` is a no-op stub in
 * include/linux/audit.h -- so on this kernel RET_LOG allows the syscall
 * and logs NOTHING. Checked in the config, not assumed: `CONFIG_AUDIT`
 * appears nowhere in kernel/config-x86_64. A logging mode that silently
 * logs nothing is worse than no logging mode, and enabling audit to get
 * it is a kernel change for an instrument.
 *
 * So: ptrace(2), which needs nothing from the config.
 *
 *   novi-syscalls [-o FILE] -- CMD [ARGS]
 *
 * One syscall number per line, sorted. **-o, and not stdout**: the
 * traced program inherits this process's stdout, so a list written
 * there arrives interleaved with whatever the program printed. Caught
 * by the tool disagreeing with itself -- `35 distinct syscall(s)` on
 * stderr beside a 50-line output file, the other fifteen being
 * novi-recon's report. Without -o the list still goes to stdout, which
 * is fine for a program that prints nothing and wrong the moment one
 * does, so the count is always on stderr for comparison.
 *
 * IT FOLLOWS CHILDREN. A tracer that traces only the first process
 * reports a subset and cannot tell you it did -- the silent-elision bug
 * class. PTRACE_O_TRACEFORK|VFORK|CLONE, and PTRACE_O_EXITKILL so a
 * tracer that dies does not leave a stopped process behind.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ptrace.h>
#include <sys/user.h>
#include <sys/wait.h>

/* x86_64 has fewer than 512 syscalls; anything above that is not one. */
#define NSYS 1024
static bool seen[NSYS];
static long unknown_high;

static void die(const char *what) {
	fprintf(stderr, "novi-syscalls: %s: %s\n", what, strerror(errno));
	exit(125);
}

int main(int argc, char **argv) {
	int i = 1;
	const char *outpath = NULL;
	for (; i < argc; i++) {
		if (strcmp(argv[i], "--") == 0) {
			i++;
			break;
		}
		if (strcmp(argv[i], "-o") == 0 && i + 1 < argc) {
			outpath = argv[++i];
			continue;
		}
		break;
	}
	if (i >= argc) {
		fprintf(stderr, "usage: novi-syscalls [-o FILE] -- CMD [ARGS]\n");
		return 2;
	}
	/* Opened BEFORE the fork, so a path that cannot be written is an
	 * error instead of a trace nobody kept. */
	FILE *out = stdout;
	if (outpath != NULL) {
		out = fopen(outpath, "w");
		if (out == NULL) {
			die("open -o file");
		}
	}

	pid_t root = fork();
	if (root < 0) {
		die("fork");
	}
	if (root == 0) {
		if (ptrace(PTRACE_TRACEME, 0, NULL, NULL) != 0) {
			die("PTRACE_TRACEME");
		}
		/* Stop here so the parent can set its options before the first
		 * syscall of the new program is made. Without this the execve
		 * itself -- and anything the loader does before the tracer
		 * attaches its options -- is missed. */
		raise(SIGSTOP);
		execvp(argv[i], &argv[i]);
		die("exec");
	}

	int status = 0;
	if (waitpid(root, &status, 0) < 0) {
		die("waitpid");
	}
	if (ptrace(PTRACE_SETOPTIONS, root, 0,
			(void *)(PTRACE_O_TRACEFORK | PTRACE_O_TRACEVFORK |
				PTRACE_O_TRACECLONE | PTRACE_O_TRACESYSGOOD |
				PTRACE_O_EXITKILL)) != 0) {
		die("PTRACE_SETOPTIONS");
	}
	if (ptrace(PTRACE_SYSCALL, root, 0, 0) != 0) {
		die("PTRACE_SYSCALL");
	}

	/* One stop per syscall ENTRY and one per EXIT, and this counts both
	 * -- reading the number on entry and ignoring the exit would need
	 * per-tracee state to know which stop this is, for no gain: the
	 * number is the same at both ends and a set does not care about
	 * duplicates. */
	int live = 1;
	while (live > 0) {
		pid_t pid = waitpid(-1, &status, __WALL);
		if (pid < 0) {
			if (errno == EINTR) {
				continue;
			}
			break;
		}
		if (WIFEXITED(status) || WIFSIGNALED(status)) {
			live--;
			continue;
		}
		if (!WIFSTOPPED(status)) {
			continue;
		}

		int sig = WSTOPSIG(status);
		unsigned event = (unsigned)status >> 16;
		if (event == PTRACE_EVENT_FORK || event == PTRACE_EVENT_VFORK ||
				event == PTRACE_EVENT_CLONE) {
			/* The new tracee is stopped and already has our options
			 * inherited; it is counted here so the loop knows how many
			 * processes it is waiting for. */
			live++;
			sig = 0;
		} else if (sig == (SIGTRAP | 0x80)) {
			struct user_regs_struct regs;
			if (ptrace(PTRACE_GETREGS, pid, NULL, &regs) == 0) {
				long nr = (long)regs.orig_rax;
				if (nr >= 0 && nr < NSYS) {
					seen[nr] = true;
				} else if (nr >= NSYS && nr > unknown_high) {
					unknown_high = nr;
				}
			}
			sig = 0;
		} else if (sig == SIGTRAP || sig == SIGSTOP) {
			/* Our own attach stops, not the program's business. */
			sig = 0;
		}
		if (ptrace(PTRACE_SYSCALL, pid, 0, (void *)(long)sig) != 0) {
			/* A tracee that exited between the wait and here is
			 * ordinary; anything else is worth knowing about. */
			if (errno != ESRCH) {
				die("PTRACE_SYSCALL (resume)");
			}
		}
	}

	int count = 0;
	for (long n = 0; n < NSYS; n++) {
		if (seen[n]) {
			fprintf(out, "%ld\n", n);
			count++;
		}
	}
	if (out != stdout && fclose(out) != 0) {
		die("closing -o file");
	}
	fprintf(stderr, "novi-syscalls: %d distinct syscall(s)\n", count);
	if (unknown_high > 0) {
		fprintf(stderr, "novi-syscalls: WARNING: a syscall number above "
			"%d was made (%ld) and is not in the list above\n",
			NSYS - 1, unknown_high);
	}
	return 0;
}
