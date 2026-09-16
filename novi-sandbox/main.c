/* novi-sandbox — run a program with a filesystem, a process table and a
 * syscall surface of its own (RFC 0039).
 *
 * RFC 0031 said this three times and never scheduled it:
 *
 *     a bound and a priority change what a hostile page can do to the
 *     machine, and nothing at all about what it can do inside the
 *     process that parsed it
 *
 * The reason it kept being deferred was an assumption that it needed
 * something this system does not have. It does not. The kernel config
 * has carried `CONFIG_USER_NS`, `CONFIG_PID_NS`, `CONFIG_IPC_NS`,
 * `CONFIG_UTS_NS`, `CONFIG_NET_NS`, `CONFIG_SECCOMP` and
 * `CONFIG_SECCOMP_FILTER` since it was written; the seccomp and BPF
 * headers are in the sysroot; and busybox already ships `unshare`,
 * `nsenter` and `setpriv`. **No new dependency at all** — the same
 * finding RFC 0031 made about the browser itself, one layer down.
 *
 * WHAT THIS IS
 *
 *   novi-sandbox [--ro PATH]... [--rw PATH]... [--no-net] -- CMD [ARGS]
 *
 * The child gets:
 *
 *   - a NEW ROOT that is an empty tmpfs plus exactly the paths named on
 *     the command line. Default deny: a path nobody named is not there,
 *     rather than there and hopefully harmless.
 *   - its own PID namespace, so it cannot see or signal anything else
 *     on the machine, and a `/proc` that shows only itself.
 *   - its own IPC and UTS namespaces.
 *   - a seccomp filter refusing the syscalls a drawing program has no
 *     business making.
 *   - no capabilities it can regain: `PR_SET_NO_NEW_PRIVS`, which is
 *     also what lets an unprivileged process install a filter at all.
 *
 * WHAT THIS IS NOT, and both halves matter:
 *
 *   - **It is not a network boundary by default.** A browser's whole
 *     job is the network. `--no-net` gives an empty network namespace
 *     for programs that have no such excuse, and saying "sandboxed"
 *     without saying which of the two you got would be the kind of
 *     overclaim RFC 0025 warns about with the word "Mesa".
 *   - **The syscall filter is a DENYLIST.** An allowlist is stronger
 *     and is what bubblewrap-class sandboxes build; it also has to know
 *     every syscall the program and its libc will ever make, and
 *     getting that wrong turns a working browser into a crash on a page
 *     nobody tested. A denylist closes the doors that are known to lead
 *     somewhere and leaves the rest open. It is the weaker half of a
 *     real sandbox and this file says so rather than letting the word
 *     "seccomp" imply the stronger one.
 *   - **There is no Landlock.** `CONFIG_SECURITY_LANDLOCK` is not in
 *     this kernel's config — checked, not assumed — so filesystem
 *     confinement here is entirely the mount namespace. That is a
 *     kernel change and it is the natural next step.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stddef.h>
#include <sched.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>

#define MAX_BINDS 64

/* The staging directory is mkdtemp()'d rather than a fixed name under
 * /tmp. A fixed name in a world-writable directory is a name somebody
 * else can create first -- as a symlink -- and this program then
 * builds a root filesystem inside whatever it points at. The mount
 * namespace makes the result invisible to them, which is not the same
 * as making it harmless. 0700 and unguessable costs one call.
 *
 * 64 bytes, not PATH_MAX, and that is -Wformat-truncation's doing --
 * for the sixth time in this repository it was right. A PATH_MAX
 * source appended to in a PATH_MAX destination can truncate, and the
 * fix it points at is the CLAMP rather than a wider buffer: the
 * template below is 25 characters and nothing else is ever written
 * here. */
static char newroot[64];

struct bind {
	const char *path;
	bool writable;
};

static struct bind binds[MAX_BINDS];
static int bind_count;

static void die(const char *what) {
	fprintf(stderr, "novi-sandbox: %s: %s\n", what, strerror(errno));
	_exit(125);
}

static void die_msg(const char *what) {
	fprintf(stderr, "novi-sandbox: %s\n", what);
	_exit(125);
}

/* mkdir -p, because a bind target three levels down needs its parents
 * and the new root starts empty. */
