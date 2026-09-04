# Novi Linux — Platform Roadmap

## Philosophy

Novi is not "another distro" — it's a from-scratch base (musl, s6, BusyBox,
custom `pkg` format) that we're building into a full platform. The rule for
every area below: **study what other projects' users love, then build our
own implementation on our own base.** We don't vendor SteamOS's session or
fork systemd to get there — we solve the same user problem with the stack
we already have.

Guiding line: *everything Linux can do, without making users choose which
Linux they want.*

**Who this is for, and why that's one audience, not four:** everyday
users, programmers/developers, security practitioners, and gamers —
tracked concretely below (§5 desktop for the everyday-user experience
and its HIG-grade design language, §7 developer, §12 pentest, §6
gaming). These aren't four separate editions or spins to choose between
at install time (the guiding line above rules that out explicitly) —
they're four use cases the same rootfs, the same `pkg` foundation, and
the same compositor serve at once, the way §11 already frames Novi's
differentiator (one foundation, not bundled-together forks of it). The
thread connecting all four: **user control over their own machine** —
a small, auditable TCB (§9), a package model that never hides what's
installed or phones home without being asked (§2), an update model the
user drives rather than one that drives them (§3), and a desktop (§5)
whose visual design is held to a real HIG, not styled after the fact.

**Long-term direction, not yet scoped — a phone/mobile target, so the
same account, the same look, and eventually the same running apps
follow a user from desktop to phone instead of stopping at it.** This is
explicitly aspirational: no mobile kernel config, no touch-first shell
mode, no phone hardware-enablement work exists yet, and none should
start without its own RFC per `CONTRIBUTING.md` (a new hardware class is
exactly the kind of architectural change that process exists for). It's
recorded here because §5's Libadwaita discussion already leans on
adaptive phone/tablet/desktop breakpoints as a reuse argument, and
because it should shape judgment calls made *today* even before it's
scoped: prefer designs and protocols that don't quietly assume a
keyboard+mouse+one-fixed-output desktop is the only target (layer-shell,
`novi-launcher`'s search-first interaction model, and adaptive-widget
toolkit choices in §5 already happen to point this way), and don't
spend real engineering effort inventing a phone story prematurely — the
open work in §4 Hardware Strategy and §5 Desktop Strategy comes first.

This doc turns that into a tracked technical roadmap. Each section states
what's **already decided** (shipped in this repo today), what's **proposed**
(needs an RFC per `CONTRIBUTING.md` before implementation), and what's
**open** (needs a decision before it can even become an RFC).

---

## 1. Base Architecture

**Decided:** musl libc 1.2.5, s6 + s6-rc supervision, execline, static
BusyBox userland, Linux 6.10.3-novi, GCC 14.2 cross-toolchain. See
`README.md` stack table and `build/00-versions.sh`.

**Why it stays this way:** this is the one layer every other section
depends on. Small libc + supervised init gives us a predictable boot,
fast service restarts, and no glibc/systemd ABI baggage to work around
when we build the layers above it. Changing init/libc later is
maximally expensive, so it's the one area we're *not* re-litigating.

**Open:** `aarch64` target (`TARGET_ARCH` in `build/00-versions.sh` is
`x86_64`-only today). Needed before "hardware strategy" can mean anything
outside PC hardware.

**Open:** BusyBox-only vs. full GNU coreutils/util-linux by default. Our
static BusyBox userland (`build/03-base.sh`) is the right call for the
minimal boot/install-stage rootfs, but it's a real capability gap against
the terminal experience Arch/Debian users are used to — BusyBox's applets
are simplified subsets (fewer flags, POSIX-only where scripts often assume
GNU extensions). See §5's "Terminal / CLI environment" for the proposed
resolution (BusyBox stays the base-stage userland; full coreutils becomes
an installable `pkg` layer for any real interactive system).

---

## 2. Package / Application Model

**Decided:** native `.pkg.tar.gz` format (`packages/pkg-format.md`),
topological dependency resolution, lifecycle scripts, install DB under
`/var/lib/pkg/`.

**Now actually real, not just designed on paper.** `packages/pkg` (the
installer) and `packages/mkpkg` (the builder) were logically complete
but had never been installed anywhere or run end-to-end — no
`build/*.sh` stage referenced `pkg` at all, so nothing in this repo had
ever actually executed `pkg install` against a real dependency chain.
`build/11-pkg.sh` now installs it into the rootfs (`mkpkg` stays a
build-host tool, not shipped — see its own header comment). Actually
running it for the first time, in a chroot of `build/rootfs` under the
real built BusyBox `ash` binary (not assumed, not a different host
shell), surfaced several real bugs that static reading hadn't caught:
a UTF-8 BOM breaking the shebang; `manifest_field()` silently killing
the whole script under `set -e` whenever an optional MANIFEST field
was absent (the normal case for most fields); dependency resolution
doing nothing at all, silently, because its collection loop piped into
`while read` — the last stage of a pipeline, which `ash` runs in a
subshell, discarding every `DEP_QUEUE` mutation inside it; the same bug
in `pkg search`; duplicate search results for installed packages still
present in the local repo; and `mkpkg` corrupting its own input
MANIFEST on a second run of the same staging directory. All fixed and
verified live: a toy two-package dependency chain (`hello` depending on
`libfoo`) installs in the correct order, files land correctly, lifecycle
scripts run, `pkg list`/`info`/`search`/`remove` (including the
reverse-dependency warning) all behave correctly, and `mkpkg` is now
idempotent. Both scripts are shellcheck-clean.

**Proposed — three-tier model**, so users never have to think about it:

```
              APPLICATION
                    │
        ┌───────────┼───────────┐
        │           │           │
   pkg (native)  container   sandboxed
        │        (dev/CLI)   desktop app
   system         toolchains   (flatpak-
   components,    exposed via  compatible
   drivers,       `pkg`-managed OCI bundle,
   base libs      runtimes      isolated by
                                 default)
```

- **Native (`pkg`)**: system components, drivers, base libraries — anything
  that needs to be musl-linked and tightly integrated. This is what exists
  today.
- **Sandboxed desktop apps**: OCI/Flatpak-compatible bundles for desktop
  software, so upstream glibc-built apps run without every app needing a
  musl port. This is the actual unlock for "huge availability without
  dependency chaos" — native stays small and clean, breadth comes from
  the sandbox layer.
- **Containers**: dev/CLI tooling, exposed through `pkg` so `pkg install
  docker-toolchain` feels the same as installing anything else.

**RFC required** (per `CONTRIBUTING.md`, "package format spec" and
"desktop stack" both trigger RFC) before any sandboxed-runtime work starts.

---

## 3. Update & Rollback Model

**Decided:** `docs/branch-strategy.md` already splits `stable/*` (LTS,
2-reviewer, workstation/enterprise) from `advanced/rolling` (newer
packages, enthusiast/dev). This is the repo-level version of the track
split; it needs a matching *on-device* update mechanism.

**Proposed:**

```
                   NOVI PLATFORM
                         │
              ┌──────────┴──────────┐
              │                     │
          STABLE TRACK          ADVANCED TRACK
       tracks stable/*        tracks advanced/rolling
       infrequent, tested     frequent, newer pkgs
       enterprise/workstation enthusiasts/devs
              │                     │
              └──────────┬──────────┘
                         │
                  same pkg format,
              same rootfs layout,
              same install base
```

- Root filesystem updates apply atomically (new rootfs staged, activated
  on next boot) so a failed or bad update can roll back to the previous
  boot entry — this is the piece that doesn't exist yet and needs design
  work: candidates are an overlay/snapshot rootfs (btrfs subvolumes or
  dm-verity + A/B slots) layered under the existing `pkg` DB.
- `pkg` itself stays track-agnostic — a package doesn't know which track
  installed it, only the repo it was resolved from differs per track.

**Open:** which rollback mechanism (A/B partitions vs. snapshotting
filesystem) — this decision blocks `mkiso.sh`/`mkinitramfs.sh` changes and
needs its own RFC since it touches the rootfs layout contract.

---

## 4. Hardware Strategy

**Decided:** `kernel/config-x86_64` (280+ options), builds a `-novi`
tagged kernel. Already reaches beyond the QEMU-only virtio set into real
hardware drivers (confirmed while building: AMD `amdgpu`, Intel `i915`,
`mac80211`-based WiFi are all compiled in), so "hardware strategy" isn't
starting from nothing.

**Guiding principle: build against open standards and device classes,
not vendor-specific paths.** This is the actual mechanism behind "not
gated by manufacturer or software" — not a policy statement, an
engineering default:

- **Class-compliant devices need zero vendor code at all.** A USB mouse
  works without a Logitech/Razer driver because it advertises USB HID
  class `03h` and one HID driver (already in the kernel) speaks the
  whole class spec; an NVMe SSD works without a driver per vendor
  because it speaks the NVMe class spec over PCIe, not a
  Samsung/WD/Crucial-specific protocol. Same pattern covers USB Mass
  Storage, USB Audio, HID (keyboards/mice/gamepads), and most storage.
  Nothing to build here beyond keeping those class drivers enabled —
  it's why most peripherals already "just work."
- **Where hardware genuinely needs vendor-specific code** (GPU
  rendering, WiFi chipsets, some laptop ACPI quirks), prefer the open,
  upstream-maintained driver over a proprietary blob wherever one
  exists and is competent: `amdgpu`+Mesa over AMD's proprietary stack,
  `i915`+Mesa for Intel, in-kernel `iwlwifi`/`ath`/`rtw88` WiFi drivers
  over vendor binary-only modules. These are already what
  `kernel/config-x86_64` builds against — the principle already in
  practice, not aspirational.
- **Where only a proprietary driver exists** (NVIDIA's GPU stack is the
  main case), package it like any other software — a `pkg` install,
  not a kernel patch — so using it is a user choice per §2's tiering,
  not something baked into the base image. This keeps the "runs on
  open standards by default" property true for the base system even
  though a proprietary option remains available.
- **The user-facing payoff**: hardware support isn't "does Novi have a
  driver for *this* laptop model," it's "does this hardware speak a
  standard the kernel already implements" — which is most hardware,
  because most hardware is built to sell into Windows/macOS/Linux
  alike and therefore already implements the relevant class specs.

**Proposed:** widen kernel config coverage (more WiFi/BT chipsets, common
laptop ACPI quirks) and add a boot-time hardware detection service (an
s6-supervised oneshot) that loads/blacklists modules and picks firmware,
rather than shipping one monolithic config for every machine. Firmware
blobs get their own `pkg` package (`linux-firmware`) so licensing stays
separated from the free kernel package.

**Open:** aarch64 support (blocks any non-x86 hardware story) and whether
firmware packages are opt-in at install or bundled in the default ISO.

---

## 5. Desktop Strategy

**Decided and under construction.** [`docs/rfcs/0001-desktop-wayland-compositor.md`](rfcs/0001-desktop-wayland-compositor.md)
proposes a wlroots-based compositor + `seatd` (no systemd-logind) with a
thin `novi-shell` on top, run as an s6-rc service like everything else.
`CONTRIBUTING.md`'s 7-day discussion period is a gate for outside
contributors once there's a community to consult — pre-launch, the
founder's own approval is what moves this from draft to build, and that's
been given: implementation is underway.

