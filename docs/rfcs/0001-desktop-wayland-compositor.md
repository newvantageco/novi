# RFC 0001: Desktop Layer — Wayland Compositor Choice

- **Status:** Draft (not yet opened for community discussion)
- **Labels:** `rfc`
- **Author:** platform roadmap follow-up (`docs/PLATFORM-ROADMAP.md` §5)
- **Requires:** RFC per `CONTRIBUTING.md` ("Introducing a desktop / GUI
  stack or Wayland compositor layer")

This is a draft to be opened as a GitHub issue (label `rfc`) or Discussion
under **Architecture & RFCs**, per the RFC Workflow in `CONTRIBUTING.md`.
It is not itself a decision — it's the proposal the 7-day discussion
period is meant to react to.

---

## Motivation & Problem Statement

Novi has no desktop layer today (`README.md` "Next" list, unchecked).
Two roadmap items are blocked on it:

- **§2 Package/application model** — the sandboxed desktop-app tier
  (Flatpak-compatible OCI bundles) needs a compositor/session to run
  under before it means anything.
- **§6 Gaming strategy** — Proton/gamescope both assume a Wayland
  session exists.

We need to pick *one* compositor architecture now, because every
downstream decision (portal support, XWayland, session management,
how `pkg` ships desktop packages) depends on it, and re-deciding later
means reworking whatever's built on top.

The constraint that makes this non-trivial: Novi is musl + s6, not
glibc + systemd. Most desktop stacks (GNOME, KDE, COSMIC) assume
systemd (logind, systemd-user sessions) and are routinely built and
tested against glibc. We either adopt a stack that's compatible with
that constraint, or we take on a maintenance burden patching around it
indefinitely.

## Proposed Technical Design & Architecture

Adopt a **wlroots-based compositor** with a thin, purpose-built Novi
shell on top, rather than importing a full desktop environment.

```
┌─────────────────────────────────────────┐
│              novi-shell                 │  panel, launcher, notifications,
│      (our compositor-side UI code)       │  session switcher — Novi-specific
├─────────────────────────────────────────┤
│                wlroots                   │  compositor library: output/
│         (upstream, unmodified)           │  input handling, XDG-shell,
│                                           │  XWayland, layer-shell protocols
├─────────────────────────────────────────┤
│         seatd (session/seat mgmt)        │  logind-alternative, no systemd
├─────────────────────────────────────────┤
│      s6-supervised graphical target      │  compositor launched as an
│                                           │  s6-rc service, like any other
└─────────────────────────────────────────┘
```

Key decisions this locks in:

1. **wlroots, not a from-scratch compositor.** It's the library Sway,
   river, Hyprland are built on — mature, actively maintained, and the
   thing we'd end up reinventing badly if we wrote our own.
2. **`seatd` instead of systemd-logind** for seat/session management —
   it's the standard logind-free answer and already used by musl-based
   distros running Sway.
3. **Compositor runs as an s6-rc service** (a `graphical` target that
   depends on `seatd`), same supervision model as everything else in
   `init/services/` — no parallel service manager introduced.
4. **XWayland support enabled** from day one — required for the
   sandboxed-app tier (§2) to run the large body of X11-only software
   that hasn't ported to Wayland.
5. **`novi-shell` is new code we own** — panel, app launcher, session
   switcher — built against wlroots' layer-shell protocol. This is
   where Novi's actual product identity lives; wlroots stays vendored
   upstream and unmodified so we're not maintaining a compositor fork.

## Impact on Footprint & Dependencies

- New build dependencies: `wlroots`, `wayland`, `wayland-protocols`,
  `seatd`, `libdrm`, `libinput`, `pixman` — all musl-compatible, all
  already used by existing musl/Alpine-based Wayland setups, so this is
  a known-good combination, not exploratory.
- New runtime service: one `graphical` s6-rc target + `seatd`, both
  fitting the existing supervision model (`init/services/`) with no new
  process-management concept introduced.
- No systemd pulled in at any layer — the constraint from the Motivation
  section holds throughout this design.
- Package footprint: this is `pkg`'s first real test of the "native for
  system components" boundary from §2 — wlroots/seatd/novi-shell ship as
  native `pkg` packages; the *applications* that run under the
  compositor go through the sandboxed tier, not native, keeping the
  native package set from ballooning.

## Alternatives Considered & Drawbacks

| Option | Why not (for now) |
|---|---|
| **Full GNOME/KDE/COSMIC** | Deep systemd assumptions (logind, systemd --user, GSettings/dconf infrastructure); large glibc-oriented dependency trees; would mean either patching a major DE against musl+s6 indefinitely, or quietly pulling in systemd and abandoning the base-architecture rationale in §1. |
| **Write a compositor from scratch** | wlroots already solves output/input/protocol handling correctly; reimplementing it is years of work for no user-visible benefit and a large ongoing security-maintenance surface. |
| **Ship Xorg instead of Wayland** | Wayland is where upstream investment (Mesa, GPU vendors, app toolkits) is now going; picking X11 as the default in 2026 trades short-term compatibility for a shrinking upstream. XWayland (included in the proposed design) already covers the compatibility gap. |
| **Defer the decision, ship headless-only for now** | Blocks §2's sandboxed-app tier and all of §6 (gaming) indefinitely; the roadmap already flagged this as the long pole, deferring further just delays every dependent item. |

## Migration / Compatibility Plan

- No existing users/state to migrate — this is greenfield (no compositor
  ships today).
- Sequencing once this RFC is accepted:
  1. Package `wlroots` + deps + `seatd` via `pkg` (native tier).
  2. Add `graphical` s6-rc service definitions under `init/services/`.
  3. Build minimal `novi-shell` (panel + launcher) against wlroots.
  4. Wire the sandboxed-app tier (§2) to launch under the new session.
  5. Gaming strategy (§6) work (gamescope, Proton packaging) can start
     once step 4 lands.
- Rollback if this RFC's approach proves wrong: since novi-shell is thin
  and wlroots is unmodified upstream, swapping compositor libraries later
  means rewriting novi-shell, not unwinding a systemd/DE dependency chain
  — the blast radius of getting this wrong is contained by design.

---

## Discussion Period

Per `CONTRIBUTING.md`: open as a GitHub issue labeled `rfc` (or a
Discussion under **Architecture & RFCs**), minimum 7 days of discussion,
core team approval before implementation begins.