static int mkdir_p(const char *path, mode_t mode) {
	char tmp[PATH_MAX];
	if (snprintf(tmp, sizeof(tmp), "%s", path) >= (int)sizeof(tmp)) {
		errno = ENAMETOOLONG;
		return -1;
	}
	for (char *p = tmp + 1; *p != '\0'; p++) {
		if (*p != '/') {
			continue;
		}
		*p = '\0';
		if (mkdir(tmp, mode) != 0 && errno != EEXIST) {
			return -1;
		}
		*p = '/';
	}
	if (mkdir(tmp, mode) != 0 && errno != EEXIST) {
		return -1;
	}
	return 0;
}

/* Writing a map is a one-shot: the file takes a single write and the
 * kernel refuses a second. setgroups has to be denied BEFORE gid_map,
 * or the gid_map write fails with EPERM -- and the error says nothing
 * about setgroups, which is why this order is a comment and not a
 * coincidence. */
static void write_file(const char *path, const char *text) {
	int fd = open(path, O_WRONLY);
	if (fd < 0) {
		die(path);
	}
	if (write(fd, text, strlen(text)) < 0) {
		die(path);
	}
	close(fd);
}

static void map_self(uid_t uid, gid_t gid) {
	char buf[64];
	write_file("/proc/self/setgroups", "deny");
	snprintf(buf, sizeof(buf), "%u %u 1\n", (unsigned)gid, (unsigned)gid);
	write_file("/proc/self/gid_map", buf);
	snprintf(buf, sizeof(buf), "%u %u 1\n", (unsigned)uid, (unsigned)uid);
	write_file("/proc/self/uid_map", buf);
}

/* A bind mount is TWO operations. `MS_BIND|MS_RDONLY` in one call does
 * not produce a read-only mount -- the kernel takes the flags from the
 * source mount and silently ignores the rest, which is a bind that
 * reads as confined and is not. The remount is what makes it true, and
 * it must repeat MS_BIND or it applies to the wrong thing. */
/* `allow_dev` exists because MS_NODEV IS NOT FREE HERE, and the
 * evidence was three layers away from the cause.
 *
 * Every bind gets MS_NOSUID|MS_NODEV, which is right for a directory
 * somebody named on the command line and exactly wrong for the device
 * nodes this program mounts ITSELF: MS_NODEV means a device node on
 * that mount cannot be OPENED, so /dev/urandom was present, correct,
 * and unreadable. What that looked like from outside was the browser
 * printing `curl_global_init failed` -- mbedTLS could not seed its
 * DRBG -- with nothing anywhere mentioning /dev.
 *
 * So the flag is per-bind rather than a constant, and the only binds
 * that get devices are the six this file creates. A path the caller
 * named still gets MS_NODEV: if they want a device inside, they can
 * say so when there is a reason to. */
static void bind_one(const char *path, bool writable, bool allow_dev) {
	struct stat st;
	if (stat(path, &st) != 0) {
		/* A path that is not on this machine is not an error: the
		 * caller names what a program MIGHT need, and a desktop
		 * without a font directory should still get a browser that
		 * starts and says what is missing itself. */
		fprintf(stderr, "novi-sandbox: skipping %s (not present)\n", path);
		return;
	}
	char target[PATH_MAX];
	if (snprintf(target, sizeof(target), "%s%s", newroot, path) >=
			(int)sizeof(target)) {
		die_msg("bind path too long");
	}
	if (S_ISDIR(st.st_mode)) {
		if (mkdir_p(target, 0755) != 0) {
			die(target);
		}
	} else {
		char *slash = strrchr(target, '/');
		if (slash != NULL) {
			*slash = '\0';
			if (mkdir_p(target, 0755) != 0) {
				die(target);
			}
			*slash = '/';
		}
		int fd = open(target, O_WRONLY | O_CREAT | O_EXCL, 0644);
		if (fd < 0 && errno != EEXIST) {
			die(target);
		}
		if (fd >= 0) {
			close(fd);
		}
	}
	if (mount(path, target, NULL, MS_BIND | MS_REC, NULL) != 0) {
		die(path);
	}
	unsigned long flags = MS_BIND | MS_REMOUNT | MS_NOSUID;
	if (!allow_dev) {
		flags |= MS_NODEV;
	}
	if (!writable) {
		flags |= MS_RDONLY;
	}
	if (mount(NULL, target, NULL, flags, NULL) != 0) {
		die("remount");
	}
}

