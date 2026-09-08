/* places.c — see places.h. */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "places.h"

#define MEDIA_PREFIX "/run/media/"

/* /proc/mounts octal-escapes the four characters that would otherwise
 * break its own whitespace-separated format: space, tab, newline and
 * backslash, as \040 \011 \012 \134. Unescaping is not optional
 * politeness -- a mount point containing a space arrives as
 * "My\040Stick", and a sidebar that showed that, or that tried to
 * chdir into it, would be wrong in a way that only shows up on
 * somebody else's machine.
 *
 * novi-mount's own safe_name() means the paths IT creates never
 * contain any of these. Something mounted by hand under /run/media
 * can, and this file does not get to assume novi-mount is the only
 * thing that ever mounts anything. */
static void unescape_mount(const char *in, char *out, size_t outlen) {
	size_t o = 0;
	for (size_t i = 0; in[i] != '\0' && o + 1 < outlen; i++) {
		if (in[i] == '\\' && in[i + 1] >= '0' && in[i + 1] <= '7' &&
				in[i + 2] >= '0' && in[i + 2] <= '7' &&
				in[i + 3] >= '0' && in[i + 3] <= '7') {
			out[o++] = (char)(((in[i + 1] - '0') << 6) |
				((in[i + 2] - '0') << 3) | (in[i + 3] - '0'));
			i += 3;
		} else {
			out[o++] = in[i];
		}
	}
	out[o] = '\0';
}

int novi_places_read(struct place *out, int max) {
	int n = 0;
	const char *home = getenv("HOME");

	if (max <= 0) {
		return 0;
	}

	out[n].kind = PLACE_HOME;
	snprintf(out[n].label, sizeof(out[n].label), "Home");
	/* /root rather than giving up when HOME is unset: this program is
	 * routinely started from a getty, where it is not. */
	snprintf(out[n].path, sizeof(out[n].path), "%s",
		(home != NULL && home[0] == '/') ? home : "/root");
	out[n].source[0] = '\0';
	n++;

	if (n < max) {
		out[n].kind = PLACE_ROOT;
		snprintf(out[n].label, sizeof(out[n].label), "Filesystem");
		snprintf(out[n].path, sizeof(out[n].path), "/");
		out[n].source[0] = '\0';
		n++;
	}

	FILE *f = fopen("/proc/self/mounts", "re");
	if (f == NULL) {
		return n;
	}
	char line[PATH_MAX * 2 + 256];
	while (n < max && fgets(line, sizeof(line), f) != NULL) {
		char dev_raw[256], mp_raw[PATH_MAX];
		if (sscanf(line, "%255s %4095s", dev_raw, mp_raw) != 2) {
			continue;
		}
		char mp[PATH_MAX];
		unescape_mount(mp_raw, mp, sizeof(mp));
		if (strncmp(mp, MEDIA_PREFIX, strlen(MEDIA_PREFIX)) != 0) {
			continue;
		}
		/* Only one level down. A filesystem someone mounted *inside* a
		 * volume is part of that volume as far as the sidebar is
		 * concerned, not a second place to click. */
		if (strchr(mp + strlen(MEDIA_PREFIX), '/') != NULL) {
			continue;
		}

		out[n].kind = PLACE_VOLUME;
		snprintf(out[n].path, sizeof(out[n].path), "%s", mp);

		/* Explicit precisions rather than a bare %s, and not to quiet
		 * the compiler: -Wformat-truncation fires here because these
		 * really can truncate, and this repo has already shipped one
		 * bug that warning would have caught (a `.app` descriptor's
		 * exec= line, silently cut, registering an application whose
		 * command could not run). Truncating is correct for both of
		 * these -- see the comment on struct place -- and saying so in
		 * the format string is how a reader tells "considered" from
		 * "overlooked". */
		snprintf(out[n].label, sizeof(out[n].label), "%.*s",
			(int)sizeof(out[n].label) - 1, mp + strlen(MEDIA_PREFIX));

		char dev[256];
		unescape_mount(dev_raw, dev, sizeof(dev));
		snprintf(out[n].source, sizeof(out[n].source), "%.*s",
			(int)sizeof(out[n].source) - 1, dev);
		n++;
	}
	fclose(f);
	return n;
}

/* Watching the mount table.
 *
 * poll() on /proc/self/mounts is the kernel's own notification for
 * this -- it has been there since 2.6.15 and it is what every mount
 * monitor uses. It reports POLLPRI (and POLLERR), NEVER POLLIN, which
 * is the first thing to get wrong: a poll set up for POLLIN waits
 * forever and the sidebar silently never updates.
 *
 * The second thing to get wrong is worse, because it is not silent
 * for the user's fan: POLLPRI STAYS ASSERTED until the file is read
 * again. A loop that wakes, redraws and polls again without re-reading
 * spins at 100% CPU forever. novi_places_watch_drain() is that read,
 * and every wake has to call it.
 */
int novi_places_watch_open(void) {
	int fd = open("/proc/self/mounts", O_RDONLY | O_CLOEXEC);
	if (fd < 0) {
		return -1;
	}
	novi_places_watch_drain(fd);
	return fd;
}

void novi_places_watch_drain(int fd) {
	char buf[4096];
	if (fd < 0) {
		return;
	}
	if (lseek(fd, 0, SEEK_SET) == (off_t)-1) {
		return;
	}
	while (read(fd, buf, sizeof(buf)) > 0) {
		;
	}
}
