/* places.h — the sidebar's model: where you can go from here.
 *
 * Home, the filesystem root, and every removable volume novi-mount has
 * put under /run/media (RFC 0023). Data only; main.c draws it.
 *
 * The volumes are read from /proc/self/mounts rather than by listing
 * /run/media, and the difference matters: a directory can be there
 * without anything mounted on it (novi-mount leaves one behind if a
 * mount fails between mkdir and mount), and the sidebar would then
 * offer a place that is an empty directory. /proc/mounts is the
 * kernel's own answer to "what is mounted", which is the question.
 */
#ifndef NOVI_FILES_PLACES_H
#define NOVI_FILES_PLACES_H

#include <limits.h>
#include <stdbool.h>

#define PLACES_MAX 24
#define PLACE_LABEL_MAX 64

enum place_kind {
	PLACE_HOME,
	PLACE_ROOT,
	PLACE_VOLUME,
};

struct place {
	enum place_kind kind;
	char label[PLACE_LABEL_MAX];
	char path[PATH_MAX];
	/* Volumes only, and DISPLAY ONLY: the device node the kernel
	 * reports, shown so a person can tell two identically-labelled
	 * sticks apart. Eject is given `path`, never this -- a truncated
	 * device name would still be a valid-looking device name, and
	 * a truncated path is caught by novi-eject as "no such volume".
	 * That asymmetry is the reason the field is allowed to truncate
	 * at all. */
	char source[64];
};

/* Fills `out` and returns how many. Never fails: the two fixed places
 * are always there, so the sidebar is never empty and never has to
 * render an error state. */
int novi_places_read(struct place *out, int max);

/* A file descriptor that becomes ready when the mount table changes,
 * or -1. Poll it for POLLPRI | POLLERR -- not POLLIN, which never
 * fires for this file. */
int novi_places_watch_open(void);

/* MUST be called on every wake, before polling again. See places.c. */
void novi_places_watch_drain(int fd);

#endif
