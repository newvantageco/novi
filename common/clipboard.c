#include "clipboard.h"

#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* The text MIME types worth asking for, best first. A source names
 * whatever it likes; we take the highest-ranked one it offered and ask
 * for exactly that. */
static const char *const TEXT_MIME[] = {
	"text/plain;charset=utf-8",
	"UTF8_STRING",
	"text/plain",
};
#define TEXT_MIME_COUNT ((int)(sizeof(TEXT_MIME) / sizeof(TEXT_MIME[0])))

/* Refuse to grow a paste past this. The far end is another program and
 * may be broken or hostile; an unbounded read from a pipe it controls is
 * an unbounded allocation it controls. */
#define PASTE_MAX_BYTES (16u * 1024u * 1024u)

/* Total time to wait for the owner to write. Generous, because it may be
 * doing real work to produce the data; bounded, because a source that
 * never writes must not hang the client's keyboard forever. */
#define PASTE_TIMEOUT_MS 3000

struct novi_clipboard {
	struct wl_display *display;
	struct wl_data_device_manager *manager;
	struct wl_seat *seat;
	struct wl_data_device *device;

	/* Ours, while we own the selection. */
	struct wl_data_source *source;
	char *owned;

	/* Somebody else's, currently on offer. */
	struct wl_data_offer *offer;
	int offer_rank;                /* index into TEXT_MIME, or -1 */

	/* An offer announces its MIME types before the selection event that
	 * names it, so the ranking is accumulated here and promoted when the
	 * selection arrives. */
	struct wl_data_offer *pending;
	int pending_rank;
};

static int mime_rank(const char *mime) {
	for (int i = 0; i < TEXT_MIME_COUNT; i++) {
		if (strcmp(mime, TEXT_MIME[i]) == 0) {
			return i;
		}
	}
	return -1;
}

/* Lower index is better; -1 means "no text at all". */
static bool rank_better(int candidate, int current) {
	if (candidate < 0) {
		return false;
	}
	return current < 0 || candidate < current;
}

/* ── The source half: we own the selection ─────────────────────── */

static void source_target(void *data, struct wl_data_source *source,
		const char *mime_type) {
	(void)data; (void)source; (void)mime_type;
}

static void source_send(void *data, struct wl_data_source *source,
		const char *mime_type, int32_t fd) {
	(void)source; (void)mime_type;
	struct novi_clipboard *cb = data;
	const char *text = cb->owned != NULL ? cb->owned : "";
	size_t len = strlen(text), written = 0;
	while (written < len) {
		ssize_t n = write(fd, text + written, len - written);
		if (n < 0 && errno == EINTR) {
			continue;
		}
		if (n <= 0) {
			break;   /* the reader went away; nothing to be done */
		}
		written += (size_t)n;
	}
	close(fd);
}

static void source_cancelled(void *data, struct wl_data_source *source) {
	struct novi_clipboard *cb = data;
	/* Another client took the selection. Our source is dead the moment
	 * this arrives -- using it again is a protocol error -- and what we
	 * were holding is no longer the clipboard's content. */
	wl_data_source_destroy(source);
	if (cb->source == source) {
		cb->source = NULL;
		free(cb->owned);
		cb->owned = NULL;
	}
}

static void source_dnd_drop_performed(void *data, struct wl_data_source *s) {
	(void)data; (void)s;
}

static void source_dnd_finished(void *data, struct wl_data_source *s) {
	(void)data; (void)s;
}

static void source_action(void *data, struct wl_data_source *s, uint32_t a) {
	(void)data; (void)s; (void)a;
}

static const struct wl_data_source_listener source_listener = {
	.target = source_target,
	.send = source_send,
	.cancelled = source_cancelled,
	.dnd_drop_performed = source_dnd_drop_performed,
	.dnd_finished = source_dnd_finished,
	.action = source_action,
};

/* ── The offer half: somebody else owns it ─────────────────────── */

static void offer_offer(void *data, struct wl_data_offer *offer,
		const char *mime_type) {
	struct novi_clipboard *cb = data;
	if (offer != cb->pending) {
		return;
	}
	int r = mime_rank(mime_type);
	if (rank_better(r, cb->pending_rank)) {
		cb->pending_rank = r;
	}
}

static void offer_source_actions(void *data, struct wl_data_offer *o,
		uint32_t actions) {
	(void)data; (void)o; (void)actions;
}

static void offer_action(void *data, struct wl_data_offer *o, uint32_t a) {
	(void)data; (void)o; (void)a;
}

static const struct wl_data_offer_listener offer_listener = {
	.offer = offer_offer,
	.source_actions = offer_source_actions,
	.action = offer_action,
};

static void device_data_offer(void *data, struct wl_data_device *device,
		struct wl_data_offer *offer) {
	(void)device;
	struct novi_clipboard *cb = data;
	cb->pending = offer;
	cb->pending_rank = -1;
	wl_data_offer_add_listener(offer, &offer_listener, cb);
}

static void device_selection(void *data, struct wl_data_device *device,
		struct wl_data_offer *offer) {
	(void)device;
	struct novi_clipboard *cb = data;
	if (cb->offer != NULL && cb->offer != offer) {
		wl_data_offer_destroy(cb->offer);
	}
	cb->offer = offer;
	cb->offer_rank = (offer != NULL && offer == cb->pending) ? cb->pending_rank : -1;
	cb->pending = NULL;
	cb->pending_rank = -1;
}

