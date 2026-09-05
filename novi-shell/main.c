/* novi-shell — Novi Linux's compositor and session shell (RFC 0001).
 *
 * The compositor core: a DRM+libinput wlroots backend, the pixman
 * software renderer, xdg-shell window management, wlr-layer-shell-v1
 * (so separate client processes can anchor to screen edges), and
 * seatd-based session handling (no logind, matching this repo's "no
 * systemd anywhere" decision). Adapted from wlroots' tinywl.c
 * reference compositor (CC0 / public domain), which already
 * implements the xdg-shell core correctly and is meant to be built on
 * rather than reinvented.
 *
 * Default keybindings implement part of RFC 0001 decision 7: Alt+Tab /
 * Alt+Shift+Tab (window switching), Alt+Space (search/launcher overlay,
 * novi-launcher/), Super+Return (spawn a terminal), Super+Q (close
 * focused window), Super+. (symbol picker, novi-launcher --symbols --
 * see that file for why "symbol" and not full emoji). Still not
 * implemented: Super+[1-9] workspaces, PrintScreen screenshots, Super+L
 * lock, and moving any of this to the user-editable config file RFC
 * 0001 calls for -- all tracked follow-up work, not part of this
 * milestone.
 */
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <linux/input-event-codes.h>
#include <stdbool.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <wayland-server-core.h>
#include <wlr/backend.h>
#include <wlr/render/allocator.h>
#include <wlr/render/wlr_renderer.h>
#include <wlr/types/wlr_cursor.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_data_device.h>
#include <wlr/types/wlr_foreign_toplevel_management_v1.h>
#include <wlr/types/wlr_input_device.h>
#include <wlr/types/wlr_keyboard.h>
#include <wlr/types/wlr_layer_shell_v1.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_output_layout.h>
#include <wlr/types/wlr_pointer.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/types/wlr_screencopy_v1.h>
#include <wlr/types/wlr_seat.h>
#include <wlr/types/wlr_subcompositor.h>
#include <wlr/types/wlr_xcursor_manager.h>
#include <wlr/types/wlr_xdg_decoration_v1.h>
#include <wlr/types/wlr_xdg_shell.h>
#include <wlr/util/log.h>
#include <xkbcommon/xkbcommon.h>

/* RFC 0001 decision 6: novi-shell defaults to a small wlroots-native
 * terminal (foot) with no GTK/Qt dependency chain, spawned on
 * Super+Return. Overridable via NOVI_TERMINAL so this doesn't need a
 * recompile once alternatives are packaged. */
#define NOVI_DEFAULT_TERMINAL "foot"
/* RFC 0001 decision 7: Alt+Space global search/launcher overlay,
 * spawned as a separate process (novi-launcher/) rather than built
 * into the compositor -- same "novi-shell UI is a layer-shell client,
 * not compositor code" split as any future panel. */
#define NOVI_DEFAULT_LAUNCHER "novi-launcher"
/* RFC 0001 decision 7: Super+. symbol picker -- the same novi-launcher
 * binary, re-invoked with --symbols (see novi-launcher/main.c's own
 * header comment for why this is "symbol", not full emoji). */
#define NOVI_DEFAULT_SYMBOL_PICKER "novi-launcher --symbols"
/* RFC 0001 decision 7: bare PrintScreen (no modifier) captures the
 * whole screen via novi-screenshot/ -- a separate client, same split
 * as the launcher/symbol picker above. Unlike every other binding
 * here, this one is dispatched with no Alt/Super requirement (see
 * keyboard_handle_key()'s separate check below), matching what every
 * PrintScreen key on real keyboards already means. */
#define NOVI_DEFAULT_SCREENSHOT "novi-screenshot"
/* RFC 0001 decision 7: Super+L session lock -- another separate
 * client (novi-lockscreen/), not compositor code, same split as every
 * other binding above. Unlike those, a lock is a real security
 * boundary, not a convenience overlay: novi_server.locked and its
 * guards in keyboard_handle_key()/focus_toplevel() are what actually
 * make this safe, not just novi-lockscreen's own layer-shell surface
 * existing (that alone is exactly what novi-launcher already does,
 * and novi-launcher grabbing keyboard focus was never meant to
 * withstand another keybinding stealing it back). */
#define NOVI_DEFAULT_LOCK "novi-lockscreen"
/* The zwlr_layer_surface_v1 namespace novi-lockscreen identifies itself
 * with (its get_layer_surface() call's namespace argument) -- how
 * layer_surface_map()/layer_surface_unmap() recognize "this is the
 * lock surface, toggle novi_server.locked" among every other
 * layer-shell client without a bespoke protocol extension just for
 * that. Matched by exact string, so novi-lockscreen and novi-shell
 * agree on this constant by both using it (novi-lockscreen's own
 * main.c defines the identical string next to its own explanation). */
#define NOVI_LOCK_NAMESPACE "novi-lockscreen"
/* RFC 0001 decision 7: Super+[1-9] workspaces. The RFC frames this as
 * per-output (the sway/i3 convention), but every other part of this
 * compositor that deals with "which output" -- new-toplevel placement,
 * layer-shell surfaces with no output requested -- already commits to
 * "there is exactly one output, use it" (see server_new_layer_surface()
 * and server_new_xdg_toplevel()'s own comments) rather than real
 * multi-output logic nothing here has ever tested. Workspace state
 * follows that same, honest scoping: one set of NOVI_WORKSPACE_COUNT
 * workspaces on novi_server itself, not per-novi_output -- a real
 * multi-output workspace model is future work alongside real
 * multi-output placement generally, not something to half-build here
 * against zero multi-monitor test coverage. */
#define NOVI_WORKSPACE_COUNT 9
/* The top bar (RFC 0001's "novi-shell" UI chrome) -- another
 * layer-shell client, auto-spawned once the compositor is up, rather
 * than left for the user to start manually or wired as a separate s6
 * service (novi-shell already owns spawning its own UI pieces, same
 * as the terminal/launcher keybindings). */
#define NOVI_DEFAULT_PANEL "novi-panel"

/* Server-side window decorations (GUI-DESIGN-LANGUAGE.md §6): a title
 * bar strip above every toplevel's content, with close and maximize
 * affordances -- the two dots the design doc treats as tractable now
 * (close: backed by wlr_xdg_toplevel_send_close(), the same request
 * Super+Q already sends; maximize: "process_cursor_resize() already
 * demonstrates the exact geometry math... what's missing is
 * remembering pre-maximize geometry to restore on a second click,
 * which is a small, contained addition" -- so this implements that,
 * not just a dimmed placeholder). Minimize stays dimmed and non-
 * interactive per the doc's own explicit instruction: wiring a "fake"
 * minimize without deciding where the window goes (no taskbar/dock
 * exists yet) would be a dead end, not a shortcut. Sized/positioned in
 * the scene graph via wlr_scene_rect, which only draws axis-aligned
 * rectangles -- the design spec's "8px diameter circle" becomes a
 * small square here rather than a real anti-aliased circle, since
 * drawing an actual circle would mean the compositor rendering its own
 * pixel buffer (the same technique novi-panel/novi-launcher use
 * client-side), a materially bigger step not taken in this pass. */
/* Floor for the size a new window is asked to take, so the 70%-of-
 * usable-area rule below cannot produce something unusably small on a
 * tiny output. On any output big enough these never bind. */
#define TOPLEVEL_MIN_WIDTH 480
#define TOPLEVEL_MIN_HEIGHT 320

/* The desktop behind everything. There was no background node at all,
 * so an empty desktop showed the scene's clear colour -- pure black,
 * indistinguishable from a display that is not being driven. This is
 * the panel's own BG_COLOR lifted a little, so the two read as one
 * palette with the panel sitting slightly darker on top of it. */
#define DESKTOP_BG_COLOR_R (0x1eu / 255.0f)
#define DESKTOP_BG_COLOR_G (0x1eu / 255.0f)
#define DESKTOP_BG_COLOR_B (0x28u / 255.0f)

#define DECO_HEIGHT 32
#define DECO_DOT_SIZE 8
#define DECO_DOT_PADDING 12
/* The design doc's literal "8px gap between centers" would put two
 * 8px-diameter dots overlapping by a full diameter (center spacing
 * less than the diameter itself) -- clearly a spec error, not
 * something to implement literally. Using 8px of edge-to-edge
 * clearance instead (16px center-to-center), the conventional reading
 * of "an 8px gap" between same-sized elements. */
#define DECO_DOT_GAP 16
/* bg-card (GUI-DESIGN-LANGUAGE.md's window-content-chrome token) and
 * text-muted at full strength -- all three dots (close/maximize/
 * minimize) are real and functional now, so none gets a "dimmed"
 * treatment, which would misleadingly signal non-interactive. As
 * wlr_scene_rect's normalized-float RGBA rather than this codebase's
 * usual packed 0xRRGGBB hex, since that's the format the scene-graph
 * rect API actually takes.
 *
 * Note for whoever adds the next translucent decoration element: a
 * wlr_scene_rect's R/G/B must be pre-multiplied by its own alpha --
 * struct wlr_render_color (wlr/render/pass.h) documents this
 * explicitly. Getting it wrong is silent, not a crash: this file used
 * to have a dimmed (40%-alpha) minimize dot, and passing straight
 * (non-premultiplied) color with alpha=0.4 rendered it BRIGHTER than
 * the full-strength dots next to it, confirmed via a pixel readback --
 * the opposite of "dimmed". */
static const float DECO_BG_COLOR[4] = {0x1B / 255.0f, 0x1C / 255.0f, 0x26 / 255.0f, 1.0f};
static const float DECO_DOT_COLOR[4] = {0x6B / 255.0f, 0x6F / 255.0f, 0x80 / 255.0f, 1.0f};

/* For brevity's sake, struct members are annotated where they are used. */
enum novi_cursor_mode {
	NOVI_CURSOR_PASSTHROUGH,
	NOVI_CURSOR_MOVE,
	NOVI_CURSOR_RESIZE,
};

struct novi_clip_read;

struct novi_server {
	struct wl_display *wl_display;
	struct wlr_backend *backend;
	struct wlr_renderer *renderer;
	struct wlr_allocator *allocator;
	struct wlr_scene *scene;
	struct wlr_scene_output_layout *scene_layout;

	struct wlr_xdg_shell *xdg_shell;
	struct wl_listener new_xdg_toplevel;
	struct wl_listener new_xdg_popup;
	struct wl_list toplevels;

	/* Announces this compositor's decorations policy to clients that
	 * ask (see server_new_xdg_decoration()) -- novi-shell draws a
	 * title bar for every toplevel unconditionally either way (see
	 * server_new_xdg_toplevel()), so this manager's only real job is
	 * telling an asking client "server-side" so it doesn't also draw
	 * its own and double up. foot does ask (confirmed live: its own
	 * log prints "using SSD decorations" once this manager answers),
	 * so this is genuinely exercised today, not speculative wiring for
	 * a hypothetical future client -- per GUI-DESIGN-LANGUAGE.md §6's
	 * explicit recommendation to implement it. */
	struct wlr_xdg_decoration_manager_v1 *xdg_decoration_manager;
	struct wl_listener new_xdg_decoration;

	struct wlr_cursor *cursor;
	struct wlr_xcursor_manager *cursor_mgr;
	struct wl_listener cursor_motion;
	struct wl_listener cursor_motion_absolute;
	struct wl_listener cursor_button;
	struct wl_listener cursor_axis;
	struct wl_listener cursor_frame;

	struct wlr_seat *seat;
	struct wl_listener new_input;
	struct wl_listener request_cursor;
	struct wl_listener request_set_selection;

	/* Clipboard persistence. See the block comment above
	 * clip_source_send(). */
	struct wl_listener set_selection;
	char *clip_text;                       /* the last text copied, ours to keep */
	size_t clip_len;
	struct wlr_data_source *clip_source;   /* our source, while it is the selection */
	struct novi_clip_read *clip_read;      /* the read in flight, if any */
	struct wl_list keyboards;
	enum novi_cursor_mode cursor_mode;
	struct novi_toplevel *grabbed_toplevel;
	double grab_x, grab_y;
	struct wlr_box grab_geobox;
	uint32_t resize_edges;

	struct wlr_output_layout *output_layout;
	struct wl_list outputs;
	struct wl_listener new_output;

	/* Layer-shell (RFC 0001 decision 5: the panel/launcher UI layer is
	 * built as a client of this protocol, not baked into the
	 * compositor). Scene trees are created once, in this fixed order,
	 * so z-order across layers is guaranteed by scene_tree child
	 * ordering alone: background is always bottom-most, overlay always
	 * top-most, and toplevels (regular windows) always sandwiched
	 * between "bottom" and "top" regardless of what's mapped later. */
	struct wlr_layer_shell_v1 *layer_shell;
	struct wl_listener new_layer_surface;
	struct wlr_scene_tree *layer_tree_background;
	struct wlr_scene_tree *layer_tree_bottom;
	struct wlr_scene_tree *layer_tree_toplevels;
	struct wlr_scene_tree *layer_tree_top;
	struct wlr_scene_tree *layer_tree_overlay;

	/* wlr-foreign-toplevel-management-unstable-v1: lets a separate
	 * layer-shell client (novi-panel's taskbar) list open windows and
	 * request activate/minimize/maximize/close on them, the standard
	 * protocol real taskbars (waybar included) use for exactly this --
	 * not a new bespoke IPC channel between novi-shell and novi-panel.
	 * wlroots implements the protocol server internally (same shape as
	 * wlr_data_device_manager_v1/wlr_layer_shell_v1 above); this is the
	 * one manager object, created once. */
	struct wlr_foreign_toplevel_manager_v1 *foreign_toplevel_manager;

	/* RFC 0001 decision 7: Super+L session lock. True while
	 * novi-lockscreen's fullscreen, keyboard-exclusive layer-shell
	 * surface is mapped (see server_new_layer_surface()'s namespace
	 * check). This flag is the compositor's own half of "locked" --
	 * see keyboard_handle_key()'s and focus_toplevel()'s guards for why
	 * a layer-shell surface grabbing keyboard focus on its own, the
	 * mechanism every other overlay (launcher, symbol picker) already
	 * uses, isn't a real lock by itself: nothing stops a *different*
	 * global keybinding (Super+Q, Alt+Tab, another Alt+Space) from
	 * moving focus away from it mid-lock, since handle_keybinding()
	 * runs before seat-focus routing, not through it. */
	bool locked;

	/* RFC 0001 decision 7: Super+[1-9] workspaces. 1-indexed (matching
	 * the keys themselves) so this can be compared directly against a
	 * novi_toplevel.workspace with no off-by-one translation at either
	 * end. See NOVI_WORKSPACE_COUNT's own comment for why this lives on
	 * novi_server, not per-output. */
	int active_workspace;
};

struct novi_output {
	struct wl_list link;
	struct novi_server *server;
	struct wlr_output *wlr_output;
	struct wl_listener frame;
	struct wl_listener request_state;
	struct wl_listener destroy;
	/* layer-shell clients (novi_layer_surface.link) mapped on this output */
	struct wl_list layer_surfaces;
	/* Flat desktop background, sized to the whole output (not the
	 * usable area -- it belongs *behind* the panel, not beside it) and
	 * resized by arrange_layers() whenever the output geometry changes.
	 * Lives in layer_tree_background, so a real background layer-shell
	 * client (a wallpaper program) still draws over it. */
	struct wlr_scene_rect *background;
	/* Output-local box left over after layer-shell exclusive zones (the
	 * top bar's reserved 32px) are subtracted -- set by arrange_layers(),
	 * read by server_new_xdg_toplevel() so a new window's initial
	 * position doesn't land underneath the panel. Starts as the full
	 * output box: arrange_layers() runs once at output creation (before
	 * any layer-shell client can possibly exist yet to shrink it), so
	 * this is never used uninitialized. */
	struct wlr_box usable_area;
};

struct novi_layer_surface {
	struct wl_list link; /* novi_output.layer_surfaces */
	struct novi_output *output;
	struct wlr_layer_surface_v1 *layer_surface;
	struct wlr_scene_layer_surface_v1 *scene_layer_surface;
	struct wl_listener map;
	struct wl_listener unmap;
	struct wl_listener destroy;
	struct wl_listener commit;
};