/* The syscalls a program that draws a window has no business making.
 *
 * EPERM rather than SECCOMP_RET_KILL_PROCESS, deliberately: a killed
 * process tells the person nothing except that their browser vanished,
 * where a refused syscall usually surfaces as the program's own error
 * message. The exception would be a filter meant to catch an exploit in
 * the act, which this is not -- this is meant to remove the tools an
 * exploit would reach for.
 */
static const int denied[] = {
	/* Reading or writing another process. */
	SYS_ptrace, SYS_process_vm_readv, SYS_process_vm_writev,
	/* The kernel's own code. */
	SYS_init_module, SYS_finit_module, SYS_delete_module,
	SYS_kexec_load, SYS_kexec_file_load,
	/* Namespaces and mounts: everything this program just built. */
	SYS_mount, SYS_umount2, SYS_pivot_root, SYS_setns, SYS_unshare,
	SYS_chroot,
	/* Interfaces that exist to observe or extend the kernel. */
	SYS_bpf, SYS_perf_event_open, SYS_userfaultfd,
	/* The keyring, which is a place to hide things. */
	SYS_add_key, SYS_request_key, SYS_keyctl,
	/* Filesystem handles that address a file without a path, so they
	 * reach outside a mount namespace by design. */
	SYS_name_to_handle_at, SYS_open_by_handle_at,
	/* Machine-wide state. */
	SYS_swapon, SYS_swapoff, SYS_reboot, SYS_acct, SYS_quotactl,
	SYS_settimeofday, SYS_clock_settime, SYS_sethostname,
	SYS_setdomainname,
	/* io_uring: a second, much less examined syscall surface. */
	SYS_io_uring_setup, SYS_io_uring_enter, SYS_io_uring_register,
};

#define DENIED_COUNT ((int)(sizeof(denied) / sizeof(denied[0])))

/* Written out rather than through BPF_STMT()/BPF_JUMP(). Those macros
 * expand to a braced initializer meant for an array, and using one as
 * a compound literal draws -Wmissing-field-initializers here; a named
 * initializer says what each field is anyway, which those four
 * positional values do not. */
static struct sock_filter bpf_stmt(unsigned short code, unsigned k) {
	struct sock_filter f = { .code = code, .jt = 0, .jf = 0, .k = k };
	return f;
}

static struct sock_filter bpf_jump(unsigned short code, unsigned k,
		unsigned char jt, unsigned char jf) {
	struct sock_filter f = { .code = code, .jt = jt, .jf = jf, .k = k };
	return f;
}

static void install_filter(void) {
	/* Two instructions per denied call, plus the architecture check and
	 * the two terminators. The architecture check is not decoration: a
	 * syscall NUMBER means nothing without it, and a 32-bit process
	 * entering through the compat layer would otherwise be filtered
	 * against a table that is not its own. */
	struct sock_filter *f = calloc(DENIED_COUNT * 2 + 5, sizeof(*f));
	if (f == NULL) {
		die_msg("out of memory building the filter");
	}
	int n = 0;
	/* arch != x86_64 -> kill. Anything that is not this ABI is not
	 * something this filter can reason about: a syscall NUMBER is
	 * meaningless without knowing whose table it indexes. */
	f[n++] = bpf_stmt(BPF_LD | BPF_W | BPF_ABS,
		offsetof(struct seccomp_data, arch));
	f[n++] = bpf_jump(BPF_JMP | BPF_JEQ | BPF_K, AUDIT_ARCH_X86_64, 1, 0);
	f[n++] = bpf_stmt(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS);
	f[n++] = bpf_stmt(BPF_LD | BPF_W | BPF_ABS,
		offsetof(struct seccomp_data, nr));
	for (int i = 0; i < DENIED_COUNT; i++) {
		f[n++] = bpf_jump(BPF_JMP | BPF_JEQ | BPF_K,
			(unsigned)denied[i], 0, 1);
		f[n++] = bpf_stmt(BPF_RET | BPF_K,
			SECCOMP_RET_ERRNO | (EPERM & SECCOMP_RET_DATA));
	}
	f[n++] = bpf_stmt(BPF_RET | BPF_K, SECCOMP_RET_ALLOW);

	struct sock_fprog prog = { .len = (unsigned short)n, .filter = f };
	/* NO_NEW_PRIVS first, and it is doing two jobs: it is what allows
	 * an unprivileged process to install a filter at all, and it is
	 * what stops a setuid binary inside the sandbox handing back what
	 * the sandbox took away. */
	if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) {
		die("prctl(PR_SET_NO_NEW_PRIVS)");
	}
	if (syscall(SYS_seccomp, SECCOMP_SET_MODE_FILTER, 0, &prog) != 0) {
		die("seccomp");
	}
}