Built and **verified booting to a running compositor** (live QEMU boot,
serial-console-confirmed), cross-compiled from source against this repo's
own musl toolchain (`build/06-wayland.sh`, `build/07-novi-shell.sh`): the
full dependency stack (wayland, wayland-protocols, libxkbcommon, pixman,
libudev-zero, libevdev, mtdev, libinput, libdrm, libdisplay-info, seatd,
wlroots, xkeyboard-config — 15 libraries, all with real cross-compilation
bugs found and fixed, not just downloaded), and a first working
`novi-shell` binary (`novi-shell/`, a wlroots DRM+libinput+pixman
compositor core adapted from wlroots' own tinywl.c reference). Wired into
s6-rc as `seatd` and `novi-shell` services (dependency verified via
`s6-rc-db`), kept out of the `default` boot bundle behind a `graphical`
bundle until the panel/launcher layer below exists — switch to it by hand
with `s6-rc -u change graphical` (plain `-u`/up, not `-up`/up+prune — see
§5's live-testing note below for why `-p` is actively dangerous here).

Getting from "links and starts" to "reaches `novi-shell running on
WAYLAND_DISPLAY=wayland-0`" took four real, empirically root-caused fixes,
each found by reading actual boot output rather than guessed: wlroots'
renderer auto-detection skips its software (pixman) renderer whenever a
DRM render node is present, assuming GPU-accelerated rendering will
succeed — this build has no GLES2/Vulkan renderer (deliberately Mesa-free
for this milestone), so auto-detection found nothing until pixman was
forced explicitly (`WLR_RENDERER=pixman`); nothing in the init sequence
created `XDG_RUNTIME_DIR`, which libwayland-server requires to open its
socket at all; `libxkbcommon` links and runs but embeds no keyboard layout
data of its own, so `xkeyboard-config` (the actual rules/symbols/keycodes
database) had to be added as a 15th package before any keymap could be
compiled; and POSIX shared memory (`shm_open`, used for keymap handoff to
Wayland clients) needed a `tmpfs` at `/dev/shm`, which devtmpfs at `/dev`
does not provide on its own.

Next slice, built on top of the now-verified core: **wlr-layer-shell-v1
protocol support** (five persistent scene-tree layers — background,
bottom, windows, top, overlay — so a panel or launcher client can anchor
to screen edges with correct z-order and exclusive-zone handling; the
protocol XML had to be vendored into `novi-shell/protocol/`, since
wlroots itself never installs it or its generated header anywhere) and
part of RFC 0001 decision 7's **default keybindings**: Alt+Tab /
Alt+Shift+Tab (window switching), Super+Return (spawn a terminal — `foot`
by default, not packaged yet, so this fails visibly until it is),
Super+Q (close focused window). Boot-verified with no regression to the
existing "reaches running" milestone; the layer-shell arrangement logic
itself is verified by implementation review against wlroots' own
geometry helper rather than a live client, since no panel/launcher
client exists yet to exercise it end-to-end.

First real UI piece landed on top of that: **`novi-launcher`**
(`novi-launcher/`), the Alt+Space search/launcher overlay, as its own
wlr-layer-shell-v1 client process rather than compositor code — the
split every future panel piece follows. novi-shell now grants keyboard
focus to a layer-shell surface on map when it requests "exclusive"
interactivity (and restores it on unmap), which the launcher needs to
receive typed input at all. v1 scope is the calculator/unit-conversion
fallback RFC 0001 describes, not app/file search — there's no
application registry or indexed filesystem to search yet in a fresh
install with no packages, so there's nothing real to search against.
Rendering uses a small hand-authored bitmap font (digits + calculator
operators only, not a full alphabet — no font-rendering stack exists in
this repo yet, and a font table copied from memory without a way to
verify it byte-for-byte isn't something to ship silently wrong).
**Verified live in QEMU** via scripted keyboard injection and
screendump capture, not just "compiles and doesn't crash": Alt+Space
opens the overlay, typing "2+2" live-renders the input and "= 4" on
screen, Escape closes it cleanly. That same live-verification pass also
caught and fixed a real protocol-ordering bug (a premature configure
sent before the client's required initial commit, logged by wlroots
itself as an error) — masked at first because the client happened to
have a defensive fallback for it.

**foot** (RFC 0001 decision 6's default terminal) is now built and
Super+Return actually does something: a real terminal window opens,
running a live BusyBox shell, rendered in JetBrains Mono via
freetype/fontconfig/fcft — the first real font-rendering stack this
repo has needed. **Live-verified interactively in QEMU**, not just
"the binary exists": typed `echo Hello` into the booted VM via
keyboard injection and got `Hello` printed back, the full
keyboard → novi-shell → foot → shell → render round trip. Along the
way, found and fixed a real, independent bug this work exposed rather
than caused: a re-run of `build/06-wayland.sh` picked up a
build-host path (`/build/rootfs/...`) baked into libxkbcommon.so's
compiled-in default XKB config root, because its build queries
xkeyboard-config's pkg-config variable through this repo's
sysroot-rewriting pkg-config wrapper — silently correct before only by
step-ordering accident (xkeyboard-config didn't exist yet the very
first time libxkbcommon was built). Fixed by pinning
`-Dxkb-config-root=` explicitly rather than leaving it to
auto-detection.

**`novi-panel`** (a top bar, third layer-shell client alongside the
compositor and launcher) is built: a live clock, always visible,
auto-spawned by novi-shell at startup. Finding it also turned up a real
infinite-loop bug in the compositor's layer-shell arrangement logic
(fixed: re-arranging was firing on every client commit instead of only
ones that actually changed geometry, closing a compositor↔client
configure/commit ping-pong — one boot logged 1,000+ cycles in 13
seconds before the fix). It initially looked like a z-order bug (the
panel appeared to vanish once a terminal opened) and took an actual
diagnostic log, not guesswork, to find the real cause. Live-verified:
the panel now stays visible and correctly on top of terminal windows.

`novi-panel` and `novi-launcher` have since dropped their hand-authored
3×5 bitmap fonts entirely: both now render through a new shared
`common/text.[ch]` module built on `fcft` (the same library `foot`
already depends on, written by `foot`'s own author to hand back
`pixman`-compatible rasterized glyphs) plus `pixman` compositing,
following the exact glyph-blit pattern read directly out of `foot`'s
own `render.c` rather than guessed. Zero new OS dependencies — fcft,
freetype, fontconfig, and pixman were all already cross-compiled and
installed in the rootfs for `foot` (`build/09-foot.sh`), just not
linked into these two clients yet. Live-verified in QEMU: the panel
clock and the launcher's calculator input/result both render as clean
anti-aliased text instead of blocky bitmap glyphs.

A real memory-safety bug was also found and fixed in
`novi-shell/main.c`'s `desktop_toplevel_at()`: it walked the scene
tree for the first non-NULL `node.data` and returned it unconditionally
cast as a `novi_toplevel*`, but layer-shell surfaces (the panel,
launcher) also set non-NULL `.data` on their own scene tree root,
pointing at a `novi_layer_surface` instead — clicking one would have
type-confused it as a toplevel. Fixed by checking the found tree's
immediate parent against `server->layer_tree_toplevels` before
trusting it. Not yet observable through normal use (see "click/pointer
input isn't routed to layer-shell surfaces yet" below — nothing has
clicked a layer-shell surface in testing so far), but real UB waiting
for that gap to close.

A new `docs/design/` directory now holds three grounding documents —
`GUI-DESIGN-LANGUAGE.md`, `ICON-PIPELINE.md`, and
`WIDGET-NOTIFICATION-ARCHITECTURE.md` — written against a target visual
direction the project maintainer supplied (dark theme, teal accent,
rounded card/glass panels, icon-grid launcher, right-aligned monochrome
window-chrome dots) and checked against this codebase as it actually
stands rather than assumed. Between them they cover: a full color/type/
spacing/radius token spec and a pixman-realistic elevation approach
(precomputed shadow sprites and rounded-corner masks — true backdrop
blur is explicitly ruled out as infeasible without GPU/Mesa); an
offline-only icon pipeline proposal (SVG-to-bitmap generation stays a
host-side build step, never cross-compiled or shipped, same category as
`depmod`); and a widget/notification architecture proposal (layer-shell
is sufficient for both, no new Wayland protocol needed; a single
persistent toast-queue daemon over a minimal Unix-socket protocol
instead of D-Bus/XDG-notifications, which would contradict the
no-systemd/no-D-Bus stance). The widget/notification review is also
what surfaced the `desktop_toplevel_at()` bug above.

Pointer/click input now reaches layer-shell surfaces: `novi-panel` has
a left-aligned "Apps" button (text label plus icon, see below) that
opens `novi-launcher` on click, the mouse-driven equivalent of
Alt+Space. The compositor-side routing turned out to already be
correct — `desktop_toplevel_at()` was always resolving the right
`wl_surface` for a layer-shell surface, even before the previous
commit's toplevel/layer-shell discriminator fix, since it sets that
out-param before the type check. The actual gap was purely
client-side: `novi-panel` never bound `wl_seat` or created a
`wl_pointer`, so nothing reached it regardless of what the compositor
sent. Live-verified in QEMU: hovering the button switches its
background/text color (bg-card-raised/text-secondary →
accent-subtle-bg/accent, per `GUI-DESIGN-LANGUAGE.md` §7), and a
press-then-release inside it reliably spawns the launcher.

New windows also no longer spawn hidden under the panel: every
`xdg_toplevel` used to map at the scene tree's default (0,0), directly
under the top bar's exclusive zone, so a window's top edge rendered
behind the opaque panel until the user moved it. `arrange_layers()`
already computed the output's usable area (full output box minus
layer-shell exclusive zones) on every layer-shell commit but discarded
it once the function returned; it's now stored on `struct novi_output`
and read back once, at toplevel creation, to set the initial position.
Live-verified with a pixel-exact column scan of a post-boot
screendump: the panel's background/border ends at row 31 and `foot`'s
own background/glyphs start cleanly at row 32, zero gap, zero overlap.

The next two items on `GUI-DESIGN-LANGUAGE.md` §8's leverage-ordered
list are also done, together: `novi-launcher` now composites real
alpha (`WL_SHM_FORMAT_ARGB8888` + pixman `a8r8g8b8`, replacing the
opaque `XRGB8888` buffer every client used before) and has real
rounded corners, punched into each of the four corner regions as a
per-pixel anti-aliased alpha mask rather than a placeholder cutoff.
Scoped to the launcher specifically, not the panel: §3 already calls
the top bar out as deliberately *not* rounded (edge-anchored chrome
touching three screen edges), while the launcher is exactly the
"floating card" the target mockup's rounded-corner language describes.
Verified live in QEMU: a zoomed screendump crop shows a real
anti-aliased curve at all four corners, with typed calculator text
still rendering correctly against the new buffer format.

Item 4 (drop shadows) is done too, following the same real, not
placeholder, standard: the card's rounded-rect silhouette, offset down
4px and feathered 16px outward per §4's elevation-1 spec, computed via
the standard 2D rounded-box signed-distance-field formula rather than
a precomputed sprite. Getting the layering right (the shadow correctly
peeking through the card's own transparent rounded corners, not erased
by them) needed alpha-*compositing* the card onto the shadow via
`PIXMAN_OP_OVER` instead of the previous raw-overwrite `draw_rect()`
calls. A real black-on-black shadow is mathematically invisible in a
plain-black-desktop screendump no matter how correct it is, so this
was verified with a temporary bright-color swap-in (reverted after): a
pixel-exact column scan confirmed the feather's 16-step linear
gradient and the bottom edge's exact 4px-sliver-then-16px-feather
shape, both landing precisely on the spec'd values with zero clipping.

Server-side window decorations (§6, item 6 of the design docs'
sequence, and the one piece of this window that's real compositor work
rather than client-side rendering) are also done: a title bar strip
above every toplevel plus a functional close dot -- "the one dot with
a real, already-implemented compositor primitive behind it" per the
design doc, since `wlr_xdg_toplevel_send_close()` already existed for
Super+Q. `wlr_xdg_decoration_manager_v1` is wired and answers
server-side to any asking client; `foot` genuinely asks (confirmed
live via its own "using SSD decorations" log line), so this isn't
speculative protocol plumbing for a hypothetical client. Building this
surfaced a second real, independent bug: a panel's exclusive zone was
silently never being applied to `usable_area` at all -- confirmed via
direct instrumentation showing it staying the full, unreduced output
size even tens of seconds after boot. Root cause (found by reading
wlroots' own scene-helper source, not guessed): the exclusive zone is
only applied when `surface->mapped` is already true, but the only
`arrange_layers()` call site that ever fires for a typical layer-shell
client (one that sets its geometry once, at startup) runs from the
*commit* handler, before mapping completes. This had been silently
masked in all earlier testing: the panel still visually draws over its
own reserved region regardless of what `usable_area` tracks, since
it's simply on a higher scene layer than toplevels -- so a window
placed as if there were no panel at all still *looked* right, by
z-order coincidence, not because its logical position was correct. The
gap only became observable once something (a title bar) needed the
exclusive zone value to be precise. Fixed by also re-arranging in
`layer_surface_map()`, where `mapped` is guaranteed true.

Design-doc §8's rendering sequence is now complete through item 6 of
6 -- text, alpha compositing, rounded rects, drop shadows, and server-
side decorations are all real, all live-verified. Item 5 (icon
rendering) has now started too: the icon-set "maintainer decision" it
was blocked on is resolved -- Lucide's `LICENSE` was fetched and read
directly from upstream (ISC + MIT, both permissive), not assumed from
training knowledge, unblocking `ICON-PIPELINE.md`'s recommendation.
`novi-panel`'s apps button now renders Lucide's `layout-grid` glyph
(four rounded-rect squares), hand-coded in C via the same rounded-box
SDF + stroke-coverage technique the launcher's drop shadow already
uses, live-verified in QEMU at both rest and hover (pixel-sampled
screendumps, not eyeballed) -- see `ICON-PIPELINE.md`'s "First icon
shipped" section for why this one icon qualified for hand-coding
instead of the full SVG pipeline (no SVG rasterizer available on this
build host, and four rounded rects is simple enough to reproduce
exactly by hand). The larger icon sets design-doc §8 still needs
(app-grid icons, status-bar wifi/battery/power) have real curves that
don't qualify for the same shortcut and remain blocked on standing up
the `tools/svg2icon/` offline pipeline `ICON-PIPELINE.md` proposes.

That pipeline is now built: `shared/icons/tools/svg2icon/` (host-only,
never cross-compiled, per `ICON-PIPELINE.md`'s Stage 1 recommendation)
vendors `nanosvg`+`nanosvgrast` (license read from upstream before
vendoring) and real Lucide SVG sources (provenance recorded, not
transcribed) to generate `shared/icons/icons_generated.c`: `terminal`,
`folder`, `globe`, `pencil`, `package`, `settings`, `shield` (app-grid)
and `wifi`, `battery`, `power`, `chevron-right`, `chevron-down`
(status/disclosure) — every icon this doc's design references named,
visually verified via the tool's own ASCII-art preview since there's no
compositor to boot for a host-only tool. `shared/icons/icon_blit.c`'s
`draw_icon()` (Stage 2) is built alongside it — real premultiplied
"over" compositing, matching `novi-launcher`'s existing drop-shadow
convention, verified against the real generated icon data with a native
test harness (exact pixel match on a fully-opaque draw including
clipped edges, correct strictly-in-between blending on a real
antialiased edge pixel).

That wiring is now done too, and QEMU-live-verified: `pkg-format.md`'s
`.app` descriptor gained an optional `icon=` field, `novi-launcher`
resolves it and calls `draw_icon()` next to a matched search result,
`foot`'s self-registered descriptor sets `icon=terminal`, and
`novi-launcher/Makefile` compiles `icon_blit.c`/`icons_generated.c`
straight in. Booted the ISO, switched to the `graphical` bundle,
Alt+Space, typed "foot" — a real, pixel-zoomed screendump shows the
actual generated terminal-icon bitmap rendered next to "-> Terminal" in
the result's own accent color, and Enter still opened a real `foot`
window afterward (no regression to the existing search/launch path).
Getting that boot to work at all surfaced two unrelated real bugs, both
fixed: `scripts/mkinitramfs.sh` never mounted anything at `/tmp` despite
`mkiso.sh` excluding it from the squashed image the same way it excludes
`/dev`/`/run` (which *are* mounted) — fixed, same tmpfs-alongside-the-
others pattern. And the documented `s6-rc -up change graphical` command
itself hangs indefinitely when actually run from `ttyS0` -- root-caused
(not just worked around): `-p` (prune) tells s6-rc to bring the live
state to *exactly* the target selection's closure, stopping everything
outside it first, and "graphical"'s closure is just
`novi-shell`+`seatd` -- so `-p` tries to stop `getty-ttyS0` (and
`getty-tty1`, `syslog`) as a side effect, including the very console
issuing the command. Confirmed two ways: `s6-svc -u` on `seatd` then
`novi-shell` directly (bypassing s6-rc's orchestration) brings both up
in seconds with no `-p` involved, and dropping the `p` --
`s6-rc -u change graphical`, layering up-only, no prune -- returns
immediately and produces the identical live compositor+panel. Fixed by
correcting the documented command (this section, above) and
`novi-shell/run`'s own comment; `init/skel/runlevel`'s generic
`s6-rc -up change "$1"` (used for real SysV-style full runlevel
switches, called once at boot for "default") is deliberately left alone
-- full-prune semantics are correct for an actual runlevel transition,
this was specifically the graphical bundle being layered on additively
rather than treated as one, and only the latter path is what
"switch to it by hand" ever meant.

The maximize dot the decorations landed with is now real too, not a
dimmed placeholder -- `GUI-DESIGN-LANGUAGE.md` had already flagged it
as "the more tractable of the two" remaining dots, and
`maximize_toplevel()`/`unmaximize_toplevel()` deliver on exactly that:
snap-to-usable-area plus a saved-geometry struct to restore on a
second click, shared by both the dot's click handler and a client's
own `xdg_toplevel_request_maximize()` (previously a stub). Minimize
stays dimmed and non-interactive, per the doc's own reasoning (no
taskbar/dock exists yet to restore to). Building this also surfaced
and fixed a real, silent bug in the dimmed dot's own color: wlroots'
`wlr_render_color` requires pre-multiplied RGB, and the first version
didn't, rendering the "dimmed" dot brighter than the full-strength
ones next to it -- confirmed via a pixel readback, not just eyeballed.
Also corrected an internally-inconsistent line in the design doc's own
dot spec ("8px gap between centers" for 8px-diameter dots, which would
overlap them by a full diameter) to 8px of edge-to-edge clearance.

`novi-launcher` now has real app search too, not just the calculator
fallback -- unblocked by defining the missing piece
`docs/PLATFORM-ROADMAP.md`'s own "Next concrete step" called out:
`packages/pkg-format.md`'s new "GUI Application Registration" section
gives `pkg` a "this is a launchable GUI app" concept without touching
`pkg`/`mkpkg` at all (a launchable app just ships one more file,
`usr/share/novi/apps/<name>.app`, extracted/removed automatically the
same as any other file in its `files/` tree). `load_apps()` scans that
directory at startup, `find_app_match()` matches typed input against
either the descriptor's filename (`foot`) or its display name
(`Terminal`) -- both need to work, since a user searching for an app
they know by binary name shouldn't fail just because the display name
reads nothing like it, confirmed live in QEMU: typing "foot" alone
initially matched nothing (only "Terminal" did, name-only matching's
real gap, not a hypothetical one) until id-matching was added, fixed,
and re-verified. `launch_app()` does a real `fork()`/`execvp()` on
Enter, no shell involved. No package ships a `.app` descriptor yet
(no real GUI apps are `pkg`-installed), so `foot` -- baked into the
base rootfs by `build/09-foot.sh`, not `pkg`-installed -- registers
itself the same way a real package would, giving this an actual
launchable app to search for and exercise rather than untestable
plumbing. Live-verified end-to-end in QEMU: typed "foot" or "Term"
both surface "-> Terminal" below the input (screendump-confirmed, not
assumed), and Enter closes the overlay and opens a real interactive
foot window with a live shell prompt. Also required relaxing
`novi-launcher`'s typed-input filter, previously restricted to the
calculator grammar's character set (digits/operators only) -- app
names need letters, which that filter rejected outright before this.

Super+. (RFC 0001 decision 7's "emoji/symbol picker") is now wired too
-- the symbol half only: JetBrainsMono-Regular.ttf's own cmap was
checked directly (via fontTools, not assumed) and has zero glyphs
anywhere in the Unicode emoji blocks, so rendering real emoji would
mean silently showing tofu boxes instead. `novi-launcher --symbols`
(same binary, same card/shadow/font chrome as Alt+Space, a new mode
rather than a duplicate client) searches ~50 real Unicode symbols this
font does have glyphs for (arrows, math, currency, quotes, box-drawing,
checkmarks), and Enter copies the match to the clipboard via the
standard core-Wayland `wl_data_device_manager` novi-shell already
creates (`wlr_data_device_manager_create()` predates this feature --
zero new compositor-side protocol work). Live-verified in QEMU end to
end, including the actual clipboard bytes: Super+., typed "arrow
right", Enter, then opened a real `foot` window and pasted into `od -c`
-- `0000000 342 206 222`, the exact correct 3-byte UTF-8 encoding of
U+2192, not just "something got copied." Getting the glyph to render
correctly at all surfaced a real, previously-invisible bug along the
way: `common/text.c`'s `novi_text_draw()`/`novi_text_width()` treated
every byte of the input string as its own codepoint (fine for the
ASCII-only callers that existed before -- the panel clock, calculator
operators -- silently wrong for anything requiring a multi-byte UTF-8
sequence, like a real arrow glyph, which rendered as three-character
mojibake). Fixed with a real UTF-8 decoder in `common/text.c`, shared
by every caller (`novi-panel`, `novi-launcher`); re-verified live that
the panel clock and app-search icon rendering were unaffected.

**Still open**: file search (indexed filesystem lookup) still doesn't
exist, and no package installs a `.app` descriptor yet since no real
GUI apps are packaged -- app search has two real entries (`foot`,
`novi-settings`) baked into the base rootfs directly, still none
installed via `pkg`; `novi-settings` itself is Account/password only,
keyboard-only (no `wl_pointer` click-to-focus yet), and a single-panel
app with no sidebar/multi-section navigation to extend into yet; RFC
0001 decision 7's entire default
keybinding set is now wired, but workspaces are per-server, not the
RFC's own per-output framing (see §5 body's own scoping note -- real
multi-output support doesn't exist anywhere else in this compositor
either); PrintScreen screenshots are wired but v1-scoped (whole-output
only, file-only, BMP not PNG -- see above); Super+L lock has no
rate-limiting/backoff on repeated wrong attempts yet (a real follow-up,
not urgent on a local single-user system with no network exposure to
brute-force); moving keybindings to RFC 0001's
user-editable config file instead of compiled-in defaults;
hardware-accelerated rendering (GLES2/Vulkan via Mesa) is out of scope
for this milestone and stays pixman-only until that's picked up
separately; the app-grid icon set is generated and wired (see above) but
only exercised for `terminal` so far (the one real `.app` descriptor);
status-bar icons (wifi/battery/power) have generated bitmaps too but
stay unwired, blocked on real wifi/battery data sources that don't exist
yet, independent of the icons themselves.

**Adjacent idea, not started**: decentralized, radio-agnostic mesh
networking (Reticulum-style — cryptographic identity as the address,
transport-agnostic routing over anything from LoRa to Wi-Fi to plain
IP) is a strong philosophical fit for this project's "own the platform,
no infrastructure you don't control" stance, and ties directly to §12's
security/pentest track. Not scoped yet: the reference implementation
is Python, a materially different kind of dependency than anything
built so far (wlroots, foot, etc. are all plain C, no scripting
runtime anywhere in this rootfs). Worth its own track when picked up,
starting with Reticulum-over-IP (needs only a socket, no new radio
drivers) before any LoRa/HaLow hardware work.

### Terminal / CLI environment

The GUI is a layer *on top of* a fully capable CLI, never a replacement
for it — this is the principle that makes "does what Arch's terminal can
do" compatible with also having a GUI, instead of the two competing:

- **Base userland stays BusyBox** (§1) for the minimal boot/install-stage
  rootfs — that's the right minimal default for a live image.
- **Full GNU coreutils/util-linux/bash become an ordinary `pkg install`**
  for any real interactive system (both stable and advanced tracks) —
  same split already implicit in the track model (§3). This closes the
  capability gap noted in §1 without bloating the base image.
- **`pkg` needs pacman-grade CLI ergonomics**: fast, scriptable, clear
  output. The dependency-resolution bones already exist
  (`packages/pkg-format.md`); an AUR-equivalent community-repo story is a
  later addition once the native/sandboxed split (§2) has real traction.
- **`novi-shell` (RFC 0001) defaults to a real terminal emulator** and
  never gates a system operation behind GUI-only tooling — service
  control (s6-rc), package management (`pkg`), and configuration all stay
  scriptable from the shell first. GUI panels are thin wrappers calling
  the same CLI underneath, not a separate code path with separate
  capabilities.

### Application toolkit (GTK4 / Libadwaita, at the user's discretion)

RFC 0001 designs `novi-shell` — the compositor and session shell — but says
nothing about what toolkit the *apps* running inside it are built with. The
app-launcher mockup (files, editor, settings, pkg) currently has icons and
no implementation. **Proposed:** GTK4 + Libadwaita as the recommended
convention for first-party apps bundled with the desktop track, not a
system dependency:

- **Why Libadwaita specifically**: its adaptive-widget/breakpoint model,
  calm-by-default views with progressive disclosure, and system light/dark
  + accent-color following line up directly with the design framework
  already applied to the `novi-shell` mockup (one accent used sparingly,
  restrained type scale, native-feeling chrome over custom-drawn UI). It's
  also what the GNOME HIG is built around, so first-party apps get a
  tested, documented pattern language for free instead of us inventing one.
- **At the user's discretion, not mandated**: this is a convention for
  *this repo's own* apps, the same way BusyBox vs. full coreutils is a
  track choice (§3) — nothing about the sandboxed-app model (§2) requires
  GTK4/Libadwaita, and a user (or a third-party package) is free to ship a
  Qt, raw-GTK, or toolkit-less app the same way. `pkg` doesn't gate on
  toolkit choice; this only decides what *we* reach for first when we build
  the first-party files/editor/settings apps the launcher mockup implies.
- **Consistent with §4's hardware principle**: GTK4 apps render through
  the same open Wayland/DRM/KMS stack `novi-shell` already targets (§4's
  amdgpu/i915/class-driver approach), not through any vendor-specific
  rendering path — so "which GTK apps run well" tracks "which GPU speaks
  the standard," the same manufacturer-agnostic property §4 already
  establishes for the kernel. Nothing here narrows what hardware the
  desktop experience runs on.
- **What re-implementing it ourselves would actually cost**: Libadwaita
  already solves adaptive layout (phone/tablet/desktop breakpoints),
  light/dark and high-contrast switching, correct touch/keyboard/pointer
  input handling, accessibility (screen readers, focus order, contrast),
  HiDPI and text-scale handling, and the long tail of window-management
  edge cases — each individually a real, multi-month problem, and
  collectively a multi-year one to get right from scratch. This is the
  same "own the platform, don't reinvent already-solved problems" judgment
  the philosophy section states for the base OS (musl/s6/BusyBox are
  reused *source*, not reinvented from zero) — a from-scratch app toolkit
  would quietly inherit exactly the class of bugs (broken screen-reader
  focus, wrong behavior at odd DPI scales, subtly wrong touch targets)
  that a toolkit with years of real-world use has already found and fixed.
  novi-shell itself (the compositor) still owns its own custom UI — this
  argument is specifically about the *apps* running inside it, where
  reuse is free and reinvention is not.

**Open:** whether to adopt Libadwaita's exact visual language verbatim or
restyle it against `novi-shell`'s own token system (accent color, spacing
unit) once one exists as committed CSS rather than a mockup.

---

## 6. Gaming Strategy

**Open, depends on §5.** Once a compositor exists, the concrete path is:
Proton/Wine via the sandboxed-app tier (§2) rather than native ports,
`gamescope`-style micro-compositor for the game session, and Mesa drivers
shipped as `pkg` packages tracking the kernel's GPU driver support (§4).
No RFC yet — blocked on the desktop RFC landing first.

---

## 7. Developer Strategy

**Decided (partially):** the musl+GCC 14.2 cross-toolchain used to build
Novi itself already exists (`build/02-toolchain.sh`) and is a real,
usable native dev toolchain, not just a build-system implementation
detail.

**Proposed:** expose dev toolchains (language runtimes, glibc-compat
containers for tools that assume glibc) through the container tier in §2,
so `pkg install <lang>-toolchain` is the on-ramp instead of asking devs to
hand-roll a musl cross-compile setup.

---

## 8. Enterprise Strategy

**Decided:** `stable/*` branches in `docs/branch-strategy.md` already
encode LTS intent (2 reviewers, CI required, maintenance branches per
minor version). `build/signing/` exists as a directory for package
signing keys.

**Proposed:** package signing enforced by default in `pkg` (verify before
install, not just on repos that opt in), and a fleet-management story
(config baseline + `pkg` repo pinning per stable branch) — this is what
turns "stable track" into an actual enterprise offering rather than just
a slower release cadence.

---

## 9. Security Model

**Decided:** small TCB by construction (musl + s6 + BusyBox has far less
attack surface than glibc + systemd + full GNU userland), s6 supervises
services in the foreground with no unmonitored background daemons
(`CONTRIBUTING.md` §"s6 & Service Definitions"), `SECURITY.md` defines a
disclosure process, `docs/branch-strategy.md` has a private `security/*`
branch flow with CVE assignment.

**Proposed:** package signature verification as a hard default (ties into
§8), and sandboxing as the default posture for the desktop-app tier in
§2 (deny-by-default filesystem/network access, not opt-in).

---

## 10. Community / Governance Model

**Decided:** RFC process for architectural changes (`CONTRIBUTING.md`),
`CODEOWNERS`, Conventional Commits, issue label taxonomy, `CODE_OF_CONDUCT.md`.
This is the most mature area of the project relative to the others —
governance is ready for the areas above to start generating RFCs.

---

## 11. What Makes Novi Different

**One source of truth for the whole system —
[`/etc/novi/system.conf`](../rootfs/etc/novi/system.conf) — that the GUI
and the text editor both write, with real diff and real rollback.**
That's the differentiator. Everything else in this doc is good
architecture; this is the part nobody else has.

### First, honestly: what is *not* a differentiator

This section used to claim it was "separating concerns other distros
bundle together" — small native base, breadth via sandboxing, two
update tracks. That's a sound architecture and it stays. It is not
distinguishing, and pretending otherwise helps nobody:

- Small immutable base + sandboxed apps *is* Fedora Silverblue, SteamOS
  3, Vanilla OS, blendOS, ChromeOS. It's the industry consensus now.
- Two update tracks *is* openSUSE Leap/Tumbleweed, Fedora
  stable/rawhide, Debian stable/sid.
- From-scratch musl + s6 *is* Alpine, Void, Chimera, Adélie, oasis, KISS.

Each of those is a real project with years of head start. "We did it
too, from scratch" is not a reason for anyone to switch.

### The gap nobody has closed

On every mainstream Linux desktop, **the GUI and the config files are
two parallel, unreconciled sources of truth.** Toggle something in
GNOME Settings and it goes to dconf: binary, ungreppable, absent from
your dotfiles, undiffable, unversioned, and unknown to the config file
that nominally governs the same thing. Edit the config file and the GUI
has no idea. They drift silently, forever. No command answers "what is
actually configured here, and what changed since Tuesday."

NixOS and Guix genuinely solve determinism — **by amputating the GUI to
do it.** Configuration is a functional-language text file; no
first-party GUI writes the system's truth, and the settings apps that
exist fight the model. The current price of reproducibility is "give up
the graphical settings surface, and learn a language."

Novi's position: **you shouldn't have to choose.** Clicking a toggle and
editing a text file should be the same operation on the same document.

### Why Novi specifically can do this

Because it owns every layer with no upstream to negotiate with: s6-rc
(already a declarative dependency graph), `pkg` (already has an install
DB), `novi-shell`, and `novi-settings`. The four layers that would each
have to cooperate on any other distro are all in this one repo. There's
no GNOME release cycle to petition and no dconf to work around.

It's also the machinery behind a Philosophy commitment that was
otherwise just a stated value — **"user control over their own
machine"**: a system that never hides what's configured, and an update
model the user drives. `novi-state diff` is what makes that checkable
instead of aspirational.

### What exists today

`novi-state` (RFC 0002) is built and QEMU-verified, not proposed:
`show` / `diff` / `apply` / `rollback` / `history`, with `hostname` and
`services.*` domains live. Verified end to end on a clean boot — a
fresh machine reports converged (exit 0); declaring
`services.novi-shell = on` and running `apply` **brought the desktop
into existence from a text file** (screendump-confirmed); `rollback`
took it back down (pixel-confirmed). Generations snapshot *observed*
state, so rollback restores where the machine really was — and rollback
is itself reversible.

**And the GUI is a real front-end to that same file**, which is what
makes the claim demonstrable rather than merely stated.
`novi-settings`' System panel lists every declared key, **marks the
ones the running system doesn't match** (no other desktop's settings
app can show drift, because none has a declared state to compare
against), toggles with Space and applies with Enter. Verified both
directions live: a GUI toggle changed `system.conf` on disk *with the
surrounding comments intact* and left the running system alone until
Enter — then applied it and wrote a generation, so a GUI change is as
rollback-able as a CLI one. And a `sed` hand-edit made in a terminal
showed up in the GUI, flagged as drift, with no reload key pressed.

Writes go through `novi-state set` rather than the GUI writing the file
itself, deliberately: one writer means one behavior, and the comment
preservation can't drift between two implementations.

**And the machine now boots into the declared state**, which is what
makes the document govern the system rather than merely describe what
you could push it to. Verified from cold boots: an image whose document
declared `services.novi-shell = on` came up in a full graphical session
with **zero input** — no login, no commands — while the stock
console-first default boots converged and doesn't even burn a
generation doing nothing. Safety is what makes that defensible by
default: convergence can never fail a boot (it always exits 0), and
`novi.state=off` on the kernel command line skips it entirely for when
the declared state is itself what's wrong — verified too. Flipping the
shipped image from console-first to desktop-first is now literally one
line in that file.

One thing stays out of the document on purpose: the Account panel still
writes `/etc/shadow` directly, because a password hash has no business
in a world-readable file this section actively encourages committing to
git. Secrets keep their own 0600 store, and the panel says so on
screen. `system.conf` is for configuration.

### And this serves all four audiences at once

Everyday users get a real undo. Developers get `git commit` for their
machine. Security practitioners get "has anything on this box changed"
as an audit primitive and a clean known state after an engagement
(§12). Gamers get to try the risky driver tweak and revert cleanly. One
mechanism, four use cases — which is what the Philosophy section means
by one rootfs serving all four, rather than four spins.

### The architecture underneath (unchanged, still true)

One rootfs/pkg foundation, two update tracks (§3) instead of forcing
rolling-vs-stable as a distro-choice decision, and an application model
(§2) that keeps the native package set small while still giving users
glibc-world app availability through sandboxing — without the user ever
needing to know which tier an app came from. Good architecture, and the
foundation the above is built on; just not, by itself, the reason to
pick Novi.

---

## 12. Security Tooling / Pentest Track

**Open.** Distinct from §9 (Security Model, which is about Novi itself
being secure by default) — this is about giving security practitioners
the curated offensive/defensive toolset that Kali/BlackArch/Parrot OS
users rely on (network analysis, password/forensics tooling, exploitation
frameworks, etc.), for legitimate security testing and research use.

**Proposed shape:** an opt-in `pkg` repo/meta-package layered on top of
the standard install — the same relationship BlackArch has to plain Arch,
or Kali's tool metapackages have to its Debian base — rather than bundled
into the default image:

- Default install stays lean (no security-tools bloat for users who don't
  need them), consistent with §1's "no bloat" ethos and the native/
  sandboxed split in §2.
- `pkg install novi-security-tools` (or individual tools) is the on-ramp
  for anyone doing pentesting/security work — same ergonomics as any
  other `pkg` install, no separate spin/ISO required to start.
- A dedicated **live/forensics boot mode** (analogous to Kali's live USB
  forensics mode — no writes to host disk, no swap auto-mount) is a
  natural fit for the `advanced` track (§3) once on-device rollback
  exists, but isn't required to ship the toolset itself.
- Tool packaging follows the same signing/verification story as §8/§9 —
  a security toolset with unverified packages would undermine the point
  of shipping one.

No RFC yet — this is packaging/repo-content work once `pkg`'s
sandboxed-app tier (§2) and signing-by-default (§8, §9) land, not a
base-architecture change, so it likely doesn't need the RFC weight §5's
compositor choice does.

---

## 13. Installation & Persistence

RFC 0003. Novi is installable onto a disk and remembers what you do to
it. Before this, the ISO was RAM-only — a squashfs with a tmpfs overlay
— so every claim `novi-state` makes about generations, rollback and
booting into a declared state was being made by a machine with no
memory.

The design constraint worth recording here, because it recurs: the
installed userland is a static BusyBox with no GRUB tooling and no
intention of acquiring any. So `grub-install` is **split across build
time and install time** — `scripts/mkiso.sh` runs `grub-mkimage` on the
build host and stages `boot.img`, `core.img` (prefix
`(hd0,msdos1)/boot/grub`) and the i386-pc module set into `/novi-boot`
on the ISO; `packages/novi-install` only *places* them, with two `dd`s
and a `cp`. Generation needs a build host. Placement does not.

The same split is the pattern to reach for whenever the target needs
something only a build host can produce.

Scope of v1, stated rather than discovered: BIOS/MBR only (UEFI/GPT is
the right long-term default and is deliberately not first — an
unverified installer is worth less than no installer), one ext2
partition with no journal (BusyBox `mke2fs`; the kernel mounts it with
the ext4 driver via `CONFIG_EXT4_USE_FOR_EXT2=y`), and the installed
system inherits the live session's users, which today means root-only.

Verified in QEMU end to end, not reasoned about: install onto a blank
disk, cold-boot from that disk through SeaBIOS → GRUB-from-the-MBR →
the generated menu, `mount` reporting a real writable `/dev/vda1` root
with no overlay, `novi-state diff` clean (so boot convergence works on
an installed system), a marker file surviving a full power cycle, and a
live ISO boot with the installed disk attached still taking the live
path. Details and the bug it surfaced — a live-media bind mount that
had been silently buried under a later `mount --move` for as long as it
had existed — are in RFC 0003.

Two things fell out of doing this that are worth their own mention.
`bash build.sh` now runs **every** `build/NN-*.sh` stage instead of
stopping at 05: the desktop, the package tooling, `novi-state` and the
installer all existed but were never reached by the one command the
README tells people to run. And the generated boot menu ships the
`novi.state=off` recovery entry, so RFC 0002's promise that a
lock-you-out declared state is escapable from the bootloader is
something you can select rather than something you have to know.

## 14. Networking & System Logging

RFC 0004. A Novi machine reaches the network, and tells you what
happened to it. Neither was true before.

Networking is one supervised `udhcpc` (`-f`, foreground, so s6
supervises the real process) plus the lease hook BusyBox does not ship
— without which the client negotiates a perfectly good lease and
applies none of it. It is declared like everything else, through a
`network.*` domain: `network.dhcp`, `network.interface`,
`network.dns`. There is deliberately no `services.network` key; two
keys governing one service is the split-brain §11 is about.

The observer design there is worth copying elsewhere. The running
service records the spec it was *started with* under `/run/novi`, and
that is what `diff` observes — so changing `network.interface` shows up
as real drift and `apply` restarts the service to make it true, instead
of the change silently doing nothing until the next reboot.

Two departures from what every other distro's DHCP hook does, both on
purpose: it never sets the hostname from DHCP (the hostname has exactly
one writer, and it is the document), and it writes the resolver to
`/run`, not `/etc` (a lease is runtime state; `/etc/resolv.conf` is a
symlink to it).

Logging was the more embarrassing gap, because it existed on paper. The
`syslog` service ran `s6-log -d3 … /var/log/syslog` and was broken two
ways at once: `-d3` asks for readiness notification on fd 3 while the
service declared no `notification-fd`, so it crash-looped invisibly —
s6-rc's "up" for a longrun means "supervised and wanted up", not
"running" — and even fixed, s6-log reads its *stdin*, so as a
standalone service it was a log file with no writers. It is now
BusyBox `syslogd` (owning `/dev/log` and `/var/log/messages`) plus a
`klog` service feeding it the kernel ring buffer.

Having a log immediately paid for itself twice:

- It exposed a boot-time race that had been manufacturing a
  `novi-state` generation on **every single boot** — `s6-rc change`
  returns as soon as a longrun is *started*, `rc.init` runs boot
  convergence the moment it returns, and convergence was observing a
  service that had not finished recording its own state yet, calling it
  drift, and restarting it. Fixed with a real readiness notification.
  Generations have to mean "the system actually changed here" or their
  history is worthless.
- It exposed eight `virtio_net: Unknown symbol` lines per boot from
  racing module loads — invisible before, because the driver did end up
  loaded and working.

Verified on both a live boot and an **installed** disk: address, route,
resolver, `ping`, a real `nslookup` answer, `logger` round-tripping
through `/dev/log`, kernel lines via klogd, `novi-state diff` clean with
an empty generation history on a fresh boot, zero `Unknown symbol`
lines, and `/var/log/messages` growing from 739 to 1106 lines across a
reboot — logs that survive a power cycle, which is the difference
between a log and a scrollback buffer.

## 15. Users & Accounts

RFC 0005. Novi had exactly one account -- `root`, with an empty
password -- on the live image and on every machine installed from it.
Defensible for a live ISO (an installable image nobody can log into is
useless), indefensible for an installed machine.

Three things were missing, not one: a group database (`/etc/group` held
the single line `root:x:0:` -- no `tty` for getty to chown a terminal
to, no `video`/`input` for a desktop session run as anyone but root, no
`wheel`), a way to *declare* an account, and `/etc/shadow` in the build
at all -- no stage had ever created it, so a genuinely clean build
produced an image with no shadow file.

`users.<name>.shell` is the anchor key: declaring it creates the
account, `absent` removes it. Removing an account never deletes the
home directory -- removing an account is a configuration change,
deleting someone's files is not, and a declarative engine that quietly
does the second while you asked for the first is one nobody should
trust with root.

**The rule this section establishes for the whole platform:
configuration is declared; secrets are not.** No password hash goes
into `system.conf` -- it is world-readable and §11 actively encourages
committing it to git. NixOS permits `hashedPassword` in
configuration.nix and warns about it; a project whose pitch is "commit
your machine's configuration" cannot rely on a warning, the design has
to not offer the footgun. Secrets keep their own 0600 store and their
own tools, exactly as `novi-settings`' Account panel already did.

`novi-install --user alice --set-root-password` creates the account
*while installing* -- with a password (sha512, not BusyBox's DES
default, which truncates at 8 characters and would silently make a long
password weak), in `wheel,users,video,input,audio,seat` -- and then
declares the same two keys in the new machine's `system.conf`. So the
machine is usable on its first boot rather than after a root login,
*and* the account is part of the document that governs it. If root is
still passwordless when the install finishes, the installer says so
loudly rather than shipping a machine anyone at the console owns.

Adding this exposed a real flaw in the convergence engine: keys are not
independent. `users.X.groups` is not applicable until `users.X.shell`
has created the account, and `state_keys` is sorted, so `.groups` was
visited first -- one sweep left the account created with no groups and
the very next `diff` reported drift the `apply` had just been asked to
fix. `apply` now converges in bounded passes, which generalizes to
every future domain instead of encoding one special case in a sort
order.

It also exposed two build bugs of the same shape, both latent re-run
hazards, both producing images that failed at boot with no build-time
signal: `03-base.sh` stripped kernel modules with `--strip-all`
(removing `.symtab`, leaving every module unloadable -- all 22 of
`/init`'s `modprobe` calls failed, no `virtio_blk`, no `/dev/vda`,
PANIC), and it handed PID 1 back to BusyBox init (`can't run
/etc/init.d/rcS`). Clean `01..05` ordering hid both. `bash build.sh
--from NN` exists and people will use it.

Verified live: a declared account created with every group in one
`apply`, created locked, `su - alice` into a real login shell after
`passwd`, removal leaving `/home/alice` in place, `rollback` restoring
account and groups, and a cold boot from an installed disk **logging in
as alice** with the password the installer set.

## 16. Package Repository & Signing

RFC 0006. `pkg` and `mkpkg` had worked for a while and there had never
been anything to point them at. There is now: a signed repository, a
network fetch path, a cryptographic trust root on the target, and
`packages.*` in the declared state.

The design decision that matters: **a package manager downloads code
and runs it as root**, so "the transport handed it to me" cannot be the
trust root. Novi's base image deliberately has no OpenSSL, no GnuPG and
no libsodium, and BusyBox's built-in TLS does not validate
certificates -- so "just use HTTPS" was not available even as a weak
answer. The base image gets a ~60 KB Ed25519 verifier instead of a TLS
stack: `novi-verify`, built on TweetNaCl (public domain, by the NaCl
authors), vendored unmodified and **hash-pinned** -- the only pinned
source in the project, because it is the only one that is itself the
trust root.

One signature over the index; every package's SHA-256 inside it. That
authenticates the whole repository with one signature, survives
mirroring and offline media in a way TLS does not, and means
`pkg install` re-checking a hash extends that signature to each
archive. A missing signature is not weaker than a wrong one -- both
fail, and the decision lives in exactly one function.

The index is one line per package, pipe-separated. `pkg` is BusyBox
ash: finding a package is `grep "^name|"` and parsing it is one
`IFS=| read`, with no state machine to get subtly wrong. It stays
greppable and diffable, which is the property this project keeps
choosing.

`packages.<name> = present | absent` puts installed software into the
same document as everything else -- same diff, same generations, same
rollback. That is what makes §11's claim true of the whole machine
rather than only of its configuration. It also makes the GUI's blocking
`novi-state` calls matter for the first time: a package install is the
first converger slow enough to be felt.

The repository's first content is the desktop -- `foot`, `fcft`, and
Novi's own shell/panel/launcher/settings/lockscreen/screenshot -- built
from exactly the binaries the earlier stages produced, so image and
repository cannot drift. They are still in the base image too;
splitting them out is the next step and what makes §2's "small native
base" real rather than described.

This surfaced three bugs, one of them a lesson worth keeping: **`/dev/fd`
did not exist on the shipped image**, so every `< <(process
substitution)` in `pkg` failed -- and not fatally, so dependency
resolution printed an error and carried on having resolved nothing.
`pkg`'s own comment said the construct was "verified working against
the real busybox binary this repo builds", and it was, on a *host* that
has a `/dev/fd`. Testing the shell answered a different question than
testing the image. (The others: `mkpkg` exited 141 after succeeding,
because `tar | head -5` plus `pipefail`; and `mkrepo`'s newline check
was `*"$(printf '\n')"*`, which is `*""*`, which matches everything.)

Verified live against a repository served over HTTP, including both
tamper cases: a package with one flipped byte failed its SHA-256 and
was discarded, and an index with an appended package line failed its
signature and left the previous index in place.

## 17. The Base/Desktop Split

RFC 0007. §2 of this document describes a small native base with
everything else delivered as packages. RFC 0006 built the repository;
this is the part that actually took something *out* of the base. Until
now the desktop was in the image AND in the repository -- the
architecture described rather than the one shipped.

The gap was not cosmetic. A console-only machine -- a server, a build
host, the thing a "small native base" is for -- was carrying a Wayland
compositor, wlroots, libdrm, pixman, fontconfig, freetype, a font
family and a terminal emulator it would never run. And the package
system, with nothing load-bearing to carry, was decoration.

**What leaves is computed, not listed.**
`tools/pkgsplit/pkgsplit.py` takes `closure(NEEDED)` from the desktop
binaries, subtracts `closure(NEEDED)` from everything else that ships,
and fails the build if anything staying behind still links against
anything moving out. Inter-package `depends=` is derived the same way:
`wlroots depends on libdisplay-info, libdrm, libinput, libudev,
libxkbcommon, pixman, seatd, wayland` is read out of the binaries, not
typed in. A hand-written list is how a split rots -- someone adds a
library in a build stage, nobody updates the list, and the
"console-only" image quietly grows a Wayland stack again.

**But the graph is not the only input, because it cannot see dlopen.**
libdrm loads libdrm_amdgpu/nouveau/radeon by name at runtime and
libwayland-egl has no in-image consumer, so nothing NEEDed them and the
first split left all four sitting in a "console-only" base. Found by
looking at what was left behind, not by reasoning about it. So there
are two inputs with different jobs: the graph finds what is reachable,
the package table claims what is ours, and a file matching neither is a
hard error rather than a guess.

The exercise turned up something worth recording on its own: the base
image was carrying **build-time tooling** that `make install` had
dropped in -- `fc-cache`, `fc-list`, `libinput`, `mtdev-test`,
`di-edid-decode`, `xmlwf`, `wayland-scanner`. While those sat in
/usr/bin they counted as part of the base, so fontconfig, freetype,
libinput, libudev, libevdev, libmtdev, expat and libdisplay-info all
counted as "needed by the base" and could never move. Eight libraries
held in a console image by eight programs nobody would run on one. The
split only became possible once those were named as desktop-side too.

After it, `/usr/lib` in the base contained exactly one library:
`libskarnet`, which s6 needs. (Two milestones later it holds three --
`libnl` arrived with the WiFi supplicant in §19 and `libasound` with
audio in §21. That is the split working, not the split eroding: both
belong to a console system, and the ELF-graph computation is re-run
every build rather than frozen at a number someone was proud of.)

**Console-only base does not mean network-only desktop.** The ISO
carries the whole signed repository at `/novi-repo` and the shipped
`pkg.conf` points at `/run/live/novi-repo`; `pkg` treats a mirror
starting with `/` as a local directory. Same index signature, same
per-package SHA-256; only the transport differs. So `pkg install
novi-desktop` on a live system with no network at all resolves and
installs 25 packages in about seven seconds -- and `novi-install
--profile desktop` (the default) does the same into the target, in a
chroot, then declares `packages.novi-desktop = present` and turns the
session on, so a fresh install boots graphical AND reports no drift.

A live ISO that could only show a console would be a real regression,
so the "Live Desktop" menu entry passes `novi.live.desktop` and rc.init
installs the desktop into the tmpfs overlay during boot. It is the
package system demonstrating itself rather than being described.

One more bug the work exposed, in the network service: **"the first
interface that is not lo" picked `sit0`**, the IPv6-in-IPv4 tunnel
pseudo-device a CONFIG_IPV6_SIT kernel creates at boot, which sorts
before `eth0`. Confirmed live -- "network: using sit0", then udhcpc
broadcasting DISCOVER forever down a tunnel with no link.
`pick_interface()` now requires ARPHRD_ETHER.

## 18. UEFI Installation & a Journalled Root

RFC 0008. RFC 0003 shipped an installer with two limitations stated up
front -- BIOS/MBR only, and a journal-less ext2 root -- and between
them they meant **Novi could not be installed on a typical machine, and
should not be trusted with data on one.**

Essentially every machine built since about 2012 boots UEFI by default.
BIOS-only is not a missing convenience; it is "this operating system
does not install on your laptop", and everything else in this document
is worth nothing if it cannot get onto a disk. And BusyBox's mke2fs
writes ext2: on real hardware an unclean shutdown becomes a full fsck
and a genuine risk to data, where a journal replays a few seconds of
log. That is a correctness gap, not a missing feature.

**The reason UEFI had been deferred was a stale belief.** OVMF was
recorded as "pathologically slow" in this project's sandbox -- but that
slowdown had been bisected to USB controller emulation and never
re-tested without it. A UEFI boot of the ISO reaches a login prompt in
**17 seconds**. Worth writing down as a pattern: a measurement kept as
a fact, past the point where the thing it measured had been fixed.

BusyBox can neither write a GPT (its fdisk reads one and cannot create
one) nor make a journal, and the target has no sfdisk, sgdisk or
parted. So two additions:

- **`novi-gpt`**, a small static C program that writes exactly one
  layout: a 512 MiB EFI System partition and a Linux root. Deliberately
  not a general partitioner -- a tool that can express every layout is
  a tool that can express the wrong one, and this runs at the moment a
  disk is being repartitioned. Verified against tools that did not
  write it: util-linux `partx` plus an independent parser checking all
  three CRCs, the protective MBR and both type GUIDs.
- **e2fsprogs**, installed selectively as `mke2fs.e2fsprogs` beside
  BusyBox's applet rather than over it -- and pointedly NOT installing
  its `blkid`/`findfs`/`fsck`, which BusyBox already provides and which
  other parts of this system parse the exact output of.

The alternative to GPT was an ESP on an MBR label with type 0xEF.
Plenty of firmware boots that, OVMF included -- which is exactly the
problem. It would have passed the test here and failed on somebody's
laptop, and "works on my emulator" is not a claim to make about the
program that partitions your disk.

`BOOTX64.EFI` goes to the removable-media path `/EFI/BOOT/`, not a
vendor directory plus an NVRAM entry: no efibootmgr, no writable EFI
variables, and it survives firmware forgetting its boot order -- which
is most firmware, eventually.

Two bugs surfaced, both of the same "described but not real" shape this
document keeps finding:

- **The kernel had no character sets.**
  `CONFIG_FAT_DEFAULT_CODEPAGE=437` was set with every `NLS_*` symbol
  unset, so `mount -t vfat` would fail with "Unable to load NLS charset
  cp437" -- the ESP could not have been mounted at all. It had also
  been quietly breaking the initramfs's vfat fallback for live media,
  unnoticed because the ISO9660 path always matched first.
- **Nothing had ever read `/etc/fstab`.** s6-linux-init's stage 1
  mounts the kernel-owned filesystems and stops, so the fstab the
  installer writes was documentation. Confirmed on the first successful
  UEFI install: `/boot/efi` existed as an empty directory and the ESP
  named in fstab was simply not mounted -- a kernel update would have
  written the new image to the root filesystem and left the firmware
  booting the old one. `rc.init` now runs `mount -a`.

Verified both ways: a UEFI install under OVMF cold-booting from its own
disk with the ISO detached (`/sys/firmware/efi` present, `/dev/vda2`
ext4 with `has_journal` and `journal_checksum_v3`, the ESP mounted at
`/boot/efi` with `codepage=437`, 25 packages, desktop up, declared
state clean, a marker surviving a further reboot), and the BIOS/MBR
path re-verified unchanged.

Secure Boot is the notable gap: `BOOTX64.EFI` is unsigned, so a machine
with Secure Boot enabled refuses it. That needs a shim, a key somebody
enrols, and a decision about whose key.

## 19. WiFi

RFC 0009. RFC 0008 made Novi installable on real hardware; a laptop
with no Ethernet port then installs perfectly and cannot reach the
package repository, which is the delivery mechanism for the desktop and
everything else past the base image. WiFi is what makes the rest of
this document reachable on the machines people actually own.

wpa_supplicant, built with **internal crypto** so it links no OpenSSL --
the base image has none, and `novi-verify` (§16) exists precisely so
that stays true. Adding a TLS stack in order to get onto a network
would undo that in one step. iwd was the alternative and is rejected:
its control interface is D-Bus, which would drag a message bus daemon
into a base image whose whole point is that it does not have one.

**No WPA3, stated rather than discovered.** SAE and OWE need
elliptic-curve crypto that internal TLS does not implement -- it links
cleanly up to `undefined reference to crypto_ec_get_prime`. The real
answer is mbedTLS (small, self-contained, has EC, supported by
wpa_supplicant 2.11) and it is its own piece of work. WPA2-Personal and
WPA2-Enterprise cover essentially every network in service and WPA3
routers run transition mode, so this connects to those too -- but not
to a WPA3-only network.

**The credentials are the interesting part**, and they are §15's rule
applied a second time: configuration is declared, secrets are not.
`system.conf` declares `network.wifi = on` -- *that* this machine uses
WiFi. `/etc/novi/wifi.conf`, mode 0600, holds *which* networks and
their keys. `novi-state diff` can tell you the supplicant should be
running; it cannot tell anyone your passphrase. The store is
wpa_supplicant's own format, not a Novi invention that gets translated:
one file, one parser, already described by every piece of WiFi
documentation on Linux, and `vi` still works when `novi-wifi` does not
suffice.

Verified against a real access point, because QEMU has no WiFi hardware
at all: two `mac80211_hwsim` radios over the kernel's virtual medium,
one running hostapd with WPA2 and udhcpd behind it, one running Novi's
supplicant -- on a machine with **no wired NIC**, so WiFi is
demonstrably what connected it. `wpa_state=COMPLETED`,
`key_mgmt=WPA2-PSK`, `pairwise_cipher=CCMP`, a DHCP lease at
192.168.50.20 on wlan0, a default route through the AP, and ping 2/2.
hostapd is built from the same upstream tree and deliberately never
installed into the image; it reaches the test VM on a separate disk.

Three bugs, two of them written here:

- A passphrase length check written as `case "${#p}" in ?|??|???)`,
  which tests the *digits of the length* -- so `"13"` matched the
  two-`?` pattern and every passphrase between 10 and 99 characters was
  rejected as too short.
- `wpa_supplicant -s` was not a valid option in the build, because
  `CONFIG_DEBUG_SYSLOG` was never enabled. It printed usage and exited,
  s6 restarted it, and **`s6-rc -a list` reported the service up the
  whole time** -- so `novi-state diff` said the machine was converged
  while nothing had ever associated. That is the third crash-loop this
  project has had hidden by "up" meaning "wanted up" for a longrun.
  Making `diff` notice it is on the roadmap and deliberately not done
  here, because the obvious implementation reintroduces the boot race
  §14 fixed.
- `sit0` again, in the same neighbourhood: "the first interface that is
  not lo" picks an IPv6-in-IPv4 tunnel pseudo-device.

The honest gap besides WPA3 is **firmware**: ath9k needs none, but
iwlwifi, ath10k/ath11k, brcmfmac, mt7921 and rtw88 all do, and this
image ships none. On a large fraction of real laptops the driver loads
and the radio does not come up. That is a packaging and licensing
question (§2, §10), not a code one.

## 20. Repository Freshness & Real Upgrades

RFC 0010. Two holes left open by §16, both on its roadmap since, and
they are the same sentence from two directions: **the repository could
not tell you what was current.**

**A signature says "genuine", not "current".** `pkg sync` verified the
index's Ed25519 signature and refused anything that failed -- and could
not detect an index that was perfectly genuine and months old. Anyone
able to serve one (a hostile mirror, a captive portal, a stale caching
proxy) could hold a machine at a version with a known hole
indefinitely, with every signature and every hash still checking out.
The index now carries `valid-until` as a comment line, which puts it
inside the signed blob where it cannot be edited off, and outside the
row parser where it cannot confuse anything. Checked AFTER the
signature, never before: an unverified header is a string an attacker
chose, and refusing on it would hand them a free denial of service.
`sync` refuses a stale index; `update` only warns, because a machine
offline for a month should explain why it has nothing to offer rather
than stop working. A failed `date` declines to judge rather than
judging wrongly.

**`pkg update` did not update.** It compared the installed version
against whatever archive was lying around locally, using string
inequality -- so it could not see the repository at all, and `!=` is
not "newer", so a stale cached archive was a perfectly good reason to
install it. Since §3's entire update model rests on this command, the
update story was a description rather than a mechanism.

The bug worth recording is the one whose symptom was a lie. After the
first fix, `pkg update` printed:

    ==> Upgrading novi-screenshot: 0.1.0 -> 0.2.0
    ==> Installing novi-screenshot (0.1.0)

It had decided correctly, then matched `novi-screenshot-*.pkg.tar.gz`
against the cache, found the archive the previous install had left
there, and installed that. The decision and the action disagreed and
only the decision was printed. Fixing it in `locate_pkg` rather than in
`cmd_update` means `pkg install` after a sync also stops handing back a
stale cached archive -- the same bug reached by a different path.

Version comparison is `sort -V`, the only one available here that knows
1.10.0 is newer than 1.9.2. An older version in the index is refused
loudly rather than silently installed: repositories do legitimately
roll back a bad release, so `pkg install <name>` is named as the
deliberate route.

Verified against a live HTTP mirror **mutated between guest commands**
while the machine ran: publishing 0.2.0 and watching the upgrade land;
publishing an older 0.0.9 and watching it refused; and rewinding
`valid-until` 40 days **and re-signing**, so the signature was
genuinely valid -- `pkg sync` verified the signature, then refused the
index as not current and left the previous one in place.

**Deliberately not done: two ISOs.** It was next on §17's roadmap and
it is not worth doing yet. The desktop is 2.8 MB of a 72 MB image;
separate console and desktop images are a habit from distributions
where the desktop is hundreds of megabytes, and building one here would
be motion rather than progress. When the package set grows enough for
the split to save something real it is half an hour's work in
`mkiso.sh`.

## 21. Hardware Enablement

RFC 0011. Everything before this point was verified in QEMU, which is
the honest way to develop a distro and a dishonest way to describe one:
QEMU hands the guest a handful of devices whose drivers are already
known, so a system can be complete by every test it has and still not
reach a login prompt on a laptop. Four things were missing, and each of
them is the difference between "boots" and "does not".

**Nothing loaded a driver it had not been told about in advance.** The
initramfs named the storage modules it hoped were enough, the network
service named some NICs, the WiFi service named some radios. Three
hardcoded lists, all written against QEMU. `packages/novi-hwdetect`
replaces the guessing with the mechanism udev uses: the kernel
publishes a `modalias` string next to every device it enumerated, and
`depmod` built `modules.alias` from every driver's declared device
table at build time, so walking the first and handing each entry to
`modprobe` matches devices to drivers with no list to maintain. It runs
in the initramfs *before* the root device is searched for -- which is
where it matters, because the alternative is an emergency shell on any
machine with a storage controller nobody anticipated -- and again from
`rc.init` once the real root is up.

**No firmware existed at all.** `build/26-firmware.sh` installs a
curated 699 MB of linux-firmware: Intel and AMD GPUs, Intel/Atheros/
MediaTek/Realtek/Broadcom WiFi, Realtek NICs, AMD microcode. Curated,
not complete -- the full tree is 1.4 GB and half of it is Qualcomm ARM
SoC firmware and NVIDIA blobs that this x86_64 image will never load.
Two things real hardware needs are not in linux-firmware and are
fetched separately: `wireless-regdb` (this kernel sets
`CONFIG_CFG80211_REQUIRE_SIGNED_REGDB`, so without `regulatory.db` and
its signature a radio comes up crippled) and Intel SOF firmware, which
almost every laptop made since about 2019 needs for sound.

**There was no sound.** `build/27-audio.sh` cross-builds alsa-lib and
alsa-utils, and `rc.init` runs `alsactl init` then `alsactl restore` --
the first because ALSA's default state on a fresh card is *muted*, so
without it a working sound path produces silence and the user concludes
the card is unsupported.

**Power was untouched.** `packages/novi-power` is `status` / `suspend`
/ `governors` over sysfs -- battery percentage, AC state, cpufreq
governor, suspend to idle or RAM -- with no daemon, and
`power.governor` joins the `novi-state` domains so a laptop can declare
`powersave` and a workstation `performance` in the same file everything
else is declared in.

The kernel config grew accordingly: I2C-HID (every modern laptop
touchpad), HID multitouch, the ThinkPad/Dell/HP/ASUS/Lenovo/Acer
platform drivers that own the function keys and the battery
thresholds, USB ethernet and dongles, MMC/SD, and NLS charsets without
which a FAT32 ESP does not mount. Still curated -- §4's answer stands,
build against open device-class standards rather than chase vendor
paths -- but curated for laptops instead of for QEMU.

`bootx64.efi` is now signed, with a caveat stated plainly rather than
buried: it is signed by a *self-generated* key, which does nothing on a
stock machine, because Secure Boot trusts Microsoft's key and not
ours. It helps exactly two people -- someone enrolling their own keys,
and someone with Secure Boot off -- and the certificate ships on the
medium so the first can. Real Secure Boot needs a Microsoft-signed
shim, which is a paperwork problem before it is a technical one.

**Verified in QEMU, including the part that was previously unprovable.**
Booting under UEFI with `virtio-balloon-pci`, `virtio-rng-pci` and
`virtio-keyboard-pci` -- three devices whose drivers are modules and
which no list anywhere in this system names -- `lsmod` shows all three
loaded. An `e1000` NIC, equally unlisted, gets a DHCP lease.
`amixer sget Master` reports 73% and `[on]`, which only happens because
`alsactl init` ran. Firmware present on the booted image, `regulatory.db`
included.

Three bugs found by reading the boot log rather than the test output,
all of the same shape -- **code that worked while its reporting
failed**. `novi-hwdetect` loaded every driver correctly in the
initramfs and then died on `tr: not found`, because the initramfs
applet list is hand-written and `tr` was not on it; the fix is both
adding it *and* removing the dependency, since a script whose job is
early boot must not fail on its own bookkeeping. `echo x > /proc/... 2>/dev/null`
does not suppress the redirection's own failure, because redirections
apply left to right. And a module built into the kernel is
indistinguishable from a missing one to `modprobe`, so `/init` printed
`WARNING: Could not load module` for ten filesystems that were compiled
in and working -- twenty-two lines of meaningless warning on every
boot, which is how people learn to ignore warnings.

**What none of this shows is that a real machine boots.** Not one line
of this has run on physical hardware. `novi-hwdetect` is proven on
three virtio devices, which is the easiest case there is; the firmware
is present but nothing has ever requested a byte of it; the platform
and I2C-HID drivers cannot be exercised here at all; suspend has never
been entered. This work makes a real machine much more likely to work,
and demonstrates nothing about whether one does. No further QEMU work
would change that -- the next step is a USB stick and a laptop.

## 22. Hotplug

RFC 0012. §21 replaced three hardcoded `modprobe` lists with one rule --
the kernel publishes a `modalias`, `depmod` built `modules.alias`, hand
one to the other -- and applied it by walking `/sys`. That makes
`novi-hwdetect` a coldplug tool by construction: it answers "what is in
this machine" once, and by the time the walk finishes it is over. Plug
something in afterwards and nothing on this system noticed. For a USB
WiFi dongle, a dock's ethernet, a headset and a memory stick, the driver
is a module sitting in the image that never gets loaded -- the device
correctly enumerated, visible in `/sys`, and dead.

The listener is busybox `uevent`, supervised like anything else. It
binds `NETLINK_KOBJECT_UEVENT` and runs a handler per notification with
the kernel's variables in its environment, and it forces a **128 MB**
receive buffer -- which is the property that decides whether a burst of
events queues or drops. Writing our own would be making that decision
again, less carefully. `packages/novi-hotplug` is the §21 rule against
that stream, plus syslog notes for devices a person would recognise,
plus `alsactl init` for a sound card that arrives late.

It deliberately does not create device nodes (devtmpfs does, in the
kernel, before any of this runs -- `mdev` is present in this busybox and
unused on purpose) and deliberately does not touch networking (an
interface appearing after boot gets a driver and no lease; per-interface
DHCP is §19's work, and reaching into the network service from a uevent
handler is the split-brain this project keeps refusing to build).

**Verified over QMP, so the plug events are genuinely runtime.**
`snd_usb_audio` -- a module named in no list anywhere in this system,
confirmed by grepping every one of them -- goes from absent to live on
`device_add usb-audio`, with its two dependencies, and `aplay -l` shows
the card. A `device_add usb-storage` carrying a 32 MB FAT image produces
`/dev/sda` and `/dev/sda1`, `blkid` identifies it, and the file on it
reads back through a real `mount`. `device_del` removes both cleanly.
`novi-state diff` clean throughout.

Two things learned by running it that will mislead the next person, both
now recorded: **`alsactl init` exits 99 on success** ("initialized using
a generic method" is the documented path for a card no ruleset matches),
and **it only knows standard mixer control names** -- QEMU's emulated
USB audio card invents `Audio Output Volume Control`, so a muted control
on it stays muted, reproduced twice. Real headsets use standard names;
the one device available to test with is the one whose naming defeats
the mechanism. The handler logs that it called alsactl precisely because
"did it run" and "did it work" are separate questions.

**And §21's unmute claim is now actually proven.** It said the HDA card
reading 73% `[on]` after boot "only happens because `alsactl init` ran",
which was an inference and a weak one -- 73% could have been the
driver's default. Muting `Master` to 0% `[off]` and running
`alsactl init 0` returns it to 73% / **-20.00dB** / `[on]`, and -20dB is
literally the value in `/usr/share/alsa/init/default`. The claim was
right; the evidence for it was not, until someone went back and checked.

**Deliberately not done: automount.** The mechanism is there -- a stick
appears, is logged, and mounts by hand -- and what is missing is policy,
which is real: read-write invites data loss on an unclean pull,
read-only makes a USB stick useless for what people use USB sticks for.
That wants a `hotplug.automount` key, a `novi-eject`, and a decision,
not a quick `mount` bolted into a uevent handler.

## 23. Power events, and a shutdown that finishes

RFC 0013. §21 gave the machine a way to suspend and a way to read its
battery, and nothing a way to *decide* to suspend. On a laptop that is
most of the feature: close the lid and it goes in a bag at 80%, runs at
full tilt in an enclosed space and comes out flat; press the power
button and nothing happens, so people hold it for four seconds, which
is the hard power cut with filesystems mounted that handling the button
exists to prevent.

busybox `acpid` is the listener, supervised like everything else. Its
event-to-path table is compiled into the binary, so
`/etc/acpi/PWRF/00000080` and `/etc/acpi/LID/00000080` are named *by
acpid*, not chosen -- rename either and acpid silently runs nothing.
Each is three lines and execs `novi-power event`, so policy lives with
suspend and `/etc/acpi/` stays pure wiring. `power.lid` and
`power.button` are declared (`suspend` / `poweroff` / `ignore`; `ignore`
is for the laptop used as a small server).

Those two are the first keys with **no converger and no observer**:
novi-power reads the declared value at the instant the event arrives,
so behaviour and document cannot disagree and `apply` has nothing to
do. Which creates a new hole -- `converge_key` is where every other
domain rejects a bad value and it never runs for these, so
`power.lid = suspned` would read as converged while the lid did
nothing. The *observer* closes it: an unusable value reports as
`unsupported`, permanent drift the machine cannot fix, which is exactly
the truth.

**And wiring the button found something much worse underneath.** With
`power.button = poweroff` the machine logged the event, stopped most of
its services, and stayed up at a prompt forever. Removing acpid from
the picture reproduced it exactly: `poweroff` typed at a shell had
never worked, in any milestone, ever.

getty execs login execs the shell, so the process s6 supervises IS the
interactive shell -- and an interactive shell ignores SIGTERM by
definition. `timeout-down` was unset, which in s6-rc means wait
forever, so `s6-rc -bDa change` stopped at "service getty-ttyS0:
stopping" and never returned (every other service stopped cleanly,
`getty-tty1` included -- the one nobody was logged into).
`s6-linux-init-shutdownd` waits on that script with a plain
`wait_pid()` and no timeout of its own, verified in its source, so it
never reached the stage that SIGTERMs everything, SIGKILLs the
remainder and calls `reboot(2)`. **A Novi machine could not shut down
while anyone was logged in** -- which is always, since somebody has to
type the command. Every power-down was a hard cut, and on an installed
ext4 root that is a journal replay on every boot.

Nothing caught it because nothing looked: every QEMU test in this repo
ended `vm.line("poweroff"); time.sleep(10); vm.kill()`, issuing the
command and killing the machine before observing whether it did
anything. That is the same lesson as `s6-rc -a list` reporting "up",
arriving from a new direction -- a test that issues a command has to
observe the command's effect.

Fixed with `down-signal = SIGHUP` and `timeout-down = 4000` on both
gettys. SIGHUP because it is correct rather than merely bigger: a getty
going away is a hangup, and hangup is what a shell is specified to die
on. `poweroff` now reaches `reboot: Power down` in under a second,
without even reaching the backstop.

**Suspend to RAM is now proven too.** §21 had to say it was never
entered; `PM: suspend entry (deep)` / `PM: suspend exit` says otherwise,
resumed over QMP with the shell alive on the other side.

**One thing does not work and is not ours: after an S3 resume the power
button stops being delivered, in QEMU.** Chased down rather than papered
over, because the tempting one-line fix would have been wrong -- acpid
keeps the same PID and the same three evdev fds, but reading the evdev
node directly during a press returns 24 bytes before the suspend and
**0 after**, and `/sys/firmware/acpi/interrupts/ff_pwr_btn` shows the
counter not incrementing with the status bit latched (`EN` -> `EN STS`).
The ACPI fixed event fires and is never cleared, so the kernel never
dispatches it to the input layer. Restarting acpid would have fixed
nothing. Whether that is QEMU's S3 emulation or this kernel's resume
path is beyond what this rig can settle, and real firmware re-arms the
event on resume -- so a physical laptop *probably* does not have this,
which is one more thing for the first real boot to check.

## 24. Service health, separate from drift

RFC 0014. `s6-rc -a list` saying a longrun is "up" means *supervised
and wanted up*. It has now hidden four separate bugs in four different
subsystems -- syslog crash-looping for its entire existence and the
network readiness race (§14), wpa_supplicant exiting on an option it
was not compiled with (§19), acpid delivering nothing after a resume
(§23) -- and every one presented as a machine `novi-state diff` called
fully converged. Three were found chasing a different symptom; the
fourth only because a test happened to read the log.

"diff should notice a crash-looping longrun" has sat on this roadmap
since §14 with a note that the obvious implementation reintroduces the
boot race. That note is right and it is not the whole objection. A
longrun that has just started is indistinguishable from one that keeps
dying, so putting this in `observe_service` would have boot convergence
restart the service it had just started. But the deeper problem is
shape: drift means "the machine does not match the document and `apply`
can fix it", and a crash-looping service *matches the document
perfectly* -- it is declared on, and the engine is keeping it up. What
is broken is the service, and no amount of applying fixes a bug in a
run script. Folding the two together would make `apply` promise what it
cannot deliver and leave `diff` unable to reach zero on an affected
machine, destroying the drift signal for everything else.

So: two questions, two commands. `novi-state diff` still answers "does
the machine match the document" and still exits 1 only on drift.
`novi-state health` answers "are the services actually doing their
jobs" and exits 1 when one is not. `diff` and boot convergence print a
note without touching exit status, so a converged-but-broken machine
stops being able to tell only the flattering half of the truth.

The primitives are `s6-svstat -o up,wantedup,ready,updownfor` and
`s6-svdt`, both of which shipped with s6 from the beginning and neither
of which anything had ever called. The death tally alone is not the
signal -- a service that died once last week and has been up since is
fine -- it is the tally together with how long the current run has
lasted: `DOWN` (wanted up, isn't), `CRASHLOOP` (deaths, and up under a
minute), `NOTREADY` (up over a minute having never signalled the
readiness it declares, which is the syslog bug as a category).

Verified by reproducing the original bugs on purpose in a booted
machine. Rewriting a live service's `run` to `exit 1`:
`s6-rc -a list | grep -c klog` still returns 1 -- the same lie, in the
same words -- while `novi-state health` reports `klog DOWN 13-deaths`
and exits 1, and `diff` correctly still exits 0 with
`WARN: converged, but a service is not doing its job`. The tally
reading 13 on one call and 14 seconds later is the loop itself showing
up in the output. A `run` of `sleep 6; exit 1` (the wpa_supplicant
shape, where the service genuinely is up with a pid when you look)
gives `CRASHLOOP 3-deaths-up-5s`; a service declaring
`notification-fd 3` that never writes to it gives `NOTREADY up-75s`.

**Nothing consumes this yet**, and that is the next piece: the panel
could show a failing service, `novi-install` could refuse to call an
install finished, and `/run/uncaught-logs/current` holds the *reason*
that would turn "klog is down" into "klog is down because ...".

## Status Summary

| # | Area | State |
|---|---|---|
| 1 | Base architecture | ✅ Decided |
| 2 | Package/application model | 🟡 Native `pkg`/`mkpkg` now installed, wired into the build, and live-verified end-to-end (real dependency chain, install/remove/search/info) after fixing several real bugs found by first actually running it; sandbox tier still proposed (RFC needed) |
| 3 | Update/rollback model | 🟡 Track split decided, on-device rollback open |
| 4 | Hardware strategy | 🟡 x86_64 kernel now carries laptop hardware (I2C-HID, HID multitouch, vendor platform drivers, USB ethernet, MMC/SD, NLS) and the image carries firmware and a generic driver loader (§21); aarch64 and real-metal validation still open |
| 5 | Desktop strategy | 🟡 Compositor + layer-shell + launcher + foot terminal + top-bar panel, real anti-aliased text rendering (fcft/pixman), a clickable apps button routing pointer input to a layer-shell surface, new windows placed below the panel's exclusive zone, real alpha compositing + rounded corners + a drop shadow on the launcher, server-side window decorations with working close + maximize buttons, all live-verified in QEMU together; design docs' rendering sequence now started on icons too — Lucide's license verified from upstream, apps-button icon shipped and live-verified; the `tools/svg2icon/` offline pipeline is built and its icons are now wired into `novi-launcher`'s search results (`icon=` in `.app` descriptors) and QEMU-live-verified — a real generated terminal icon renders next to a matched result, pixel-confirmed via screendump; status-bar icons are generated but unwired, blocked on real wifi/battery data; real app search too — `pkg-format.md`'s GUI-app-registration convention, foot registered and launchable by typed name, fork+execvp on Enter, live-verified end-to-end; file search still doesn't exist; Super+. symbol picker (not full emoji — no emoji-capable font exists) now wired too, `novi-launcher --symbols` copying to the clipboard via novi-shell's existing `wl_data_device_manager`, QEMU-live-verified down to the exact pasted UTF-8 bytes; found and fixed a real, previously-invisible `common/text.c` bug along the way (byte-per-codepoint rendering silently mojibake'd any multi-byte UTF-8 glyph); two more unrelated bugs found and fixed live-testing all this: a missing `/tmp` mount, and the documented `s6-rc -up change graphical` command itself (root-caused: `-p`/prune tries to stop the console's own getty; corrected to plain `-u`); a real taskbar now too — `novi-panel` is a `wlr-foreign-toplevel-management-unstable-v1` client (the standard taskbar protocol, XML vendored under `protocol/`), minimize is a real function instead of a dimmed placeholder, QEMU-live-verified end to end (minimize, restore via taskbar click, close removing the entry, all pixel-confirmed); PrintScreen screenshots also wired — `novi-screenshot/` is a `wlr-screencopy-unstable-v1` client writing an uncompressed 24-bit BMP, `novi-shell`'s key dispatch gained its first no-modifier binding to reach it, QEMU-live-verified with the actual BMP bytes read back (correct header, exact expected file size, correct bottom-up pixel orientation against a screendump of the same frame); Super+L session lock also real now — `novi-lockscreen` checks a typed password against `/etc/shadow` via musl's real `crypt(3)`, and `novi-shell` gained a `locked` flag that actually disables every keybinding and blocks focus-stealing while active (not just a visual overlay), QEMU-live-verified including the bypass attempt itself (Super+Q/Alt+Space confirmed inert while locked via `ps`, wrong password rejected, correct password unlocked and restored normal keybindings); RFC 0001 decision 7's default keybinding set is now fully wired — Super+[1-9]/Shift+[1-9] workspaces landed last, per-server not per-output (no multi-output support exists anywhere else in this compositor either), and surfaced a real bug along the way: Shift+digit reports a different keysym entirely on this compositor's hardcoded US layout (Shift+3 is `XKB_KEY_numbersign`, never `XKB_KEY_3`), the same class of bug the existing Shift+Tab handling already worked around for one key, just needing nine shifted forms covered instead of one; confirmed both broken (stray `@`/`#` typed into a focused terminal) and fixed (window actually moves, workspace becomes genuinely empty) via QEMU screendumps; first first-party app now exists too — `novi-settings` (Account/change-password), this repo's first plain `xdg-shell` window app rather than a layer-shell overlay, real SHA-512 `crypt(3)` + atomic `/etc/shadow` rewrite, QEMU-live-verified via the actual round trip (password set through the GUI successfully unlocked `novi-lockscreen`, not just "a message appeared") |
| 6 | Gaming strategy | 🔴 Open — blocked on #5 |
| 7 | Developer strategy | 🟡 Native toolchain exists, container tier proposed |
| 8 | Enterprise strategy | 🟡 LTS branches exist, signing enforcement + fleet mgmt open |
| 9 | Security model | 🟡 Small TCB + disclosure process exist, signing default open |
| 10 | Community/governance | ✅ Decided |
| 11 | Differentiation | ✅ Articulated above |
| 12 | Security tooling / pentest track | 🔴 Open — packaging work, blocked on §2/§8/§9 |
| 13 | Installation & persistence | ✅ Installable and QEMU-verified end to end (install → cold boot from disk via GRUB in the MBR → marker file survives a power cycle → live ISO unregressed); BIOS/MBR + journal-less ext2 + root-only are the stated v1 limits, UEFI/GPT and e2fsprogs are next |
| 14 | Networking & logging | ✅ DHCP + resolver as a supervised service with a `network.*` state domain, syslogd/klogd replacing a logger that had never once run; verified live and installed, including logs surviving a reboot. Static IP, WiFi and DHCPv6 are roadmap |
| 15 | Users & accounts | ✅ `users.*` domain, a real group database, installer-created accounts with passwords; "configuration is declared, secrets are not" is now a stated platform rule. Non-root `novi-settings`, `users.*.home`/`.uid`, and undeclared-user removal are roadmap |
| 16 | Package repository & signing | ✅ Signed index (Ed25519 via a hash-pinned TweetNaCl verifier on-target), SHA-256 per package, `pkg sync` + mirror fetch, `packages.*` state domain, first-party desktop repository; both tamper cases verified live. Desktop still also in the base image; release keys, index expiry and version constraints are roadmap |
| 17 | Base/desktop split | ✅ Console-only base (three libraries left in /usr/lib: libskarnet, libnl for the supplicant, libasound for audio — the split is recomputed as the base grows, not frozen at one), desktop is 25 packages on the medium, split computed from the ELF graph with a build-failing safety check; live-desktop boot, `pkg install novi-desktop` offline, and `novi-install --profile desktop` all verified. Separate console/desktop ISOs and finer-grained packages are roadmap |
| 18 | UEFI install & journalled root | ✅ Firmware detected from /sys/firmware/efi; GPT+ESP via a purpose-built `novi-gpt`, real ext4 via e2fsprogs, one menu written to two prefixes. Both paths verified end to end. Secure Boot, kernel updates to the ESP, swap//home/encryption are roadmap |
| 19 | WiFi | ✅ wpa_supplicant with internal crypto (no OpenSSL), `network.wifi` declared with credentials in a 0600 store, wired-first interface selection; verified end to end against a real WPA2 AP on hwsim radios with no wired NIC present. WPA3 (needs mbedTLS), firmware packages, per-interface DHCP and a panel applet are roadmap |
| 20 | Repository freshness & upgrades | ✅ `valid-until` inside the signature (replay closed, verified with a re-signed 40-day-old index), `pkg update` driven by the index with `sort -V` comparison and no silent downgrades. Index serial, cache pruning and version constraints are roadmap |
| 21 | Hardware enablement | ✅ Generic modalias-driven driver loading (`novi-hwdetect`, in the initramfs before the root search), 699 MB of curated firmware + `regulatory.db` + Intel SOF, ALSA with `alsactl init` at boot, `novi-power` and a `power.governor` state domain, a laptop-oriented kernel config, and a self-signed `bootx64.efi`. Verified in QEMU on drivers no list names (three virtio modules + an e1000 lease) — **but never once on physical hardware**, which is the whole subject. Firmware-as-packages, a real shim, hotplug, lid/hotkeys and Mesa are roadmap |
| 22 | Hotplug | ✅ Supervised uevent listener (busybox `uevent`, 128 MB netlink buffer) + `novi-hotplug`: §21's modalias rule against the kernel's event stream, syslog notes, `alsactl init` for late-arriving sound cards. QMP-verified at runtime — a driver in no list loading on plug, a USB stick mounting and reading back, clean removal. Automount (needs policy), per-interface DHCP and a desktop that notices are roadmap |
| 23 | Power events & shutdown | ✅ acpid wired to lid and power button, `power.lid`/`power.button` declared and read at event time (with invalid values surfacing as drift, since these keys cannot drift and so are never converged). Found and fixed a bug present since the beginning: **the machine could not shut down while anyone was logged in** — an interactive shell ignores SIGTERM and `timeout-down` was unset, so s6-rc waited forever and shutdownd's `wait_pid()` never returned. Suspend/resume now proven. Power-button-after-S3 is broken in QEMU, traced to a latched ACPI status bit below all of our code |
| 24 | Service health | ✅ `novi-state health` — `DOWN`/`CRASHLOOP`/`NOTREADY` from `s6-svstat` + `s6-svdt`, closing a blind spot that had hidden four bugs across §14/§19/§23. Deliberately NOT folded into `diff`: a crash-looping service matches the document, and `apply` cannot fix a run script, so drift and health are separate questions with separate exit codes. All four states verified by reproducing the original bugs on a booted machine. Nothing consumes the signal yet (panel, installer, log excerpts) |

**Next concrete step: write the ISO to a USB stick and boot a real
machine.** This is no longer a development task, and that is the point.
Twenty-one milestones were each verified the same honest way -- boot it
in QEMU and prove the behaviour end to end -- and §21 is where that
method runs out of information. Everything it added exists precisely
because QEMU does not have the problem: unknown devices, missing
firmware, muted codecs, batteries. The code is written, cross-compiled
and QEMU-verified as far as QEMU can go, and the only remaining
question is one no VM can answer.

What a first real boot would actually tell us, in order of how likely
it is to be what breaks: whether `novi-hwdetect` finds the storage
controller before `/init` gives up; whether the WiFi radio comes up now
that firmware and `regulatory.db` are present; whether the touchpad
works through I2C-HID; whether sound reaches a speaker; whether the
battery reads.

Ordered honestly, what is left after that:

1. **Real-metal validation** -- the above, and the fixes it produces.
   Nothing else on this list is worth much until a machine boots.
2. **A published repository and an offline release key** -- something
   at a stable URL, signed off the build host. Everything a package
   system needs exists and is verified; it all points at a repository
   that lives only on whichever machine last ran `build/20-repo.sh`,
   with a development key the image trusts. A real release key lives
   offline and signs somewhere that is not the build host.
3. **A Microsoft-signed shim** -- `bootx64.efi` is signed now, but by a
   key nothing trusts. This is an organisational step before a
   technical one.
4. **WPA3**, which needs mbedTLS as wpa_supplicant's crypto backend.
5. **Automount for removable media** -- hotplug itself is done (§22);
   what is left is policy, and `novi-eject` to go with it.
6. **Hotkeys, idle-suspend and low-battery actions** -- the lid and
   power button are done (§23); what is left is the rest of the
   laptop's decisions, and a desktop that can ask before suspending.
7. **Mesa**, for GPU acceleration. The compositor renders in software,
   which will show on a high-resolution panel.
8. **Something should consume `novi-state health`** -- the signal
   exists now (§24) and nothing reads it. The panel showing a failing
   service, the installer refusing to call an install finished, and
   the failing service's own last log lines are what would make it
   visible without someone thinking to ask.

---

*Historical, kept for the root-cause records:* the `tools/svg2icon/` offline SVG-to-bitmap
pipeline (`ICON-PIPELINE.md` Stage 1+2) is built, wired into
`novi-launcher`'s search results, and QEMU-live-verified end to end —
booted the ISO, opened Alt+Space, typed "foot", and a real screendump
shows the generated terminal icon rendered next to the matched result.
What's left of the icon set: `novi-panel`/`novi-shell` don't call
`draw_icon()` yet (no app-grid view or status bar content exists to put
icons in yet, independent of the icons themselves being ready), and the
status-bar icons stay unwired until real wifi/battery data sources
exist. Two unrelated bugs surfaced by actually booting this, both fixed:
a missing `/tmp` mount in `scripts/mkinitramfs.sh`, and the documented
"switch to graphical by hand" command itself, which hung indefinitely
because of `-p` (prune) trying to stop the issuing console's own getty
— corrected to `s6-rc -u change graphical` (see §5 above for the full
root-cause).

App search also went from fully blocked to actionable: `pkg-format.md`'s "GUI
Application Registration" convention gives `pkg` the "this is a
launchable GUI app" concept it was missing, `novi-launcher` scans and
matches against it, and `foot` proves it end-to-end — but real
packages still don't ship `.app` descriptors (no GUI apps are
`pkg`-installed yet), so there's exactly one app to find until that
changes. Dogfoodable now via `foot`'s real interactive shell inside
the graphical session (with real, clickable close and maximize
buttons, and now reachable by typing its name into Alt+Space, not only
Super+Return) instead of only QEMU-injection-and-screendump from
outside.

RFC 0001 decision 7's Super+. binding is done too, as far as it can be:
`novi-launcher --symbols` reuses the whole launcher client for a
searchable list of ~50 real Unicode symbols (checked against
JetBrainsMono-Regular.ttf's actual cmap, not assumed — this repo has no
emoji-capable font, so full "emoji/symbol picker" stays symbol-only
until one is added, a real font dependency and its own future work, not
this milestone's). Enter copies the match to the clipboard through
novi-shell's existing `wl_data_device_manager` (zero new compositor
protocol work — it already existed for regular app copy/paste). Getting
the glyph to even render correctly surfaced a real bug in the shared
`common/text.[ch]` module both `novi-panel` and `novi-launcher` use:
it silently treated every byte as its own codepoint, mojibake-ing any
real multi-byte UTF-8 character — invisible until something actually
needed one. Fixed with a real UTF-8 decoder, and re-verified live that
the ASCII-only callers (the clock, calculator, app icons) were
unaffected. The whole path was QEMU-live-verified down to the actual
clipboard bytes: pasted into a real `foot` window and read back via
`od -c` as the exact correct 3-byte UTF-8 sequence, not just "something
non-empty got copied."

Minimize went from a dimmed placeholder to a real, working taskbar next:
`novi-panel` is now also a `wlr-foreign-toplevel-management-unstable-v1`
client (the standard protocol real taskbars use — waybar included —
not a bespoke novi-shell↔novi-panel IPC channel; the XML is vendored
under `protocol/` for the same reason `wlr-layer-shell-unstable-v1.xml`
already is, since wlroots implements the server side internally but
never installs this XML anywhere for a client to consume). `novi-shell`
creates one `wlr_foreign_toplevel_manager_v1` and gives each mapped
toplevel a handle (title/app_id kept live via `xdg_toplevel`'s own
`set_title`/`set_app_id` signals), wired to real
`request_activate`/`request_minimize`/`request_maximize`/`request_close`
handlers that all funnel through the exact same
`focus_toplevel()`/`minimize_toplevel()`/`maximize_toplevel()`/
`wlr_xdg_toplevel_send_close()` functions the compositor-native paths
(decoration dots, Super+Q) already used — one place per state change,
regardless of which UI asked. Minimize itself
(`minimize_toplevel()`/`unminimize_toplevel()`) hides a window by
disabling its scene node rather than unmapping the real Wayland
surface (the client's own state/frame callbacks are undisturbed), and
`focus_toplevel()` now unminimizes automatically, so Alt+Tab and a
taskbar click both restore a minimized window the same way every real
desktop does. The minimize dot itself is real now too, no longer the
dimmed, non-interactive placeholder GUI-DESIGN-LANGUAGE.md's original
reasoning left it as — this taskbar is exactly the restore path that
reasoning was waiting on.

`novi-panel`'s taskbar renders one pill per open window after the Apps
button (ellipsis-truncated past a max width, real UTF-8-safe
truncation that never cuts a multi-byte title character in half),
teal/accent when active, blended into the bar background when
minimized (pixel-confirmed distinct from "open but unfocused"), click
to activate/restore or (if already active) minimize — the same toggle
convention real taskbars use. QEMU-live-verified end to end with two
real `foot` windows: opened both (two real taskbar entries appeared),
minimized the active one via its dot (pixel-sampled its taskbar entry's
background as exactly the plain panel background color, confirming
the "blended" minimized style actually rendered, and focus correctly
moved to the other window), clicked the minimized entry to restore it
(pixel-confirmed it took over the active/teal color and the window
reappeared), then closed a window via its close dot and confirmed its
taskbar entry actually disappeared (the `closed` event path, not just
the open path).

PrintScreen screenshots (RFC 0001 decision 7) are wired now too: a new
`novi-screenshot/` client binds `wlr-screencopy-unstable-v1` (XML
vendored under `protocol/` for the same reason every other wlroots
protocol here is — the server side is entirely wlroots' own, enabled
with one `wlr_screencopy_manager_v1_create()` call in `novi-shell`'s
`main()`, same shape as the data-device and foreign-toplevel managers
next to it), captures the focused output's current frame into a
`wl_shm` buffer, and writes it as an uncompressed 24-bit BMP to
`/root/screenshot-<timestamp>.bmp`. `novi-shell`'s key-dispatch loop
needed a real change, not just another binding in the existing
Alt/Super-gated table: PrintScreen takes no modifier on every real
keyboard, so `keyboard_handle_key()` now has a second, unconditional
check for `XKB_KEY_Print` alongside the Alt/Super-gated loop, spawning
`novi-screenshot` (overridable via `NOVI_SCREENSHOT`, matching every
other spawned binding's `NOVI_*` env override convention). v1 scope is
deliberately narrower than RFC 0001's full description: whole-output
capture only (`capture_output`, not `capture_output_region` — region
select needs an interactive rubber-band overlay, a real UI surface this
one-shot tool deliberately isn't, so Shift+PrintScreen stays unwired
until that overlay exists) and file-only, not "clipboard + file" (an
image `wl_data_source` is a real, separate follow-up, not done here).
BMP rather than PNG for the same reason ICON-PIPELINE.md gave for never
adding SVG *decoding*: this repo has zero image-*encoding* capability
either (no libpng, no zlib) and a 24-bit uncompressed BMP needs none of
it while still being a real, universally-openable format.

QEMU-live-verified end to end, including a from-scratch fix to the
verification environment itself: the sandboxed host this session runs
in has no `/dev/kvm`, and the project's existing OVMF+GRUB+q35 boot
path (`scripts/mkvm.sh`'s own shape) turned out to hang for many
real minutes under this host's TCG once `virtio-gpu-pci` and the
xhci/USB input devices were both present together — confirmed via QMP
register polling that the vCPU was making genuine (if glacial) forward
progress, not deadlocked, then isolated by bisecting the device list
with direct `-kernel`/`-initrd` boots (skipping OVMF/GRUB entirely):
`machine=pc` + a single `virtio-gpu-pci` device boots to a shell in
seconds, so the slowdown is specific to xhci/USB (or q35's ACPI table
generation for that many PCIe devices) under this host's TCG, not
`virtio-gpu-pci` itself and not this project's own boot path in
general — real hardware and less-constrained TCG hosts are unaffected;
using `machine=pc`'s always-present i8042 PS/2 controller for keyboard
input (libinput/evdev don't care whether a keyboard is PS/2 or USB)
sidesteps the slow path entirely for headless testing. Booted the ISO
this way, brought up `graphical` (`s6-rc -u change graphical`), a
screendump confirmed the live compositor and panel rendering correctly,
sent PrintScreen via QMP `send-key`, and confirmed a real
`/root/screenshot-*.bmp` landed: exactly the expected size for a
1280×800 24-bit BMP (3,072,054 bytes, matching the header math exactly,
not just "a file exists"), every header field read back correct via
`od` (`BM` magic, file size, 54-byte pixel offset, 40-byte info header,
1280×800, 1 plane, 24 bits/pixel, `BI_RGB`, correct pixel-data size),
and the actual pixel bytes confirmed both correct content and correct
bottom-up/`y_invert` row orientation: the file's first row reads pure
black (0,0,0) — the screen's black background — and its last row reads
a consistent dark navy (matching the panel bar's actual color in the
same screendump), which is exactly right for a bottom-up BMP whose
bottom-of-file row is the bottom of the screen and top-of-file row is
the top, where the panel actually is.

Super+L session lock is real now too, not the "cheap" overlay RFC 0001's
own prose called it — this project's own security bar made it the one
binding that actually needed compositor-level changes, not just a new
client. A visual full-screen layer-shell surface alone (the exact
mechanism novi-launcher's overlay already uses) was never going to be
enough: nothing about that stops a *different* global keybinding
(Super+Q, another Alt+Space, Alt+Tab) from running and stealing focus
back, since `handle_keybinding()` fires before any focus check at all.
So this is two real pieces, not one:

`novi-lockscreen/` is a new layer-shell client, anchored to all four
edges with `exclusive_zone=-1` (covering `novi-panel`'s own top bar
too, not just the area below it) and keyboard-interactivity=exclusive,
rendering a plain "Locked" screen with a fixed-width password-length
dot indicator (the common GNOME/macOS convention: length is shown,
content isn't) via the same fcft+pixman pipeline every other UI client
here uses. It checks a typed password against a *real* password, not a
placeholder: `/etc/shadow`'s own `root` entry (the one interactive user
this system has today), verified with musl's real `crypt(3)` — the
same primitive `passwd`/`login` already rely on, confirmed working via
`nm` showing both `crypt` and `explicit_bzero` live in musl's libc.a
directly (no separate `-lcrypt` needed, unlike glibc). If root has no
password set — this repo's stock `/etc/shadow` ships an empty hash
field, since no `passwd` flow has ever run on a fresh install — it
refuses to lock at all (checked before ever opening a Wayland
connection), logging why rather than either accepting any input as
correct or locking someone out with nothing that could ever unlock it.
Escape deliberately does not dismiss this overlay (unlike every other
one in this repo) — it only clears the typed field; the only way out is
a correct password.

The other half is in `novi-shell` itself: a new `novi_server.locked`
flag, set/cleared by `layer_surface_map()`/`layer_surface_unmap()`
recognizing `novi-lockscreen`'s own `zwlr_layer_surface_v1` namespace
(a plain string match both sides share as `NOVI_LOCK_NAMESPACE`, not a
new protocol extension), gates the two real bypass paths:
`keyboard_handle_key()` skips its entire keybinding-dispatch table
while locked (every key just falls through to whatever holds seat
keyboard focus, which is always the lock surface itself once mapped),
and `focus_toplevel()` itself refuses to run at all while locked — the
one choke point every focus-stealing path shares (a pointer click can't
physically reach anything under a full-output OVERLAY-layer surface
anyway, but a newly-mapped toplevel's own auto-focus-on-map call still
reaches this function, and this guard closes it too).

QEMU-live-verified end to end, including the actual bypass this whole
design exists to prevent, not just the happy path: set a real password
live (`passwd root`), brought up `graphical`, confirmed the desktop
rendering normally, sent Super+L via QMP and confirmed `novi-lockscreen`
was running and the full-screen "Locked" prompt rendered correctly
(covering the panel). Then, while locked, sent Super+Q and Alt+Space and
confirmed via `ps` that neither had any effect — no `novi-launcher`
process ever spawned, `novi-lockscreen`'s own PID never changed —
proving the keybinding lockout actually holds, not just that the
overlay looks right. Typed a wrong password: rejected, dots cleared,
"Incorrect password" rendered in red, still locked. Typed the correct
password: `novi-lockscreen` exited cleanly, the desktop screendump
showed the normal session again, and Alt+Space immediately worked again
(a fresh `novi-launcher` process appeared), confirming both the unlock
itself and that `focus_toplevel()`'s guard clearing didn't leave
keyboard focus stranded afterward.

Super+[1-9] workspaces are wired now too — RFC 0001 decision 7 is fully
implemented. Scoped per-server, not per-output as the RFC's own prose
frames it: every other part of this compositor that deals with "which
output" (new-toplevel placement, layer-shell surfaces requesting no
specific output) already commits to "there is exactly one output, use
it," so a real per-output workspace model would be new, untested
multi-monitor logic layered on top of a codebase that has never
actually run on more than one output — a real per-output model is
future work alongside real multi-output support generally, not
something to half-build here. `novi_server.active_workspace` (1-9) and
a new `novi_toplevel.workspace` field (set to whatever's active at map
time, so new windows open where you are) drive it: switching workspace
walks every toplevel, enabling or disabling its scene node by whether
`workspace == active_workspace && !minimized` — the same
`wlr_scene_node_set_enabled()` primitive minimize already uses, since
minimize and workspace-visibility are independent hidden-reasons, not
one flag doing double duty. Alt+Tab/taskbar-activate on a toplevel from
a hidden workspace now switches to it automatically first (real desktop
behavior — activating a window brings you to wherever it is, rather
than silently focusing something that stays invisible).

Getting this right surfaced a real bug, not caught until actually
testing the *combined* modifier case rather than each modifier alone:
`keyboard_handle_key()` reads keysyms through
`xkb_state_key_get_syms()`, which returns the keysym *after* applying
the current modifier state — so on the hardcoded "us" layout this
compositor's `xkb_keymap_new_from_names()` call always produces,
Shift+3 reports `XKB_KEY_numbersign` ('#'), never `XKB_KEY_3` with a
separate Shift bit. A plain `case XKB_KEY_3:` can never match
Super+Shift+3's actual keysym at all — confirmed live, twice: the
literal `@` and `#` characters landed straight in a focused `foot`
window instead of moving it, on both the QMP `send-key` chord and a
manually-sequenced, explicitly-timed `input-send-event` down/up
sequence (ruling out a QMP timing artifact before concluding it was a
real code bug). This is the exact class of bug this file's own
Alt+Tab/Shift+Tab binding already has a fix for one keysym
(`XKB_KEY_ISO_Left_Tab`) — digits just need nine shifted forms covered
instead of Tab's one, so `workspace_digit_for_keysym()` maps both the
unshifted and shifted keysym for each digit (1/!, 2/@, 3/#, ... 9/() )
back to its workspace number, checked before the modifier switch
rather than as switch cases. Confirmed fixed live the same two ways the
bug was confirmed real: Super+Shift+2 now actually moves the focused
window (screendump-confirmed it vanished from workspace 1 with no
stray character typed anywhere), Super+2 shows it arrived and focused
on workspace 2, and Super+1 confirms workspace 1 is now genuinely
empty, not just visually similar.

RFC 0001 decision 7's entire default keybinding set is done: Alt+Space,
Alt+Tab/Shift+Tab, Super+Return/Q, Super+[1-9]/Shift+[1-9],
Super+./symbol picker, PrintScreen, and Super+L, every one QEMU-live-
verified against its own real behavior, not just "the process starts."

### First first-party app: novi-settings

The compositor's whole interaction shell was essentially done at this
point, but the desktop had almost nothing to actually run: one real
launchable app (`foot`, a third-party binary this repo bakes in), for
an "everyday users" pillar this doc's own Philosophy section names as
equal to developer/pentest/gaming. `novi-settings` closes a real,
previously-missing gap, not a mockup: this system has had no GUI way to
set a password at all — `novi-lockscreen`'s own header comment already
noted the stock `/etc/shadow` ships an empty hash because "no `passwd`
flow has ever run" — so the only way to make Super+L's lock feature
actually usable day-to-day was dropping to a shell and running
`passwd` by hand. `novi-settings`'s "Account" panel is that missing
GUI path, and nothing more in v1: two fields, New password and Confirm,
no "current password" field at all -- root changing its own password
never needs the old one first (standard Unix semantics; only a
non-root user changing their own needs to prove the old one), which is
both more correct and simpler than a fake three-field form. Real
SHA-512 `crypt(3)` hashing with a genuine random salt from
`/dev/urandom` (not a placeholder), an atomic `/etc/shadow` rewrite
(write to a temp file, `rename()` over the original — a crash or power
loss mid-write can never leave it half-written), every other shadow
field and every other line preserved byte-for-byte.

This is also this repo's first first-party app built as a plain
`xdg-shell` window rather than a layer-shell overlay — a real,
decorated, closable, taskbar-listed window like `foot`, not a
full-screen or centered overlay the way `novi-launcher`/`novi-panel`/
`novi-lockscreen` all are. `novi-shell` already decorates every
`xdg_toplevel` unconditionally regardless of what the client requests
(its own `xdg_decoration_manager` comment), so `novi-settings` didn't
need to negotiate decoration mode at all — a real, documented scope
narrowing specific to this one compositor, not something a portable
app would get away with. Keyboard-only interaction (Tab/Shift+Tab
between fields, Enter to advance or submit) — no `wl_pointer`/click-
to-focus yet, a real v1 limit matching every other new client's own
honest scoping in this doc, not an oversight.

QEMU-live-verified end to end, including the test that actually proves
the round trip rather than just "a message appeared": typed mismatched
passwords first and confirmed the real validation path ("Passwords
don't match", both fields cleared, screendump-confirmed); then typed
matching ones and confirmed "Password changed"; then read `/etc/shadow`
directly over the serial console and confirmed a real `$6$`-prefixed
hash with a proper 16-character salt, `0600 root:root` permissions
preserved, and every other field (`19000:0:99999:7:::`) untouched byte-
for-byte. The actual proof, not just "a plausible-looking hash exists":
closed `novi-settings`, locked the session with Super+L, and typed the
*exact same new password* into `novi-lockscreen` — it unlocked,
confirming `novi-settings`'s write and `novi-lockscreen`'s independent
`crypt(3)` read of that same file genuinely agree, not just that each
one looks right in isolation.