struct novi_toplevel {
	struct wl_list link;
	struct novi_server *server;
	struct wlr_xdg_toplevel *xdg_toplevel;
	struct wlr_scene_tree *scene_tree;
	/* Server-side decoration -- all children of scene_tree, positioned
	 * in the negative-y space above the content (see server_new_xdg_
	 * toplevel()'s initial-placement comment for why the content itself
	 * is now placed DECO_HEIGHT lower than before, to leave room). Kept
	 * as direct pointers, not walked from the scene tree, so xdg_
	 * toplevel_commit() can resize the bar and all three dots'
	 * decoration_rect_toplevel_at() hit-test can identify a click
	 * without re-deriving them. */
	struct wlr_scene_rect *titlebar;
	struct wlr_scene_rect *close_dot;
	struct wlr_scene_rect *maximize_dot;
	struct wlr_scene_rect *minimize_dot;
	/* Maximize state, toggled by maximize_toplevel()/unmaximize_
	 * toplevel() -- both the maximize dot and a client's own request
	 * (xdg_toplevel_request_maximize()) go through the same two
	 * functions, so there's exactly one place that ever changes this. */
	bool maximized;
	/* Minimize state, toggled by minimize_toplevel()/unminimize_
	 * toplevel() -- the (now-live, no longer dimmed) minimize dot, a
	 * taskbar's request_minimize, and focus_toplevel() restoring a
	 * minimized window (Alt+Tab or a taskbar's request_activate) all go
	 * through this same pair. */
	bool minimized;
	/* RFC 0001 decision 7: which of NOVI_WORKSPACE_COUNT workspaces this
	 * toplevel belongs to (1-indexed, see novi_server.active_workspace).
	 * Set once at map time to whatever's active then -- new windows open
	 * on the current workspace, matching every real i3/sway-family
	 * compositor's behavior -- and changed only by an explicit
	 * Super+Shift+[1-9] (move_focused_to_workspace()). Visibility is
	 * `workspace == server->active_workspace && !minimized`: these two
	 * hidden-reasons are independent (see switch_workspace()'s own
	 * comment), not one flag doing double duty. */
	int workspace;
	struct wlr_box saved_geometry;
	struct wl_listener map;
	struct wl_listener unmap;
	struct wl_listener commit;
	struct wl_listener destroy;
	struct wl_listener request_move;
	struct wl_listener request_resize;
	struct wl_listener request_maximize;
	struct wl_listener request_fullscreen;
	struct wl_listener set_title;
	struct wl_listener set_app_id;

	/* This toplevel's handle on the foreign-toplevel-management
	 * protocol (see novi_server.foreign_toplevel_manager) -- created on
	 * map, destroyed on unmap, so a taskbar only ever lists windows
	 * that are actually currently mapped. */
	struct wlr_foreign_toplevel_handle_v1 *foreign_handle;
	struct wl_listener foreign_request_maximize;
	struct wl_listener foreign_request_minimize;
	struct wl_listener foreign_request_activate;
	struct wl_listener foreign_request_close;
};

struct novi_popup {
	struct wlr_xdg_popup *xdg_popup;
	struct wl_listener commit;
	struct wl_listener destroy;
};

struct novi_keyboard {
	struct wl_list link;
	struct novi_server *server;
	struct wlr_keyboard *wlr_keyboard;

	struct wl_listener modifiers;
	struct wl_listener key;
	struct wl_listener destroy;
};

/* Defined near xdg_toplevel_request_maximize() below, alongside the
 * geometry-save/restore logic they share with it; forward-declared
 * here since server_cursor_button() (the maximize dot's click path)
 * needs them earlier in the file than that. */
static void maximize_toplevel(struct novi_toplevel *toplevel);
static void unmaximize_toplevel(struct novi_toplevel *toplevel);
/* Same reason: unminimize_toplevel() needs calling from focus_toplevel()
 * itself (Alt+Tab or a taskbar "activate" request restoring a minimized
 * window), defined near minimize_toplevel() below for the same "keep
 * the state-owning pair together" reason as maximize/unmaximize. */
static void minimize_toplevel(struct novi_toplevel *toplevel);
static void unminimize_toplevel(struct novi_toplevel *toplevel);
/* Forward-declared for the same reason: handle_keybinding() (below)
 * needs to call these for Super+[1-9]/Super+Shift+[1-9], but they're
 * defined next to minimize_toplevel() further down (same "state-owning
 * pair stays together" grouping -- these two own novi_toplevel.workspace
 * the same way minimize_toplevel()/unminimize_toplevel() own .minimized). */
static void switch_workspace(struct novi_server *server, int workspace);
static void move_focused_to_workspace(struct novi_server *server, int workspace);

static void focus_toplevel(struct novi_toplevel *toplevel, struct wlr_surface *surface) {
	/* Note: this function only deals with keyboard focus. */
	if (toplevel == NULL) {
		return;
	}
	if (toplevel->server->locked) {
		/* Refuse every path that reaches this function while locked --
		 * a pointer click hit-testing to a toplevel can't happen for
		 * real (the lock surface is a full-output OVERLAY-layer surface
		 * with exclusive_zone=-1, so it's hit before anything under it
		 * ever could be), but a newly mapped toplevel's own
		 * auto-focus-on-map call still reaches here, and this is the
		 * one choke point all such callers share. See novi_server.locked's
		 * comment for why the keyboard-shortcut path needs its own,
		 * separate guard instead of relying on this alone. */
		return;
	}
	if (toplevel->workspace != toplevel->server->active_workspace) {
		/* Alt+Tab and a taskbar's "activate" request can both land on a
		 * toplevel that lives on a workspace that isn't currently
		 * visible (the taskbar shows every open window regardless of
		 * workspace -- see novi-panel/main.c). Real desktops switch you
		 * to wherever the window you're activating actually is, rather
		 * than silently focusing something that stays hidden; this is
		 * that switch. Done before the minimized check below on
		 * purpose: switch_workspace() has to run first so
		 * unminimize_toplevel()'s own visibility computation (workspace
		 * == active_workspace) sees the workspace it's ABOUT to be
		 * shown on, not the one being switched away from. switch_
		 * workspace() may itself focus some other toplevel as part of
		 * making the new workspace visible (its own default MRU pick)
		 * -- harmless, since this function's own focus-setting code
		 * below still runs afterward and re-focuses THIS toplevel
		 * regardless of whatever it picked in the meantime. */
		switch_workspace(toplevel->server, toplevel->workspace);
	}
	if (toplevel->minimized) {
		/* Alt+Tab and a taskbar's "activate" request both just call this
		 * function -- restoring a minimized window on either path,
		 * rather than requiring callers to remember to unminimize first,
		 * matches how every real desktop's taskbar/Alt+Tab behaves. */
		unminimize_toplevel(toplevel);
	}
	struct novi_server *server = toplevel->server;
	struct wlr_seat *seat = server->seat;
	struct wlr_surface *prev_surface = seat->keyboard_state.focused_surface;
	if (prev_surface == surface) {
		/* Don't re-focus an already focused surface. */
		return;
	}
	if (prev_surface) {
		/*
		 * Deactivate the previously focused surface. This lets the client know
		 * it no longer has focus and the client will repaint accordingly, e.g.
		 * stop displaying a caret.
		 */
		struct wlr_xdg_toplevel *prev_toplevel =
			wlr_xdg_toplevel_try_from_wlr_surface(prev_surface);
		if (prev_toplevel != NULL) {
			wlr_xdg_toplevel_set_activated(prev_toplevel, false);
		}
	}
	struct wlr_keyboard *keyboard = wlr_seat_get_keyboard(seat);
	/* Move the toplevel to the front */
	wlr_scene_node_raise_to_top(&toplevel->scene_tree->node);
	wl_list_remove(&toplevel->link);
	wl_list_insert(&server->toplevels, &toplevel->link);
	/* Activate the new surface */
	wlr_xdg_toplevel_set_activated(toplevel->xdg_toplevel, true);
	/* Keep every toplevel's foreign-toplevel-management "activated" bit
	 * (what a taskbar highlights as the current window) in sync -- a
	 * plain iteration rather than tracking just the two that changed,
	 * since the window count here is always small (an "everyday
	 * desktop" workload, not hundreds of toplevels) and this only runs
	 * on an actual focus change, not per-frame. */
	struct novi_toplevel *activated_iter;
	wl_list_for_each(activated_iter, &server->toplevels, link) {
		if (activated_iter->foreign_handle != NULL) {
			wlr_foreign_toplevel_handle_v1_set_activated(
				activated_iter->foreign_handle, activated_iter == toplevel);
		}
	}
	/*
	 * Tell the seat to have the keyboard enter this surface. wlroots will keep
	 * track of this and automatically send key events to the appropriate
	 * clients without additional work on your part.
	 */
	if (keyboard != NULL) {
		wlr_seat_keyboard_notify_enter(seat, toplevel->xdg_toplevel->base->surface,
			keyboard->keycodes, keyboard->num_keycodes, &keyboard->modifiers);
	}
}

static void keyboard_handle_modifiers(
		struct wl_listener *listener, void *data) {
	/* This event is raised when a modifier key, such as shift or alt, is
	 * pressed. We simply communicate this to the client. */
	struct novi_keyboard *keyboard =
		wl_container_of(listener, keyboard, modifiers);
	/*
	 * A seat can only have one keyboard, but this is a limitation of the
	 * Wayland protocol - not wlroots. We assign all connected keyboards to the
	 * same seat. You can swap out the underlying wlr_keyboard like this and
	 * wlr_seat handles this transparently.
	 */
	wlr_seat_set_keyboard(keyboard->server->seat, keyboard->wlr_keyboard);
	/* Send modifiers to the client. */
	wlr_seat_keyboard_notify_modifiers(keyboard->server->seat,
		&keyboard->wlr_keyboard->modifiers);
}

/* Spawns `cmd` via /bin/sh -c, same fork+exec shape main()'s -s startup
 * command already uses. Used by keybindings, not just at startup. */
static void spawn(const char *cmd) {
	pid_t pid = fork();
	if (pid < 0) {
		wlr_log_errno(WLR_ERROR, "fork failed for \"%s\"", cmd);
		return;
	}
	if (pid == 0) {
		/* Detach into its own session so it isn't killed by whatever
		 * signal eventually stops novi-shell itself, and so its
		 * lifetime isn't tied to being a direct child novi-shell has
		 * to reap. */
		setsid();
		/* Start in the user's home, not wherever novi-shell happens to
		 * be running from. s6 starts this compositor with its cwd set
		 * to its own service directory, and a child inherits that -- so
		 * every terminal opened from the desktop came up sitting in
		 * /run/s6-rc:s6-rc-init:XXXXXX/servicedirs/novi-shell, with
		 * that whole path in the prompt. Visible in a screenshot the
		 * moment anyone looked. */
		const char *home = getenv("HOME");
		if (home == NULL || *home == '\0') {
			home = "/root";
		}
		if (chdir(home) != 0) {
			(void)chdir("/");
		}
		execl("/bin/sh", "/bin/sh", "-c", cmd, (void *)NULL);
		/* execl only returns on failure. */
		_exit(127);
	}
}

/* Cycle keyboard focus through server->toplevels, which focus_toplevel()
 * keeps in most-recently-focused-first order. Forward (Alt+Tab) always
 * grabs the tail (least-recently-focused); repeating it visits every
 * window exactly once per full cycle. Reverse (Alt+Shift+Tab) undoes one
 * step by grabbing the second entry (the one focused immediately before
 * the current one) rather than maintaining a separate MRU-scroll state
 * machine -- a reasonable, correct simplification for this milestone,
 * not full held-Alt scroll-through semantics. */
static void cycle_toplevel(struct novi_server *server, bool forward) {
	if (wl_list_length(&server->toplevels) < 2) {
		return;
	}
	struct novi_toplevel *target;
	if (forward) {
		target = wl_container_of(server->toplevels.prev, target, link);
	} else {
		target = wl_container_of(server->toplevels.next->next, target, link);
	}
	focus_toplevel(target, target->xdg_toplevel->base->surface);
}

/* Super+Q: ask the focused window's client to close itself (the same
 * request a client-side close button would send) rather than forcibly
 * destroying it -- lets the client save state / show an "unsaved
 * changes" prompt like any normal close request would. */
static void close_focused_toplevel(struct novi_server *server) {
	struct wlr_surface *focused = server->seat->keyboard_state.focused_surface;
	if (focused == NULL) {
		return;
	}
	struct wlr_xdg_toplevel *xdg_toplevel =
		wlr_xdg_toplevel_try_from_wlr_surface(focused);
	if (xdg_toplevel != NULL) {
		wlr_xdg_toplevel_send_close(xdg_toplevel);
	}
}

/* Maps a keysym back to its Super+[1-9] workspace number (1-9), or 0 if
 * it isn't one -- needed because xkb_state_key_get_syms() (what
 * keyboard_handle_key() actually calls) returns the keysym AFTER
 * applying the current modifier state, and on a standard US layout
 * (the only one this compositor's hardcoded xkb_keymap_new_from_names()
 * call ever produces -- see server_new_keyboard()) Shift+3 reports
 * XKB_KEY_numbersign ('#'), never XKB_KEY_3. A plain `case XKB_KEY_3:`
 * switch can never match Super+Shift+3's actual keysym, silently
 * falling through to deliver "#" to the focused client instead --
 * confirmed live: exactly that happened before this fix, typed
 * straight into a focused foot window. This is the identical class of
 * bug XKB_KEY_ISO_Left_Tab's own case (right below) already works
 * around for Shift+Tab; digits just have nine shifted forms to cover
 * instead of Tab's one. */
static int workspace_digit_for_keysym(xkb_keysym_t sym) {
	switch (sym) {
	case XKB_KEY_1: case XKB_KEY_exclam: return 1;
	case XKB_KEY_2: case XKB_KEY_at: return 2;
	case XKB_KEY_3: case XKB_KEY_numbersign: return 3;
	case XKB_KEY_4: case XKB_KEY_dollar: return 4;
	case XKB_KEY_5: case XKB_KEY_percent: return 5;
	case XKB_KEY_6: case XKB_KEY_asciicircum: return 6;
	case XKB_KEY_7: case XKB_KEY_ampersand: return 7;
	case XKB_KEY_8: case XKB_KEY_asterisk: return 8;
	case XKB_KEY_9: case XKB_KEY_parenleft: return 9;
	default: return 0;
	}
}

/* RFC 0001 decision 7's default keybindings, all implemented:
 * Alt+Tab/Shift+Tab (window switching), Super+Return/Super+Q (terminal/
 * close), Super+[1-9]/Super+Shift+[1-9] (workspaces -- see
 * NOVI_WORKSPACE_COUNT's own comment for the per-server, not per-output,
 * scoping), Super+. (symbol picker), PrintScreen (screenshot, checked
 * separately in keyboard_handle_key() since it takes no modifier), and
 * Super+L (lock). All of this is compositor-internal default behavior
 * for now; RFC 0001 calls for these to move to a user-editable config
 * file, a follow-up, not implemented here yet. */
static bool handle_keybinding(struct novi_server *server, uint32_t modifiers,
		xkb_keysym_t sym) {
	if (modifiers & WLR_MODIFIER_ALT) {
		switch (sym) {
		case XKB_KEY_Escape:
			/* Not part of RFC 0001's spec -- kept as a development/
			 * test convenience for exiting the compositor cleanly
			 * under QEMU, where there's no other way to do so yet. */
			wl_display_terminate(server->wl_display);
			return true;
		case XKB_KEY_Tab:
			cycle_toplevel(server, true);
			return true;
		case XKB_KEY_ISO_Left_Tab:
			/* Most keyboard layouts report Shift+Tab as this keysym,
			 * not as Tab with the shift modifier bit set. */
			cycle_toplevel(server, false);
			return true;
		case XKB_KEY_space:
			/* RFC 0001 decision 7: global search/launcher overlay.
			 * novi-launcher is a separate layer-shell client (overlay
			 * layer, exclusive keyboard interactivity) spawned fresh
			 * each time, not toggled -- it exits itself on Escape or
			 * Enter, so double-spawning only happens if Alt+Space is
			 * pressed again while one is already open, an edge case
			 * not worth extra state for yet. */
			spawn(getenv("NOVI_LAUNCHER") ?
				getenv("NOVI_LAUNCHER") : NOVI_DEFAULT_LAUNCHER);
			return true;
		default:
			break;
		}
	}
	if (modifiers & WLR_MODIFIER_LOGO) {
		/* RFC 0001 decision 7: Super+[1-9] switch workspace,
		 * Super+Shift+[1-9] move the focused window to one -- checked
		 * here, before the switch below, rather than as switch cases:
		 * workspace_digit_for_keysym() already covers both a digit's
		 * shifted and unshifted keysym (see its own comment for why
		 * that's required at all), so this one check replaces what
		 * would otherwise need to be 18 separate case labels. */
		int workspace_n = workspace_digit_for_keysym(sym);
		if (workspace_n != 0) {
			if (modifiers & WLR_MODIFIER_SHIFT) {
				move_focused_to_workspace(server, workspace_n);
			} else {
				switch_workspace(server, workspace_n);
			}
			return true;
		}
		switch (sym) {
		case XKB_KEY_Return:
			spawn(getenv("NOVI_TERMINAL") ?
				getenv("NOVI_TERMINAL") : NOVI_DEFAULT_TERMINAL);
			return true;
		case XKB_KEY_q:
		case XKB_KEY_Q:
			close_focused_toplevel(server);
			return true;
		case XKB_KEY_l:
		case XKB_KEY_L:
			/* RFC 0001 decision 7: session lock. novi-lockscreen sets
			 * server->locked itself once its surface actually maps
			 * (server_new_layer_surface()'s namespace check) rather
			 * than this setting it directly -- if the client fails to
			 * start, or refuses to lock because no password is set
			 * (see novi-lockscreen/main.c), the compositor should never
			 * believe it's locked when no real lock surface exists to
			 * back that up. */
			spawn(getenv("NOVI_LOCK") ? getenv("NOVI_LOCK") : NOVI_DEFAULT_LOCK);
			return true;
		case XKB_KEY_period:
			/* RFC 0001 decision 7: symbol picker. Same spawn-fresh-
			 * overlay pattern as Alt+Space above, just a different
			 * argv -- novi-launcher decides what that means. */
			spawn(getenv("NOVI_SYMBOL_PICKER") ?
				getenv("NOVI_SYMBOL_PICKER") : NOVI_DEFAULT_SYMBOL_PICKER);
			return true;
		default:
			break;
		}
	}
	return false;
}