/* THE SUPERVISOR'S SIGNALS, and a kernel rule that makes both halves
 * of this necessary rather than tidy.
 *
 * The child is pid 1 of its own PID namespace, and the kernel gives
 * such a process the same protection it gives the machine's init: a
 * signal whose disposition is SIG_DFL is DISCARDED when it comes from
 * outside the namespace, and `kill(2)` returns 0 for it. Measured on a
 * booted machine, not read off a man page -- `kill <child>` reported
 * success and the process was still there two seconds later; `kill -9`
 * ended it. SIGKILL and SIGSTOP are the exception the kernel makes,
 * and only from an ancestor namespace.
 *
 * So there are two ways for this program to leave a runaway behind,
 * and they need different answers:
 *
 *   - THE SUPERVISOR IS SIGNALLED. Without a handler it dies on
 *     SIGTERM and the child, being nobody's child now, carries on
 *     forever. Watched live: `kill <novi-sandbox>` left a `sleep 300`
 *     running with its supervisor gone. So the signal is FORWARDED --
 *     and because a default-action forward is discarded by the rule
 *     above, a SECOND signal of any of these is SIGKILL. Escalation is
 *     the sender doing it again, never a timer: RFC 0038 argues that
 *     for the force-quit key and the argument is the same here, since
 *     from out here "handled it and is shutting down" and "the kernel
 *     threw it away" look identical.
 *   - THE SUPERVISOR IS SIGKILLED, which no handler can forward. That
 *     is PR_SET_PDEATHSIG's case, set in the child below.
 *
 * A shell's Ctrl+C is fine either way -- it signals the whole
 * foreground process group, so both get it -- which is most of why
 * this went unnoticed until something used `kill` on a pid. */
static volatile sig_atomic_t child_pid;
static volatile sig_atomic_t already_forwarded;

static void forward_signal(int sig) {
	int saved = errno;
	if (child_pid > 0) {
		kill((pid_t)child_pid, already_forwarded ? SIGKILL : sig);
		already_forwarded = 1;
	}
	errno = saved;
}

static void forward_signals_to_child(void) {
	static const int fwd[] = { SIGTERM, SIGINT, SIGHUP, SIGQUIT };
	struct sigaction sa;
	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = forward_signal;
	sigemptyset(&sa.sa_mask);
	/* No SA_RESTART: the waitpid() below already retries on EINTR, and
	 * an interrupted wait is how the parent notices a child that the
	 * forwarded signal actually ended. */
	for (size_t i = 0; i < sizeof(fwd) / sizeof(fwd[0]); i++) {
		if (sigaction(fwd[i], &sa, NULL) != 0) {
			die("sigaction");
		}
	}
}

static void usage(void) {
	fprintf(stderr,
		"Usage: novi-sandbox [--ro PATH]... [--rw PATH]... [--no-net]\n"
		"                    [--] COMMAND [ARGS...]\n"
		"\n"
		"Runs COMMAND with a root filesystem containing only the paths\n"
		"named, its own process table, and a seccomp filter.\n"
		"\n"
		"  --ro PATH   make PATH visible, read-only\n"
		"  --rw PATH   make PATH visible and writable\n"
		"  --no-net    an empty network namespace (NOT the default:\n"
		"              a browser needs the network)\n");
	_exit(2);
}

