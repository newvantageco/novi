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
tagged kernel.

**Proposed:** widen kernel config coverage (WiFi/BT stacks, common laptop
ACPI quirks, GPU drivers) and add a boot-time hardware detection service
(an s6-supervised oneshot) that loads/blacklists modules and picks
firmware, rather than shipping one monolithic config for every machine.
Firmware blobs get their own `pkg` package (`linux-firmware`) so licensing
stays separated from the free kernel package.

**Open:** aarch64 support (blocks any non-x86 hardware story) and whether
firmware packages are opt-in at install or bundled in the default ISO.

---

## 5. Desktop Strategy

**Open — no compositor chosen yet.** `CONTRIBUTING.md` already flags
"introducing a desktop / GUI stack or Wayland compositor layer" as
RFC-required, and `README.md`'s "Next" list has it unchecked. This is the
single biggest undecided piece of the platform, since the sandboxed-app
model (§2) and gaming strategy (§6) both depend on which compositor/
session we pick.

Drafted: [`docs/rfcs/0001-desktop-wayland-compositor.md`](rfcs/0001-desktop-wayland-compositor.md)
proposes a wlroots-based compositor + `seatd` (no systemd-logind) with a
thin `novi-shell` on top, run as an s6-rc service like everything else.
It's a draft, not yet opened for the 7-day discussion period required by
`CONTRIBUTING.md`.

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

## Status Summary

| # | Area | State |
|---|---|---|
| 1 | Base architecture | ✅ Decided |
| 2 | Package/application model | 🟡 Native done, sandbox tier proposed (RFC needed) |
| 3 | Update/rollback model | 🟡 Track split decided, on-device rollback open |
| 4 | Hardware strategy | 🟡 x86_64 kernel exists, coverage + aarch64 open |
| 5 | Desktop strategy | 🔴 Open — next RFC to open |
| 6 | Gaming strategy | 🔴 Open — blocked on #5 |
| 7 | Developer strategy | 🟡 Native toolchain exists, container tier proposed |
| 8 | Enterprise strategy | 🟡 LTS branches exist, signing enforcement + fleet mgmt open |
| 9 | Security model | 🟡 Small TCB + disclosure process exist, signing default open |
| 10 | Community/governance | ✅ Decided |
| 11 | Differentiation | ✅ Articulated above |

**Next concrete step:** open [RFC 0001](rfcs/0001-desktop-wayland-compositor.md)
(desktop/compositor choice) for the 7-day community discussion period —
every open item in §2, §6 depends on it, and it's the largest remaining
unknown.