static void keyboard_handle_key(
		struct wl_listener *listener, void *data) {
	/* This event is raised when a key is pressed or released. */
	struct novi_keyboard *keyboard =
		wl_container_of(listener, keyboard, key);
	struct novi_server *server = keyboard->server;
	struct wlr_keyboard_key_event *event = data;
	struct wlr_seat *seat = server->seat;

	/* Translate libinput keycode -> xkbcommon */
	uint32_t keycode = event->keycode + 8;
	/* Get a list of keysyms based on the keymap for this keyboard */
	const xkb_keysym_t *syms;
	int nsyms = xkb_state_key_get_syms(
			keyboard->wlr_keyboard->xkb_state, keycode, &syms);

	bool handled = false;
	uint32_t modifiers = wlr_keyboard_get_modifiers(keyboard->wlr_keyboard);
	/* While locked, no compositor keybinding fires at all -- every key
	 * just falls through to the final wlr_seat_keyboard_notify_key()
	 * below, which delivers only to whatever holds seat keyboard focus.
	 * That's always novi-lockscreen's own surface while locked (it
	 * grabbed focus on map, and focus_toplevel()'s own guard stops
	 * anything from stealing it back) -- so this is the other half of
	 * making Super+L a real lock, not just an overlay: without this,
	 * Super+Q or another Alt+Space while "locked" would still run,
	 * since handle_keybinding() normally runs before any focus check at
	 * all. See novi_server.locked's own comment for the full picture. */
	if (!server->locked &&
			(modifiers & (WLR_MODIFIER_ALT | WLR_MODIFIER_LOGO)) &&
			event->state == WL_KEYBOARD_KEY_STATE_PRESSED) {
		/* If Alt or Super (Logo) is held down and this key was
		 * _pressed_, attempt to process it as a compositor keybinding
		 * before ever considering passing it to the focused client. */
		for (int i = 0; i < nsyms; i++) {
			if (handle_keybinding(server, modifiers, syms[i])) {
				handled = true;
			}
		}
	}

	if (!server->locked && !handled &&
			event->state == WL_KEYBOARD_KEY_STATE_PRESSED) {
		/* PrintScreen needs no modifier (see NOVI_DEFAULT_SCREENSHOT's
		 * comment) so it can't live inside the Alt/Super-gated loop
		 * above -- check it unconditionally instead. */
		for (int i = 0; i < nsyms; i++) {
			if (syms[i] == XKB_KEY_Print) {
				spawn(getenv("NOVI_SCREENSHOT") ?
					getenv("NOVI_SCREENSHOT") : NOVI_DEFAULT_SCREENSHOT);
				handled = true;
			}
		}
	}

	if (!handled) {
		/* Otherwise, we pass it along to the client. */
		wlr_seat_set_keyboard(seat, keyboard->wlr_keyboard);
		wlr_seat_keyboard_notify_key(seat, event->time_msec,
			event->keycode, event->state);
	}
}

static void keyboard_handle_destroy(struct wl_listener *listener, void *data) {
	/* This event is raised by the keyboard base wlr_input_device to signal
	 * the destruction of the wlr_keyboard. It will no longer receive events
	 * and should be destroyed.
	 */
	struct novi_keyboard *keyboard =
		wl_container_of(listener, keyboard, destroy);
	wl_list_remove(&keyboard->modifiers.link);
	wl_list_remove(&keyboard->key.link);
	wl_list_remove(&keyboard->destroy.link);
	wl_list_remove(&keyboard->link);
	free(keyboard);
}

static void server_new_keyboard(struct novi_server *server,
		struct wlr_input_device *device) {
	struct wlr_keyboard *wlr_keyboard = wlr_keyboard_from_input_device(device);

	struct novi_keyboard *keyboard = calloc(1, sizeof(*keyboard));
	keyboard->server = server;
	keyboard->wlr_keyboard = wlr_keyboard;

	/* We need to prepare an XKB keymap and assign it to the keyboard. This
	 * assumes the defaults (e.g. layout = "us"). */
	struct xkb_context *context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
	struct xkb_keymap *keymap = xkb_keymap_new_from_names(context, NULL,
		XKB_KEYMAP_COMPILE_NO_FLAGS);

	wlr_keyboard_set_keymap(wlr_keyboard, keymap);
	xkb_keymap_unref(keymap);
	xkb_context_unref(context);
	wlr_keyboard_set_repeat_info(wlr_keyboard, 25, 600);

	/* Here we set up listeners for keyboard events. */
	keyboard->modifiers.notify = keyboard_handle_modifiers;
	wl_signal_add(&wlr_keyboard->events.modifiers, &keyboard->modifiers);
	keyboard->key.notify = keyboard_handle_key;
	wl_signal_add(&wlr_keyboard->events.key, &keyboard->key);
	keyboard->destroy.notify = keyboard_handle_destroy;
	wl_signal_add(&device->events.destroy, &keyboard->destroy);

	wlr_seat_set_keyboard(server->seat, keyboard->wlr_keyboard);

	/* And add the keyboard to our list of keyboards */
	wl_list_insert(&server->keyboards, &keyboard->link);
}

static void server_new_pointer(struct novi_server *server,
		struct wlr_input_device *device) {
	/* We don't do anything special with pointers. All of our pointer handling
	 * is proxied through wlr_cursor. On another compositor, you might take this
	 * opportunity to do libinput configuration on the device to set
	 * acceleration, etc. */
	wlr_cursor_attach_input_device(server->cursor, device);
}

static void server_new_input(struct wl_listener *listener, void *data) {
	/* This event is raised by the backend when a new input device becomes
	 * available. */
	struct novi_server *server =
		wl_container_of(listener, server, new_input);
	struct wlr_input_device *device = data;
	switch (device->type) {
	case WLR_INPUT_DEVICE_KEYBOARD:
		server_new_keyboard(server, device);
		break;
	case WLR_INPUT_DEVICE_POINTER:
		server_new_pointer(server, device);
		break;
	default:
		break;
	}
	/* We need to let the wlr_seat know what our capabilities are, which is
	 * communiciated to the client. In TinyWL we always have a cursor, even if
	 * there are no pointer devices, so we always include that capability. */
	uint32_t caps = WL_SEAT_CAPABILITY_POINTER;
	if (!wl_list_empty(&server->keyboards)) {
		caps |= WL_SEAT_CAPABILITY_KEYBOARD;
	}
	wlr_seat_set_capabilities(server->seat, caps);
}

static void seat_request_cursor(struct wl_listener *listener, void *data) {
	struct novi_server *server = wl_container_of(
			listener, server, request_cursor);
	/* This event is raised by the seat when a client provides a cursor image */
	struct wlr_seat_pointer_request_set_cursor_event *event = data;
	struct wlr_seat_client *focused_client =
		server->seat->pointer_state.focused_client;
	/* This can be sent by any client, so we check to make sure this one is
	 * actually has pointer focus first. */
	if (focused_client == event->seat_client) {
		/* Once we've vetted the client, we can tell the cursor to use the
		 * provided surface as the cursor image. It will set the hardware cursor
		 * on the output that it's currently on and continue to do so as the
		 * cursor moves between outputs. */
		wlr_cursor_set_surface(server->cursor, event->surface,
				event->hotspot_x, event->hotspot_y);
	}
}

/* ── Clipboard persistence ─────────────────────────────────────── */

/* A Wayland selection is owned by the client that set it, and it dies
 * with that client. Copy in the editor, close the editor, paste
 * anywhere: nothing. That is not a bug in any of those programs -- it
 * is what the protocol says -- and every desktop that does not feel
 * broken has something that fixes it. The two ways are a clipboard
 * manager speaking zwlr_data_control_v1, or the compositor keeping the
 * text itself. This is the second: the seat is already here, and a
 * clipboard buffer is not UI, so RFC 0001's "UI belongs in a client"
 * rule does not reach it.
 *
 * The rule is: watch what clients put on the selection, keep a copy,
 * and when the selection goes away because its owner did, put the copy
 * back as a source of our own.
 *
 * **Neither half may block.** This is PID-1-of-the-desktop code: a
 * blocking read from a client's pipe freezes every window on the
 * screen, and so does a blocking write of a megabyte into a 64 KB pipe
 * whose reader is slow. Both directions therefore run on the
 * compositor's own event loop, in chunks, which is most of the length
 * of what follows.
 */

#define CLIP_MAX_BYTES (1u * 1024u * 1024u)

/* Best first. A client offers what it likes; we ask for the best text
 * type it named, and offer all three when the text is ours. */
static const char *const CLIP_MIME[] = {
	"text/plain;charset=utf-8",
	"UTF8_STRING",
	"text/plain",
};
#define CLIP_MIME_COUNT ((int)(sizeof(CLIP_MIME) / sizeof(CLIP_MIME[0])))

/* Our own data source. wlr_data_source has no user-data field, so the
 * server pointer rides along in the enclosing struct. */
struct novi_clip_source {
	struct wlr_data_source base;
	struct novi_server *server;
};

/* One in-flight read of a client's selection into our buffer. */
struct novi_clip_read {
	struct novi_server *server;
	struct wl_event_source *ev;
	int fd;
	char *buf;
	size_t len, cap;
};

/* One in-flight write of our buffer to a client's pipe. It owns its own
 * copy of the text, so a new copy landing mid-paste cannot pull the
 * bytes out from under a reader. */
struct novi_clip_write {
	struct wl_event_source *ev;
	int fd;
	char *data;
	size_t len, sent;
};

static void clip_read_finish(struct novi_clip_read *r, bool keep) {
	struct novi_server *server = r->server;
	if (keep && r->len > 0) {
		free(server->clip_text);
		server->clip_text = r->buf;
		server->clip_len = r->len;
		r->buf = NULL;
	}
	if (server->clip_read == r) {
		server->clip_read = NULL;
	}
	wl_event_source_remove(r->ev);
	close(r->fd);
	free(r->buf);
	free(r);
}

static int clip_read_cb(int fd, uint32_t mask, void *data) {
	struct novi_clip_read *r = data;
	if (mask & (WL_EVENT_ERROR | WL_EVENT_HANGUP)) {
		/* HANGUP can arrive with the last bytes still buffered, so
		 * drain before giving up rather than after. */
		for (;;) {
			if (r->len + 1 >= r->cap) {
				size_t grown = r->cap ? r->cap * 2 : 4096;
				if (grown > CLIP_MAX_BYTES) {
					break;
				}
				char *p = realloc(r->buf, grown);
				if (p == NULL) {
					break;
				}
				r->buf = p;
				r->cap = grown;
			}
			ssize_t n = read(fd, r->buf + r->len, r->cap - r->len - 1);
			if (n <= 0) {
				break;
			}
			r->len += (size_t)n;
		}
		if (r->buf != NULL) {
			r->buf[r->len] = '\0';
		}
		clip_read_finish(r, true);
		return 0;
	}

	if (r->len + 1 >= r->cap) {
		size_t grown = r->cap ? r->cap * 2 : 4096;
		if (grown > CLIP_MAX_BYTES) {
			/* Too big to keep. Not an error and not worth a log line
			 * every time somebody copies a large file's contents --
			 * the selection still works normally while its owner is
			 * alive, it just will not outlive it. */
			clip_read_finish(r, false);
			return 0;
		}
		char *p = realloc(r->buf, grown);
		if (p == NULL) {
			clip_read_finish(r, false);
			return 0;
		}
		r->buf = p;
		r->cap = grown;
	}

	ssize_t n = read(fd, r->buf + r->len, r->cap - r->len - 1);
	if (n < 0) {
		if (errno == EAGAIN || errno == EINTR) {
			return 0;
		}
		clip_read_finish(r, false);
		return 0;
	}
	if (n == 0) {
		r->buf[r->len] = '\0';
		clip_read_finish(r, true);
		return 0;
	}
	r->len += (size_t)n;
	return 0;
}

static void clip_write_finish(struct novi_clip_write *w) {
	wl_event_source_remove(w->ev);
	close(w->fd);
	free(w->data);
	free(w);
}

static int clip_write_cb(int fd, uint32_t mask, void *data) {
	struct novi_clip_write *w = data;
	if (mask & (WL_EVENT_ERROR | WL_EVENT_HANGUP)) {
		clip_write_finish(w);
		return 0;
	}
	while (w->sent < w->len) {
		ssize_t n = write(fd, w->data + w->sent, w->len - w->sent);
		if (n < 0) {
			if (errno == EAGAIN) {
				return 0;   /* come back when it drains */
			}
			if (errno == EINTR) {
				continue;
			}
			break;          /* reader went away */
		}
		w->sent += (size_t)n;
	}
	clip_write_finish(w);
	return 0;
}

static void clip_source_send(struct wlr_data_source *source,
		const char *mime_type, int32_t fd) {
	(void)mime_type;
	struct novi_clip_source *cs = wl_container_of(source, cs, base);
	struct novi_server *server = cs->server;

	int flags = fcntl(fd, F_GETFL, 0);
	if (flags >= 0) {
		fcntl(fd, F_SETFL, flags | O_NONBLOCK);
	}

	struct novi_clip_write *w = calloc(1, sizeof(*w));
	if (w == NULL || server->clip_text == NULL) {
		free(w);
		close(fd);
		return;
	}
	w->data = malloc(server->clip_len + 1);
	if (w->data == NULL) {
		free(w);
		close(fd);
		return;
	}
	memcpy(w->data, server->clip_text, server->clip_len);
	w->data[server->clip_len] = '\0';
	w->len = server->clip_len;
	w->fd = fd;
	w->ev = wl_event_loop_add_fd(wl_display_get_event_loop(server->wl_display),
		fd, WL_EVENT_WRITABLE, clip_write_cb, w);
	if (w->ev == NULL) {
		free(w->data);
		free(w);
		close(fd);
	}
}

static void clip_source_destroy(struct wlr_data_source *source) {
	struct novi_clip_source *cs = wl_container_of(source, cs, base);
	if (cs->server != NULL && cs->server->clip_source == source) {
		cs->server->clip_source = NULL;
	}
	free(cs);
}

static const struct wlr_data_source_impl clip_source_impl = {
	.send = clip_source_send,
	.destroy = clip_source_destroy,
};

/* Put our remembered text back on the selection, as a source that
 * belongs to the compositor and therefore outlives every client. */
static void clip_offer_ours(struct novi_server *server) {
	if (server->clip_text == NULL || server->clip_len == 0) {
		return;
	}
	struct novi_clip_source *cs = calloc(1, sizeof(*cs));
	if (cs == NULL) {
		return;
	}
	/* wlr_data_source_init() overwrites the whole base struct, so
	 * anything of ours is set after it, never before. */
	wlr_data_source_init(&cs->base, &clip_source_impl);
	cs->server = server;
	struct wlr_data_source *src = &cs->base;
	for (int i = 0; i < CLIP_MIME_COUNT; i++) {
		char **slot = wl_array_add(&src->mime_types, sizeof(char *));
		char *dup = strdup(CLIP_MIME[i]);
		if (slot == NULL || dup == NULL) {
			free(dup);
			wlr_data_source_destroy(src);
			return;
		}
		*slot = dup;
	}
	server->clip_source = src;
	wlr_seat_set_selection(server->seat, src,
		wl_display_next_serial(server->wl_display));
}

