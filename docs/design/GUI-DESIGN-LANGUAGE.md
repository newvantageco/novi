# Novi GUI Design Language

- **Status:** Adopted reference for `novi-shell`, `novi-panel`,
  `novi-launcher`, and any future GUI component (file manager, settings
  app, notification daemon, etc.).
- **Scope:** Visual design tokens (color, type, spacing, elevation,
  iconography) and component patterns. Not an RFC — it doesn't change
  architecture (`docs/rfcs/0001-desktop-wayland-compositor.md` already
  locked that in), it specifies what gets drawn inside it.
- **Grounding:** Every recommendation below was checked against what
  `novi-shell/main.c`, `novi-panel/main.c`, `novi-launcher/main.c`,
  `build/06-wayland.sh`, and `build/09-foot.sh` actually build and link
  today (September 2026), not against what a generic desktop toolkit
  would let you assume. Section 8 lists exactly where today's code
  falls short of this spec.

**Hard constraint carried over from `build/06-wayland.sh` and
`docs/rfcs/0001-desktop-wayland-compositor.md`:** this stack is
deliberately Mesa-free (`-Drenderers=[]` — only wlroots' mandatory
`pixman` software renderer is built; no GLES2, no Vulkan) and
deliberately toolkit-free (no Cairo, no Skia, no GTK/Qt). Nothing in
this document proposes pulling in any of those. Every technique here
has to be achievable with `pixman` (already a build dependency of
wlroots) plus `fcft`/`freetype`/`fontconfig` (already build
dependencies of `foot`, see `build/09-foot.sh`) — libraries this repo
has already decided to have, not new ones.

---

## 1. Color Palette

Dark, near-black base with a single accent hue used sparingly. Values
are XRGB8888/ARGB8888-ready hex (`0xAARRGGBB` when alpha matters — the
renderer already speaks this format, see `novi-panel/main.c`'s
`BG_COLOR 0xff181820u`).

### Background layers

Three flat layers, each a fixed step lighter than the one below, so
elevation reads from color alone even before any shadow is drawn:

| Token | Hex | Used for |
|---|---|---|
| `bg-base` | `#0A0A0F` | Desktop background / anything behind everything else |
| `bg-panel` | `#15161D` | Top bar (`novi-panel`), non-floating chrome |
| `bg-card` | `#1B1C26` | Floating cards, the launcher overlay, notification toasts, window content chrome |
| `bg-card-raised` | `#232430` | A card-on-a-card, e.g. a hovered row inside a card, an input field's own background |

`bg-base` is intentionally not pure `#000000` — a true black next to a
teal accent reads harsher and crushes shadow contrast to nothing; a
hair of blue keeps it feeling like glass, not a void.

### Teal accent

Mockup's `#2dd4bf` is exactly Tailwind's `teal-400` — good default,
reuse it rather than inventing a near-duplicate:

| Token | Hex | Used for |
|---|---|---|
| `accent` | `#2DD4BF` | Active/interactive elements: active workspace dot, focused input caret/border, selected launcher grid item, primary button fill |
| `accent-hover` | `#5EEAD4` | Hover state on anything using `accent` |
| `accent-active` | `#14B8A6` | Pressed/mouse-down state (one step darker, not lighter — presses should feel like they *sank in*) |
| `accent-disabled` | `#2F5350` | A flat, desaturated stand-in for `accent` at ~35% opacity over `bg-card`, for contexts where true alpha blending isn't wired up yet (see §8) |
| `accent-subtle-bg` | `#17302C` (or `rgba(45,212,191,0.12)` once alpha compositing exists) | Background wash behind a selected list row / active nav item — never use full-strength `accent` as a large fill, it's a signal color, not a background color |
| `text-on-accent` | `#071310` | Text/icon color for content sitting on a solid `accent` fill (e.g. the label inside a filled teal button). `accent` is a light-mid hue — near-black text reads with far more contrast on it than white does. |

