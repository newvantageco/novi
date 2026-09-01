# Widget & Notification Architecture — Design Proposal

- **Status:** Proposal (design doc, not an RFC — layer placement reuses
  wlr-layer-shell-v1 as-is; the notification *delivery* channel is new
  but is a plain local Unix socket, not a new Wayland protocol or a new
  system service in the systemd/D-Bus sense)
- **Scope:** floating "widget" cards (e.g. the system-monitor mockup)
  and transient notification toasts (e.g. "pkg — updates available").
- **Grounded in:** `novi-shell/main.c`, `novi-panel/main.c`,
  `novi-launcher/main.c`, `docs/rfcs/0001-desktop-wayland-compositor.md`,
  `docs/PLATFORM-ROADMAP.md` §5 and §12.

## What already exists to build on

- `novi-shell` implements wlr-layer-shell-v1 fully server-side: five
  persistent, fixed-order scene-tree layers (background, bottom,
  toplevels, top, overlay — `server_new_output`/`arrange_layers` in
  `novi-shell/main.c`), correct anchor/margin/exclusive-zone handling
  via wlroots' own scene helper, and keyboard-focus grant on map for
  surfaces requesting `KEYBOARD_INTERACTIVITY_EXCLUSIVE`
  (`layer_surface_map`).
- `novi-launcher` and `novi-panel` are the working reference
  implementations of "separate process, layer-shell client, own
  event loop, own shm rendering" — `novi-launcher` for a short-lived,
  keyboard-exclusive **overlay**-layer client; `novi-panel` for a
  persistent, non-interactive, **top**-layer client with a positive
  exclusive zone and a `timerfd`-driven periodic redraw loop.
- Both already hit and fixed the same two sharp edges any new client
  will hit again: (1) `wl_display_flush()` must happen before `close()`
  on the shm fd, or the fd can be invalid by the time it's actually
  written to the socket (hit for real in `novi-panel`, whose hand-rolled
  poll loop exposed the race `novi-launcher`'s dispatch-loop timing
  happened to mask); (2) neither client tracks `wl_buffer` release, so
  each leaks one buffer per redraw — noted in both as "acceptable for a
  short-lived/low-frequency client, not for a compositor-lifetime
  daemon." Any **persistent** widget/notification client (see below)
  inherits that second warning as a real requirement, not a nice-to-have.

## Do widgets/toasts need a new Wayland protocol?

**No — wlr-layer-shell-v1 alone is sufficient for placement and
rendering of both.** The overlay layer plus anchor bits plus margin
already gives exact corner-anchored floating placement (the same
mechanism `novi-launcher` uses to center itself, just with different
anchor/margin values for a top-right corner card); `arrange_layers()`
needs no changes. What's actually missing is not a rendering protocol —
it's a way for an arbitrary, unrelated process (`pkg`, a script, a
future service) to **tell** the desktop a toast should appear. That's
addressed separately below.

### Widget cards: layer-shell client, not an xdg-shell toplevel