/* Start reading a client's selection into our buffer. */
static void clip_capture(struct novi_server *server,
		struct wlr_data_source *src) {
	int best = -1;
	char **mime;
	wl_array_for_each(mime, &src->mime_types) {
		for (int i = 0; i < CLIP_MIME_COUNT; i++) {
			if (strcmp(*mime, CLIP_MIME[i]) == 0 && (best < 0 || i < best)) {
				best = i;
			}
		}
	}
	if (best < 0) {
		/* Not text. We do not persist images or anything else yet, and
		 * the honest consequence is that the previous *text* stays
		 * remembered rather than being replaced by something we cannot
		 * hold. */
		return;
	}

	int fds[2];
	if (pipe(fds) != 0) {
		return;
	}
	if (fcntl(fds[0], F_SETFL, O_NONBLOCK) != 0) {
		close(fds[0]);
		close(fds[1]);
		return;
	}

	struct novi_clip_read *r = calloc(1, sizeof(*r));
	if (r == NULL) {
		close(fds[0]);
		close(fds[1]);
		return;
	}
	r->server = server;
	r->fd = fds[0];
	r->ev = wl_event_loop_add_fd(wl_display_get_event_loop(server->wl_display),
		fds[0], WL_EVENT_READABLE, clip_read_cb, r);
	if (r->ev == NULL) {
		free(r);
		close(fds[0]);
		close(fds[1]);
		return;
	}
	server->clip_read = r;

	wlr_data_source_send(src, CLIP_MIME[best], fds[1]);
	close(fds[1]);
}

static void seat_set_selection(struct wl_listener *listener, void *data) {
	(void)data;
	struct novi_server *server = wl_container_of(listener, server, set_selection);
	struct wlr_data_source *src = server->seat->selection_source;

	if (src != NULL && src->impl == &clip_source_impl) {
		return;   /* our own; setting it below is what got us here */
	}

	/* Whatever we were reading is about to be stale either way. */
	if (server->clip_read != NULL) {
		clip_read_finish(server->clip_read, false);
	}

	if (src != NULL) {
		clip_capture(server, src);
		return;
	}

	/* The selection is empty. Either a client cleared it deliberately
	 * or -- far more often -- the client that owned it exited, which is
	 * exactly the case this whole file section exists for. */
	clip_offer_ours(server);
}

static void seat_request_set_selection(struct wl_listener *listener, void *data) {
	/* This event is raised by the seat when a client wants to set the selection,
	 * usually when the user copies something. wlroots allows compositors to
	 * ignore such requests if they so choose, but in novi-shell we always honor
	 */
	struct novi_server *server = wl_container_of(
			listener, server, request_set_selection);
	struct wlr_seat_request_set_selection_event *event = data;
	wlr_seat_set_selection(server->seat, event->source, event->serial);
}

static struct novi_toplevel *desktop_toplevel_at(
		struct novi_server *server, double lx, double ly,
		struct wlr_surface **surface, double *sx, double *sy) {
	/* This returns the topmost node in the scene at the given layout coords.
	 * We only care about surface nodes as we are specifically looking for a
	 * surface in the surface tree of a novi_toplevel. */
	struct wlr_scene_node *node = wlr_scene_node_at(
		&server->scene->tree.node, lx, ly, sx, sy);
	if (node == NULL || node->type != WLR_SCENE_NODE_BUFFER) {
		return NULL;
	}
	struct wlr_scene_buffer *scene_buffer = wlr_scene_buffer_from_node(node);
	struct wlr_scene_surface *scene_surface =
		wlr_scene_surface_try_from_buffer(scene_buffer);
	if (!scene_surface) {
		return NULL;
	}

	*surface = scene_surface->surface;
	/* Find the node corresponding to the novi_toplevel at the root of this
	 * surface tree, it is the only one for which we set the data field. */
	struct wlr_scene_tree *tree = node->parent;
	while (tree != NULL && tree->node.data == NULL) {
		tree = tree->node.parent;
	}
	if (tree == NULL) {
		return NULL;
	}
	/* A layer-shell surface's own root scene tree ALSO has non-NULL
	 * .data (set in server_new_layer_surface(), pointing at its
	 * novi_layer_surface, not a novi_toplevel) -- and the scan above
	 * walks the ENTIRE scene, not just server->layer_tree_toplevels,
	 * so clicking on the panel or launcher would find that tree here
	 * too. Returning it as-is would type-confuse a novi_layer_surface*
	 * as a novi_toplevel* in every caller (server_cursor_button ->
	 * focus_toplevel() dereferences ->server/->link/->scene_tree/
	 * ->xdg_toplevel at the wrong offsets) -- undefined behavior with
	 * real crash/corruption potential, not yet hit only because
	 * nothing has clicked a layer-shell surface in testing so far.
	 * Toplevel scene trees are always DIRECT children of
	 * layer_tree_toplevels (server_new_xdg_toplevel's
	 * wlr_scene_xdg_surface_create() call), so this is a correct,
	 * cheap discriminator. (This function only ever resolves
	 * WLR_SCENE_NODE_BUFFER nodes -- see the type check above -- so a
	 * layer-shell surface's own content correctly reaches this same
	 * path via *surface, even though the discriminator below rejects
	 * it as a *novi_toplevel; novi-panel's apps button relies on
	 * exactly that split. novi-shell's own title bar/close-dot
	 * decorations, added later, are WLR_SCENE_NODE_RECT and never reach
	 * here at all -- see close_dot_toplevel_at() for their own,
	 * separate hit-test.) */
	if (tree->node.parent != server->layer_tree_toplevels) {
		return NULL;
	}
	return tree->node.data;
}

/* Separate from desktop_toplevel_at() above: that function only ever
 * resolves WLR_SCENE_NODE_BUFFER nodes (real client surface content),
 * so it correctly returns NULL for the title bar or any of its dots --
 * all plain WLR_SCENE_NODE_RECT nodes with no wlr_surface behind them.
 * Clicking a dot still needs its owning toplevel resolved, so this
 * walks the scene separately for that case, handing back which exact
 * rect was hit (the title bar backdrop itself is a legal, common
 * answer -- not clickable in this pass, see DECO_HEIGHT's comment on
 * no drag-to-move yet -- so callers must compare *rect_out themselves
 * against the specific dot(s) they care about, same as this function
 * doesn't privilege any one dot over another). */
static struct novi_toplevel *decoration_rect_toplevel_at(
		struct novi_server *server, double lx, double ly,
		struct wlr_scene_rect **rect_out) {
	double sx, sy;
	struct wlr_scene_node *node = wlr_scene_node_at(
		&server->scene->tree.node, lx, ly, &sx, &sy);
	if (node == NULL || node->type != WLR_SCENE_NODE_RECT) {
		return NULL;
	}
	if (node->parent == NULL || node->parent->node.data == NULL) {
		return NULL;
	}
	/* Same structural check desktop_toplevel_at() uses: only trust
	 * .data if this rect's immediate parent is actually a toplevel's
	 * own scene_tree (a direct child of layer_tree_toplevels), not
	 * some other tree that happens to have non-NULL .data. */
	if (node->parent->node.parent != server->layer_tree_toplevels) {
		return NULL;
	}
	*rect_out = wlr_scene_rect_from_node(node);
	return node->parent->node.data;
}

static void reset_cursor_mode(struct novi_server *server) {
	/* Reset the cursor mode to passthrough. */
	server->cursor_mode = NOVI_CURSOR_PASSTHROUGH;
	server->grabbed_toplevel = NULL;
}

static void process_cursor_move(struct novi_server *server, uint32_t time) {
	/* Move the grabbed toplevel to the new position. */
	struct novi_toplevel *toplevel = server->grabbed_toplevel;
	wlr_scene_node_set_position(&toplevel->scene_tree->node,
		server->cursor->x - server->grab_x,
		server->cursor->y - server->grab_y);
}

static void process_cursor_resize(struct novi_server *server, uint32_t time) {
	/*
	 * Resizing the grabbed toplevel can be a little bit complicated, because we
	 * could be resizing from any corner or edge. This not only resizes the
	 * toplevel on one or two axes, but can also move the toplevel if you resize
	 * from the top or left edges (or top-left corner).
	 *
	 * Note that some shortcuts are taken here. In a more fleshed-out
	 * compositor, you'd wait for the client to prepare a buffer at the new
	 * size, then commit any movement that was prepared.
	 */
	struct novi_toplevel *toplevel = server->grabbed_toplevel;
	double border_x = server->cursor->x - server->grab_x;
	double border_y = server->cursor->y - server->grab_y;
	int new_left = server->grab_geobox.x;
	int new_right = server->grab_geobox.x + server->grab_geobox.width;
	int new_top = server->grab_geobox.y;
	int new_bottom = server->grab_geobox.y + server->grab_geobox.height;

	if (server->resize_edges & WLR_EDGE_TOP) {
		new_top = border_y;
		if (new_top >= new_bottom) {
			new_top = new_bottom - 1;
		}
	} else if (server->resize_edges & WLR_EDGE_BOTTOM) {
		new_bottom = border_y;
		if (new_bottom <= new_top) {
			new_bottom = new_top + 1;
		}
	}
	if (server->resize_edges & WLR_EDGE_LEFT) {
		new_left = border_x;
		if (new_left >= new_right) {
			new_left = new_right - 1;
		}
	} else if (server->resize_edges & WLR_EDGE_RIGHT) {
		new_right = border_x;
		if (new_right <= new_left) {
			new_right = new_left + 1;
		}
	}

	struct wlr_box geo_box;
	wlr_xdg_surface_get_geometry(toplevel->xdg_toplevel->base, &geo_box);
	wlr_scene_node_set_position(&toplevel->scene_tree->node,
		new_left - geo_box.x, new_top - geo_box.y);

	int new_width = new_right - new_left;
	int new_height = new_bottom - new_top;
	wlr_xdg_toplevel_set_size(toplevel->xdg_toplevel, new_width, new_height);
}

static void process_cursor_motion(struct novi_server *server, uint32_t time) {
	/* If the mode is non-passthrough, delegate to those functions. */
	if (server->cursor_mode == NOVI_CURSOR_MOVE) {
		process_cursor_move(server, time);
		return;
	} else if (server->cursor_mode == NOVI_CURSOR_RESIZE) {
		process_cursor_resize(server, time);
		return;
	}

	/* Otherwise, find the toplevel under the pointer and send the event along. */
	double sx, sy;
	struct wlr_seat *seat = server->seat;
	struct wlr_surface *surface = NULL;
	struct novi_toplevel *toplevel = desktop_toplevel_at(server,
			server->cursor->x, server->cursor->y, &surface, &sx, &sy);
	if (!toplevel) {
		/* If there's no toplevel under the cursor, set the cursor image to a
		 * default. This is what makes the cursor image appear when you move it
		 * around the screen, not over any toplevels. */
		wlr_cursor_set_xcursor(server->cursor, server->cursor_mgr, "default");
	}
	if (surface) {
		/*
		 * Send pointer enter and motion events.
		 *
		 * The enter event gives the surface "pointer focus", which is distinct
		 * from keyboard focus. You get pointer focus by moving the pointer over
		 * a window.
		 *
		 * Note that wlroots will avoid sending duplicate enter/motion events if
		 * the surface has already has pointer focus or if the client is already
		 * aware of the coordinates passed.
		 */
		wlr_seat_pointer_notify_enter(seat, surface, sx, sy);
		wlr_seat_pointer_notify_motion(seat, time, sx, sy);
	} else {
		/* Clear pointer focus so future button events and such are not sent to
		 * the last client to have the cursor over it. */
		wlr_seat_pointer_clear_focus(seat);
	}
}

static void server_cursor_motion(struct wl_listener *listener, void *data) {
	/* This event is forwarded by the cursor when a pointer emits a _relative_
	 * pointer motion event (i.e. a delta) */
	struct novi_server *server =
		wl_container_of(listener, server, cursor_motion);
	struct wlr_pointer_motion_event *event = data;
	/* The cursor doesn't move unless we tell it to. The cursor automatically
	 * handles constraining the motion to the output layout, as well as any
	 * special configuration applied for the specific input device which
	 * generated the event. You can pass NULL for the device if you want to move
	 * the cursor around without any input. */
	wlr_cursor_move(server->cursor, &event->pointer->base,
			event->delta_x, event->delta_y);
	process_cursor_motion(server, event->time_msec);
}

static void server_cursor_motion_absolute(
		struct wl_listener *listener, void *data) {
	/* This event is forwarded by the cursor when a pointer emits an _absolute_
	 * motion event, from 0..1 on each axis. This happens, for example, when
	 * wlroots is running under a Wayland window rather than KMS+DRM, and you
	 * move the mouse over the window. You could enter the window from any edge,
	 * so we have to warp the mouse there. There is also some hardware which
	 * emits these events. */
	struct novi_server *server =
		wl_container_of(listener, server, cursor_motion_absolute);
	struct wlr_pointer_motion_absolute_event *event = data;
	wlr_cursor_warp_absolute(server->cursor, &event->pointer->base, event->x,
		event->y);
	process_cursor_motion(server, event->time_msec);
}

static void server_cursor_button(struct wl_listener *listener, void *data) {
	/* This event is forwarded by the cursor when a pointer emits a button
	 * event. */
	struct novi_server *server =
		wl_container_of(listener, server, cursor_button);
	struct wlr_pointer_button_event *event = data;
	/* Notify the client with pointer focus that a button press has occurred */
	wlr_seat_pointer_notify_button(server->seat,
			event->time_msec, event->button, event->state);
	/* Decoration-dot clicks, on press -- matching the rest of this
	 * function's own convention of acting on press, not press-then-
	 * release (unlike novi-panel's client-side apps button, which does
	 * track press-then-release since it's a separate client with its
	 * own hit-testing conventions; this compositor's existing click-to-
	 * focus below has always acted on press alone). */
	if (event->button == BTN_LEFT &&
			event->state == WL_POINTER_BUTTON_STATE_PRESSED) {
		struct wlr_scene_rect *hit_rect = NULL;
		struct novi_toplevel *hit = decoration_rect_toplevel_at(
			server, server->cursor->x, server->cursor->y, &hit_rect);
		if (hit != NULL && hit_rect == hit->close_dot) {
			wlr_xdg_toplevel_send_close(hit->xdg_toplevel);
		} else if (hit != NULL && hit_rect == hit->maximize_dot) {
			if (hit->maximized) {
				unmaximize_toplevel(hit);
			} else {
				maximize_toplevel(hit);
			}
		} else if (hit != NULL && hit_rect == hit->minimize_dot) {
			minimize_toplevel(hit);
		}
	}

	double sx, sy;
	struct wlr_surface *surface = NULL;
	struct novi_toplevel *toplevel = desktop_toplevel_at(server,
			server->cursor->x, server->cursor->y, &surface, &sx, &sy);
	if (event->state == WL_POINTER_BUTTON_STATE_RELEASED) {
		/* If you released any buttons, we exit interactive move/resize mode. */
		reset_cursor_mode(server);
	} else {
		/* Focus that client if the button was _pressed_ */
		focus_toplevel(toplevel, surface);
	}
}

static void server_cursor_axis(struct wl_listener *listener, void *data) {
	/* This event is forwarded by the cursor when a pointer emits an axis event,
	 * for example when you move the scroll wheel. */
	struct novi_server *server =
		wl_container_of(listener, server, cursor_axis);
	struct wlr_pointer_axis_event *event = data;
	/* Notify the client with pointer focus of the axis event. */
	wlr_seat_pointer_notify_axis(server->seat,
			event->time_msec, event->orientation, event->delta,
			event->delta_discrete, event->source, event->relative_direction);
}

static void server_cursor_frame(struct wl_listener *listener, void *data) {
	/* This event is forwarded by the cursor when a pointer emits an frame
	 * event. Frame events are sent after regular pointer events to group
	 * multiple events together. For instance, two axis events may happen at the
	 * same time, in which case a frame event won't be sent in between. */
	struct novi_server *server =
		wl_container_of(listener, server, cursor_frame);
	/* Notify the client with pointer focus of the frame event. */
	wlr_seat_pointer_notify_frame(server->seat);
}

