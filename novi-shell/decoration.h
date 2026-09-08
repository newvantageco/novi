/* decoration.h — novi-shell's server-side window chrome.
 *
 * The one place this compositor draws pixels of its own, and the
 * exception is deliberate rather than a crack in RFC 0001's "UI
 * belongs in a client" rule. Server-side decorations are, by
 * definition, drawn by the server: there is no client to ask, because
 * the whole point of SSD is that the client did not want to draw its
 * own frame. GUI-DESIGN-LANGUAGE.md §6 makes the same argument from
 * the other end -- a title bar every client drew for itself would
 * fragment the moment a second toolkit showed up.
 *
 * WHAT IT DRAWS, and why each piece is here:
 *
 *   - A title bar: bg-card, radius-lg on the TOP corners only (§6's
 *     own recommendation -- the window body below it is square, so
 *     rounding all four would round a corner that has no window at
 *     it), a one-pixel border-subtle hairline along the bottom, and
 *     the window's title in it. The bar had existed for a while as a
 *     flat strip with three dots and no text, which reads as
 *     unfinished chrome rather than as minimal chrome.
 *
 *   - Three control dots, right-aligned, 8px, MONOCHROME. §6 is
 *     explicit that they are not red/yellow/green: that is the one
 *     thing the original mockup called out as not wanted. text-muted
 *     at rest, text-secondary under the pointer.
 *
 *   - An elevation-1 drop shadow (§4: y+4, feather 16, alpha 0.35,
 *     black) as a NINE-SLICE of pre-rendered sprites -- four corners
 *     and four edges, rendered once for the whole compositor and
 *     shared by every window. §4 is blunt that pixman has no blur
 *     operation and that blurring a window-sized region per frame is
 *     not affordable; a sprite scaled by the scene graph costs
 *     nothing per frame and nothing per resize. The centre slice is
 *     deliberately absent: the window is opaque and covers it.
 *
 * WHY CUSTOM wlr_buffers. The scene graph takes rectangles
 * (wlr_scene_rect, one solid colour) or buffers (wlr_scene_buffer).
 * Rounded corners, anti-aliased circles, a gradient and text are none
 * of those until something rasterises them, so this rasterises into
 * pixman images and wraps them in the smallest possible wlr_buffer --
 * five callbacks, of which only two do anything. That is the
 * documented way to put your own pixels into a wlroots scene.
 */
#ifndef NOVI_DECORATION_H
#define NOVI_DECORATION_H

#include <stdbool.h>
#include <wlr/types/wlr_scene.h>

/* Title bar height. §6 recommends 32 -- smaller than the 40px top
 * bar on purpose, since a window title bar is a per-window affordance
 * rather than primary chrome. */
#define NOVI_DECO_HEIGHT 32

/* The controls, in the order they sit on screen (left to right). A
 * hit test answers one of these or NOVI_DECO_CONTROL_NONE. */
enum novi_deco_control {
	NOVI_DECO_CONTROL_NONE = -1,
	NOVI_DECO_MINIMIZE = 0,
	NOVI_DECO_MAXIMIZE = 1,
	NOVI_DECO_CLOSE = 2,
};
/* Not a member of the enum above: as one it would have to appear in
 * every switch over a control, which is a case that can never happen
 * being written out at each site to satisfy -Wswitch. */
#define NOVI_DECO_CONTROL_COUNT 3

struct novi_decor;

/* Loads the UI font and renders every shared sprite, once, for the
 * life of the compositor. Returns false if the font is not there --
 * the caller carries on undecorated rather than refusing to start,
 * because a desktop with plain windows is worse than no desktop to
 * log into. Every entry point below tolerates a NULL decor. */
bool novi_decor_init(void);
void novi_decor_finish(void);

/* Chrome parented to a toplevel's own scene tree. The shadow nodes
 * are lowered to the bottom of that tree, so they sit under the
 * client's surface however the caller ordered its own nodes. */
struct novi_decor *novi_decor_create(struct wlr_scene_tree *tree);
void novi_decor_destroy(struct novi_decor *d);

/* Each of these records the new state and redraws only what actually
 * changed. That matters most for set_size(): it is driven by
 * xdg_toplevel_commit(), which runs on every frame a client draws --
 * a terminal with a running command hits it dozens of times a second
 * -- and an unconditional redraw there would rasterise a title bar
 * per frame per window for the life of the session. */
void novi_decor_set_size(struct novi_decor *d, int width, int height);
void novi_decor_set_title(struct novi_decor *d, const char *title);
void novi_decor_set_focused(struct novi_decor *d, bool focused);
void novi_decor_set_hover(struct novi_decor *d, enum novi_deco_control control);

/* Which control `node` is, for a caller that has already resolved the
 * node to this window. NOVI_DECO_CONTROL_NONE for anything else,
 * including the bar itself -- ask novi_decor_is_bar() about that. */
enum novi_deco_control novi_decor_control_at(const struct novi_decor *d,
	const struct wlr_scene_node *node);
bool novi_decor_is_bar(const struct novi_decor *d,
	const struct wlr_scene_node *node);

#endif
