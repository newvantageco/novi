/* novi-umh — the one binary the kernel is allowed to execute.
 *
 * kernel/config-x86_64 sets CONFIG_STATIC_USERMODEHELPER=y, in the
 * hardening block, and has since that block existed. What that option
 * does is redirect EVERY usermode-helper call the kernel makes --
 * request_module() above all -- to the single fixed path in
 * CONFIG_STATIC_USERMODEHELPER_PATH, which defaults to
 * /sbin/usermode-helper. This image never contained that file.
 *
 * So every kernel-initiated module autoload on this system has failed,
 * silently, for the entire life of the project. Nothing noticed,
 * because every module this image loads is loaded by something in
 * userspace naming it: /init's list, novi-hwdetect's modalias walk,
 * novi-hotplug's uevents. It surfaced only when nftables asked the
 * kernel to add a `ct` rule, the kernel tried to autoload nft_ct,
 * nothing ran, and the error came back as ENOENT -- "Could not process
 * rule: No such file or directory", which reads like a missing file
 * and is actually a missing exec.
 *
 * The option is worth keeping. modprobe_path and core_pattern are
 * writable by root, and pinning what the kernel can exec to one
 * compiled-in path is a real constraint on what an attacker who
 * reaches them can do with it. What was missing is the other half:
 * the program at that path.
 *
 * The kernel puts the helper it MEANT to run in argv[0] and leaves the
 * rest of the argument vector alone, so this is a filter, not a
 * dispatcher: check argv[0] against a list compiled into this binary,
 * and exec it unchanged.
 *
 * Static, because it runs before anything is guaranteed to be mounted
 * and because a dynamic loader is one more thing between the kernel
 * and the decision this program exists to make.
 */
#include <fcntl.h>
#include <string.h>
#include <unistd.h>

/* Exactly what this system's kernel actually calls, and nothing else.
 *
 * One entry, and that is not an oversight. request_module() is the
 * only usermode helper this configuration reaches: /proc/sys/kernel/
 * hotplug is empty (uevents go over netlink to busybox `uevent`, RFC
 * 0012), core_pattern names a file rather than a pipe, and nothing
 * here uses request-key or nfsd. Listing helpers "in case" would
 * widen exactly the surface the option exists to narrow.
 *
 * A refusal is loud on purpose. The bug this program fixes was a
 * silent exec failure; a silent refusal would be the same bug wearing
 * a different hat, and the next person to add a helper the kernel
 * calls needs to find the reason it did not run in dmesg rather than
 * in this file.
 */
static const char *const ALLOWED[] = {
	"/sbin/modprobe",
};
#define ALLOWED_COUNT ((int)(sizeof(ALLOWED) / sizeof(ALLOWED[0])))

/* No stdio: this runs in a kernel-spawned process with an environment
 * nobody chose, and /dev/kmsg is where a message has somewhere to go
 * even when nothing else is up yet. Failure to log is not failure to
 * decide, so the result is ignored. */
static void kmsg(const char *a, const char *b) {
	int fd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
	if (fd < 0) {
		return;
	}
	(void)!write(fd, a, strlen(a));
	if (b != NULL) {
		(void)!write(fd, b, strlen(b));
	}
	(void)!write(fd, "\n", 1);
	close(fd);
}

int main(int argc, char **argv) {
	if (argc < 1 || argv[0] == NULL || argv[0][0] == '\0') {
		kmsg("novi-umh: refused a call with no program name", NULL);
		return 1;
	}

	for (int i = 0; i < ALLOWED_COUNT; i++) {
		if (strcmp(argv[0], ALLOWED[i]) == 0) {
			execv(argv[0], argv);
			/* Allowed and still did not run: the file is missing or
			 * not executable. That is worth a line of its own -- it
			 * is a different fault from a refusal, and confusing the
			 * two is how this whole class of bug stays invisible. */
			kmsg("novi-umh: could not execute ", argv[0]);
			return 1;
		}
	}

	kmsg("novi-umh: refused ", argv[0]);
	return 1;
}