static void output_frame(struct wl_listener *listener, void *data) {
	/* This function is called every time an output is ready to display a frame,
	 * generally at the output's refresh rate (e.g. 60Hz). */
	struct novi_output *output = wl_container_of(listener, output, frame);
	struct wlr_scene *scene = output->server->scene;

	struct wlr_scene_output *scene_output = wlr_scene_get_scene_output(
		scene, output->wlr_output);

	/* Render the scene if needed and commit the output */
	wlr_scene_output_commit(scene_output, NULL);

	struct timespec now;
	clock_gettime(CLOCK_MONOTONIC, &now);
	wlr_scene_output_send_frame_done(scene_output, &now);
}

static void arrange_layers(struct novi_output *output);

static void output_request_state(struct wl_listener *listener, void *data) {
	/* This function is called when the backend requests a new state for
	 * the output. For example, Wayland and X11 backends request a new mode
	 * when the output window is resized. */
	struct novi_output *output = wl_container_of(listener, output, request_state);
	const struct wlr_output_event_request_state *event = data;
	wlr_output_commit_state(output->wlr_output, event->state);
	/* Resolution may have changed -- layer-shell surfaces anchored to
	 * this output (a panel spanning full width, say) need their boxes
	 * recomputed against the new dimensions. */
	arrange_layers(output);
}

static void output_destroy(struct wl_listener *listener, void *data) {
	struct novi_output *output = wl_container_of(listener, output, destroy);

	/* Layer-shell clients hold a pointer back to this output
	 * (novi_layer_surface.output) that would otherwise dangle once
	 * `output` is freed below -- tear them down explicitly rather than
	 * leave that as a use-after-free waiting to happen. destroy() on
	 * each triggers layer_surface_destroy(), which unlinks itself from
	 * output->layer_surfaces, so this list is safe to walk with the
	 * _safe iterator. */
	struct novi_layer_surface *surface, *tmp;
	wl_list_for_each_safe(surface, tmp, &output->layer_surfaces, link) {
		wlr_layer_surface_v1_destroy(surface->layer_surface);
	}

	wl_list_remove(&output->frame.link);
	wl_list_remove(&output->request_state.link);
	wl_list_remove(&output->destroy.link);
	wl_list_remove(&output->link);
	free(output);
}

static void server_new_output(struct wl_listener *listener, void *data) {
	/* This event is raised by the backend when a new output (aka a display or
	 * monitor) becomes available. */
	struct novi_server *server =
		wl_container_of(listener, server, new_output);
	struct wlr_output *wlr_output = data;

	/* Configures the output created by the backend to use our allocator
	 * and our renderer. Must be done once, before commiting the output */
	wlr_output_init_render(wlr_output, server->allocator, server->renderer);

	/* The output may be disabled, switch it on. */
	struct wlr_output_state state;
	wlr_output_state_init(&state);
	wlr_output_state_set_enabled(&state, true);

	/* Some backends don't have modes. DRM+KMS does, and we need to set a mode
	 * before we can use the output. The mode is a tuple of (width, height,
	 * refresh rate), and each monitor supports only a specific set of modes. We
	 * just pick the monitor's preferred mode, a more sophisticated compositor
	 * would let the user configure it. */
	struct wlr_output_mode *mode = wlr_output_preferred_mode(wlr_output);
	if (mode != NULL) {
		wlr_output_state_set_mode(&state, mode);
	}

	/* Atomically applies the new output state. */
	wlr_output_commit_state(wlr_output, &state);
	wlr_output_state_finish(&state);

	/* Allocates and configures our state for this output */
	struct novi_output *output = calloc(1, sizeof(*output));
	output->wlr_output = wlr_output;
	output->server = server;
	wl_list_init(&output->layer_surfaces);
	/* Backpointer so a layer-shell surface's wlr_output can be mapped
	 * back to our novi_output wrapper (server_new_layer_surface does
	 * this when a client requests a specific output, or when we assign
	 * one ourselves for a client that left it unspecified). */
	wlr_output->data = output;

	/* Sets up a listener for the frame event. */
	output->frame.notify = output_frame;
	wl_signal_add(&wlr_output->events.frame, &output->frame);

	/* Sets up a listener for the state request event. */
	output->request_state.notify = output_request_state;
	wl_signal_add(&wlr_output->events.request_state, &output->request_state);

	/* Sets up a listener for the destroy event. */
	output->destroy.notify = output_destroy;
	wl_signal_add(&wlr_output->events.destroy, &output->destroy);

	wl_list_insert(&server->outputs, &output->link);

	/* Adds this to the output layout. The add_auto function arranges outputs
	 * from left-to-right in the order they appear. A more sophisticated
	 * compositor would let the user configure the arrangement of outputs in the
	 * layout.
	 *
	 * The output layout utility automatically adds a wl_output global to the
	 * display, which Wayland clients can see to find out information about the
	 * output (such as DPI, scale factor, manufacturer, etc).
	 */
	struct wlr_output_layout_output *l_output = wlr_output_layout_add_auto(server->output_layout,
		wlr_output);
	struct wlr_scene_output *scene_output = wlr_scene_output_create(server->scene, wlr_output);
	wlr_scene_output_layout_add_output(server->scene_layout, l_output, scene_output);

	arrange_layers(output);
}

/* ── Layer-shell (wlr-layer-shell-unstable-v1) ──────────────────────
 *
 * RFC 0001 decision 5: the panel, launcher, and other novi-shell UI
 * pieces are separate Wayland clients using this protocol to anchor
 * themselves to screen edges, not code baked into the compositor.
 * This section is the compositor-side half only: accept layer-shell
 * clients, place them in the right z-order layer, and give each one
 * a correctly-computed box. It does not implement any panel itself.
 */

static void arrange_layers(struct novi_output *output) {
	if (output->wlr_output == NULL) {
		return;
	}

	struct wlr_box full_area = {0};
	wlr_output_effective_resolution(output->wlr_output,
		&full_area.width, &full_area.height);
	struct wlr_box usable_area = full_area;

	/* Keep the desktop background covering the whole output. Created
	 * lazily here rather than in server_new_output() because this is
	 * the one place that already knows the output's effective
	 * resolution and is already called whenever it changes. */
	if (output->background == NULL) {
		float bg[4] = {DESKTOP_BG_COLOR_R, DESKTOP_BG_COLOR_G,
			DESKTOP_BG_COLOR_B, 1.0f};
		output->background = wlr_scene_rect_create(
			output->server->layer_tree_background,
			full_area.width, full_area.height, bg);
		wlr_scene_node_lower_to_bottom(&output->background->node);
	} else {
		wlr_scene_rect_set_size(output->background,
			full_area.width, full_area.height);
	}

	/* wlroots' own scene helper (types/scene/layer_shell_v1.c) already
	 * implements the protocol's anchor/margin/exclusive-zone math
	 * correctly -- we just have to call it once per mapped surface on
	 * this output, in the fixed background -> bottom -> top -> overlay
	 * order the protocol expects, threading usable_area through so a
	 * later layer sees the space an earlier one reserved. */
	static const enum zwlr_layer_shell_v1_layer arrange_order[] = {
		ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND,
		ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM,
		ZWLR_LAYER_SHELL_V1_LAYER_TOP,
		ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
	};
	for (size_t i = 0; i < sizeof(arrange_order) / sizeof(arrange_order[0]); i++) {
		struct novi_layer_surface *surface;
		wl_list_for_each(surface, &output->layer_surfaces, link) {
			if (surface->layer_surface->current.layer != arrange_order[i]) {
				continue;
			}
			wlr_scene_layer_surface_v1_configure(surface->scene_layer_surface,
				&full_area, &usable_area);
		}
	}

	output->usable_area = usable_area;
}

static void layer_surface_map(struct wl_listener *listener, void *data) {
	struct novi_layer_surface *surface = wl_container_of(listener, surface, map);
	wlr_log(WLR_INFO, "layer-shell surface mapped: namespace=\"%s\" layer=%d",
		surface->layer_surface->namespace ? surface->layer_surface->namespace : "",
		surface->layer_surface->current.layer);

	/* Re-arrange on map, not just on commit: wlroots' own scene helper
	 * (types/scene/layer_shell_v1.c's layer_surface_configure()) only
	 * applies a surface's exclusive zone when `surface->mapped` is
	 * already true at the moment wlr_scene_layer_surface_v1_configure()
	 * runs -- confirmed by reading that source directly, not guessed.
	 * layer_surface_commit() above only calls arrange_layers() on the
	 * surface's first commit or a later geometry-affecting one (see its
	 * own comment for why -- unconditional re-arranging caused a real
	 * infinite ping-pong loop), and a layer-shell client typically sets
	 * its size/anchor/exclusive-zone once and never again, so that one
	 * commit-triggered arrange is often the ONLY one that ever fires --
	 * and at that exact point, this surface isn't mapped yet (mapping
	 * is a consequence of that same commit, processed after the commit
	 * signal novi-shell listens on). Net effect, confirmed live: a
	 * panel's exclusive zone was silently never applied -- new windows
	 * kept landing at the true top of the screen with usable_area
	 * staying the full, unreduced output size forever, invisibly masked
	 * because the panel still draws over that region regardless (it's
	 * on a higher scene layer), so nothing ever looked wrong without
	 * decorations to expose the gap. Re-arranging here, once mapped is
	 * guaranteed true, closes it. */
	arrange_layers(surface->output);

	/* This is the lock surface mapping: flip novi_server.locked so
	 * keyboard_handle_key() and focus_toplevel() start refusing every
	 * path that could steal focus or run a keybinding while locked.
	 * Deliberately checked by namespace, not by anything novi-lockscreen
	 * requests of the protocol itself (keyboard-interactivity=exclusive
	 * alone is exactly what novi-launcher already uses for a plain
	 * overlay) -- see novi_server.locked's own comment for why that
	 * alone was never a real lock. */
	if (surface->layer_surface->namespace != NULL &&
			strcmp(surface->layer_surface->namespace, NOVI_LOCK_NAMESPACE) == 0) {
		surface->output->server->locked = true;
	}

	/* "exclusive" keyboard-interactivity (the launcher overlay's case:
	 * it needs to receive typed input the instant it appears) means
	 * grab keyboard focus now. "on_demand" (click-to-focus layer
	 * surfaces) isn't implemented -- nothing needs it yet. */
	if (surface->layer_surface->current.keyboard_interactive ==
			ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE) {
		struct wlr_seat *seat = surface->output->server->seat;
		struct wlr_keyboard *keyboard = wlr_seat_get_keyboard(seat);
		if (keyboard != NULL) {
			wlr_seat_keyboard_notify_enter(seat, surface->layer_surface->surface,
				keyboard->keycodes, keyboard->num_keycodes, &keyboard->modifiers);
		}
	}
}

static void layer_surface_unmap(struct wl_listener *listener, void *data) {
	struct novi_layer_surface *surface = wl_container_of(listener, surface, unmap);
	struct novi_server *server = surface->output->server;
	struct wlr_seat *seat = server->seat;

	/* Clear the lock *before* the focus-restore logic below runs --
	 * focus_toplevel() itself refuses to move focus while
	 * server->locked is true (see its own guard), so leaving this set
	 * past this point would make a successful unlock (novi-lockscreen
	 * exiting after a correct password) restore no keyboard focus at
	 * all instead of handing it back to the top toplevel. */
	if (surface->layer_surface->namespace != NULL &&
			strcmp(surface->layer_surface->namespace, NOVI_LOCK_NAMESPACE) == 0) {
		server->locked = false;
	}

	/* Only act if this surface actually held keyboard focus (a
	 * non-interactive layer surface unmapping shouldn't disturb
	 * whatever toplevel currently has focus). Restore focus to the
	 * most-recently-focused toplevel, matching what focus_toplevel()
	 * would have left focused before this surface grabbed it. */
	if (seat->keyboard_state.focused_surface != surface->layer_surface->surface) {
		return;
	}
	if (!wl_list_empty(&server->toplevels)) {
		struct novi_toplevel *top =
			wl_container_of(server->toplevels.next, top, link);
		focus_toplevel(top, top->xdg_toplevel->base->surface);
	} else {
		wlr_seat_keyboard_notify_clear_focus(seat);
	}
}

static void layer_surface_commit(struct wl_listener *listener, void *data) {
	struct novi_layer_surface *surface = wl_container_of(listener, surface, commit);
	struct wlr_layer_surface_v1 *layer_surface = surface->layer_surface;

	/* Re-arrange only when this commit actually touched geometry-
	 * affecting state (or hasn't been configured at all yet) -- NOT on
	 * every commit. Confirmed live, the hard way: arranging
	 * unconditionally sends a fresh configure via
	 * wlr_scene_layer_surface_v1_configure() on every single commit,
	 * including plain content-only redraws (a clock ticking) that
	 * never called set_size/set_anchor/etc. again -- and both
	 * novi-launcher and novi-panel ack + immediately re-commit in
	 * response to any configure, whether or not anything actually
	 * changed. That closes an infinite compositor<->client ping-pong:
	 * one boot logged over 1,000 arrange/configure cycles in 13
	 * seconds, continuously reallocating shm buffers, until the whole
	 * session visibly degraded (the panel silently stopped updating
	 * once a terminal was also opened -- almost certainly fd/resource
	 * churn from the runaway loop, not a z-order bug as it first
	 * appeared). wlr_layer_surface_v1_state.committed is genuinely
	 * per-commit (surface_synced_move_state resets pending.committed
	 * to 0 after each promotion, confirmed by reading
	 * types/wlr_layer_shell_v1.c), so this check is reliable. */
	uint32_t geometry_fields =
		WLR_LAYER_SURFACE_V1_STATE_DESIRED_SIZE |
		WLR_LAYER_SURFACE_V1_STATE_ANCHOR |
		WLR_LAYER_SURFACE_V1_STATE_EXCLUSIVE_ZONE |
		WLR_LAYER_SURFACE_V1_STATE_MARGIN |
		WLR_LAYER_SURFACE_V1_STATE_LAYER;
	if (!layer_surface->configured ||
			(layer_surface->current.committed & geometry_fields)) {
		arrange_layers(surface->output);
	}
}

static void layer_surface_destroy(struct wl_listener *listener, void *data) {
	struct novi_layer_surface *surface = wl_container_of(listener, surface, destroy);
	struct novi_output *output = surface->output;

	wl_list_remove(&surface->link);
	wl_list_remove(&surface->map.link);
	wl_list_remove(&surface->unmap.link);
	wl_list_remove(&surface->destroy.link);
	wl_list_remove(&surface->commit.link);
	/* surface->scene_layer_surface frees itself: wlr_scene_layer_surface_v1_create()
	 * (types/scene/layer_shell_v1.c) hooks the layer_surface's own destroy
	 * signal to tear down its scene tree and free that struct. */
	free(surface);

	/* A departing surface may have held a positive exclusive zone (a
	 * panel, say) -- re-arrange so any remaining layer surfaces get
	 * that space back. output_destroy() (which is what's tearing this
	 * output down when output is no longer valid) always empties
	 * layer_surfaces before freeing the output itself, so this pointer
	 * is safe to use here. */
	arrange_layers(output);
}

static struct wlr_scene_tree *layer_tree_for(struct novi_server *server,
		enum zwlr_layer_shell_v1_layer layer) {
	switch (layer) {
	case ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND:
		return server->layer_tree_background;
	case ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM:
		return server->layer_tree_bottom;
	case ZWLR_LAYER_SHELL_V1_LAYER_TOP:
		return server->layer_tree_top;
	case ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY:
	default:
		return server->layer_tree_overlay;
	}
}

