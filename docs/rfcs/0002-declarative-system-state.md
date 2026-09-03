# RFC 0002: One Source of Truth — Declarative System State

- **Status:** Draft (not yet opened for community discussion). Core
  engine implemented and QEMU-verified; see "Implementation status".
- **Labels:** `rfc`
- **Author:** platform direction follow-up (`docs/PLATFORM-ROADMAP.md`
  §3, §11)
- **Requires:** RFC per `CONTRIBUTING.md` — this defines a new
  system-wide configuration contract and is the intended spine for §3's
  unsolved on-device rollback story.

---

## Motivation & Problem Statement

### The honest version of "what makes Novi different"

`docs/PLATFORM-ROADMAP.md` §11 currently claims the differentiator is
separating concerns other distros bundle: two update tracks, a small
native base, breadth via sandboxed apps. That is a good architecture.
It is not a *differentiator*, and the roadmap should not pretend
otherwise:

- **Small immutable base + sandboxed apps** is precisely Fedora
  Silverblue, SteamOS 3, Vanilla OS, blendOS, and ChromeOS. It is the
  current industry consensus, not a distinguishing position.
- **Two update tracks** is openSUSE (Leap/Tumbleweed), Fedora
  (stable/rawhide), Debian (stable/sid).
- **From-scratch musl + s6** is Alpine, Void (musl), Chimera, Adélie,
  oasis, KISS.

Every one of those is a real project with years of head start. "We did
it too, from scratch" is not a reason for anyone to switch.

### The gap nobody has actually closed

On every mainstream Linux desktop, **the GUI and the config files are
two parallel, unreconciled sources of truth.**

Toggle a setting in GNOME Settings and it lands in dconf: a binary
keystore, invisible to `grep`, absent from your dotfiles, undiffable,
unversioned, and unknown to the config file that nominally governs the
same thing. Edit the config file instead and the GUI has no idea. The
two drift, silently, forever. Ask any Linux user to answer "what is
actually configured on this machine, and what changed since last
Tuesday" and there is no command that answers it.

This is not a small papercut. It is the reason system configuration on
Linux is not reproducible, not reviewable, and not undoable — and the
reason "it works on my machine" survives.

**NixOS and Guix genuinely solve determinism — by amputating the GUI to
do it.** Configuration is a functional-language text file; there is no
first-party GUI that can *write* the system's truth, and the GUI
settings apps that do exist actively fight the model (change something,
lose it on next rebuild, or diverge invisibly). The price of
reproducibility is currently "give up the graphical settings surface,
and learn a language."

Nobody ships an OS where **clicking a toggle and editing a text file
are the same operation on the same document**, with real diff and real
rollback.

### Why Novi specifically can

Because Novi owns every layer with no upstream to negotiate with: the
init system (s6-rc — already a declarative, compiled dependency graph),
the package manager (`pkg` — already has an install DB), the compositor
(`novi-shell`), and the settings app (`novi-settings`). There is no
GNOME release cycle to petition, no dconf to work around, no systemd
generator to fight. The four layers that would each have to cooperate
on any other distro are all in this repo.

This is also the *exact* mechanism behind a philosophy commitment
already written in `docs/PLATFORM-ROADMAP.md` and currently unbacked by
anything: **"user control over their own machine"** — "a package model
that never hides what's installed," "an update model the user drives
rather than one that drives them." Today those are stated values. This
RFC is the machinery that makes them checkable.

---

## Proposed Design

### The document

`/etc/novi/system.conf` is the system's declared state. Not a cache of
it, not a hint to it, not one of several places it might live — the
single declared truth, in plain text.

```
hostname = novi

services.syslog = on
services.getty-tty1 = on
services.seatd = off
services.novi-shell = off
```

Format: `key = value`, one per line; `#` comments; blank lines and
indentation allowed and preserved. Keys are dotted paths, values are
bare words.

**Why not TOML/JSON/YAML.** This file must be parsed by a BusyBox shell
script *and* by a C GUI with no parser library on either side, stay
greppable (`grep services. system.conf`), stay diffable line-by-line in
git, and stay comfortable to hand-edit with comments. A flat dotted-key
format is the only candidate that is all five at once. Nesting buys
nothing here and costs a parser on both sides.

### The four verbs

```
novi-state show        what the system is DECLARED to be
novi-state diff        declared vs. what it ACTUALLY is (drift)
novi-state apply       make actual match declared
novi-state rollback    restore a previous generation and apply it
```