static void device_enter(void *data, struct wl_data_device *d, uint32_t serial,
		struct wl_surface *surface, wl_fixed_t x, wl_fixed_t y,
		struct wl_data_offer *offer) {
	(void)data; (void)d; (void)serial; (void)surface; (void)x; (void)y; (void)offer;
}

static void device_leave(void *data, struct wl_data_device *d) {
	(void)data; (void)d;
}

static void device_motion(void *data, struct wl_data_device *d, uint32_t time,
		wl_fixed_t x, wl_fixed_t y) {
	(void)data; (void)d; (void)time; (void)x; (void)y;
}

static void device_drop(void *data, struct wl_data_device *d) {
	(void)data; (void)d;
}

static const struct wl_data_device_listener device_listener = {
	.data_offer = device_data_offer,
	.enter = device_enter,
	.leave = device_leave,
	.motion = device_motion,
	.drop = device_drop,
	.selection = device_selection,
};

/* ── Public interface ──────────────────────────────────────────── */

struct novi_clipboard *novi_clipboard_create(struct wl_display *display,
		struct wl_data_device_manager *manager, struct wl_seat *seat) {
	struct novi_clipboard *cb = calloc(1, sizeof(*cb));
	if (cb == NULL) {
		return NULL;
	}
	cb->display = display;
	cb->manager = manager;
	cb->seat = seat;
	cb->offer_rank = -1;
	cb->pending_rank = -1;

	if (manager != NULL && seat != NULL) {
		cb->device = wl_data_device_manager_get_data_device(manager, seat);
		wl_data_device_add_listener(cb->device, &device_listener, cb);
	}
	return cb;
}

void novi_clipboard_destroy(struct novi_clipboard *cb) {
	if (cb == NULL) {
		return;
	}
	if (cb->offer != NULL) {
		wl_data_offer_destroy(cb->offer);
	}
	if (cb->source != NULL) {
		wl_data_source_destroy(cb->source);
	}
	if (cb->device != NULL) {
		wl_data_device_destroy(cb->device);
	}
	free(cb->owned);
	free(cb);
}

bool novi_clipboard_copy(struct novi_clipboard *cb, const char *utf8,
		uint32_t serial) {
	if (cb == NULL || cb->device == NULL || utf8 == NULL) {
		return false;
	}
	char *copy = strdup(utf8);
	if (copy == NULL) {
		return false;
	}

	struct wl_data_source *source =
		wl_data_device_manager_create_data_source(cb->manager);
	if (source == NULL) {
		free(copy);
		return false;
	}
	for (int i = 0; i < TEXT_MIME_COUNT; i++) {
		wl_data_source_offer(source, TEXT_MIME[i]);
	}
	wl_data_source_add_listener(source, &source_listener, cb);

	/* Replacing our own selection: the old source is superseded the
	 * moment set_selection names the new one, and the compositor will
	 * send it `cancelled`, which frees it. Do not destroy it here. */
	cb->source = source;
	free(cb->owned);
	cb->owned = copy;

	wl_data_device_set_selection(cb->device, source, serial);
	wl_display_flush(cb->display);
	return true;
}

char *novi_clipboard_paste(struct novi_clipboard *cb) {
	if (cb == NULL) {
		return NULL;
	}

	/* Pasting what we ourselves copied never goes near the wire.
	 * It cannot: answering our own wl_data_offer means our own `send`
	 * callback has to run, and that needs the event loop we would be
	 * sitting inside blocked on the pipe. That is a deadlock, not a
	 * slow path, and the whole reason `owned` is kept. */
	if (cb->source != NULL && cb->owned != NULL) {
		return strdup(cb->owned);
	}
	if (cb->offer == NULL || cb->offer_rank < 0) {
		return NULL;
	}

	int fds[2];
	if (pipe(fds) != 0) {
		return NULL;
	}
	wl_data_offer_receive(cb->offer, TEXT_MIME[cb->offer_rank], fds[1]);
	/* Flush before closing our copy of the write end: the fd is only
	 * handed to the compositor when the request actually goes out. */
	wl_display_flush(cb->display);
	close(fds[1]);

	/* The timeout is per-wait, not a total: an owner that keeps sending
	 * is working, and should not be cut off for taking a while. What
	 * bounds a source that dribbles forever is PASTE_MAX_BYTES. */
	char *buf = NULL;
	size_t len = 0, cap = 0;
	for (;;) {
		struct pollfd pfd = { .fd = fds[0], .events = POLLIN };
		int pr = poll(&pfd, 1, PASTE_TIMEOUT_MS);
		if (pr < 0 && errno == EINTR) {
			continue;
		}
		if (pr <= 0) {
			break;   /* timed out, or the poll failed: take what we have */
		}
		if (len + 4096 + 1 > cap) {
			size_t grown = cap ? cap * 2 : 8192;
			if (grown > PASTE_MAX_BYTES) {
				break;
			}
			char *p = realloc(buf, grown);
			if (p == NULL) {
				break;
			}
			buf = p;
			cap = grown;
		}
		ssize_t n = read(fds[0], buf + len, cap - len - 1);
		if (n < 0 && errno == EINTR) {
			continue;
		}
		if (n <= 0) {
			break;   /* EOF: the owner finished writing */
		}
		len += (size_t)n;
	}
	close(fds[0]);

	if (buf == NULL) {
		return NULL;
	}
	buf[len] = '\0';
	return buf;
}

bool novi_clipboard_serving(const struct novi_clipboard *cb) {
	return cb != NULL && cb->source != NULL;
}