static void server_new_layer_surface(struct wl_listener *listener, void *data) {
	struct novi_server *server = wl_container_of(listener, server, new_layer_surface);
	struct wlr_layer_surface_v1 *layer_surface = data;

	/* Per wlr_layer_shell_v1.h: "the output may be NULL. In this case,
	 * it is your responsibility to assign an output before returning."
	 * This compositor only ever has one output under test today, so
	 * "pick the first one" is correct; a real multi-output setup would
	 * pick the output under the cursor or the focused one instead. */
	if (layer_surface->output == NULL) {
		if (wl_list_empty(&server->outputs)) {
			wlr_log(WLR_ERROR,
				"layer-shell client requested a surface but no output exists yet");
			wlr_layer_surface_v1_destroy(layer_surface);
			return;
		}
		struct novi_output *first_output =
			wl_container_of(server->outputs.next, first_output, link);
		layer_surface->output = first_output->wlr_output;
	}

	struct novi_output *output = layer_surface->output->data;
	assert(output != NULL);

	struct novi_layer_surface *surface = calloc(1, sizeof(*surface));
	surface->output = output;
	surface->layer_surface = layer_surface;
	surface->scene_layer_surface = wlr_scene_layer_surface_v1_create(
		layer_tree_for(server, layer_surface->current.layer), layer_surface);
	if (surface->scene_layer_surface == NULL) {
		wlr_log(WLR_ERROR, "failed to create wlr_scene_layer_surface_v1");
		free(surface);
		wlr_layer_surface_v1_destroy(layer_surface);
		return;
	}
	surface->scene_layer_surface->tree->node.data = surface;
	layer_surface->data = surface->scene_layer_surface->tree;

	surface->map.notify = layer_surface_map;
	wl_signal_add(&layer_surface->surface->events.map, &surface->map);
	surface->unmap.notify = layer_surface_unmap;
	wl_signal_add(&layer_surface->surface->events.unmap, &surface->unmap);
	surface->destroy.notify = layer_surface_destroy;
	wl_signal_add(&layer_surface->events.destroy, &surface->destroy);
	surface->commit.notify = layer_surface_commit;
	wl_signal_add(&layer_surface->surface->events.commit, &surface->commit);

	wl_list_insert(&output->layer_surfaces, &surface->link);

	/* Deliberately NOT calling arrange_layers() here: this fires while
	 * handling the client's get_layer_surface request, before it has
	 * sent set_size/set_anchor/etc. or its required initial commit
	 * (wlr-layer-shell-unstable-v1.xml: "the client must perform an
	 * initial commit without any buffer attached" before the
	 * compositor may configure it). Confirmed live: arranging here
	 * sent a real client a 0x0 configure and logged wlroots' own
	 * "A configure is sent to an uninitialized wlr_layer_surface_v1"
	 * error -- silently absorbed only because that particular client
	 * happened to fall back to a default size on a zero configure, not
	 * because it was correct. layer_surface_commit() already arranges
	 * on every commit, including the first real one. */
}

/* wlr-foreign-toplevel-management-unstable-v1: a taskbar client
 * (novi-panel) requesting a state change on one of our toplevels via
 * its handle. Each just calls the exact same function the
 * compositor-native path (a decoration dot, a client's own xdg_
 * toplevel request) already uses -- one place that ever changes each
 * piece of state, regardless of which UI asked. */
static void foreign_toplevel_handle_request_maximize(
		struct wl_listener *listener, void *data) {
	struct novi_toplevel *toplevel =
		wl_container_of(listener, toplevel, foreign_request_maximize);
	struct wlr_foreign_toplevel_handle_v1_maximized_event *event = data;
	if (event->maximized) {
		maximize_toplevel(toplevel);
	} else {
		unmaximize_toplevel(toplevel);
	}
}

static void foreign_toplevel_handle_request_minimize(
		struct wl_listener *listener, void *data) {
	struct novi_toplevel *toplevel =
		wl_container_of(listener, toplevel, foreign_request_minimize);
	struct wlr_foreign_toplevel_handle_v1_minimized_event *event = data;
	if (event->minimized) {
		minimize_toplevel(toplevel);
	} else {
		unminimize_toplevel(toplevel);
	}
}

static void foreign_toplevel_handle_request_activate(
		struct wl_listener *listener, void *data) {
	(void)data;
	struct novi_toplevel *toplevel =
		wl_container_of(listener, toplevel, foreign_request_activate);
	/* focus_toplevel() itself unminimizes first if needed -- a taskbar
	 * click on a minimized entry both restores and focuses it, same as
	 * every real desktop. */
	focus_toplevel(toplevel, toplevel->xdg_toplevel->base->surface);
}

static void foreign_toplevel_handle_request_close(
		struct wl_listener *listener, void *data) {
	(void)data;
	struct novi_toplevel *toplevel =
		wl_container_of(listener, toplevel, foreign_request_close);
	wlr_xdg_toplevel_send_close(toplevel->xdg_toplevel);
}

static void xdg_toplevel_map(struct wl_listener *listener, void *data) {
	/* Called when the surface is mapped, or ready to display on-screen. */
	struct novi_toplevel *toplevel = wl_container_of(listener, toplevel, map);

	/* New windows open on the current workspace -- every real i3/sway-
	 * family compositor's behavior, and simplest for a user (a freshly
	 * launched app appears where you are, not wherever workspace 1
	 * happens to be). */
	toplevel->workspace = toplevel->server->active_workspace;

	wl_list_insert(&toplevel->server->toplevels, &toplevel->link);

	/* Foreign-toplevel-management handle: created here (not in
	 * server_new_xdg_toplevel(), where the surface isn't shown yet) and
	 * destroyed in xdg_toplevel_unmap() below, so a taskbar only ever
	 * lists windows that are actually currently mapped -- same map/
	 * unmap-scoped lifetime as the surface's own on-screen presence. */
	toplevel->foreign_handle = wlr_foreign_toplevel_handle_v1_create(
		toplevel->server->foreign_toplevel_manager);
	wlr_foreign_toplevel_handle_v1_set_title(toplevel->foreign_handle,
		toplevel->xdg_toplevel->title ? toplevel->xdg_toplevel->title : "");
	wlr_foreign_toplevel_handle_v1_set_app_id(toplevel->foreign_handle,
		toplevel->xdg_toplevel->app_id ? toplevel->xdg_toplevel->app_id : "");
	toplevel->foreign_request_maximize.notify = foreign_toplevel_handle_request_maximize;
	wl_signal_add(&toplevel->foreign_handle->events.request_maximize,
		&toplevel->foreign_request_maximize);
	toplevel->foreign_request_minimize.notify = foreign_toplevel_handle_request_minimize;
	wl_signal_add(&toplevel->foreign_handle->events.request_minimize,
		&toplevel->foreign_request_minimize);
	toplevel->foreign_request_activate.notify = foreign_toplevel_handle_request_activate;
	wl_signal_add(&toplevel->foreign_handle->events.request_activate,
		&toplevel->foreign_request_activate);
	toplevel->foreign_request_close.notify = foreign_toplevel_handle_request_close;
	wl_signal_add(&toplevel->foreign_handle->events.request_close,
		&toplevel->foreign_request_close);

	focus_toplevel(toplevel, toplevel->xdg_toplevel->base->surface);
}

static void xdg_toplevel_unmap(struct wl_listener *listener, void *data) {
	/* Called when the surface is unmapped, and should no longer be shown. */
	struct novi_toplevel *toplevel = wl_container_of(listener, toplevel, unmap);

	/* Reset the cursor mode if the grabbed toplevel was unmapped. */
	if (toplevel == toplevel->server->grabbed_toplevel) {
		reset_cursor_mode(toplevel->server);
	}

	wl_list_remove(&toplevel->link);

	if (toplevel->foreign_handle != NULL) {
		wl_list_remove(&toplevel->foreign_request_maximize.link);
		wl_list_remove(&toplevel->foreign_request_minimize.link);
		wl_list_remove(&toplevel->foreign_request_activate.link);
		wl_list_remove(&toplevel->foreign_request_close.link);
		wlr_foreign_toplevel_handle_v1_destroy(toplevel->foreign_handle);
		toplevel->foreign_handle = NULL;
	}
}

/* The size a new window should open at: 70% of the output's usable area
 * (the space left after the panel's exclusive zone), floored so a tiny
 * output cannot produce something unusable. Returns false when there is
 * no output yet, in which case the caller leaves the client to choose.
 *
 * Used from two places that must agree: xdg_toplevel_commit()'s
 * initial_commit branch, which is the point in the xdg-shell handshake
 * where a compositor's size preference actually reaches the client, and
 * server_new_xdg_toplevel(), which centres the window on that same
 * size. They were briefly out of step -- the size was requested at
 * creation and then overwritten with (0,0) at initial_commit -- which
 * produced a window at the client's own size sitting off-centre by the
 * difference. One function, called twice, cannot drift like that. */
static bool default_toplevel_size(struct novi_server *server, int *out_w,
		int *out_h) {
	if (wl_list_empty(&server->outputs)) {
		return false;
	}
	struct novi_output *output =
		wl_container_of(server->outputs.next, output, link);
	int avail_w = output->usable_area.width;
	int avail_h = output->usable_area.height - DECO_HEIGHT;
	if (avail_w <= 0 || avail_h <= 0) {
		return false;
	}
	int w = avail_w * 7 / 10;
	int h = avail_h * 7 / 10;
	if (w < TOPLEVEL_MIN_WIDTH) {
		w = avail_w < TOPLEVEL_MIN_WIDTH ? avail_w : TOPLEVEL_MIN_WIDTH;
	}
	if (h < TOPLEVEL_MIN_HEIGHT) {
		h = avail_h < TOPLEVEL_MIN_HEIGHT ? avail_h : TOPLEVEL_MIN_HEIGHT;
	}
	*out_w = w;
	*out_h = h;
	return true;
}

static void xdg_toplevel_commit(struct wl_listener *listener, void *data) {
	/* Called when a new surface state is committed. */
	struct novi_toplevel *toplevel = wl_container_of(listener, toplevel, commit);

	if (toplevel->xdg_toplevel->base->initial_commit) {
		/* When an xdg_surface performs an initial commit, the compositor
		 * must reply with a configure so the client can map the surface.
		 * This is also the only moment a size preference reaches the
		 * client, so it is where the default goes.
		 *
		 * It used to send (0,0) -- "pick your own size" -- and foot
		 * duly picked its built-in 700x565, which on a 1280x800 screen
		 * is a small box with two thirds of the desktop empty next to
		 * it. A compositor that expresses no opinion about window size
		 * is not being neutral, it is making every application's
		 * hardcoded default into the desktop's layout policy. */
		int w = 0, h = 0;
		if (default_toplevel_size(toplevel->server, &w, &h)) {
			wlr_xdg_toplevel_set_size(toplevel->xdg_toplevel, w, h);
		} else {
			wlr_xdg_toplevel_set_size(toplevel->xdg_toplevel, 0, 0);
		}
	}

	/* Keep the title bar/dots in sync with the content's current width
	 * on every commit -- necessary because both interactive resize
	 * (process_cursor_resize()) and the client's own size choice can
	 * change this at any time, and a title bar has to span the actual
	 * window width to read as real chrome rather than a mismatched
	 * strip. Geometry is 0x0 until the client's first real commit (the
	 * initial_commit branch above only sends a configure, it doesn't
	 * itself establish geometry) -- the guard below just leaves the
	 * placeholder size/position from server_new_xdg_toplevel() alone
	 * until then, which is harmless since nothing is mapped yet either. */
	struct wlr_box geo_box;
	wlr_xdg_surface_get_geometry(toplevel->xdg_toplevel->base, &geo_box);
	if (geo_box.width > 0) {
		wlr_scene_rect_set_size(toplevel->titlebar, geo_box.width, DECO_HEIGHT);
		/* Right-to-left: close (rightmost), then maximize, then
		 * minimize, each DECO_DOT_GAP further left than the last. */
		int close_x = geo_box.width - DECO_DOT_PADDING - DECO_DOT_SIZE;
		int maximize_x = close_x - DECO_DOT_GAP;
		int minimize_x = maximize_x - DECO_DOT_GAP;
		wlr_scene_node_set_position(&toplevel->close_dot->node, close_x,
			toplevel->close_dot->node.y);
		wlr_scene_node_set_position(&toplevel->maximize_dot->node, maximize_x,
			toplevel->maximize_dot->node.y);
		wlr_scene_node_set_position(&toplevel->minimize_dot->node, minimize_x,
			toplevel->minimize_dot->node.y);
	}
}

static void xdg_toplevel_destroy(struct wl_listener *listener, void *data) {
	/* Called when the xdg_toplevel is destroyed. */
	struct novi_toplevel *toplevel = wl_container_of(listener, toplevel, destroy);

	wl_list_remove(&toplevel->map.link);
	wl_list_remove(&toplevel->unmap.link);
	wl_list_remove(&toplevel->commit.link);
	wl_list_remove(&toplevel->destroy.link);
	wl_list_remove(&toplevel->request_move.link);
	wl_list_remove(&toplevel->request_resize.link);
	wl_list_remove(&toplevel->request_maximize.link);
	wl_list_remove(&toplevel->request_fullscreen.link);
	wl_list_remove(&toplevel->set_title.link);
	wl_list_remove(&toplevel->set_app_id.link);

	free(toplevel);
}

/* Keeps a mapped toplevel's foreign-toplevel-management handle (its
 * taskbar entry) showing the client's current title/app_id -- these
 * can change any time after the initial commit (a browser tab switch,
 * a terminal's shell prompt updating its title), not just once at
 * creation. Guarded on foreign_handle != NULL since these listeners
 * are wired for the toplevel's whole lifetime (server_new_xdg_
 * toplevel()) but the handle itself only exists between map and
 * unmap. */
static void xdg_toplevel_set_title(struct wl_listener *listener, void *data) {
	(void)data;
	struct novi_toplevel *toplevel = wl_container_of(listener, toplevel, set_title);
	if (toplevel->foreign_handle != NULL) {
		wlr_foreign_toplevel_handle_v1_set_title(toplevel->foreign_handle,
			toplevel->xdg_toplevel->title ? toplevel->xdg_toplevel->title : "");
	}
}

static void xdg_toplevel_set_app_id(struct wl_listener *listener, void *data) {
	(void)data;
	struct novi_toplevel *toplevel = wl_container_of(listener, toplevel, set_app_id);
	if (toplevel->foreign_handle != NULL) {
		wlr_foreign_toplevel_handle_v1_set_app_id(toplevel->foreign_handle,
			toplevel->xdg_toplevel->app_id ? toplevel->xdg_toplevel->app_id : "");
	}
}

static void begin_interactive(struct novi_toplevel *toplevel,
		enum novi_cursor_mode mode, uint32_t edges) {
	/* This function sets up an interactive move or resize operation, where the
	 * compositor stops propegating pointer events to clients and instead
	 * consumes them itself, to move or resize windows. */
	struct novi_server *server = toplevel->server;
	struct wlr_surface *focused_surface =
		server->seat->pointer_state.focused_surface;
	if (toplevel->xdg_toplevel->base->surface !=
			wlr_surface_get_root_surface(focused_surface)) {
		/* Deny move/resize requests from unfocused clients. */
		return;
	}
	server->grabbed_toplevel = toplevel;
	server->cursor_mode = mode;

	if (mode == NOVI_CURSOR_MOVE) {
		server->grab_x = server->cursor->x - toplevel->scene_tree->node.x;
		server->grab_y = server->cursor->y - toplevel->scene_tree->node.y;
	} else {
		struct wlr_box geo_box;
		wlr_xdg_surface_get_geometry(toplevel->xdg_toplevel->base, &geo_box);

		double border_x = (toplevel->scene_tree->node.x + geo_box.x) +
			((edges & WLR_EDGE_RIGHT) ? geo_box.width : 0);
		double border_y = (toplevel->scene_tree->node.y + geo_box.y) +
			((edges & WLR_EDGE_BOTTOM) ? geo_box.height : 0);
		server->grab_x = server->cursor->x - border_x;
		server->grab_y = server->cursor->y - border_y;

		server->grab_geobox = geo_box;
		server->grab_geobox.x += toplevel->scene_tree->node.x;
		server->grab_geobox.y += toplevel->scene_tree->node.y;

		server->resize_edges = edges;
	}
}

static void xdg_toplevel_request_move(
		struct wl_listener *listener, void *data) {
	/* This event is raised when a client would like to begin an interactive
	 * move, typically because the user clicked on their client-side
	 * decorations. Note that a more sophisticated compositor should check the
	 * provided serial against a list of button press serials sent to this
	 * client, to prevent the client from requesting this whenever they want. */
	struct novi_toplevel *toplevel = wl_container_of(listener, toplevel, request_move);
	begin_interactive(toplevel, NOVI_CURSOR_MOVE, 0);
}

static void xdg_toplevel_request_resize(
		struct wl_listener *listener, void *data) {
	/* This event is raised when a client would like to begin an interactive
	 * resize, typically because the user clicked on their client-side
	 * decorations. Note that a more sophisticated compositor should check the
	 * provided serial against a list of button press serials sent to this
	 * client, to prevent the client from requesting this whenever they want. */
	struct wlr_xdg_toplevel_resize_event *event = data;
	struct novi_toplevel *toplevel = wl_container_of(listener, toplevel, request_resize);
	begin_interactive(toplevel, NOVI_CURSOR_RESIZE, event->edges);
}

/* Snaps a toplevel to the output's usable area (below the panel, same
 * as initial placement), remembering its current position/size first
 * so unmaximize_toplevel() can put it back. GUI-DESIGN-LANGUAGE.md
 * flagged this as the tractable one of the two remaining dots: the
 * geometry math is exactly what process_cursor_resize() already does
 * for interactive resize, just driven by a click instead of a drag,
 * and the only genuinely new piece is saving/restoring the pre-
 * maximize geometry, which is what saved_geometry is for. */