### Text

| Token | Hex | Used for |
|---|---|---|
| `text-primary` | `#F2F3F7` | Primary labels, titles, clock, input text |
| `text-secondary` | `#A3A7B7` | Subtitles, secondary metadata (notification subtitle, app label under an icon) |
| `text-muted` | `#6B6F80` | Placeholder text, disabled labels, timestamps that shouldn't compete for attention |

`text-primary` is an off-white (`#F2F3F7`), not `#FFFFFF` — pure white
on a near-black background produces more contrast than comfortable
reading needs and looks slightly clinical against a warm dark palette;
the same reasoning `bg-base` uses in reverse.

### Borders / dividers

| Token | Hex (flat) | Alpha equivalent (once available) | Used for |
|---|---|---|---|
| `border-subtle` | `#292B35` | `rgba(255,255,255,0.08)` | Panel bottom hairline, card outlines, dividers between list rows |
| `border-strong` | `#3A3D4A` | `rgba(255,255,255,0.16)` | Rarely used; a stronger separator when two adjacent surfaces are the same `bg-card` and need a visible seam |
| `border-focus` | `accent` (`#2DD4BF`) | — | Focus ring on the launcher search input, keyboard-focused controls |

### Status colors

Match the mockup's "green = up" service dot directly, and round out
the set with the conventional pair so future components (package
manager errors, low-battery warnings) don't need to invent their own:

| Token | Hex | Used for |
|---|---|---|
| `status-success` | `#22C55E` | Supervised service "up" dot, successful operation toasts |
| `status-warning` | `#F59E0B` | Package updates available, low battery, degraded service |
| `status-error` | `#EF4444` | Supervised service "down"/crashed, failed operation |