int main(int argc, char **argv) {
	bool no_net = false;
	int i = 1;
	for (; i < argc; i++) {
		if (strcmp(argv[i], "--") == 0) {
			i++;
			break;
		} else if (strcmp(argv[i], "--ro") == 0 ||
				strcmp(argv[i], "--rw") == 0) {
			if (i + 1 >= argc) {
				usage();
			}
			if (bind_count >= MAX_BINDS) {
				die_msg("too many paths");
			}
			binds[bind_count].writable = argv[i][3] == 'w';
			binds[bind_count].path = argv[i + 1];
			bind_count++;
			i++;
		} else if (strcmp(argv[i], "--no-net") == 0) {
			no_net = true;
		} else if (strcmp(argv[i], "-h") == 0 ||
				strcmp(argv[i], "--help") == 0) {
			usage();
		} else {
			break;
		}
	}
	if (i >= argc) {
		usage();
	}
	char **cmd = &argv[i];

	uid_t uid = getuid();
	gid_t gid = getgid();

	/* CLONE_NEWUSER in the SAME call as the rest, and first. An
	 * unprivileged process may create the other namespaces only as a
	 * side effect of creating a user namespace it owns; two separate
	 * unshare() calls fail with EPERM on the second.
	 *
	 * THE SET IS ASKED FOR RATHER THAN ASSUMED, because this kernel
	 * does not have all of them. `CONFIG_IPC_NS` depends on
	 * `CONFIG_SYSVIPC`, which Novi's kernel deliberately does not set
	 * (RFC 0004 found that out from the other end: busybox syslogd's
	 * `-C` logs to a SysV shm ring and therefore logs nowhere here).
	 * A machine with no System V IPC has nothing for an IPC namespace
	 * to isolate -- so asking for one is not a stricter sandbox, it is
	 * `unshare()` returning EINVAL and no sandbox at all. That is
	 * exactly what it did on the first booted run, with the kernel
	 * config saying `CONFIG_IPC_NS=y` and olddefconfig having silently
	 * dropped it.
	 *
	 * /proc/self/ns lists what this kernel actually supports. */
	int flags = CLONE_NEWUSER | CLONE_NEWNS | CLONE_NEWPID;
	if (access("/proc/self/ns/ipc", F_OK) == 0) {
		flags |= CLONE_NEWIPC;
	}
	if (access("/proc/self/ns/uts", F_OK) == 0) {
		flags |= CLONE_NEWUTS;
	}
	if (no_net) {
		if (access("/proc/self/ns/net", F_OK) != 0) {
			die_msg("--no-net: this kernel has no network namespaces");
		}
		flags |= CLONE_NEWNET;
	}
	if (unshare(flags) != 0) {
		if (errno == EPERM || errno == EINVAL) {
			fprintf(stderr,
				"novi-sandbox: the kernel refused to create a user "
				"namespace (%s).\n"
				"              This build sets CONFIG_USER_NS; check "
				"/proc/sys/user/max_user_namespaces\n"
				"              and kernel.unprivileged_userns_clone.\n",
				strerror(errno));
			_exit(125);
		}
		die("unshare");
	}
	map_self(uid, gid);

	/* CLONE_NEWPID takes effect for CHILDREN, not for the process that
	 * asked. So everything below happens after a fork, in a process
	 * that is pid 1 of the new namespace -- which is also what makes
	 * the fresh /proc show only the sandbox. */
	/* A LIFELINE, because the obvious race check cannot work here.
	 * PR_SET_PDEATHSIG has a window: if the supervisor dies between
	 * fork() and the prctl(), the signal has already been sent and
	 * nothing will send another. Everywhere else in Unix that is
	 * closed by comparing getppid() against the pid captured before
	 * the fork -- and in a NEW PID NAMESPACE getppid() is 0, always,
	 * because the parent has no pid in the namespace to report. So
	 * the check reads as load-bearing, can never pass, and exits the
	 * child immediately: the first build of this did exactly that,
	 * and reported it as a supervisor exiting 125 with nothing on
	 * stderr.
	 *
	 * A pipe says the same thing without needing a shared namespace.
	 * The child closes its write end and then asks whether the pipe
	 * is already at EOF; it can only be if the supervisor's end is
	 * closed too, which means the supervisor is gone. O_CLOEXEC so
	 * neither descriptor reaches the program being sandboxed. */
	int lifeline[2];
	if (pipe2(lifeline, O_CLOEXEC) != 0) {
		die("pipe");
	}
	pid_t pid = fork();
	if (pid < 0) {
		die("fork");
	}
	if (pid > 0) {
		int status = 0;
		close(lifeline[0]);
		child_pid = (sig_atomic_t)pid;
		forward_signals_to_child();
		while (waitpid(pid, &status, 0) < 0) {
			if (errno != EINTR) {
				die("waitpid");
			}
		}
		/* A pid is a number the kernel reuses, and this is the only
		 * place this program acts on one. Past the wait it names
		 * nothing, so a signal arriving now must not be forwarded to
		 * whoever inherits the number. */
		child_pid = 0;
		if (WIFEXITED(status)) {
			return WEXITSTATUS(status);
		}
		if (WIFSIGNALED(status)) {
			return 128 + WTERMSIG(status);
		}
		return 1;
	}

	/* SIGKILL, and it has to be SIGKILL: this process is pid 1 of the
	 * namespace it was just created in, so a default-action SIGTERM
	 * from the outside is discarded by the rule described above the
	 * forwarder. A PDEATHSIG the kernel throws away is a death switch
	 * that reads as load-bearing and cannot fire.
 */
	if (prctl(PR_SET_PDEATHSIG, SIGKILL, 0, 0, 0) != 0) {
		die("prctl PR_SET_PDEATHSIG");
	}
	close(lifeline[1]);
	if (fcntl(lifeline[0], F_SETFL, O_NONBLOCK) == 0) {
		char probe;
		if (read(lifeline[0], &probe, 1) == 0) {
			_exit(125);   /* the supervisor is already gone */
		}
	}
	close(lifeline[0]);

	/* Nothing this process mounts may propagate back to the machine.
	 * Without this the new root's binds appear on the real filesystem,
	 * which is the sandbox leaking in the one direction nobody looks. */
	if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) != 0) {
		die("mount --make-rprivate /");
	}
	snprintf(newroot, sizeof(newroot), "/tmp/.novi-sandbox-XXXXXX");
	if (mkdtemp(newroot) == NULL) {
		die("mkdtemp");
	}
	if (mount("tmpfs", newroot, "tmpfs", MS_NOSUID | MS_NODEV,
			"mode=0755") != 0) {
		die("mount tmpfs");
	}
	for (int b = 0; b < bind_count; b++) {
		bind_one(binds[b].path, binds[b].writable, false);
	}
	/* A private /tmp, always. Every program expects one, and sharing
	 * the machine's is a two-way channel by definition. */
	char tmpdir[PATH_MAX];
	snprintf(tmpdir, sizeof(tmpdir), "%s/tmp", newroot);
	if (mkdir_p(tmpdir, 01777) != 0) {
		die(tmpdir);
	}
	if (mount("tmpfs", tmpdir, "tmpfs", MS_NOSUID | MS_NODEV,
			"mode=1777") != 0) {
		die("mount /tmp");
	}
	/* A minimal /dev, always, rather than something every caller has to
	 * remember to ask for. Nothing runs without /dev/null, and a
	 * program denied /dev/urandom usually fails somewhere far from the
	 * cause. Bind-mounted, not mknod'd: creating a device node needs a
	 * capability the user namespace does not grant over the real
	 * filesystem, and binding the node that already exists needs
	 * none. */
	char devdir[PATH_MAX];
	snprintf(devdir, sizeof(devdir), "%s/dev", newroot);
	if (mkdir_p(devdir, 0755) != 0) {
		die(devdir);
	}
	if (mount("tmpfs", devdir, "tmpfs", MS_NOSUID, "mode=0755") != 0) {
		die("mount /dev");
	}
	static const char *const devnodes[] = {
		"/dev/null", "/dev/zero", "/dev/full",
		"/dev/random", "/dev/urandom", "/dev/tty",
	};
	for (size_t d = 0; d < sizeof(devnodes) / sizeof(devnodes[0]); d++) {
		bind_one(devnodes[d], true, true);
	}

	char procdir[PATH_MAX];
	snprintf(procdir, sizeof(procdir), "%s/proc", newroot);
	if (mkdir_p(procdir, 0555) != 0) {
		die(procdir);
	}
	if (mount("proc", procdir, "proc",
			MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL) != 0) {
		die("mount /proc");
	}

	/* pivot_root, not chroot. chroot leaves the old root reachable
	 * through any directory fd that survives it and through `..` from a
	 * directory outside the new tree; pivot_root replaces the process's
	 * idea of the filesystem and then the old one is unmounted. */
	char oldroot[PATH_MAX];
	snprintf(oldroot, sizeof(oldroot), "%s/.oldroot", newroot);
	if (mkdir_p(oldroot, 0755) != 0) {
		die(oldroot);
	}
	if (syscall(SYS_pivot_root, newroot, oldroot) != 0) {
		die("pivot_root");
	}
	if (chdir("/") != 0) {
		die("chdir /");
	}
	if (umount2("/.oldroot", MNT_DETACH) != 0) {
		die("umount /.oldroot");
	}
	if (rmdir("/.oldroot") != 0 && errno != EBUSY) {
		die("rmdir /.oldroot");
	}

	install_filter();

	execvp(cmd[0], cmd);
	fprintf(stderr, "novi-sandbox: %s: %s\n", cmd[0], strerror(errno));
	_exit(127);
}
