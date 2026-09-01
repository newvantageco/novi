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
with `s6-rc -up change graphical`.

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

**Still open**: file search (indexed filesystem lookup) still doesn't
exist, and no package installs a `.app` descriptor yet since no real
GUI apps are packaged -- app search only has one real entry (foot) to
find until that changes; Super+[1-9] workspaces
(needs real per-output workspace state), PrintScreen screenshots,
Super+L lock, Super+. emoji picker — none of RFC 0001 decision 7's
remaining bindings are wired up yet; moving keybindings to RFC 0001's
user-editable config file instead of compiled-in defaults;
hardware-accelerated rendering (GLES2/Vulkan via Mesa) is out of scope
for this milestone and stays pixman-only until that's picked up
separately; the app-grid and status-bar (wifi/battery/power) icon sets
design-doc §8 calls for are still unimplemented, blocked on standing up
the `tools/svg2icon/` offline SVG-to-bitmap pipeline (real curves,
don't qualify for the hand-coded parametric shortcut the apps-button
icon used); status icons are additionally blocked on real wifi/battery
data sources that don't exist yet either.

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

Not "yet another from-scratch distro" — the differentiator is that the
from-scratch base (musl/s6) is being used to build a platform that
*separates concerns other distros bundle together*: one rootfs/pkg
foundation, two update tracks (§3) instead of forcing rolling-vs-stable
as a distro-choice decision, and an application model (§2) that keeps the
native package set small while still giving users glibc-world app
availability through sandboxing — without the user ever needing to know
which tier an app came from.

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

## Status Summary

| # | Area | State |
|---|---|---|
| 1 | Base architecture | ✅ Decided |
| 2 | Package/application model | 🟡 Native `pkg`/`mkpkg` now installed, wired into the build, and live-verified end-to-end (real dependency chain, install/remove/search/info) after fixing several real bugs found by first actually running it; sandbox tier still proposed (RFC needed) |
| 3 | Update/rollback model | 🟡 Track split decided, on-device rollback open |
| 4 | Hardware strategy | 🟡 x86_64 kernel exists, coverage + aarch64 open |
| 5 | Desktop strategy | 🟡 Compositor + layer-shell + launcher + foot terminal + top-bar panel, real anti-aliased text rendering (fcft/pixman), a clickable apps button routing pointer input to a layer-shell surface, new windows placed below the panel's exclusive zone, real alpha compositing + rounded corners + a drop shadow on the launcher, server-side window decorations with working close + maximize buttons, all live-verified in QEMU together; design docs' rendering sequence now started on icons too — Lucide's license verified from upstream, apps-button icon shipped and live-verified; app-grid/status-bar icon sets still open (need the offline SVG pipeline); real app search now too — `pkg-format.md`'s new GUI-app-registration convention, foot registered and launchable by typed name (id or display name), fork+execvp on Enter, live-verified end-to-end; file search still doesn't exist |
| 6 | Gaming strategy | 🔴 Open — blocked on #5 |
| 7 | Developer strategy | 🟡 Native toolchain exists, container tier proposed |
| 8 | Enterprise strategy | 🟡 LTS branches exist, signing enforcement + fleet mgmt open |
| 9 | Security model | 🟡 Small TCB + disclosure process exist, signing default open |
| 10 | Community/governance | ✅ Decided |
| 11 | Differentiation | ✅ Articulated above |
| 12 | Security tooling / pentest track | 🔴 Open — packaging work, blocked on §2/§8/§9 |

**Next concrete step:** design doc §8's rendering sequence item 5 (icon
rendering) is unblocked and has its first real icon shipped (Lucide's
`layout-grid` on the apps button, license-verified from upstream
rather than assumed). What's left of it is the app-grid and
status-bar (wifi/battery/power) icon sets, which need real curves and
so need the `tools/svg2icon/` offline SVG-to-bitmap pipeline
`ICON-PIPELINE.md` proposes (Stage 1) actually built — that's now
purely implementation effort, no decision blocking it. App search also
went from fully blocked to actionable: `pkg-format.md`'s "GUI
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
