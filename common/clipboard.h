/* common/clipboard.h — the Wayland clipboard, for any Novi client.
 *
 * Core-Wayland wl_data_device_manager, which novi-shell already creates
 * (wlr_data_device_manager_create() in novi-shell/main.c). No new
 * protocol, no compositor change: this is the mechanism foot, and every
 * other Wayland client, already uses, which is the point -- copying in
 * the terminal and pasting in the editor has to work, and it only works
 * if both ends speak the standard thing.
 *
 * novi-launcher had the copy half of this inline, written for its own
 * single-character symbol picker: one static source, one string, and a
 * lifetime tied to that program exiting. Two implementations of a
 * clipboard is how one of them ends up subtly different from the other,
 * so it lives here now and the launcher calls it.
 *
 * The client owns the registry, so it binds wl_data_device_manager
 * itself and hands it over -- this module does not guess at globals.
 */
#ifndef NOVI_CLIPBOARD_H
#define NOVI_CLIPBOARD_H

#include <stdbool.h>
#include <stdint.h>
#include <wayland-client.h>

struct novi_clipboard;

/* `manager` and `seat` may be NULL -- a compositor without a clipboard
 * is a working compositor, and a client should degrade to "copy does
 * nothing" rather than refuse to start. Returns NULL only on allocation
 * failure. */
struct novi_clipboard *novi_clipboard_create(struct wl_display *display,
	struct wl_data_device_manager *manager, struct wl_seat *seat);

void novi_clipboard_destroy(struct novi_clipboard *cb);

/* Claim the selection with a copy of `utf8`. `serial` must be the serial
 * of the input event that justifies the claim -- the keypress the user
 * made -- or the compositor is entitled to ignore it. */
bool novi_clipboard_copy(struct novi_clipboard *cb, const char *utf8,
	uint32_t serial);

/* The current selection as a malloc'd NUL-terminated string, or NULL if
 * there is nothing, nothing in a text format, or the owner never
 * answered. The caller frees it. */
char *novi_clipboard_paste(struct novi_clipboard *cb);

/* True while this process still owns the selection it copied. A
 * one-shot client that copies and exits has to stay alive until the
 * paste actually happens -- that is the standard data-source lifetime,
 * the same reason wl-copy stays resident -- so its main loop asks this. */
bool novi_clipboard_serving(const struct novi_clipboard *cb);

#endif /* NOVI_CLIPBOARD_H */