Plus `get`, `set`, `history`, and `apply --dry-run`.

**Declaring and applying are deliberately separate.** `set` only edits
the document; nothing touches the running system until `apply`. That
separation is what makes "review the diff before it happens" possible,
and it is what lets a GUI toggle and a text edit be *the same
operation* — both merely write the document.

`diff`'s exit status is meaningful: `0` converged, `1` drifted. It is
usable as a check in a script or CI job, not only as something a human
reads.

### Observation is ground truth

Every key has an *observer* that goes and looks at the real running
system — never a cache, never the state file:

| Key | Observed from | Converged by |
|---|---|---|
| `hostname` | `/proc/sys/kernel/hostname` | `hostname` + `/etc/hostname` |
| `services.<name>` | `s6-rc -a list` | `s6-rc -u/-d change <name>` |

`diff` is only meaningful if these genuinely go and look. A state
engine that compares the file to itself is theatre.

### Generations

Every `apply` first snapshots **what the system actually is, as
observed** — not what the file says — into
`/var/lib/novi-state/generations/NNNN.conf`, then converges.

Snapshotting observation rather than the document is load-bearing, and
was found the hard way (see "Implementation status"): by the time
`apply` runs, the document has already been edited to the *new* desired
state, so copying it would save the change rather than what the change
replaced, and `rollback` would restore the very thing it was meant to
undo. Snapshotting observation also makes a generation ground truth: if
the machine had drifted from the document before this apply, the
generation records where the machine really was, which is what someone
rolling back actually wants back.

`rollback` is itself an `apply`, so it snapshots too — **rolling back is
reversible.**

### What this is not

- **Not Nix.** No functional language, no content-addressed store, no
  rebuild-the-world. The state file describes *configuration*, not
  package derivations. Package state stays `pkg`'s job (§2); this
  engine will eventually *declare* it, not replace it.
- **Not full-system immutability.** Nothing here prevents imperative
  changes. It makes them *visible* — that is precisely what `diff` is
  for. Novi's position is "you may do anything to your machine, and the
  machine will always be able to tell you what you did," not "you may
  not touch anything."
- **Not a config-management agent.** No daemon, no polling, no central
  server. `apply` runs when a person or a script runs it.

---

## Alternatives Considered

| Alternative | Why not |
|---|---|
| **Adopt Nix/Guix wholesale** | Buys determinism at the cost of the entire from-scratch base this project exists to be, a functional language as the config surface, and a ~GB store on a distro whose whole pitch is a small auditable TCB. Also inherits the no-GUI-writer problem verbatim. |
| **dconf/gsettings-style keystore** | The exact anti-pattern this RFC exists to fix: binary, invisible, ungreppable, undiffable. |
| **Just document "edit these config files"** | That is every distro today. The GUI still can't participate, and nothing can answer "what drifted." |
| **Make it a C daemon** | A state engine's core value is auditability — "you can read the thing that governs your OS" is part of the pitch. A ~400-line shell script anyone can read beats a binary. Matches `pkg`'s existing precedent exactly. |
| **etckeeper (git over /etc)** | Versions the files but has no notion of declared-vs-actual, no observers, no convergence. Answers "what changed on disk," never "does the running system match." |

---

## Implementation status

The core engine is **built and QEMU-verified**, not proposed:

- `packages/novi-state` — the engine (shellcheck-clean, BusyBox ash).
- `rootfs/etc/novi/system.conf` — shipped default, declaring exactly
  what a stock boot actually produces.
- `build/15-novi-state.sh` — installs both plus the generations dir.

Verified live on a fresh boot, in this order:

1. **Fresh boot reports converged**, exit `0` — no spurious drift. (A
   state engine whose very first `diff` is wrong teaches users to
   ignore it, so this property is worth protecting deliberately.)
2. `set services.seatd on` + `set services.novi-shell on` — **surgical
   in-place edit**: values changed, every comment and blank line in the
   file intact.
3. `diff` — both drifts reported, exit `1`.
4. `apply` — generation `0001` snapshotted, both services converged,
   and **the desktop came up**: screendump confirmed the live panel,
   Apps button and clock. A compositor session brought into existence
   by editing a text file.