The system-monitor mockup draws its own small title bar (3 dots, "same
window-chrome style as a real terminal window") — but it should **not**
actually be an xdg-shell toplevel. Toplevels go through
`novi-shell`'s window-management machinery: `cycle_toplevel()` walks
`server->toplevels` for Alt+Tab, `close_focused_toplevel()` treats
Super+Q as "close whatever's focused," `begin_interactive()` supports
click-drag move/resize. None of that is wanted for a system-monitor
card — it shouldn't be Alt-Tab-able, shouldn't be accidentally closed by
Super+Q, and should float above ordinary windows regardless of focus.
Layer-shell's **top** or **overlay** layer already gives exactly that
"always above toplevels, outside the window-management model" property
for free, via the fixed scene-tree z-order `novi-shell` already
maintains (`layer_tree_toplevels` is sandwiched between
`layer_tree_bottom` and `layer_tree_top` unconditionally).

So: the "title bar with 3 dots" is not real window-manager decoration —
it's just pixels the widget draws itself with `draw_rect()`/`draw_text()`
(and, per `ICON-PIPELINE.md`, `draw_icon()`), the same way `novi-launcher`
already draws its own border/background. A `novi-monitor-widget` binary
is a fourth layer-shell client, same shape as `novi-panel`: persistent,
`timerfd`-driven periodic redraw (matching the mockup's "live" status),
`keyboard_interactivity = NONE` (nothing about it needs typed input),
`exclusive_zone = -1` or `0` (it floats over content, unlike the panel,
it must not reserve screen space and push other windows around).

### Toasts: one persistent client owns a toast queue, not one surface per toast

A toast is transient (appears, times out, disappears) and there can be
more than one queued at once. Two shapes were considered:

- **One layer-shell surface per toast**, created/destroyed per
  notification. Rejected: each surface needs its own
  map/unmap/configure/commit lifecycle managed against `novi-shell`'s
  arrange logic, multiplied by however many toasts are visible
  simultaneously — real complexity for no benefit, since toasts stack
  in a fixed corner and don't need independent window identity.
- **One persistent client (`novi-notifyd`), one layer-shell surface,
  sized to hold up to N stacked cards, redrawn whenever the queue
  changes or a timer expires.** Recommended. This is a direct extension
  of `novi-panel`'s existing pattern (persistent client, `timerfd`,
  redraw-on-change) rather than a new mechanism — the surface just
  draws 0..N cards top-to-bottom instead of one clock string.

`novi-notifyd` is proposed as its **own** binary, not folded into
`novi-shell`, for the same separation of concerns RFC 0001 decision 5
already states: "novi-shell owns no UI of its own" — the compositor
spawns it at startup the same way it already spawns `novi-panel`
(`NOVI_DEFAULT_PANEL`/`spawn()` in `main()`), via a new
`NOVI_DEFAULT_NOTIFYD` env-overridable default.

## Delivery: how does an arbitrary process post a notification?

This is the actual new piece — everything above is existing protocol
reused as-is.

**Rejected: XDG Desktop Notifications (`org.freedesktop.Notifications`
over D-Bus).** This is the real, standard desktop-notification spec —
what a stock GNOME/KDE app already expects to call — but it requires a
running D-Bus message bus (`dbus-daemon`/`dbus-broker`) as a new system
service, plus a D-Bus client library (`libdbus` or `sd-bus`-alike)
linked into every process that wants to notify. Both are exactly the
class of dependency this repo has stated it avoids: no systemd anywhere
(`CLAUDE.md`), and D-Bus's session/activation model is deeply
systemd-adjacent even run standalone. Not proposed.

**Proposed: a small local Unix-domain-socket protocol, `novi-notifyd`
listens on it directly.**

- Socket path: `$XDG_RUNTIME_DIR/novi-notify.sock` — reusing the same
  `XDG_RUNTIME_DIR` requirement `novi-shell` already needed for its own
  Wayland socket and POSIX shm (`PLATFORM-ROADMAP.md` §5), not a new
  environment convention.
- Wire format: minimal and line-oriented, e.g. one framed message per
  notification —
  `title\x1Fsubtitle\x1Ficon-id\x1Ftimeout-ms\n`
  (`\x1F` unit separator between fields, matching the kind of
  dependency-free plain-text protocol this repo already favors — `pkg`
  itself is POSIX shell driving `tar`/`grep`/`awk`, not a binary
  protocol). `icon-id` names an entry from `shared/icons/icons.h`
  (`ICON-PIPELINE.md`); an unrecognized id just renders no icon rather
  than erroring.
- Any process can speak this with **zero new library dependency** — a
  one-line `printf ... | nc -U "$XDG_RUNTIME_DIR/novi-notify.sock"`-style
  shell invocation works, or ship a trivial static `novi-notify-send`
  CLI helper (the same relationship `notify-send` has to
  `org.freedesktop.Notifications` on a normal desktop, just talking this
  socket instead of D-Bus). `pkg` itself is the natural first caller —
  a post-transaction hook shelling out to `novi-notify-send "pkg —
  updates available" "3 packages · run pkg upgrade" --icon pkg`.
- `novi-notifyd` accepts connections, parses one message per connection
  (or newline-delimited messages per persistent connection — either is
  fine, this is a design detail for implementation time, not an
  architectural fork), appends to its in-memory toast queue, and
  triggers a redraw. Auto-dismiss reuses the same `timerfd` pattern
  `novi-panel` already has, just per-queue-entry instead of once a
  second.

This resolves the prompt's actual question directly: **layer-shell is
sufficient for the rendering half; it is not a delivery mechanism at
all, and doesn't need to be — the delivery half is a separate, ordinary
local socket, orthogonal to Wayland, not a Wayland protocol extension
and not D-Bus.**

## Click routing is a hard prerequisite this doc is not designing around

Per the task brief and confirmed by reading `novi-shell/main.c`:
`desktop_toplevel_at()` walks the scene graph via `wlr_scene_node_at()`
(which does find nodes in *any* layer, layer-shell included) and
correctly forwards pointer **motion**/**enter** events to whatever
surface is actually under the cursor (`process_cursor_motion()` uses
the returned `surface` directly, which is protocol-correct regardless
of layer). But `server_cursor_button()` calls `focus_toplevel(toplevel,
surface)` on button press, and that function's `toplevel` parameter is
typed and dereferenced as `struct novi_toplevel *`
(`toplevel->server`, `toplevel->scene_tree`, `toplevel->xdg_toplevel`) —
`desktop_toplevel_at()` gets that pointer from
`tree->node.data`, which for a layer-shell surface's tree is actually a
`struct novi_layer_surface *` (set in `server_new_layer_surface()`:
`surface->scene_layer_surface->tree->node.data = surface`). If the
pointer is over a layer-shell surface at click time today, that's a
type-confused read, not a supported code path — there is currently no
real "click on a layer-shell surface" support, only an accidental
partial one for hover/motion.

**This doc does not design around that gap being solved.** Concretely:

- Neither the widget nor toasts get click interactivity (dismiss, "run
  `pkg upgrade`" action button, etc.) in v1. `keyboard_interactivity`
  stays `NONE` on both, matching `novi-panel` — nothing about clicking
  is wired up regardless.
- The socket protocol above reserves room for a future `action` field
  (e.g. a command string to run on click) but that field is inert until
  click routing lands — no code should be written that assumes it works.
- **Click/pointer routing to layer-shell surfaces landing first** is
  the explicit, named prerequisite for any interactive widget or
  actionable toast, matching what `PLATFORM-ROADMAP.md` §5 already
  tracks as open work ("click/pointer input isn't routed to layer-shell
  surfaces yet, so the panel isn't interactive"). This doc treats that
  as out of scope, not as solved.

## System-monitor widget: where its data actually comes from

Per RFC 0001 decision 6 / `PLATFORM-ROADMAP.md`'s "GUI is a layer over
the CLI, never a replacement" principle, the widget should query exactly
what a terminal user would, not reimplement s6-rc's state tracking:

- **Service list + up/down status**: `s6-rc -a list` enumerates the
  service database; per-service live status is what `s6-svstat
  <servicedir>` already reports (s6-rc-managed services are still
  ordinary s6-supervised service directories underneath — s6-rc is a
  thin dependency/orchestration layer on top, not a replacement
  supervisor). Two implementation options, both legitimate:
  - Shell out to `s6-svstat` (its human-readable text output is stable
    across s6 versions and simplest to parse; matches "the widget is
    running `watch s6-svstat ...`, just rendered as a card").
  - Read each service's `supervise/status` file directly (a small
    fixed-size binary struct: TAI64N timestamp + pid + flags,
    documented by skalibs) if avoiding a subprocess spawn per refresh
    matters — more brittle against internal format changes across s6
    versions, so only worth it if `s6-svstat`'s spawn overhead is
    actually measured as a problem.
  Either way, this logic lives **in the widget's own process**
  (`novi-monitor-widget`, another `timerfd`-driven periodic-redraw
  client, same cadence pattern as `novi-panel`'s once-a-second clock) —
  not inside `novi-shell`, and not a new always-running monitoring
  daemon polling in the background. It only does work while the widget
  is actually visible.
- **Uptime**: derived from the same `s6-svstat`/`supervise/status`
  "up since" timestamp — the widget just formats elapsed time, it
  doesn't track it independently.
- **Kernel version**: `uname -r` (or reading `/proc/version`) — trivial,
  no s6 involvement, mentioned for completeness.

## Out of scope, flagged so it isn't left dangling

The mockup's expandable "security tools" section in the app-grid is
launcher-internal UI state (an accordion/disclosure toggle over
`novi-launcher`'s own app list) — it is not a widget, not a
notification, and needs no new protocol or IPC; it belongs in a future
`novi-launcher` app-search/registry design (already tracked as open
work in `PLATFORM-ROADMAP.md` §5, blocked on §2's package model), not
this doc.

## Summary of new pieces

| Piece | What it is | New dependency? |
|---|---|---|
| Widget placement/rendering | wlr-layer-shell-v1, top/overlay layer | None — protocol already implemented |
| `novi-monitor-widget` | New layer-shell client binary, `timerfd`-redraw | None — same shape as `novi-panel` |
| `novi-notifyd` | New layer-shell client binary, owns toast queue + socket | None — same shape as `novi-panel` |
| Notification delivery | New Unix-socket text protocol, `novi-notifyd`-owned | New, but zero-library (plain socket I/O) |
| `novi-notify-send` | Small optional CLI helper for callers like `pkg` | None |
| Click/action support | **Not built** — blocked on layer-shell click routing | N/A (explicit prerequisite, not solved here) |