static void maximize_toplevel(struct novi_toplevel *toplevel) {
	if (toplevel->maximized) {
		return;
	}
	struct novi_server *server = toplevel->server;
	if (wl_list_empty(&server->outputs)) {
		return;
	}
	struct novi_output *output =
		wl_container_of(server->outputs.next, output, link);
	struct wlr_box layout_box = {0};
	wlr_output_layout_get_box(server->output_layout,
		output->wlr_output, &layout_box);

	struct wlr_box geo_box;
	wlr_xdg_surface_get_geometry(toplevel->xdg_toplevel->base, &geo_box);
	toplevel->saved_geometry.x = (int)toplevel->scene_tree->node.x;
	toplevel->saved_geometry.y = (int)toplevel->scene_tree->node.y;
	toplevel->saved_geometry.width = geo_box.width;
	toplevel->saved_geometry.height = geo_box.height;

	int max_height = output->usable_area.height - DECO_HEIGHT;
	if (max_height < 0) {
		max_height = 0;
	}
	wlr_scene_node_set_position(&toplevel->scene_tree->node,
		layout_box.x + output->usable_area.x,
		layout_box.y + output->usable_area.y + DECO_HEIGHT);
	wlr_xdg_toplevel_set_size(toplevel->xdg_toplevel,
		output->usable_area.width, max_height);
	wlr_xdg_toplevel_set_maximized(toplevel->xdg_toplevel, true);
	toplevel->maximized = true;
}

/* Restores the geometry maximize_toplevel() saved. A no-op if the
 * toplevel was somehow never actually maximized (defensive, not
 * expected -- both call sites (the maximize dot's click handler,
 * xdg_toplevel_request_maximize() below) only ever call this when
 * toplevel->maximized is already true). */
static void unmaximize_toplevel(struct novi_toplevel *toplevel) {
	if (!toplevel->maximized) {
		return;
	}
	wlr_scene_node_set_position(&toplevel->scene_tree->node,
		toplevel->saved_geometry.x, toplevel->saved_geometry.y);
	wlr_xdg_toplevel_set_size(toplevel->xdg_toplevel,
		toplevel->saved_geometry.width, toplevel->saved_geometry.height);
	wlr_xdg_toplevel_set_maximized(toplevel->xdg_toplevel, false);
	toplevel->maximized = false;
}

/* Hides the toplevel by disabling its scene node -- the client's own
 * wl_surface stays mapped throughout (no unmap/re-map round trip, no
 * lost frame callbacks), only its on-screen visibility changes, the
 * same technique sway and other wlroots compositors use for
 * minimize/scratchpad-hide. Was previously a dimmed, non-interactive
 * placeholder (see the minimize_dot creation comment) because there
 * was no taskbar to ever bring a hidden window back from; now that
 * novi-panel has one via wlr-foreign-toplevel-management, hiding is
 * no longer a dead end. */
static void minimize_toplevel(struct novi_toplevel *toplevel) {
	if (toplevel->minimized) {
		return;
	}
	toplevel->minimized = true;
	wlr_scene_node_set_enabled(&toplevel->scene_tree->node, false);
	if (toplevel->foreign_handle != NULL) {
		wlr_foreign_toplevel_handle_v1_set_minimized(toplevel->foreign_handle, true);
	}
	struct novi_server *server = toplevel->server;
	if (server->seat->keyboard_state.focused_surface ==
			toplevel->xdg_toplevel->base->surface) {
		/* Nothing useful stays focused on a surface that's no longer
		 * visible -- hand focus to the next non-minimized window in MRU
		 * order (the same list cycle_toplevel() walks for Alt+Tab), or
		 * clear focus entirely if this was the only one open. */
		wlr_xdg_toplevel_set_activated(toplevel->xdg_toplevel, false);
		struct novi_toplevel *next = NULL;
		struct novi_toplevel *t;
		wl_list_for_each(t, &server->toplevels, link) {
			if (t != toplevel && !t->minimized) {
				next = t;
				break;
			}
		}
		if (next != NULL) {
			focus_toplevel(next, next->xdg_toplevel->base->surface);
		} else {
			wlr_seat_keyboard_notify_clear_focus(server->seat);
		}
	}
}

static void unminimize_toplevel(struct novi_toplevel *toplevel) {
	if (!toplevel->minimized) {
		return;
	}
	toplevel->minimized = false;
	/* Only actually show it if its own workspace is the visible one --
	 * unminimizing (e.g. a taskbar click) doesn't imply "also switch
	 * to wherever this window lives," that's what focus_toplevel()'s
	 * own workspace guard is for (see its comment) when this runs on
	 * the path that leads there. Called with the node left disabled
	 * here is correct, not a bug: a minimized toplevel on a
	 * currently-inactive workspace becoming "not minimized anymore"
	 * should still need a workspace switch to actually see it, exactly
	 * like a real desktop. */
	struct novi_server *server = toplevel->server;
	wlr_scene_node_set_enabled(&toplevel->scene_tree->node,
		toplevel->workspace == server->active_workspace);
	if (toplevel->foreign_handle != NULL) {
		wlr_foreign_toplevel_handle_v1_set_minimized(toplevel->foreign_handle, false);
	}
}

/* RFC 0001 decision 7: Super+[1-9]. Switches which workspace is visible
 * on this (only) output -- see NOVI_WORKSPACE_COUNT's own comment for
 * why this is per-server, not per-output. A toplevel's visibility is
 * always `workspace == active_workspace && !minimized`: these are
 * independent hidden-reasons (a minimized window on the active
 * workspace stays hidden; a non-minimized window on another workspace
 * is also hidden), so both minimize_toplevel()/unminimize_toplevel()
 * above and this function each apply that same formula rather than one
 * flag silently overriding the other. */
static void switch_workspace(struct novi_server *server, int workspace) {
	if (workspace == server->active_workspace) {
		return;
	}
	server->active_workspace = workspace;

	struct wlr_surface *prev_focus = server->seat->keyboard_state.focused_surface;
	struct novi_toplevel *focus_candidate = NULL;
	struct novi_toplevel *t;
	wl_list_for_each(t, &server->toplevels, link) {
		bool visible = t->workspace == workspace && !t->minimized;
		wlr_scene_node_set_enabled(&t->scene_tree->node, visible);
		/* server->toplevels is MRU-ordered (focus_toplevel() moves
		 * whatever it focuses to the front) -- the first visible match
		 * walking front-to-back is exactly "the most recently used
		 * window on this workspace," the same convention
		 * minimize_toplevel()'s own "next" pick and cycle_toplevel()
		 * already use, not a new one invented here. */
		if (visible && focus_candidate == NULL) {
			focus_candidate = t;
		}
	}

	if (focus_candidate != NULL) {
		focus_toplevel(focus_candidate, focus_candidate->xdg_toplevel->base->surface);
		return;
	}
	/* Nothing visible on the new workspace -- explicitly deactivate
	 * whatever was focused before (it's about to be hidden, if it
	 * wasn't already) and clear seat focus, the same cleanup
	 * minimize_toplevel() does when hiding the last visible window. */
	if (prev_focus != NULL) {
		struct wlr_xdg_toplevel *prev_xdg_toplevel =
			wlr_xdg_toplevel_try_from_wlr_surface(prev_focus);
		if (prev_xdg_toplevel != NULL) {
			wlr_xdg_toplevel_set_activated(prev_xdg_toplevel, false);
		}
	}
	wlr_seat_keyboard_notify_clear_focus(server->seat);
}

/* RFC 0001 decision 7: Super+Shift+[1-9]. Moves whichever toplevel
 * currently holds keyboard focus to a different workspace -- a no-op
 * if nothing's focused (e.g. focus is on a layer-shell overlay, or
 * nothing at all) or if it's already on that workspace. Unlike
 * switch_workspace(), this never changes server->active_workspace
 * itself: real i3/sway behavior is "the window leaves with you staying
 * put," not "follow it to where it went." */
static void move_focused_to_workspace(struct novi_server *server, int workspace) {
	struct wlr_surface *focused = server->seat->keyboard_state.focused_surface;
	if (focused == NULL) {
		return;
	}
	struct novi_toplevel *toplevel = NULL;
	struct novi_toplevel *t;
	wl_list_for_each(t, &server->toplevels, link) {
		if (t->xdg_toplevel->base->surface == focused) {
			toplevel = t;
			break;
		}
	}
	if (toplevel == NULL || toplevel->workspace == workspace) {
		return;
	}
	toplevel->workspace = workspace;

	/* It just left the visible workspace -- hide it and hand focus to
	 * whatever's next, the same "find the next visible MRU toplevel or
	 * clear focus" pattern minimize_toplevel() uses when hiding
	 * whatever currently holds focus. */
	wlr_scene_node_set_enabled(&toplevel->scene_tree->node, false);
	wlr_xdg_toplevel_set_activated(toplevel->xdg_toplevel, false);
	struct novi_toplevel *next = NULL;
	wl_list_for_each(t, &server->toplevels, link) {
		if (t != toplevel && !t->minimized && t->workspace == server->active_workspace) {
			next = t;
			break;
		}
	}
	if (next != NULL) {
		focus_toplevel(next, next->xdg_toplevel->base->surface);
	} else {
		wlr_seat_keyboard_notify_clear_focus(server->seat);
	}
}

static void xdg_toplevel_request_maximize(
		struct wl_listener *listener, void *data) {
	/* This event is raised when a client would like to maximize (or
	 * unmaximize -- toplevel->requested.maximized carries which)
	 * itself, typically because the user clicked a client-side
	 * maximize control or used a toolkit keybinding. Both directions
	 * go through the same maximize_toplevel()/unmaximize_toplevel()
	 * pair the decoration's own maximize dot uses, so there's exactly
	 * one place that ever changes a toplevel's maximized state. If the
	 * request arrived before an initial commit, there's no geometry to
	 * save/restore yet -- let the client finish its initial setup
	 * instead (matching the previous behavior for that edge case). */
	struct novi_toplevel *toplevel =
		wl_container_of(listener, toplevel, request_maximize);
	if (!toplevel->xdg_toplevel->base->initialized) {
		return;
	}
	if (toplevel->xdg_toplevel->requested.maximized) {
		maximize_toplevel(toplevel);
	} else {
		unmaximize_toplevel(toplevel);
	}
}

static void xdg_toplevel_request_fullscreen(
		struct wl_listener *listener, void *data) {
	/* Just as with request_maximize, we must send a configure here. */
	struct novi_toplevel *toplevel =
		wl_container_of(listener, toplevel, request_fullscreen);
	if (toplevel->xdg_toplevel->base->initialized) {
		wlr_xdg_surface_schedule_configure(toplevel->xdg_toplevel->base);
	}
}

static void server_new_xdg_toplevel(struct wl_listener *listener, void *data) {
	/* This event is raised when a client creates a new toplevel (application window). */
	struct novi_server *server = wl_container_of(listener, server, new_xdg_toplevel);
	struct wlr_xdg_toplevel *xdg_toplevel = data;

	/* Allocate a novi_toplevel for this surface */
	struct novi_toplevel *toplevel = calloc(1, sizeof(*toplevel));
	toplevel->server = server;
	toplevel->xdg_toplevel = xdg_toplevel;
	/* Parented under layer_tree_toplevels, not the scene root directly:
	 * that tree was created between layer_tree_bottom and layer_tree_top
	 * (see main()), so regular windows always render above background/
	 * bottom layer-shell surfaces and below top/overlay ones (a panel),
	 * regardless of creation order at runtime. */
	toplevel->scene_tree = wlr_scene_xdg_surface_create(
		toplevel->server->layer_tree_toplevels, xdg_toplevel->base);
	toplevel->scene_tree->node.data = toplevel;
	xdg_toplevel->base->data = toplevel->scene_tree;

	/* Server-side decoration: a title bar strip and three dots, all
	 * children of scene_tree, positioned in the negative-y space above
	 * the content (local (0,-DECO_HEIGHT) and up) -- content itself
	 * stays at local (0,0) exactly as before, so move/resize logic
	 * elsewhere (process_cursor_move/resize(), both operate on scene_
	 * tree's own node position) needs no changes; the decoration just
	 * rides along as sibling children whenever the tree moves. All
	 * placeholder-positioned at x=0 here since the content's real width
	 * (needed to right-align them) isn't known until its first commit
	 * (see xdg_toplevel_commit(), which the client's own initial_commit
	 * -> ack_configure -> real commit sequence guarantees fires before
	 * this is visible). Creation order right-to-left (close, maximize,
	 * minimize) matches their intended screen order, though it isn't
	 * load-bearing -- xdg_toplevel_commit() repositions all three by
	 * direct pointer, not by sibling order. */
	toplevel->titlebar = wlr_scene_rect_create(
		toplevel->scene_tree, 0, DECO_HEIGHT, DECO_BG_COLOR);
	wlr_scene_node_set_position(&toplevel->titlebar->node, 0, -DECO_HEIGHT);
	toplevel->close_dot = wlr_scene_rect_create(
		toplevel->scene_tree, DECO_DOT_SIZE, DECO_DOT_SIZE, DECO_DOT_COLOR);
	toplevel->maximize_dot = wlr_scene_rect_create(
		toplevel->scene_tree, DECO_DOT_SIZE, DECO_DOT_SIZE, DECO_DOT_COLOR);
	/* Real now, not dimmed -- novi-panel's taskbar (wlr-foreign-toplevel-
	 * management) is the restore path GUI-DESIGN-LANGUAGE.md's original
	 * dimmed-placeholder reasoning was waiting on. */
	toplevel->minimize_dot = wlr_scene_rect_create(
		toplevel->scene_tree, DECO_DOT_SIZE, DECO_DOT_SIZE, DECO_DOT_COLOR);
	int dot_y = -DECO_HEIGHT + (DECO_HEIGHT - DECO_DOT_SIZE) / 2;
	wlr_scene_node_set_position(&toplevel->close_dot->node, 0, dot_y);
	wlr_scene_node_set_position(&toplevel->maximize_dot->node, 0, dot_y);
	wlr_scene_node_set_position(&toplevel->minimize_dot->node, 0, dot_y);

	/* Initial placement: land the window in the output's usable area
	 * (below the panel's exclusive zone), not at the scene tree's
	 * default (0,0) -- which is directly under the top bar, so every
	 * new window used to open with its top ~32px hidden behind it.
	 * Same "single output for now" simplification server_new_layer_
	 * surface() already uses (and explains) for picking an output when
	 * a client doesn't specify one; a real multi-output compositor
	 * would place new windows on the focused/cursor output instead.
	 * This only sets an initial position, once, at creation -- it's not
	 * re-applied on every map, so a window the user has since moved
	 * doesn't get snapped back if it's ever unmapped and remapped.
	 *
	 * The extra "+ DECO_HEIGHT" is new: content now sits DECO_HEIGHT
	 * lower than the usable area's own top edge, leaving exactly enough
	 * room above it (in scene_tree's negative-y space) for the title
	 * bar to occupy without overlapping the panel above it. Before
	 * decorations existed, content started flush against the panel with
	 * zero headroom -- there was nowhere for a title bar to go without
	 * this shift. */
	if (!wl_list_empty(&server->outputs)) {
		struct novi_output *output =
			wl_container_of(server->outputs.next, output, link);
		struct wlr_box layout_box = {0};
		wlr_output_layout_get_box(server->output_layout,
			output->wlr_output, &layout_box);

		/* Suggest a size, and centre the window on it.
		 *
		 * Nothing used to ask for one, so a new window got whatever
		 * the client picked on its own -- foot's built-in default is
		 * around 700x565 -- and landed hard against the top-left
		 * corner of the usable area. On a 1280x800 screen that is a
		 * small box in the corner with two thirds of the desktop empty
		 * beside it, which reads as broken rather than as a choice.
		 *
		 * Setting the size here, before the client's first commit, is
		 * the point in the xdg-shell handshake where a compositor is
		 * meant to express a preference: it goes out in the initial
		 * configure and the client acks it. A client that insists on
		 * its own size still wins, and it will simply be off-centre by
		 * the difference -- which is why the position is computed from
		 * the size we asked for rather than assumed to be exact. */
		int want_w = 0, want_h = 0;
		int x = layout_box.x + output->usable_area.x;
		int y = layout_box.y + output->usable_area.y + DECO_HEIGHT;
		if (default_toplevel_size(server, &want_w, &want_h)) {
			x += (output->usable_area.width - want_w) / 2;
			y += (output->usable_area.height - DECO_HEIGHT - want_h) / 2;
		}
		wlr_scene_node_set_position(&toplevel->scene_tree->node, x, y);
	}

	/* Listen to the various events it can emit */
	toplevel->map.notify = xdg_toplevel_map;
	wl_signal_add(&xdg_toplevel->base->surface->events.map, &toplevel->map);
	toplevel->unmap.notify = xdg_toplevel_unmap;
	wl_signal_add(&xdg_toplevel->base->surface->events.unmap, &toplevel->unmap);
	toplevel->commit.notify = xdg_toplevel_commit;
	wl_signal_add(&xdg_toplevel->base->surface->events.commit, &toplevel->commit);

	toplevel->destroy.notify = xdg_toplevel_destroy;
	wl_signal_add(&xdg_toplevel->events.destroy, &toplevel->destroy);

	/* cotd */
	toplevel->request_move.notify = xdg_toplevel_request_move;
	wl_signal_add(&xdg_toplevel->events.request_move, &toplevel->request_move);
	toplevel->request_resize.notify = xdg_toplevel_request_resize;
	wl_signal_add(&xdg_toplevel->events.request_resize, &toplevel->request_resize);
	toplevel->request_maximize.notify = xdg_toplevel_request_maximize;
	wl_signal_add(&xdg_toplevel->events.request_maximize, &toplevel->request_maximize);
	toplevel->request_fullscreen.notify = xdg_toplevel_request_fullscreen;
	wl_signal_add(&xdg_toplevel->events.request_fullscreen, &toplevel->request_fullscreen);
	toplevel->set_title.notify = xdg_toplevel_set_title;
	wl_signal_add(&xdg_toplevel->events.set_title, &toplevel->set_title);
	toplevel->set_app_id.notify = xdg_toplevel_set_app_id;
	wl_signal_add(&xdg_toplevel->events.set_app_id, &toplevel->set_app_id);
}