5. `rollback` — restored `0001`, snapshotted the current state as
   `0002` first (so the rollback is reversible), converged both
   services back down, and the desktop went away: pixel-confirmed the
   panel row is `(0,0,0)` black where the navy bar had been.

A real bug was found and fixed during that run: `rollback` initially
answered "already converged — nothing to apply", because
`snapshot_generation` copied the state file (already edited to the new
values) instead of observing the system. Fixed as described under
"Generations" above, and re-verified from a clean boot.

### The GUI is now a front-end to the same document

`novi-settings` gained a **System** panel, which is what turns this
RFC's central claim from an assertion into something demonstrable. It
lists every key in `/etc/novi/system.conf` with its declared value,
marks the ones the running system doesn't currently match, toggles with
Space, and applies with Enter.

Two implementation constraints hold the claim up:

- **Writes go through `novi-state set`, never through the GUI's own
  file writer.** novi-state's `state_set()` edits in place, preserving
  comments and ordering; a second implementation in C would be a second
  thing that can drift from it, and the first time the GUI clobbered a
  user's comments the document would stop being worth hand-editing —
  which is the whole proposition. One writer, one behavior.
- **Drift comes from `novi-state diff`, not from observing anything in
  C.** A parallel "is this service up" check in the GUI would be
  exactly the second source of truth this RFC exists to abolish.

Verified live, both directions:

1. Opened Settings from the launcher, `→` to the System panel: all six
   declared keys listed, no drift markers, correctly converged.
2. Toggled `services.syslog` with Space. The row went to `* off` in the
   accent colour with "Declared — press Enter to apply", and on disk
   `system.conf` line 30 had changed while line 29's comment
   (`# Structured system logging (s6-log).`) was **intact** — and
   `s6-rc` still reported syslog *up*, because declaring is not
   applying.
3. Enter. `s6-rc` then reported syslog down, generation `0002` was
   written, and the marker cleared to "Applied — system matches the
   document". **A GUI change is as rollback-able as a CLI one.**
4. Hand-edited the file from a terminal with `sed` — deliberately *not*
   through `novi-state`, to prove the GUI reads the real file — then
   took keyboard focus away and gave it back. The GUI showed the
   hand-edit and flagged it as drifted, **with no reload key pressed**.

An efficiency problem surfaced there and was fixed in the canonical
path: `observe_service()` forked `s6-rc -a list` once *per declared
service*, and `diff` is the hot path (the System panel calls it on
every refresh). The live list is now read once per run and cached.
Priming that cache has to happen in the parent shell, never lazily
inside `observe_service()` — every caller reads it as
`have="$(observe_key …)"`, and a command substitution is a subshell, so
an assignment made in there is discarded on return. That is the same
subshell trap `packages/pkg` hit for real. `apply` re-primes each
iteration and invalidates after every converge, because s6-rc brings a
service's dependencies up with it (`novi-shell` pulls `seatd`), so a
list cached before a converge is stale for every key after it.

### Boot-time convergence

Until this landed, the document governed the machine only *after* you
logged in and asked it to. Declaring `services.novi-shell = on` and
rebooting got you a bare console — the state file was something you
could push the system to, not something the system booted into. That is
a real hole in "the document is the truth", and closing it is what
makes the claim hold across a power cycle.

`novi-state boot` runs once per boot and converges. Two safety
properties make it defensible to enable by default, because a state
engine that can brick a boot is worse than no state engine:

1. **It always exits 0.** A failed converge must never stop a machine
   from reaching a login prompt you can fix it from.
2. **`novi.state=off` on the kernel command line skips it entirely** —
   the recovery path for when the declared state is itself the problem
   (someone declares every getty off). Same shape as `single` or
   `init=/bin/sh`, and reachable from the bootloader without needing
   the machine to boot first.

`state.apply_on_boot = off` in the document turns it off the ordinary
way. That key is the first of a `state.*` class that configures the
engine rather than the machine: such keys observe as their own declared
value and never register as drift, because there is no external fact to
compare against.

**Where it runs, and the wrong answer that was tried first.** The
obvious design — an s6-rc oneshot in the `default` bundle — does not
work, and failed in a way worth recording because it looked like it
worked. The oneshot ran, reported success, and appeared as `up` in
`s6-rc -a list`; the declared desktop simply never started. The cause:
a oneshot in a bundle runs *during* that bundle's transition, and a
nested `s6-rc change` cannot proceed while the transition holds the
live-state lock. It failed instantly, and safety property (1) turned
that into a clean exit rather than a visible error. The same
`novi-state boot`, run by hand seconds later, brought the desktop
straight up — which is what proved the code was right and the *timing*
was wrong.

