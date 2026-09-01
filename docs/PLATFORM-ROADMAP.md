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

Built so far, cross-compiled from source against this repo's own musl
toolchain (`build/06-wayland.sh`, `build/07-novi-shell.sh`): the full
dependency stack (wayland, wayland-protocols, libxkbcommon, pixman,
libudev-zero, libevdev, mtdev, libinput, libdrm, libdisplay-info, seatd,
wlroots itself — 14 libraries, all with real cross-compilation bugs found
and fixed, not just downloaded), and a first working `novi-shell` binary
(`novi-shell/`, a wlroots DRM+libinput+pixman compositor core adapted from
wlroots' own tinywl.c reference). It compiles, links, and runs correctly
up to the point of connecting to `seatd` over its socket. Wired into
s6-rc as `seatd` and `novi-shell` services (dependency verified via
`s6-rc-db`), deliberately kept out of the `default` boot bundle behind a
new `graphical` bundle until it's actually proven on real output.

**Still open**: pixel-verified rendering (blocked on this environment's
QEMU virtio-gpu module not auto-loading yet, and on the root-login policy
gap noted in §9 blocking an interactive shell to switch runlevels by
hand); the panel, app launcher, and layer-shell protocol support that
RFC 0001 actually means by "novi-shell" — what exists today is the
compositor core they'll be built on, not that UI layer itself; the
keyboard-shortcut conventions (Alt+Space search, etc.) RFC 0001 specs are
not implemented in code yet either.

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
| 2 | Package/application model | 🟡 Native done, sandbox tier proposed (RFC needed) |
| 3 | Update/rollback model | 🟡 Track split decided, on-device rollback open |
| 4 | Hardware strategy | 🟡 x86_64 kernel exists, coverage + aarch64 open |
| 5 | Desktop strategy | 🟡 RFC approved, compositor core built + s6-wired, unverified on real output, no panel/launcher yet |
| 6 | Gaming strategy | 🔴 Open — blocked on #5 |
| 7 | Developer strategy | 🟡 Native toolchain exists, container tier proposed |
| 8 | Enterprise strategy | 🟡 LTS branches exist, signing enforcement + fleet mgmt open |
| 9 | Security model | 🟡 Small TCB + disclosure process exist, signing default open |
| 10 | Community/governance | ✅ Decided |
| 11 | Differentiation | ✅ Articulated above |
| 12 | Security tooling / pentest track | 🔴 Open — packaging work, blocked on §2/§8/§9 |

**Next concrete step:** verify `novi-shell` actually renders on real output
(load `virtio_gpu` in the test VM, resolve the root-login gap enough to
drive a manual runlevel switch or start `graphical` by default for
testing), then build the panel/launcher/layer-shell UI layer RFC 0001
actually describes as "novi-shell" on top of the now-working compositor
core.