static void server_new_xdg_decoration(struct wl_listener *listener, void *data) {
	/* Fires when a client explicitly asks (via zxdg_decoration_manager_v1
	 * .get_toplevel_decoration) whether it should draw its own title bar
	 * or let the compositor do it. novi-shell always draws one anyway
	 * (server_new_xdg_toplevel() creates the title bar/close dot
	 * unconditionally, not gated on this) -- this listener's only job is
	 * answering "server-side" so an asking client doesn't ALSO draw its
	 * own and end up with two title bars stacked. foot does ask --
	 * confirmed live, its own log prints "using SSD decorations" once
	 * this answers -- so this path is genuinely exercised today. */
	(void)listener;
	struct wlr_xdg_toplevel_decoration_v1 *decoration = data;
	wlr_xdg_toplevel_decoration_v1_set_mode(decoration,
		WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
}

static void xdg_popup_commit(struct wl_listener *listener, void *data) {
	/* Called when a new surface state is committed. */
	struct novi_popup *popup = wl_container_of(listener, popup, commit);

	if (popup->xdg_popup->base->initial_commit) {
		/* When an xdg_surface performs an initial commit, the compositor must
		 * reply with a configure so the client can map the surface.
		 * novi-shell sends an empty configure. A more sophisticated compositor
		 * might change an xdg_popup's geometry to ensure it's not positioned
		 * off-screen, for example. */
		wlr_xdg_surface_schedule_configure(popup->xdg_popup->base);
	}
}

static void xdg_popup_destroy(struct wl_listener *listener, void *data) {
	/* Called when the xdg_popup is destroyed. */
	struct novi_popup *popup = wl_container_of(listener, popup, destroy);

	wl_list_remove(&popup->commit.link);
	wl_list_remove(&popup->destroy.link);

	free(popup);
}

static void server_new_xdg_popup(struct wl_listener *listener, void *data) {
	/* This event is raised when a client creates a new popup. */
	struct wlr_xdg_popup *xdg_popup = data;

	struct novi_popup *popup = calloc(1, sizeof(*popup));
	popup->xdg_popup = xdg_popup;

	/* We must add xdg popups to the scene graph so they get rendered. The
	 * wlroots scene graph provides a helper for this, but to use it we must
	 * provide the proper parent scene node of the xdg popup. To enable this,
	 * we always set the user data field of xdg_surfaces to the corresponding
	 * scene node. */
	struct wlr_xdg_surface *parent = wlr_xdg_surface_try_from_wlr_surface(xdg_popup->parent);
	assert(parent != NULL);
	struct wlr_scene_tree *parent_tree = parent->data;
	xdg_popup->base->data = wlr_scene_xdg_surface_create(parent_tree, xdg_popup->base);

	popup->commit.notify = xdg_popup_commit;
	wl_signal_add(&xdg_popup->base->surface->events.commit, &popup->commit);

	popup->destroy.notify = xdg_popup_destroy;
	wl_signal_add(&xdg_popup->events.destroy, &popup->destroy);
}

int main(int argc, char *argv[]) {
	wlr_log_init(WLR_DEBUG, NULL);
	char *startup_cmd = NULL;

	int c;
	while ((c = getopt(argc, argv, "s:h")) != -1) {
		switch (c) {
		case 's':
			startup_cmd = optarg;
			break;
		default:
			printf("Usage: %s [-s startup command]\n", argv[0]);
			return 0;
		}
	}
	if (optind < argc) {
		printf("Usage: %s [-s startup command]\n", argv[0]);
		return 0;
	}

	struct novi_server server = {0};
	/* Matches every toplevel's own default (xdg_toplevel_map() sets
	 * workspace = server->active_workspace at map time) -- 1, not the
	 * calloc'd 0, since Super+[1-9] only ever produces 1-9. Leaving
	 * this at 0 would make every window mapped before the first
	 * workspace switch belong to a workspace number no keybinding can
	 * ever reach again once one *is* pressed. */
	server.active_workspace = 1;
	/* The Wayland display is managed by libwayland. It handles accepting
	 * clients from the Unix socket, manging Wayland globals, and so on. */
	server.wl_display = wl_display_create();
	/* The backend is a wlroots feature which abstracts the underlying input and
	 * output hardware. The autocreate option will choose the most suitable
	 * backend based on the current environment, such as opening an X11 window
	 * if an X11 server is running. */
	server.backend = wlr_backend_autocreate(wl_display_get_event_loop(server.wl_display), NULL);
	if (server.backend == NULL) {
		wlr_log(WLR_ERROR, "failed to create wlr_backend");
		return 1;
	}

	/* Autocreates a renderer, either Pixman, GLES2 or Vulkan for us. The user
	 * can also specify a renderer using the WLR_RENDERER env var.
	 * The renderer is responsible for defining the various pixel formats it
	 * supports for shared memory, this configures that for clients. */
	server.renderer = wlr_renderer_autocreate(server.backend);
	if (server.renderer == NULL) {
		wlr_log(WLR_ERROR, "failed to create wlr_renderer");
		return 1;
	}

	wlr_renderer_init_wl_display(server.renderer, server.wl_display);

	/* Autocreates an allocator for us.
	 * The allocator is the bridge between the renderer and the backend. It
	 * handles the buffer creation, allowing wlroots to render onto the
	 * screen */
	server.allocator = wlr_allocator_autocreate(server.backend,
		server.renderer);
	if (server.allocator == NULL) {
		wlr_log(WLR_ERROR, "failed to create wlr_allocator");
		return 1;
	}

	/* This creates some hands-off wlroots interfaces. The compositor is
	 * necessary for clients to allocate surfaces, the subcompositor allows to
	 * assign the role of subsurfaces to surfaces and the data device manager
	 * handles the clipboard. Each of these wlroots interfaces has room for you
	 * to dig your fingers in and play with their behavior if you want. Note that
	 * the clients cannot set the selection directly without compositor approval,
	 * see the handling of the request_set_selection event below.*/
	wlr_compositor_create(server.wl_display, 5, server.renderer);
	wlr_subcompositor_create(server.wl_display);
	wlr_data_device_manager_create(server.wl_display);
	/* wlr-foreign-toplevel-management-unstable-v1: lets novi-panel's
	 * taskbar (a separate layer-shell client, not compositor code, same
	 * split as everything else in this UI) list open windows and
	 * request activate/minimize/maximize/close on them. */
	server.foreign_toplevel_manager =
		wlr_foreign_toplevel_manager_v1_create(server.wl_display);
	/* wlr-screencopy-unstable-v1: lets novi-screenshot/ (PrintScreen,
	 * RFC 0001 decision 7) capture an output's contents. wlroots
	 * implements the whole server side; this is the one line needed to
	 * turn it on, same as the two manager creates just above. */
	wlr_screencopy_manager_v1_create(server.wl_display);

	/* Creates an output layout, which a wlroots utility for working with an
	 * arrangement of screens in a physical layout. */
	server.output_layout = wlr_output_layout_create(server.wl_display);

	/* Configure a listener to be notified when new outputs are available on the
	 * backend. */
	wl_list_init(&server.outputs);
	server.new_output.notify = server_new_output;
	wl_signal_add(&server.backend->events.new_output, &server.new_output);

	/* Create a scene graph. This is a wlroots abstraction that handles all
	 * rendering and damage tracking. All the compositor author needs to do
	 * is add things that should be rendered to the scene graph at the proper
	 * positions and then call wlr_scene_output_commit() to render a frame if
	 * necessary.
	 */
	server.scene = wlr_scene_create();
	server.scene_layout = wlr_scene_attach_output_layout(server.scene, server.output_layout);

	/* Five persistent scene-tree layers, created in this fixed order so
	 * z-order across them is guaranteed by scene_tree child ordering
	 * alone (see the novi_server struct comment): background is always
	 * bottom-most, overlay always top-most, regular windows always
	 * sandwiched between "bottom" and "top" layer-shell surfaces. */
	server.layer_tree_background = wlr_scene_tree_create(&server.scene->tree);
	server.layer_tree_bottom = wlr_scene_tree_create(&server.scene->tree);
	server.layer_tree_toplevels = wlr_scene_tree_create(&server.scene->tree);
	server.layer_tree_top = wlr_scene_tree_create(&server.scene->tree);
	server.layer_tree_overlay = wlr_scene_tree_create(&server.scene->tree);

	/* Set up xdg-shell version 3. The xdg-shell is a Wayland protocol which is
	 * used for application windows. For more detail on shells, refer to
	 * https://drewdevault.com/2018/07/29/Wayland-shells.html.
	 */
	wl_list_init(&server.toplevels);
	server.xdg_shell = wlr_xdg_shell_create(server.wl_display, 3);
	server.new_xdg_toplevel.notify = server_new_xdg_toplevel;
	wl_signal_add(&server.xdg_shell->events.new_toplevel, &server.new_xdg_toplevel);
	server.new_xdg_popup.notify = server_new_xdg_popup;
	wl_signal_add(&server.xdg_shell->events.new_popup, &server.new_xdg_popup);

	/* xdg-decoration (GUI-DESIGN-LANGUAGE.md §6): lets an asking client
	 * learn this compositor always wants server-side decorations. See
	 * server_new_xdg_decoration()'s own comment -- the title bar/close
	 * dot themselves are drawn unconditionally in server_new_xdg_
	 * toplevel(), not gated on this negotiation. */
	server.xdg_decoration_manager =
		wlr_xdg_decoration_manager_v1_create(server.wl_display);
	server.new_xdg_decoration.notify = server_new_xdg_decoration;
	wl_signal_add(&server.xdg_decoration_manager->events.new_toplevel_decoration,
		&server.new_xdg_decoration);

	/* wlr-layer-shell-unstable-v1 (RFC 0001 decision 5): lets separate
	 * client processes -- the panel, launcher, and other novi-shell UI
	 * pieces, none of which exist yet -- anchor surfaces to screen
	 * edges. Version 4 matches the protocol version this repo vendors
	 * (novi-shell/protocol/wlr-layer-shell-unstable-v1.xml) and is the
	 * latest wlroots 0.18 implements. */
	server.layer_shell = wlr_layer_shell_v1_create(server.wl_display, 4);
	server.new_layer_surface.notify = server_new_layer_surface;
	wl_signal_add(&server.layer_shell->events.new_surface, &server.new_layer_surface);

	/*
	 * Creates a cursor, which is a wlroots utility for tracking the cursor
	 * image shown on screen.
	 */
	server.cursor = wlr_cursor_create();
	wlr_cursor_attach_output_layout(server.cursor, server.output_layout);

	/* Creates an xcursor manager, another wlroots utility which loads up
	 * Xcursor themes to source cursor images from and makes sure that cursor
	 * images are available at all scale factors on the screen (necessary for
	 * HiDPI support). */
	server.cursor_mgr = wlr_xcursor_manager_create(NULL, 24);

	/*
	 * wlr_cursor *only* displays an image on screen. It does not move around
	 * when the pointer moves. However, we can attach input devices to it, and
	 * it will generate aggregate events for all of them. In these events, we
	 * can choose how we want to process them, forwarding them to clients and
	 * moving the cursor around. More detail on this process is described in
	 * https://drewdevault.com/2018/07/17/Input-handling-in-wlroots.html.
	 *
	 * And more comments are sprinkled throughout the notify functions above.
	 */
	server.cursor_mode = NOVI_CURSOR_PASSTHROUGH;
	server.cursor_motion.notify = server_cursor_motion;
	wl_signal_add(&server.cursor->events.motion, &server.cursor_motion);
	server.cursor_motion_absolute.notify = server_cursor_motion_absolute;
	wl_signal_add(&server.cursor->events.motion_absolute,
			&server.cursor_motion_absolute);
	server.cursor_button.notify = server_cursor_button;
	wl_signal_add(&server.cursor->events.button, &server.cursor_button);
	server.cursor_axis.notify = server_cursor_axis;
	wl_signal_add(&server.cursor->events.axis, &server.cursor_axis);
	server.cursor_frame.notify = server_cursor_frame;
	wl_signal_add(&server.cursor->events.frame, &server.cursor_frame);

	/*
	 * Configures a seat, which is a single "seat" at which a user sits and
	 * operates the computer. This conceptually includes up to one keyboard,
	 * pointer, touch, and drawing tablet device. We also rig up a listener to
	 * let us know when new input devices are available on the backend.
	 */
	wl_list_init(&server.keyboards);
	server.new_input.notify = server_new_input;
	wl_signal_add(&server.backend->events.new_input, &server.new_input);
	server.seat = wlr_seat_create(server.wl_display, "seat0");
	server.request_cursor.notify = seat_request_cursor;
	wl_signal_add(&server.seat->events.request_set_cursor,
			&server.request_cursor);
	server.request_set_selection.notify = seat_request_set_selection;
	wl_signal_add(&server.seat->events.request_set_selection,
			&server.request_set_selection);
	/* request_set_selection is a client ASKING; set_selection is the
	 * selection having actually changed, including to nothing when its
	 * owner exits. Clipboard persistence needs the second. */
	server.set_selection.notify = seat_set_selection;
	wl_signal_add(&server.seat->events.set_selection, &server.set_selection);

	/* Add a Unix socket to the Wayland display. */
	const char *socket = wl_display_add_socket_auto(server.wl_display);
	if (!socket) {
		wlr_backend_destroy(server.backend);
		return 1;
	}

	/* Start the backend. This will enumerate outputs and inputs, become the DRM
	 * master, etc */
	if (!wlr_backend_start(server.backend)) {
		wlr_backend_destroy(server.backend);
		wl_display_destroy(server.wl_display);
		return 1;
	}

	/* Set the WAYLAND_DISPLAY environment variable to our socket and run the
	 * startup command if requested. */
	setenv("WAYLAND_DISPLAY", socket, true);
	if (startup_cmd) {
		if (fork() == 0) {
			execl("/bin/sh", "/bin/sh", "-c", startup_cmd, (void *)NULL);
		}
	}
	spawn(getenv("NOVI_PANEL") ? getenv("NOVI_PANEL") : NOVI_DEFAULT_PANEL);
	/* Run the Wayland event loop. This does not return until you exit the
	 * compositor. Starting the backend rigged up all of the necessary event
	 * loop configuration to listen to libinput events, DRM events, generate
	 * frame events at the refresh rate, and so on. */
	wlr_log(WLR_INFO, "novi-shell running on WAYLAND_DISPLAY=%s", socket);
	wl_display_run(server.wl_display);

	/* Once wl_display_run returns, we destroy all clients then shut down the
	 * server. */
	wl_display_destroy_clients(server.wl_display);
	wlr_scene_node_destroy(&server.scene->tree.node);
	wlr_xcursor_manager_destroy(server.cursor_mgr);
	wlr_cursor_destroy(server.cursor);
	wlr_allocator_destroy(server.allocator);
	wlr_renderer_destroy(server.renderer);
	wlr_backend_destroy(server.backend);
	wl_display_destroy(server.wl_display);
	return 0;
}