Do not add a separate "info" color — `accent` already carries that
meaning (it's the one color reserved for "this is active/interactive/
notable"), and a second blue-ish hue next to teal would just compete
with it.

---

## 2. Typography

### What's already real

`build/09-foot.sh` already builds `freetype` → `fontconfig` → `fcft`
→ installs **JetBrains Mono** (OFL-1.1) for `foot`. That's the
monospace stack, and it stays exactly as-is for anything genuinely
monospaced: the terminal itself, and any UI element displaying code,
logs, or tabular machine output (e.g. the `pkg list` command hint in
a notification toast).

### What's missing: a UI sans-serif

Nothing in this repo currently installs a proportional/sans-serif
face — `novi-panel` and `novi-launcher` don't use fonts at all today
(§8). For labels, titles, body text, and the search input, a
proportional sans is the right call (a monospace UI reads as a
terminal wearing a costume, not a desktop).

**Recommendation: Inter** (SIL OFL-1.1, same license family already
in this repo via JetBrains Mono, so no new licensing review needed).
Reasons specific to this project:
- Ships as a single variable-font file (~840 KB for the full weight
  range 100–900) — one font file, not four-per-family the way
  JetBrains Mono's regular/bold/italic/bold-italic were extracted in
  `build/09-foot.sh` step 5. Smaller footprint for more weights.
- Has genuine tabular figures (`tnum` OpenType feature) — load-bearing
  for the panel clock (`14:32`) and battery percentage (`86%`) not
  jittering sideways as digits change width. `fcft`/`freetype` support
  OpenType feature selection at load time (`fcft_from_name()` accepts
  a `:features=` pattern element), so this is usable without extra
  shaping libraries.
- It's what the overwhelming majority of Linux distro UI toolwork
  already defaults to (GNOME's Adwaita Sans is an Inter-family fork),
  so it will look "correct" to a Linux user without explanation.

**Alternative worth naming: IBM Plex Sans** (also OFL-1.1). The
argument for it over Inter is identity, not technical merit: Inter is
now so ubiquitous ("the Bootstrap of fonts") that a from-scratch distro
explicitly trying to not be a derivative of anything might reasonably
want a UI face with more of its own character. Plex Sans has that
without sacrificing legibility or license cleanliness. This is a
product/brand call the platform maintainer should make deliberately,
not a technical constraint — either is a correct engineering choice.

**Do not fetch or add either font as part of this document.** This
spec only recommends; adding the actual font files follows the exact
pattern `build/09-foot.sh` step 5 already established for JetBrains
Mono (download release asset with checksum, extract only the needed
files into `${ROOTFS}/usr/share/fonts/<name>/`, `fc-cache` chrooted)
and belongs in that build stage or a new one alongside it, as separate
follow-up work.

### Type scale

All sizes in logical px (this compositor has no HiDPI output-scale
handling yet — see §8 — so px is physical px for now):

| Token | Size / weight | Used for |
|---|---|---|
| `text-display` | 15px / Medium (500) | Launcher search input |
| `text-title` | 14px / Semibold (600) | Card titles ("system-monitor"), notification title |
| `text-body` | 13px / Regular (400) | Default UI text, app labels, list rows |
| `text-caption` | 12px / Regular (400) | Panel clock, status bar icons' adjacent text (battery %), notification subtitle, service uptime |
| `text-mono` | 13px / JetBrains Mono Regular | Any command hint, log line, or literal system value (kernel version string, `pkg` command) shown outside the terminal itself |

---

## 3. Spacing, Sizing, and Radius

### Spacing scale

A single 4px-rooted scale, used for all padding/margin/gap values
everywhere — no ad hoc numbers:

```
4px   xs   — tight internal gaps (icon-to-label gap in a compact chip)
8px   sm   — default gap between adjacent inline elements
12px  md   — internal padding of compact controls, gap between panel regions
16px  lg   — card/window outer padding, gap between grid items
24px  xl   — separation between distinct sections within a card
32px  2xl  — outer margin between a floating card/toast and the screen edge
```

### Corner radius

Scaled to element size — the mockup's "~8–12px" isn't one number, it's
a range that should track how big the thing is:

| Token | Radius | Used for |
|---|---|---|
| `radius-sm` | 6px | Small chips, status pills, individual buttons |
| `radius-md` | 8px | App-grid icon buttons, input fields, single-line controls |
| `radius-lg` | 12px | Floating cards, the launcher panel, notification toasts, window corners |
| `radius-pill` | 999px (fully rounded) | The launcher's search input, the workspace-indicator strip |

The top bar itself is **not** rounded — it's edge-anchored full-width
chrome (`ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP|LEFT|RIGHT` in
`novi-panel/main.c`), and rounding a surface that touches the screen
edge on three sides would just clip content against a straight edge
for no visual benefit. Individual elements *inside* the bar (the apps
button, the workspace pill) use `radius-sm`/`radius-pill` as normal.

### Top bar height

**40px**, matching the mockup exactly. `novi-panel/main.c` currently
hardcodes `PANEL_HEIGHT 32` (line 39) — bumping this to 40 is a
one-line, zero-risk change and is listed as a concrete gap-closing
item in §8.

### Standard padding

- Floating card / window content: **16px** on all sides.
- Compact widget (a single status row, a toast): **12px**.
- Button / chip internal padding: **8px horizontal, 4px vertical**.
- Top bar horizontal edge padding (before the first / after the last
  item): **12px**.

---

## 4. Elevation and Depth

The mockup's "glass card" language (soft drop shadows implying
floating panels) has to be reinterpreted for what this renderer can
actually do efficiently — **and the honest limit here matters more
than the aesthetic goal**:

### What's realistic with pixman

`pixman` is a CPU-side compositing library. It composites
pre-rasterized image buffers via operators like `PIXMAN_OP_OVER` with
real alpha — it does **not** do live GPU blur, and it has no built-in
Gaussian/box-blur filter operation for arbitrary regions. Two
techniques are realistic; one that the mockup's "soft glass" language
implies is not.

**Realistic — flat drop shadow via a pre-rendered shadow sprite.**
Generate a soft rounded-rectangle shadow (blurred edges, radial
falloff) *once*, offline or at first use, as a small ARGB8888 bitmap
(e.g. a 9-slice-able sprite: four corners + edge strips, or simply a
handful of fixed sizes for the handful of card sizes this UI actually
uses — cards aren't arbitrarily sized). Composite that sprite under
the card via `pixman_image_composite32` with `PIXMAN_OP_OVER`, offset
~4px down, ~16px feather. This is cheap: it's a handful of image
composites per redraw, not a per-pixel blur computed live. Recommended
values:

| Elevation | Shadow | Used for |
|---|---|---|
| `elevation-0` | none — 1px `border-subtle` hairline only | Top bar (edge-anchored, doesn't "float") |
| `elevation-1` | `y-offset: 4px, feather: 16px, alpha: 0.35, color: #000000` | Floating cards, launcher, toast, window chrome |

**Realistic — precomputed rounded-corner alpha masks.** `pixman` has
no native rounded-rect or bezier primitive, but it does rasterize
trapezoids with anti-aliasing (`pixman_add_trapezoids` /
`pixman_rasterize_trapezoid`), which is enough to build a rounded-rect
clip mask — but the pragmatic version most minimal software UIs
actually use, and the one recommended here, is simpler: rasterize just
the **four corner arcs** once as small A8 coverage bitmaps (a handful
of fixed radii from §3's scale covers every case), and composite a
straight-edged rect for everything else. Four cached corner stamps
plus straight `pixman_image_composite32` fills reproduces a rounded
rect without touching a trapezoid API per frame.

### Not realistic — true backdrop blur

The mockup's "glass card" implies content *behind* a translucent panel
is itself blurred (what compositors like KWin/Hyprland do as a GPU
shader pass over the framebuffer region under a surface). That
requires either:
- GPU compute/shader access — explicitly out of scope (`-Drenderers=[]`
  in `build/06-wayland.sh`, Mesa-free by design), or
- The **compositor** (not the layer-shell client) reading back and
  blurring the composited scene beneath a surface's region before
  drawing that surface on top — `wlr_scene` has no built-in blur-region
  concept, and implementing one CPU-side means blurring a
  variable-sized, possibly-large screen region every frame, which is
  real per-frame cost pixman was never optimized for.

**Recommendation: skip backdrop blur entirely.** Use a solid (fully
opaque, or very lightly transparent — 90%+ opacity) `bg-card` instead
of a see-through glass panel, plus the flat drop shadow above to
convey "floating." This is the honest tradeoff the mockup's soft-glass
look doesn't get for free here; a solid panel with a good shadow still
reads as "elevated card," just not "see-through glass."

---

## 5. Iconography Direction

**Which icon set/library to use is a separate, parallel task — this
section defines only the style constraints that task must satisfy to
fit this design language, not the set itself.**

- **Line icons, not filled.** Matches the mockup's "simple flat/
  line-art style" and reads as lighter-weight against the dark
  background than solid filled glyphs would.
- **Consistent stroke weight across the whole set** — recommend
  **1.5–2px stroke at a 24×24px canvas** (the common convention used
  by Feather, Tabler, and Lucide-style icon families — naming these as
  reference points for *style*, not as a recommendation of which one
  to actually adopt). Mixed stroke weights across an icon set is the
  single most common way an otherwise-good icon choice ends up looking
  inconsistent.
- **Single-color (monochrome) only.** No multi-color or gradient
  icons. This isn't just an aesthetic preference — it's what keeps
  rendering cheap under pixman: a monochrome line icon can be
  rasterized once into an **A8 coverage mask** (identical treatment to
  a text glyph, §8) and tinted at composite time via
  `PIXMAN_OP_OVER` with whatever color the context needs
  (`text-secondary` at rest, `text-primary` or `accent` on
  hover/active) — one cached mask serves every color state. A
  multi-color icon needs its own full ARGB bitmap per icon and can't
  reuse that mask-plus-tint pipeline.
- **24×24px bounding box with internal padding**, so icons of
  differing visual weight (a wifi glyph vs. a battery glyph) still
  align on a shared grid inside app-icon buttons and status rows.
- Default tint is `text-secondary`; interactive icons (the apps
  button, a hovered grid item) move to `text-primary` or `accent` on
  hover/active, following the same state pattern as text.

---

## 6. Window Chrome

The mockup describes a `foot` terminal window with a rounded title bar
and three monochrome traffic-light dots on the **right** (not macOS's
left). Before specifying dot semantics, it matters what `novi-shell`
can actually back them with — checked directly against
`novi-shell/main.c`:

### What the compositor actually implements today

- **No window decorations exist at all.** `struct novi_toplevel`'s
  listener set is `map / unmap / commit / destroy / request_move /
  request_resize / request_maximize / request_fullscreen` — there is
  no `wlr_xdg_decoration_manager_v1` anywhere in the file, and no
  `#include <wlr/types/wlr_xdg_decoration_v1.h>`. Every `xdg_toplevel`
  is placed borderless; nothing draws a title bar today, for `foot` or
  anything else.
- **Close is real.** Super+Q calls `close_focused_toplevel()`, which
  sends `wlr_xdg_toplevel_send_close()` — the same polite
  "please close yourself" request a real close button would send
  (`xdg_toplevel_request_move`'s sibling handlers don't apply here;
  this is a compositor-initiated close, not a client request).
- **Maximize and fullscreen are explicit no-op stubs, not
  unimplemented placeholders.** `xdg_toplevel_request_maximize()` and
  `xdg_toplevel_request_fullscreen()` both just call
  `wlr_xdg_surface_schedule_configure()` — an empty configure sent
  purely to satisfy the xdg-shell protocol's requirement that a
  request gets *some* reply — with the comment in the source stating
  plainly: *"novi-shell doesn't support maximization."* Geometry never
  changes. A client that requests fullscreen or maximize today gets
  acknowledged and ignored.
- **Minimize doesn't exist as a concept at all.** xdg-shell has no
  core "minimize" request the way it has maximize/fullscreen, and
  nothing in `novi-shell` implements hide/restore, a taskbar, or any
  place a minimized window's affordance would live. There is no
  partial implementation to check — it is simply not present anywhere
  in the codebase.
- **No pointer input reaches window decorations or layer-shell
  surfaces yet** (confirmed by `docs/PLATFORM-ROADMAP.md` §5's "still
  open" list: "click/pointer input isn't routed to layer-shell
  surfaces yet"). Even once a title bar exists to draw dots on, a real
  click-to-close/maximize interaction needs its own hit-testing path
  distinct from `desktop_toplevel_at()` (which only resolves toplevel
  *content* surfaces, not compositor-drawn decoration).

### Spec: what the three dots mean, and how to be honest about it

Keep the mockup's convention — **three monochrome dots, right-aligned,
not colored red/yellow/green** — but wire only what's real, and make
the other two visually present-but-inert rather than pretending they
work:

| Dot | Meaning | Status |
|---|---|---|
| **Close** | Sends `wlr_xdg_toplevel_send_close()` on click | **Wire it up.** This is the one dot with a real, already-implemented compositor primitive behind it. Making it clickable is "add decoration hit-testing," not "add a new compositor capability." |
| **Maximize** | Snap the window to the output's usable area | **Wired and real, same as close.** Was flagged here as "the more tractable of the two to actually implement later" — since implemented: `maximize_toplevel()`/`unmaximize_toplevel()` in `novi-shell/main.c` reuse `process_cursor_resize()`'s exact geometry approach, plus a saved-geometry struct to restore on a second click, exactly as anticipated. Full strength `text-muted`, not dimmed, since it's genuinely interactive now — dimming it would misleadingly signal "disabled." |
| **Minimize** | Hide the window, keep it referenced somewhere to restore from | **Style as present, dimmed, non-interactive.** Do not implement a "fake" minimize (e.g. just unmapping the scene node) without also deciding where the window goes to be restored from — there's no taskbar/dock in this design yet for it to live in, so wiring the dot before that exists would be a dead end, not a shortcut. |

Visual spec for the dots themselves: **8px diameter circles, monochrome
`text-muted` at rest → `text-secondary` on hover (close/maximize, once
hover state is wired — currently unwired, see `novi-shell/main.c`'s own
comments) → `status-error`-tinted only at the instant of a close click
if a "destructive confirm" flash is wanted (optional, not required)**.
Never use red/yellow/green fills — that's the one explicit thing the
mockup calls out as *not* wanted here.

Spacing correction: this section originally specified "8px gap between
centers" for same-sized 8px dots, which is a contradiction — center
spacing narrower than the dots' own diameter means they'd overlap by a
full diameter, not sit apart. The implementation uses 8px of
edge-to-edge clearance instead (16px center-to-center), the
conventional reading of "an 8px gap" between equal-sized elements.

### Consequence for who draws the title bar

Because decorations don't exist as compositor state today, and because
relying on every individual client (foot, any future GUI app) to draw
its own consistent title bar would fragment the look the moment a
second toolkit shows up, **the title bar + dots should be
server-side decorations drawn by `novi-shell` itself** (via
`wlr_xdg_decoration_manager_v1`, requesting
`ZWLR_XDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE`), not client-side
decorations `foot` draws itself. This keeps the chrome identical across
every window regardless of what toolkit produced its content — the
same reasoning RFC 0001 decision 5 already applies to the panel/
launcher being separate processes rather than baked into arbitrary
clients. This is new compositor work, tracked in §8, not implemented
today.

Recommended title-bar sizing: **32px height** (distinct from the
40px top bar — a window title bar is a smaller, per-window affordance,
not primary chrome), `bg-card` background, `radius-lg` top corners
only (matching the window body below it), 12px horizontal padding, the
window title in `text-caption` / `text-secondary`.

---

## 7. Component Patterns

Each of these is meant to be copied, not reinvented, by the next GUI
component that needs one.

### Top bar (`novi-panel`)

- Full-width, top-anchored, exclusive zone, `elevation-0` (hairline
  border only, no drop shadow — it's edge chrome, not a floating
  object).
- `bg-panel`, 40px height, 12px horizontal edge padding.
- Three-region flex layout: left / center / right, each region's
  children laid out with `sm` (8px) gaps, vertically centered.
- Left region: apps button (icon + `text-body` label, opens
  `novi-launcher`) + workspace indicator (a `radius-pill` strip,
  `bg-card-raised`, containing N small dots — `accent` for the active
  workspace, `border-strong` for the rest).
- Center region: date/time in `text-caption`, tabular figures.
- Right region: status icons (wifi, battery + percentage, power) at
  `text-secondary` tint, `sm` gap between each.
- Every future full-width persistent chrome element (a second bar, if
  one is ever added) follows this same three-region shape.

### Floating widget card (e.g. `system-monitor`)

- `bg-card`, `radius-lg`, `elevation-1` (the drop-shadow sprite from
  §4).
- Optional title-bar strip at the top: `text-title` label + three small
  dots top-right *matching window-chrome dot styling* — **but these
  are purely decorative status affordances on a widget, not a real
  `xdg_toplevel`'s window controls.** A widget card is a layer-shell
  surface, not a toplevel window; nothing should wire a widget's
  corner dots to `wlr_xdg_toplevel_send_close()`, because there's no
  toplevel behind it to send that to. If a widget needs a real close
  action, give it its own explicit affordance/behavior — don't borrow
  window-chrome semantics by accident just because the dots look alike.
- Content area: 16px padding, rows separated by `md` (12px) gaps.
- A status row pattern (used by the "supervised services" list):
  status dot (`status-success`/`status-error`, 8px) + service name
  (`text-body`) + right-aligned uptime/detail (`text-secondary`,
  `text-mono` if the value itself is a raw system string like a kernel
  version).

### Notification toast

- `bg-card`, `radius-lg`, `elevation-1`, fixed width ~340px, height
  hugs content.
- Anchored top-right via the **overlay** layer-shell layer (same layer
  `novi-launcher` already uses), `2xl` (32px) margin from both the top
  and right edges.
- Layout: icon (24px, `text-secondary` or `status-*` tint depending on
  severity) + stacked text block (title `text-title`, subtitle
  `text-secondary`) + optional inline command hint styled as a small
  `radius-sm` chip in `bg-card-raised` with `text-mono` (JetBrains
  Mono) text in `accent` — this is how "run `pkg upgrade`" reads as an
  actionable command rather than plain prose.
- Needs its own dismiss timer — reuse the exact `timerfd` + `poll()`
  pattern `novi-panel/main.c` already uses for its clock tick, not a
  new event-loop mechanism.

### Launcher overlay (`novi-launcher`)

- `bg-card`, `radius-lg`, `elevation-1`.
- Search input at top: `radius-pill`, `bg-card-raised` fill,
  `text-display` size, `accent`-colored blinking caret, 16px internal
  horizontal padding.
- App grid below: each entry is an icon (in a `radius-md` button,
  `bg-card-raised` at rest → `accent-subtle-bg` + `accent` icon tint on
  hover/keyboard-selected) with a `text-caption` label centered
  underneath, laid out in a grid with `lg` (16px) gaps.
- A "security tools" row beneath the grid (per
  `docs/PLATFORM-ROADMAP.md` §12) with a trailing chevron icon
  indicating it expands — same row treatment as a single grid item but
  full-width, `text-body` label instead of icon-plus-caption.
- **Positioning gap, noted not solved here:** the mockup shows this
  panel opening *below the apps button*, not screen-centered.
  `novi-launcher/main.c` currently requests `anchor = 0` (no anchor
  bits set), which per `wlr-layer-shell-unstable-v1` centers the
  surface on the output — that's why it appears centered today. Two
  panel-relative positioning options exist once this is picked up:
  anchor top-left with a fixed margin approximating the apps button's
  known position (`novi-panel`'s layout is deterministic/hardcoded, so
  this is a reasonable static offset rather than needing live
  coordination), or a small IPC channel between `novi-panel` and
  `novi-launcher` if the button's position ever becomes dynamic. Both
  are launcher/panel implementation work, not a design-language
  decision — flagged here so whoever picks it up doesn't have to
  rediscover it.

---

## 8. Gap From Today, Sequenced by Leverage

> **Update since this doc was written:** item 1 below (fcft text
> rendering) is now done — both `novi-panel/main.c` and
> `novi-launcher/main.c` link `fcft`+`pixman` (see `../../common/text.h`)
> and render real anti-aliased glyphs instead of the 3×5 bitmap font
> described below. The "current state" paragraph and item 1 are kept
> as-written for the historical reasoning (why fcft was the right
> first move); treat them as describing the state *before* that
> change. Items 2–6 are still open and their sequencing/reasoning is
> unaffected — item 2 (real alpha compositing) is the next one up.

Current state, confirmed by reading the code, not assumed: both
`novi-panel/main.c` and `novi-launcher/main.c` render by writing raw
`uint32_t` values directly into an `XRGB8888` (opaque-only, no alpha
channel) shm buffer via a hand-rolled `draw_rect()` — there is no
`pixman_image_composite32` call, no `pixman_image_t`, anywhere in
either file, and neither file's `Makefile` even lists `pixman` in
`PKGS`. Text is a hand-authored 3×5 bitmap font covering only digits
and a handful of symbols (`FONT[]` in each file). Neither links
`fcft`, `freetype`, or `fontconfig`, despite all three already being
built, working, cross-compiled dependencies in this same rootfs for
`foot` (`build/09-foot.sh`). In short: **the hardest dependency
problem is already solved and sitting unused one build stage away.**

Sequenced by "most visual improvement for least new dependency risk"
— every item below adds zero new libraries to the OS build, only new
linkage in two already-tiny C programs:

1. **Anti-aliased text via `fcft` + `freetype` + `fontconfig`.**
   Highest leverage, essentially free in dependency terms: these three
   libraries are already cross-compiled and installed in the rootfs
   for `foot`; this is "add `fcft`/`fontconfig` to each Makefile's
   `PKGS`," not "teach the build system a new library." `fcft` was
   written by `foot`'s own author specifically to hand rasterized
   glyphs back as `pixman`-compatible surfaces — pairing it with a
   `pixman`-based renderer (item 2) is its intended integration path,
   not a bespoke adaptation. This single change replaces the 3×5
   bitmap font everywhere, unlocks a real UI typeface (§2), and is the
   one item on this list that touches the most visible surface area
   (every label, every piece of text in every component) for the
   least code.

2. **Real `pixman` compositing, including alpha.** Currently both
   clients allocate `WL_SHM_FORMAT_XRGB8888` (opaque only — confirmed
   in both `surface_draw_frame()` functions) and write pixels by hand;
   `pixman` itself is a transitive build dependency (wlroots needs it)
   but is not actually linked into either client program today. Adding
   it properly — link `pixman-1`, switch to `WL_SHM_FORMAT_ARGB8888`
   with premultiplied alpha, replace `draw_rect()` with
   `pixman_image_composite32(..., PIXMAN_OP_OVER, ...)` — is what
   unlocks every alpha-dependent thing in this document: hover-state
   washes (`accent-subtle-bg`), the shadow sprite (§4), dimmed/disabled
   dot styling (§6), and glyph compositing from item 1. Low risk: the
   library is already proven at this exact cross-compilation target
   (it's in every `wlroots` build already booted in QEMU this session).

3. **Rounded-rect drawing** (precomputed corner alpha masks, §4) once
   1–2 are in place — this is a straightforward application of the A8
   coverage-mask technique text rendering already needs, not a new
   rendering concept.

4. **Drop-shadow sprites** (§4) — same mask-and-composite technique
   again, applied to a blurred shape generated once rather than a
   sharp corner. Natural next step once rounded rects work, since a
   card needs both together to read as a "glass card."

5. **Icon rendering** — once an icon set is chosen (separate task) and
   1–2 exist, icons are just another A8 coverage mask tinted at
   composite time (§5), reusing the exact same pipeline glyphs use. No
   new rendering capability needed beyond what items 1–2 already add.

6. **Server-side window decorations** (§6) — the one item here that is
   genuinely new *compositor* work, not renderer work: wiring
   `wlr_xdg_decoration_manager_v1` into `novi-shell`, drawing a title
   bar via the scene graph, and adding decoration-aware pointer
   hit-testing. Sequenced last because it depends on rounded-rect +
   text rendering existing first (the title bar needs both to look
   like anything in this spec) and because, unlike 1–5, it touches
   `novi-shell/main.c` (the compositor) rather than just the two
   client programs.

Explicitly **not** on this list, and not recommended: pulling in
Cairo, Skia, GTK, or a GPU-accelerated renderer to shortcut any of the
above. Every technique here was chosen because `pixman` +
`fcft`/`freetype`/`fontconfig` — libraries this repo has already
built, tested, and booted — can do it. Reaching for a heavier
toolkit would undo the Mesa-free, minimal-dependency posture
`build/06-wayland.sh` and RFC 0001 both commit to, for a visual result
this pairing already gets you.
