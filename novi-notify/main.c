/* novi-notify — say something to whoever is looking.
 *
 *   novi-notify [-u low|normal|critical] [-i icon] <summary> [body]
 *
 * RFC 0024. Sends one notification to novi-notifyd and always records
 * it in syslog. Lives in the BASE image, deliberately: the things that
 * have something to say -- novi-mount when a stick arrives, novi-eject
 * when one is safe to pull -- are base tools that run on machines with
 * no desktop at all. A notifier that only exists when the desktop does
 * would have to be conditionally called by every one of them.
 *
 * NOT D-BUS, and that is the third time this project has declined it:
 * RFC 0009 rejected iwd and RFC 0023 rejected udisks2 on the same
 * grounds -- a message bus daemon in a base image whose entire point
 * is not having one. org.freedesktop.Notifications is the standard
 * interface and it is a D-Bus interface; what is actually needed here
 * is "hand a short string to a program that may not be running", and a
 * datagram socket is that, in about eighty lines.
 *
 * A UNIX DATAGRAM SOCKET, not a stream and not a FIFO, and each of
 * those is a decision:
 *
 *   - Datagram, so one message is one message. No framing to get
 *     wrong, no partial reads, no connection state, and no ordering
 *     between senders to reason about.
 *   - Not a stream, because a stream needs connect() to succeed and a
 *     daemon that is starting up would make senders block or fail
 *     depending on timing.
 *   - NOT A FIFO, which is the option a shell script could have used
 *     without any C at all. open(O_WRONLY) on a FIFO with no reader
 *     BLOCKS FOREVER. The largest caller here is a uevent handler,
 *     where blocking forever means the kernel's hotplug queue stops
 *     (RFC 0012), so the one transport a shell could reach is the one
 *     transport this must not use.
 *
 * With no daemon listening, sendto() fails immediately with ENOENT or
 * ECONNREFUSED and this exits 0. Having no desktop is not an error.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <syslog.h>
#include <unistd.h>

#define SOCK_PATH "/run/novi/notify.sock"

/* A datagram is bounded and so is this. The daemon caps what it will
 * accept at the same number, and anything longer is a caller with a
 * bug rather than a notification anybody wants to read. */
#define MSG_MAX 4096

static void usage(void) {
	fprintf(stderr,
		"Usage: novi-notify [-u low|normal|critical] [-i icon] <summary> [body]\n"
		"\n"
		"Shows a notification on the desktop, if there is one, and\n"
		"records it in syslog either way.\n");
	exit(1);
}

static int valid_urgency(const char *u) {
	return strcmp(u, "low") == 0 || strcmp(u, "normal") == 0 ||
		strcmp(u, "critical") == 0;
}

int main(int argc, char **argv) {
	const char *urgency = "normal";
	const char *icon = "";
	int opt;

	while ((opt = getopt(argc, argv, "u:i:h")) != -1) {
		switch (opt) {
		case 'u':
			urgency = optarg;
			if (!valid_urgency(urgency)) {
				fprintf(stderr, "novi-notify: urgency must be low, normal or critical\n");
				return 1;
			}
			break;
		case 'i': icon = optarg; break;
		default: usage();
		}
	}
	if (optind >= argc) {
		usage();
	}
	const char *summary = argv[optind];
	const char *body = (optind + 1 < argc) ? argv[optind + 1] : "";

	/* Syslog ALWAYS, delivered or not. A notification worth showing is
	 * worth recording, and on a console-only machine this line is the
	 * whole of the feature -- which is the reason this program is in
	 * the base image rather than beside the daemon. */
	openlog("novi-notify", 0, LOG_DAEMON);
	syslog(strcmp(urgency, "critical") == 0 ? LOG_WARNING : LOG_INFO,
		"%s%s%s", summary, body[0] ? ": " : "", body);
	closelog();

	/* Newline-separated key=value: greppable, trivially parsed, and
	 * debuggable by anyone who can point socat at the socket. The
	 * VALUES are untrusted text -- a filesystem label off a stranger's
	 * USB stick reaches this program as a summary -- so a newline
	 * inside one would forge a field. They are truncated at the first
	 * one here and re-checked by the daemon; the same call novi-wifi
	 * makes about an SSID and the package index makes about `|`.
	 * Checked on BOTH sides on purpose: this program is not the only
	 * thing that can write to that socket. */
	char msg[MSG_MAX];
	int n = snprintf(msg, sizeof(msg),
		"urgency=%s\nicon=%.32s\nsummary=%.200s\nbody=%.400s\n",
		urgency, icon, summary, body);
	if (n < 0) {
		return 1;
	}
	for (char *p = msg; *p != '\0'; p++) {
		/* Everything below space except the separator itself. */
		if ((unsigned char)*p < 0x20 && *p != '\n') {
			*p = ' ';
		}
	}
	size_t len = strlen(msg);

	int fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
	if (fd < 0) {
		return 0; /* no socket, no notification, no complaint */
	}
	struct sockaddr_un addr;
	memset(&addr, 0, sizeof(addr));
	addr.sun_family = AF_UNIX;
	snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", SOCK_PATH);

	if (sendto(fd, msg, len, MSG_NOSIGNAL,
			(struct sockaddr *)&addr, sizeof(addr)) < 0) {
		/* ENOENT: no daemon has ever bound it. ECONNREFUSED: the
		 * socket file is there but nothing is reading -- a daemon that
		 * died without unlinking. Both mean "nobody is looking", which
		 * on a console-only machine is the normal state and not
		 * something to print about. Anything else is worth a word. */
		if (errno != ENOENT && errno != ECONNREFUSED) {
			fprintf(stderr, "novi-notify: %s\n", strerror(errno));
		}
	}
	close(fd);
	return 0;
}