Convergence therefore runs from `init/skel/rc.init`, immediately after
the initial `s6-rc change` returns. `rc.init` no longer `exec`s into
the runlevel script so that something can follow it; nothing is lost,
since `s6-rc change` exits when the transition completes and `rc.init`
already ended there.

Verified live, all three paths, each from a cold boot:

- **Stock default** (desktop declared off): boots to a console, reports
  converged (exit 0), and writes **no generation** — convergence found
  nothing to do, and correctly declined to burn one.
- **Desktop declared on in the shipped image**: boots straight into a
  graphical session — panel, Apps button, clock — with **zero input**.
  No login, no commands. The machine booted into what the document
  said.
- **`novi.state=off` on the kernel command line**: document still
  declares `services.novi-shell = on`, `s6-rc -a list` reports it not
  running, machine sits at a plain console. The escape hatch works.

A bug in the safety property itself was found and fixed before any of
that: `die()` ends in `exit 1`, and `cmd_apply` runs in the same shell,
so a converge failure tore the script down before `|| warn` could run —
`novi-state boot` exited 1, which would have marked the boot step
failed. Exactly the outcome property (1) promises cannot happen.
`cmd_apply` now runs in a subshell so the exit is confined to it, and
the failure surfaces as a console warning instead. Measured before and
after: exit 1, then exit 0, with the warning still printed.

Generations are now pruned to the most recent 20
(`NOVI_STATE_KEEP`). Without that, a machine whose declared state
differs from what the `default` bundle starts — the normal case for
anyone who declared a desktop — would write one generation per boot,
forever.

### What deliberately does *not* go in the document

The Account panel still writes `/etc/shadow` directly, and that is now
a **decision, not a gap**: a password hash has no business in a
world-readable file that this RFC actively encourages people to commit
to git. Secrets stay in their own 0600 store. The panel says so on
screen rather than leaving it looking like unfinished work.

The general rule this sets: `system.conf` is for *configuration*, and
anything whose confidentiality matters keeps its own storage with its
own permissions. A future `users.*` domain can declare that a user
exists without declaring their secret.

---

## Roadmap

**Landed (this RFC):** the engine, generations, `hostname`,
`services.*` and `state.*` domains, `novi-settings`' System panel (the
GUI reading and writing the same document, both directions verified
live), and boot-time convergence with a kernel-command-line escape
hatch.

**Next, in dependency order:**

1. **More domains:** `packages.*` (declare installed packages, converge
   via `pkg`), `users.*`, `network.*`, `desktop.*` (keybindings, theme
   — RFC 0001 already calls for keybindings to move to a user-editable
   config file; this is that file). `packages.*` is the one that makes
   "commit your machine, reproduce it elsewhere" literally true.
2. **Move the subprocess calls off the GUI event loop.** They block it
   today. Fine at this scale (an `apply` is a couple of s6-rc
   transitions) and noted in a comment where someone will hit it, but
   it stops being fine the first time a domain converges something slow
   — a package install.
3. **`novi-state diff` in CI**, and a `--json` projection for tooling.
4. **Concurrent-edit safety.** Two writers racing on `system.conf`
   (the GUI and an editor) can currently lose one side's change; the
   atomic `mv` keeps the file well-formed but does not detect a
   conflict. A generation counter or mtime check on write would.

**Deliberately out of scope for now:** atomic rootfs A/B switching (§3)
— this RFC gives that a spine to hang from (generations are already the
right shape) but does not attempt it.

---

## Impact

- **Everyday users:** every setting is visible in one file, and "undo"
  is a real command instead of trying to remember what you clicked.
- **Developers:** `git commit /etc/novi/system.conf` versions your
  machine; the same file reproduces it on another one.
- **Security practitioners:** `novi-state diff` answers "has anything
  on this box changed" — a genuine audit primitive, and a clean known
  state to return to after an engagement (§12).
- **Gamers:** try the risky driver setting, roll it back cleanly.

One mechanism, all four audiences — which is exactly what the
Philosophy section means by "four use cases the same rootfs serves at
once," rather than four spins.

**Footprint:** one ~400-line shell script and a text file. No daemon,
no new library, no new dependency. Consistent with §1's "no bloat."
