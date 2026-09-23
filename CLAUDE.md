# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Novi Linux ("Axiom") is a from-scratch Linux distro — not a derivative of any
existing distro. Own cross-toolchain (musl-linked GCC/binutils), own libc
(musl, not glibc), own init (s6 + s6-rc + execline, not systemd), own
userland (static BusyBox), own kernel build (vanilla Linux source + a
curated config), own package format (`.pkg.tar.gz` via `pkg`/`mkpkg`, not
apt/dpkg/pacman/rpm). See `README.md` for the stack table and
`docs/PLATFORM-ROADMAP.md` for the full platform vision (package model,
update tracks, hardware/desktop/gaming/security strategy) — that doc and
`docs/rfcs/` are the source of truth for architectural direction, not just
this file.

## Build commands

Full pipeline: `bash build.sh` — it **discovers** `build/NN-*.sh` and runs
all of them in numeric order, so a new stage is part of the build the moment
the file exists. **01–49 build content into the rootfs; 50+ package
it.** That gap is deliberate: everything that puts a file in the image
has to run before `50-repo.sh` computes the base/desktop split from
what is there. A base binary built *after* the split would ship, but
pkgsplit would have computed the split without it — which is a trap
rather than a rule, and the reason the gap is enforced by numbering
instead of by care.

**The packaging stages have moved twice, and the second time is why
40–49 is empty today.** They were 30/31/32 with content filling 20–29;
they became 40..43; they are 50..53 now. Each move happened because
content had filled the range and a new stage had nowhere legal to go —
the third time, RFC 0031's browser had to become a *phase* of
`35-devtools.sh` for want of a number, which is exactly the squeeze
this numbering exists to prevent. **So: put a new content stage in a
free number in 40–49, and do not squeeze an unrelated phase into an
existing stage.** When 40–49 fills, the next person moves the
packaging stages again (50..53 → 60..63) before adding anything, and
updates this paragraph — `NN` appears in prose all over this
repository, so a renumber is about thirty files, most of them
documentation. Two stages may not share a number and `build.sh` refuses
if they do: `NN` is what `--from`/`--to` name and what a failed stage tells
you to resume from, so a duplicate turns the identity into a guess. `--base-only` stops after the kernel (01–05: bootable
console, no desktop/pkg/state/installer), `--from NN` resumes. Each stage can
also be run standalone (`bash build/NN-*.sh`) but stages depend on prior
stages' output in `/build/{sources,tools,sysroot,rootfs}` — see Architecture
below for why `/build` is hardcoded and unrelated to the repo checkout path.

- `bash build/01-fetch.sh` — download all sources (idempotent, skips existing files)
- `bash build/02-toolchain.sh` — cross-compiler: binutils → gcc → musl (7 phases, order matters — see below)
- `bash build/03-base.sh` — static BusyBox + rootfs hierarchy
- `bash build/04-s6.sh` — skalibs → execline → s6 → s6-rc → s6-linux-init
- `bash build/05-kernel.sh` — Linux kernel using `kernel/config-x86_64`.
  It also runs `scripts/prune-dead-applets.sh`, which removes busybox
  applet symlinks this kernel cannot support (`kernel/dead-applets`) —
  here rather than in 03, because the answer comes from the GENERATED
  config and that does not exist until this stage
- `bash scripts/mkinitramfs.sh --output <path>` — build the boot initramfs
- `bash scripts/mkiso.sh` — squash rootfs + GRUB hybrid ISO. Takes no
  arguments: its defaults are `${ROOTFS}` and
  `${ROOTFS}/boot/vmlinuz-${LINUX_VERSION}`, which are correct. (This
  note used to say the defaults were wrong and to pass
  `--rootfs`/`--kernel` explicitly. They were fixed; the note was not,
  and it outlived the bug by long enough to waste real time. Verified
  by running it bare.)
- `bash scripts/mkvm.sh [--disk]` — boot the ISO in QEMU/KVM
- `novi-install install --disk DEV` (on the booted live system) — install to
  disk (RFC 0003)
- `bash build/50-repo.sh` — build and sign the first-party package
  repository into `/build/repo` (RFC 0006); serve that directory over HTTP
  and point a machine at it with `mirror =` in `/etc/novi/pkg.conf`
- `bash build/25-wifi.sh` — libnl, wpa_supplicant, `iw`, `novi-wifi`
  (RFC 0009); also builds hostapd into `/build/wifi-test/` for the hwsim
  test harness, deliberately not into the image
- `bash build/21-imagelibs.sh`, `bash build/22-novi-view.sh` — zlib and
  libpng (the first image *decoding* on this system; novi-screenshot
  could only ever write) and the viewer that uses them
- `bash build/23-e2fsprogs.sh`, `bash build/24-novi-gpt.sh` — real `mke2fs`
  (journalled ext4) and the GPT writer UEFI installs need (RFC 0008)
- `bash build/51-desktop-split.sh` — **destructive**: removes the packaged
  desktop from `/build/rootfs`, leaving a console-only base (RFC 0007).
  Must run after 50; re-running the content stages (`--from 06 --to
  49`) puts the files back
- `bash build/26-firmware.sh` — curated linux-firmware + `wireless-regdb`
  + Intel SOF into `${ROOTFS}/lib/firmware` (~699 MB)
- `bash build/27-audio.sh` — alsa-lib + alsa-utils (`amixer`, `alsactl`,
  `aplay`, `speaker-test`)
- `bash build/28-native-toolchain.sh [musl-dev|make|binutils|gcc|repo|all]`
  — the native (self-hosting) toolchain, staged into
  `/build/stage-toolchain` and packaged into `/build/repo` by the
  `repo` phase, which re-signs the index. Takes a phase argument
  because the gcc build is long and the others are not
- `bash build/30-novi-umh.sh` — `/sbin/usermode-helper`, the one binary
  `CONFIG_STATIC_USERMODEHELPER` lets the kernel exec. Without it no
  kernel-initiated `request_module()` runs at all (RFC 0016)
- `bash build/33-nftables.sh` — libmnl, libnftnl, nftables and the
  shipped ruleset `/etc/novi/firewall.nft` (RFC 0016). Base image, not
  a package: 1.1 MB stripped
- `bash build/34-cryptsetup.sh` — LUKS2 (RFC 0018): popt, json-c,
  libuuid and libdevmapper built static into a private prefix and
  linked into one `cryptsetup` binary, which is the only thing
  installed
- `bash build/31-mbedtls.sh` — mbedTLS (RFC 0020), into
  `/build/tls-deps` for linking and into the `mbedtls` package for the
  target. Never `${ROOTFS}`: a TLS stack in the base image is the
  thing that RFC is careful to avoid
- `bash build/35-devtools.sh [openssh|ca|curl|git|netsurf|repo|all]` —
  the ssh client, the CA bundle, curl, git and **NetSurf** (RFC 0019,
  RFC 0020, RFC 0031), staged into `/build/stage-devtools` and
  published by `53-devtools-repo.sh`. Packages, never base. Also
  builds `sshd` into `/build/ssh-test/` as the test peer, deliberately
  not into the image. The `netsurf` phase is a phase of 35 rather than
  a stage of its own because it must run BEFORE `51-desktop-split.sh`
  (it reads `${ROOTFS}` headers) and publish AFTER `50-repo.sh` (which
  wipes the repo). It was also written when every number from 01 to
  39 was taken; 40–49 is free now, but moving it would be churn
- `bash build/32-openssl.sh` — OpenSSL 3.5 LTS (RFC 0027), into
  `/build/openssl-target` for linking and into the `openssl` package
  for the target. Never `${ROOTFS}`: the base image still ships no TLS
  library, and `novi-verify` is still static TweetNaCl. It exists
  because CPython's `ssl` accepts no other implementation
- `bash build/40-ncurses.sh [ncurses|readline|package|all]` — ncurses
  and GNU readline (RFC 0026 roadmap 2), into `/build/ncurses-target`
  for linking and into their own packages. **Must run before
  `41-sqlite.sh` and `43-python.sh`**: CPython decides at configure
  time whether `readline` and `_curses` exist and says nothing
  afterwards, and sqlite's CLI links this readline
- `bash build/41-sqlite.sh [sqlite|package|all]` — SQLite (RFC 0026
  roadmap 3), into `/build/sqlite-target` for linking and into its own
  package. **Between 40 and 43, and bracketed by both**: the CLI links
  the readline built at 40, and CPython decides at configure time
  whether `_sqlite3` exists. 38 and 39 are free and are no use here
- `bash build/43-python.sh` — CPython, cross-compiled against musl and
  staged into `/build/stage-devtools` for `53-devtools-repo.sh` to
  publish (RFC 0026). A package, never base. It reads zlib, libffi and
  expat out of `${ROOTFS}`, so it must run before
  `51-desktop-split.sh` takes them out, and it needs a **`python3.11`
  on the build host** — cross-compiling CPython runs an interpreter of
  the same major.minor during `make`
- `bash build/15-novi-state.sh` also installs `/usr/lib/novi/json.sh`
  and `novi-agent` (RFC 0029) — the agent interface is base image, not
  a package
- `bash build/46-gnu.sh [bash|coreutils|package|all]` — GNU bash and
  coreutils (RFC 0040), the CLI gap `docs/PLATFORM-ROADMAP.md` §5
  named and nobody built. Staged into `/build/stage-devtools` and
  published by `53-devtools-repo.sh`. **`/usr/gnu/bin`, never
  `/usr/bin`**: `pkg` refuses an unowned path now (RFC 0040 roadmap
  1), so a package shipping `/usr/bin/ls` would have to declare
  `replaces-files=` for it -- ~100 declared takeovers with ~100 saved
  originals, which is a worse answer than a prefix and a PATH entry
- `bash build/47-mandoc.sh [mandoc|package|all]` -- mandoc (RFC 0040
  roadmap 2), the `man` package. Staged into `/build/stage-devtools`
  and published by `53-devtools-repo.sh`. Every `configure` answer is
  supplied by hand in `configure.local`, because mandoc's `runtest`
  compiles a probe and then **executes** it
- `bash build/44-novi-recon.sh` — `novi-recon` (RFC 0028), the recon
  tool. Nothing to compile: it is a Python script, which is the point.
  It runs the host test suite and parses the script with the target's
  exact major.minor before packaging — a syntax error in Python is a
  RUNTIME error, so without that the package builds, signs, verifies
  and fails at the first invocation
- **`bash build/16-s6-rc-db.sh` after ANY change under `init/`** (see below),
  then `bash scripts/mkinitramfs.sh --output build/initramfs.cpio.gz` and
  `bash scripts/mkiso.sh` to get it into a bootable image

Lint: `shellcheck build/*.sh scripts/*.sh packages/pkg packages/mkpkg`.
Full verification sequence (from `CONTRIBUTING.md`): shellcheck clean →
`rm -rf build/rootfs build/isoroot && bash build.sh` → `mkiso.sh` →
`mkvm.sh` boots to login without panic → binaries link against musl only
(`readelf -d`/`ldd`, no glibc symbols).

Package tooling: `packages/mkpkg <src-dir> <out-dir>` builds a
`<name>-<version>-<arch>.pkg.tar.gz`; `packages/pkg install <file-or-name>`
installs one. Format spec: `packages/pkg-format.md`.

## Architecture: `novi-state` is the system's single source of truth

`packages/novi-state` (RFC 0002, `docs/rfcs/0002-declarative-system-state.md`)
is the project's actual differentiator, not a side utility:
`/etc/novi/system.conf` is the declared system state, and
`show`/`diff`/`apply`/`rollback` converge the running system to it.
Observers read real live state (`/proc/sys/kernel/hostname`,
`s6-rc -a list`) — never a cache, or `diff` is meaningless.

Two invariants worth not breaking:

- **`state_set` edits in place, preserving comments and ordering.** The
  file must stay pleasant to hand-edit, or the "GUI and text editor
  write the same document" claim collapses and it becomes another
  machine-owned blob.
  The same care applies to editing the *shipped* `system.conf` by hand:
  most of that file is commented-out examples, and a patch that lands
  one line off turns an example into a declaration. That is how
  `power.governor = schedutil` — documented right there as *"not set by
  default"* — became live on every image. Read a `system.conf` diff for
  what it **uncomments**, not only for what it adds.
- **There is ONE WRITER AT A TIME now, and there was not before.**
  `state_set` is a read-modify-write of the whole document; the `mv`
  is atomic, so the file is never half-written, and that was the whole
  of the protection. Two overlapping writers produced a well-formed
  document with one of the two changes in it and **no error from
  either** — the losing caller was told `declared: hostname = one`
  while the document still said `start`. `apply` had it one level up:
  `next_generation()` reads the highest number and adds one, so two
  applies pick the same one and a snapshot a rollback would restore is
  silently replaced. `mkdir(2)` is the lock (no `flock` in BusyBox —
  novi-mount's mechanism), reentrant within one process (rollback →
  apply → set would otherwise deadlock on its own correctness), and
  **stale is a fact rather than a timeout**: the owner file records
  the boot time as well as the pid, because a lock that survived a
  crash would otherwise be held forever by an innocent process that
  inherited the number. The test runs the same race against a copy
  with the locking removed and fails if that copy stops losing a
  write — a green test over a race that no longer reproduces has
  stopped watching. What is still unprotected, and cannot be from
  here: an editor saving a whole buffer over changes made since it
  opened the file.
- **Generations snapshot *observed* state, not the state file.** By the
  time `apply` runs, the file already holds the new values, so copying
  it would save the change instead of what the change replaced, and
  `rollback` would restore the very thing it was meant to undo. That
  bug was real and caught live; don't reintroduce it.

**Anything new that changes persistent system configuration should go
through `novi-state`, not straight to `/etc`.** `novi-settings`' System
panel is the worked example: it *reads* `system.conf` directly (reading
breaks no invariant) but every *write* shells out to `novi-state set`,
and drift comes from `novi-state diff` rather than a second observer
written in C. Don't reimplement either in a client.

The one deliberate exception is secrets: the Account panel writes
`/etc/shadow` directly because a password hash must not land in a
world-readable file the project encourages committing to git.
`system.conf` is for configuration; anything whose confidentiality
matters keeps its own 0600 storage.

**Boot convergence lives in `init/skel/rc.init`, not in an s6-rc
oneshot** — and that placement is load-bearing, not preference. A
oneshot inside the `default` bundle runs *during* that bundle's
transition, and a nested `s6-rc change` cannot proceed while the
transition holds the live-state lock. It fails in the worst way:
reporting success and appearing `up` in `s6-rc -a list` while having
converged nothing. Convergence has to run after `s6-rc change` returns,
which is why `rc.init` calls the runlevel script instead of `exec`ing
it. Don't "tidy" that back into a service.

`novi-state boot` must stay unfailable: it always exits 0, honours
`novi.state=off` on the kernel command line, and runs `cmd_apply` in a
**subshell** because `die()` ends in `exit 1` and would otherwise take
the whole script — and the boot step — down with it.

Three smaller things worth knowing before extending this:

- **The System panel edits VALUES now, not just on/off.** It could
  only flip booleans, so every key with a value — the hostname, the
  DNS list, `network.firewall.allow`, `storage.automount` — answered
  "edit it in the file", which made "the GUI and a text editor write
  the same document" a claim only half kept. `e` opens an inline
  editor on the selected row; the write still goes through
  `novi-state set`, never to the file. Three things it has to get
  right: the edit branch runs BEFORE the panel's other keys (Space
  must type a space, not toggle the row being edited), leaving the
  panel with Left/Right cancels the edit (that check runs first, so
  without it `editing` survives the switch and the panel is silently
  modal when you come back), and a value containing `#` is REFUSED —
  it would start a comment when the file is read back, so the GUI
  would corrupt the document it is a view of.
- **A list that shows a subset without saying so is a bug class, not
  an instance.** Having fixed it once, the same sweep found it in two
  more places -- the launcher stopped at six matches silently (its own
  symbol table produces nineteen more on a one-letter query), and the
  Network panel both stopped drawing at the window edge and dropped
  every SSID past its 24-entry cap. Where it was already handled it was
  handled loudly: novi-files reports a truncated listing in its status
  bar, novi-edit opens a too-large file read-only with the reason. The
  one deliberate elision left is novi-panel's taskbar, which gives an
  entry that will not fit `w = 0` so that render and hit-test agree it
  is absent -- Alt+Tab still reaches those windows, and the comment
  there says why.
- **The panel could only ever show its first fourteen keys.** No
  scrolling, a hard `break` at the window's bottom edge — so
  `network.firewall.allow` and everything after it was in the
  document, named in the panel's own heading, and unreachable. The
  scroll window is clamped in the draw, where the height is known, so
  a resize cannot leave it pointing at a row that no longer exists.
  Two things that must stay counted over the WHOLE document rather
  than the visible rows: the drift tally (scrolling must not change
  how many things are wrong with your machine) and the count of lines
  `load_state_file()` skipped for being too long, which used to vanish
  silently and is now reported.
- The GUI's `novi-state` calls **block the Wayland event loop**. Fine
  for a `set` (one awk pass) or an `apply` (a couple of s6-rc
  transitions); not fine once a domain converges something slow, like a
  package install. There's a comment at the call site.
- `observe_service()`'s live-service-list cache **must be primed from
  the parent shell** (`service_cache_load`), never lazily inside the
  function: callers use `have="$(observe_key …)"`, and a command
  substitution is a subshell, so the assignment would be discarded.
  Same subshell trap `packages/pkg` hit for real.
- **One key that cannot converge must not take the rest of the document
  with it.** `converge_key` reports an impossible value by calling
  `die`, which ends the script — so `cmd_apply` abandoned every key
  sorted *after* the failure, silently, with an exit status nobody read.
  It cost five boots. `power.governor = schedutil` was declared on a VM
  with no cpufreq driver; `power` sorts before `services`, and
  `novi-live-desktop` brings the desktop up by setting
  `services.novi-shell on` and running `novi-state boot` — so the
  desktop packages installed, the keys were declared on, and nothing
  started them. The machine came up to a console login prompt with one
  ERROR line three sections of the document away from the symptom, and
  `novi-live-desktop` printed "desktop ready" regardless because every
  step of it ends in `|| true`. Each converge runs in a **subshell**
  now, so a failure is a value rather than the end of the program, and
  a failed key is skipped in later passes (or one bad key prints the
  same error three times). `apply` returns non-zero; boot convergence
  still always exits 0.
- **A key that is *read at use time* is validated in the observer and
  nowhere else** (`power.blank`, `power.lid`, `power.button`,
  `storage.automount`). Nothing holds them, so they cannot drift and
  `apply` has nothing to converge — which also means `converge_key`
  never runs to reject a typo. `power.blank = ten` reports as
  `unsupported`, i.e. as drift, which is where a person finds out.
- **`bash build/16-s6-rc-db.sh` after ANY change under `init/`.** Both
  the s6-rc database and the s6-linux-init scripts are *generated*; the
  running system reads the generated copies, never `init/`, so an
  unregenerated change simply doesn't exist at boot. That stage is the
  two generation steps from `04-s6.sh` on their own — seconds instead
  of rebuilding the whole skarnet stack.

## Architecture: the shipped document, and the reference nobody could read

RFC 0002 roadmap 3. `packages/tests/test-state-document.sh`.

- **THE `--json` PROJECTION THAT ROADMAP ITEM ASKED FOR ALREADY
  EXISTED.** `show --json`, `diff --json` and `health --json` were
  built for RFC 0029's agent interface, which composes its document
  out of them. **Fourth roadmap item in this repository found to be
  wrong about what is already built**, after RFC 0002's own
  `packages.*`, RFC 0030's "a re-render there is not one function
  call", and RFC 0033's wired-network GUI. Check the code before
  believing an item — including one in your own RFC.
- **`diff` CANNOT RUN IN CI, and that is what it is rather than a
  gap.** It observes a RUNNING machine — s6-rc's service list,
  `/run/novi`, `/proc` — and a runner has none of that. Making it run
  there would mean faking the machine, and a test against a fake
  machine tests the fake.
- **What a runner CAN do is the shipped document.** Drive the observer
  over `rootfs/etc/novi/system.conf` and assert no key comes back
  `unmanaged`. The failure is silent BY DESIGN — an unrecognised key
  observes as `unmanaged` on purpose, for forward compatibility — so a
  typo there ships as a line that reads declarative, looks converged
  to anyone skimming, and converges nothing. Same class as the
  `power.governor = schedutil` line that got accidentally uncommented.
  `unknown` is NOT the same answer and must not be asserted on:
  services observe through `s6-rc` and `storage.automount` through
  `novi-mount`, neither of which exists on a build host.
- **Three lists, and the third is the one people read.** The DOCUMENT,
  the DISPATCHER, and `novi-state --help`'s `Keys:` block — the only
  place a person learns what a key is CALLED. Its first run found
  `power.lid`, `power.button`, `agent.enabled`, `agent.allow` and
  `agent.rate` live in the shipped document and absent from that
  reference. Five keys nobody could look up.
- **A `--json` mode that emits something unparseable breaks the AGENT
  INTERFACE, not just the command**, because `novi-agent describe`
  splices these into its own document. `health --json` needs
  `s6-svstat`, so what is checked on a runner is that it fails
  CLEANLY — nothing on stdout — and that novi-agent still substitutes
  `{}` for the empty answer.

## Architecture: declaring what is installed

`packages.<name> = present | absent` (RFC 0002). The observer reads
`/var/lib/pkg/installed/<name>/MANIFEST`; the converger runs `pkg`.

- **It already existed and the roadmap said it did not.** RFC 0002
  listed `packages.*` under "next, in dependency order" for the whole
  life of the project while `observe_package` and `converge_package`
  sat in `novi-state` -- untested, undocumented and live. A roadmap
  that is wrong about what is BUILT is the same defect as one that is
  wrong about what is possible (RFC 0031's browser, from the other
  side). Check the code before believing either.
- **The document is ADDITIVE.** A package nobody mentions is a package
  nothing touches. "Unlisted means absent" is what a strict reading of
  *declarative* suggests and it would make `pkg install` by hand
  something the next `apply` silently undoes. Same shape as
  `users.<name>.shell`: the anchor key is what brings a thing under
  management.
- **A removal that would break another package is REFUSED**, and the
  refusal is the feature. `pkg remove` warns about reverse dependencies
  and proceeds -- right for a person who typed it and is reading the
  warning, wrong for a document applied at boot with nobody there. The
  result is PERMANENT DRIFT, which is the honest report: the machine
  does not match the document and this engine will not make it.
- **`pkg rdeps` exists so there is ONE implementation of "what depends
  on this".** A second scan written in novi-state would drift from
  pkg's the first time the `depends` syntax gains a spelling -- and it
  already has several (version constraints).
- **A QUERY THAT FAILED IS NOT AN EMPTY ANSWER.** `pkg rdeps` from a
  pkg too old to know the subcommand exits non-zero, and reading that
  as "nothing depends on it" turns the refusal into permission at
  exactly the moment it is least justified. Refuse on a failed query
  too.
- **And the first fix for that failed the same way the bug did.**
  `if ! rdeps="$(pkg rdeps "$name" | tr '\n' ' ')"` tests the
  PIPELINE's status, which is `tr`'s -- so the substitution reported
  success and handed back the empty answer regardless. Capture first,
  reshape after. Third time this repository has been caught by a
  pipeline's exit status.
- **BusyBox wget's default timeout is 900 seconds**, and nothing cared
  while every fetch had a person waiting at a prompt. A declared
  package is fetched by BOOT CONVERGENCE, so an unreachable mirror
  would stall the boot for a quarter of an hour per package with
  nothing on the console to say why. `pkg.conf`'s `timeout` is 30 now
  -- a READ timeout, so a slow but progressing 90 MB download is
  unaffected.
- **A FAILED KEY IS RETRIED in the next pass if the pass made
  progress**, and this domain is what forced it. `cmd_apply` used to
  strike a failed key off for the rest of the apply -- to stop one bad
  key printing the same error three times -- and that defeats the
  passes for exactly the case they exist for: declare
  `packages.expat = absent` and `packages.fontconfig = absent`
  together, expat sorts first, its removal is refused because
  fontconfig still needs it, fontconfig is then removed, and expat
  stays. Watched live. A key that is merely EARLY now converges; a key
  that is simply wrong costs one extra error line, because nothing
  else converges on the retry pass and the loop ends there.
- **A test that needs root does not run in CI, and the whole of it
  fails there rather than skipping.** `novi-state apply` calls
  `need_root`, this container is root, and the packages test passed
  here and failed on every apply-shaped check in CI with
  `ERROR: This operation requires root.` The test copy is already a
  doctored copy (the install database path is sed'd into /tmp), so
  `need_root` is sed'd out with it: the thing under test is the
  converger's decisions, not the privilege check.
- **And `packages/pkg` CANNOT RUN UNDER DASH.** It is `#!/bin/sh` and
  uses `set -o pipefail` deliberately -- busybox ash supports it and
  that is what runs on the target. `/bin/sh` on a CI runner is dash,
  which does not, so pkg dies on its second line and every check that
  depends on it fails for a reason unrelated to the code. Where the
  other tests here fall back to `sh` when there is no shipped busybox,
  a test that runs `pkg` falls back to **bash**: running it under a
  shell it could never meet is not a test.
- **The System panel's apply is a JOB now, not a blocking fork.** The
  comment in `novi-settings/main.c` had warned since it was written
  that these calls block the Wayland event loop and that it would stop
  being acceptable "the first time a domain converges something slow (a
  package install)". This is that. Nothing new was needed: `JOB_APPLY`
  already existed for the WiFi radio. A side effect worth having --
  the runner captures stderr, so a failed apply shows novi-state's own
  `ERROR:` line instead of the word "failed".

## Architecture: hardware you have never seen

RFC 0011 (`docs/rfcs/0011-hardware-enablement.md`). The traps here are
all the same shape — **something worked while the thing reporting on it
failed** — which is exactly how three of them survived earlier reviews.

- **`packages/novi-hwdetect` is the only generic driver loader.** Every
  other module load in this system is a hardcoded list: `/init`'s
  storage guesses, the network service's NICs, the WiFi service's
  radios. All three were written against QEMU. `novi-hwdetect` walks
  `/sys/devices/**/modalias` and hands each string to `modprobe`, which
  matches it against the `modules.alias` `depmod` generated at build
  time — udev's builtin, in fifteen lines. It runs **in the initramfs
  before the root search**, which is the placement that matters: a
  storage controller nobody listed otherwise ends in an emergency
  shell.
- **A script that runs in the initramfs may only use applets
  `mkinitramfs.sh` links.** That list is hand-written. `novi-hwdetect`
  loaded every driver correctly and then died on `tr: not found`; the
  fix was both adding `tr` *and* removing the dependency (`comm` falls
  back to `grep -Fxv -f`; arithmetic replaces `tr -d ' '`). Adding the
  applet alone leaves the next script to rediscover the trap.
- **`echo x > /proc/... 2>/dev/null` does not suppress the redirection's
  own failure.** Redirections apply left to right, so `>` fails while
  stderr is still the console. Test `[ -w ... ]` instead.
- **A builtin and a missing module are indistinguishable to
  `modprobe`.** `/init` printed `WARNING: Could not load module` for ten
  filesystems that were compiled in and working — twenty-two warnings a
  boot, all meaningless, which trains people to ignore warnings.
  `/sys/module/<name>` exists for a builtin; check it before believing
  the exit status.
- **ALSA's default state on a fresh card is muted.** `rc.init` runs
  `alsactl init` then `alsactl restore`. Without the first, a completely
  correct audio path produces silence and the card looks unsupported.
- **`regulatory.db` and Intel SOF firmware are not in linux-firmware.**
  They are separate upstreams (`wireless-regdb`, `sof-bin`), and this
  kernel sets `CONFIG_CFG80211_REQUIRE_SIGNED_REGDB`, so a missing
  `regulatory.db` leaves every radio crippled rather than absent.
- **A tar wildcard that matches nothing is silent.** The first firmware
  extraction shipped 393 MB with zero iwlwifi files and looked like a
  success — linux-firmware had reorganised into per-vendor directories.
  `26-firmware.sh` distinguishes "Not found in archive" from a real tar
  failure rather than discarding stderr.
- **`bootx64.efi` is signed by a self-generated key**, which no stock
  machine trusts. It is useful to someone who enrolls their own keys or
  has Secure Boot off, and to nobody else; the certificate ships as
  `/novi-boot/novi-secureboot.der` so the first case is possible. Do not
  describe this as Secure Boot support.

**None of this has run on physical hardware.** Keep that qualifier
wherever this work is described. `novi-hwdetect` is verified on three
virtio devices — the easiest case there is — and the firmware has never
been requested by a device.

## Architecture: hotplug is the other half of hwdetect

RFC 0012 (`docs/rfcs/0012-hotplug.md`).

- **`novi-hwdetect` is coldplug and cannot be anything else.** It walks
  `/sys` once, so it answers "what is in this machine" and never "what
  did someone just plug in". `packages/novi-hotplug` is the same
  modalias-to-`modprobe` rule driven by the kernel's uevent netlink
  stream instead of a directory walk. Two sources, one rule — don't
  merge them, and don't let either grow a device list.
- **The listener is busybox `uevent`, not ours.** It forces a 128 MB
  netlink receive buffer, which is the whole ballgame: events queue in
  the kernel during a burst rather than being dropped. It runs the
  handler with `spawn_and_wait`, so a slow handler stalls the queue but
  loses nothing. Nothing in the handler may *block*, though — hence the
  backgrounded `alsactl`.
- **`mdev` is deliberately unused.** devtmpfs (`CONFIG_DEVTMPFS_MOUNT`)
  creates the device nodes in the kernel before any of this runs; mdev
  would be a second creator with its own rule file to keep in sync.
- **`alsactl init` exits 99 on success.** "Hardware is initialized using
  a generic method" + exit 99 is the documented path for a card no
  ruleset matches, and it did initialise. Do not "fix" the 99.
- **`alsactl init` only knows standard mixer control names** (`Master
  Playback Volume`, `PCM …`, `Headphone …`, `Speaker …`). QEMU's
  emulated USB audio card invents `Audio Output Volume Control`, so a
  muted control on it stays muted — reproduced twice. Real headsets use
  standard names. This is why the handler *logs* that it called
  alsactl: whether it ran and whether it worked are separate questions.
- **The handler does not touch networking.** An interface that appears
  after boot gets a driver and no lease, because `network` picks one
  interface at start. Per-interface DHCP is RFC 0009's work; reaching
  into the network service from a uevent handler is split-brain.

## Architecture: the design system, and where it lives

`docs/design/GUI-DESIGN-LANGUAGE.md` has been the adopted reference
since September 2026 and was only half implemented; `common/theme.h`
is §1-§3 as C constants and every client includes it.

- **Every colour existed six times before this.** novi-panel called
  the card background `0xff232430`, novi-files the same, novi-notifyd
  `0xff1b1b26`, and nothing connected them to the token they were all
  trying to be. New UI code uses a `NOVI_*` token or adds one; a raw
  hex literal in a client is the bug this file exists to prevent.
- **`NOVI_PIX()` expands 8-bit channels by REPLICATION (`0xA3` ->
  `0xA3A3`), not by shifting left 8.** A shift maps `0xFF` to `0xFF00`,
  so pure white comes out 0.4% grey and full alpha is very slightly
  transparent. Several hand-written `pixman_color_t` literals in this
  repo had exactly that shift.
- **Inter for language, JetBrains Mono for machine values**, and the
  split is by what the text IS, not where it sits: a filename is
  Inter, a path and a size in bytes are mono. novi-edit's *buffer*
  stays mono because its cursor arithmetic assumes a fixed advance;
  only its chrome changed.
- **Static Inter weights, not the variable font** the design doc
  recommends. Selecting a weight out of a variable font depends on
  fontconfig's named-instance handling, and a build where that quietly
  does not work gives Regular everywhere with no error to notice.
- **Accent is a signal colour and never a large fill**, and getting
  that wrong is easy: the first pass made every directory row in
  novi-files teal, beside an accent-tinted selection that was trying
  to mean something. Hierarchy between kinds of thing is brightness;
  accent means one thing per window.
- **`novi-bg` paints the desktop, not the compositor.** A
  `wlr_scene_rect` is one solid colour by construction, and teaching
  novi-shell to rasterise a gradient is the UI work RFC 0001 keeps out
  of it. Generated rather than an image file: no asset, no decoder, no
  resolution to be wrong at. It sets an EMPTY INPUT REGION -- a
  full-screen background surface that takes clicks swallows nearly
  every press on the desktop.
- **A library linked by more than one client belongs in the library
  stage**, and this repo has now learned it twice. novi-panel (stage
  10) started linking libnl, which 25-wifi.sh built at stage 25:
  invisible in a warm tree, fatal in a clean one, exactly as
  novi-launcher/fcft was. libnl is built by `06-wayland.sh` now.
- **One missing `.pc` makes pkg-config blame every package in the
  query.** Asked for `wayland-client fcft libnl-genl-3.0` in one
  invocation, it reported all three as not found, and the build died
  on `wayland-client.h: No such file or directory` with
  `wayland-client.pc` sitting in the rootfs. Read the whole list
  before believing the first name in it.

## Architecture: `xkb_context_new` returns NULL, and nobody checked

Every Wayland client here -- novi-view, novi-edit, novi-files,
novi-settings, novi-lockscreen, novi-launcher -- called
`xkb_context_new(XKB_CONTEXT_NO_FLAGS)` and used the result unchecked.

- **IT RETURNS NULL when it cannot add a single default include path**,
  having logged `failed to add default include path /usr/share/X11/xkb`
  -- a message that reads like a warning and is a fatal error one
  event later. The first keymap the compositor sends then reaches
  `xkb_keymap_new_from_string(NULL, ...)` and the process dies with
  **SIGSEGV**.
- **novi-lockscreen is one of the six**, and there a crash means the
  session is not locked. That is the reason this is written up as a
  class rather than as one client's bug.
- **Nothing had ever produced a machine without xkeyboard-config**, so
  it was unreachable until RFC 0039 roadmap 4 put novi-view in a
  sandbox whose root contains only what was named. It presented as
  `exit=139` with one xkbcommon line above it.
- The fix is five lines in each: check, name the directory, exit 1.
  A program that cannot read a keyboard should say so, not fall over.
- **The first theory was wrong and reading the code is what stopped
  it.** `keyboard_modifiers` calls `xkb_state_update_mask(v->xkb_state,
  ...)` and looked like the obvious unguarded deref -- it is guarded.
  The NULL was one level up, in the context nobody checked.

## Architecture: the compositor draws exactly one thing

`novi-shell/decoration.c` is the whole of the window chrome — title,
top corners, hairline, three control dots, nine-slice drop shadow —
and it is the only place this compositor rasterises anything. That is
not a crack in RFC 0001's "UI belongs in a client" rule: server-side
decorations are by definition drawn by the server, because the client
that wanted none is not there to ask.

- **The scene graph takes rects or buffers, and chrome is neither.**
  A `wlr_scene_rect` is one solid colour; a rounded corner, an
  anti-aliased circle, a gradient and text are all "rasterise it
  yourself and wrap it in a `wlr_buffer`". Five callbacks, two of
  which do anything — `get_dmabuf`/`get_shm` correctly answer "no"
  because it is malloc'd memory, and the pixman renderer wants the
  pointer anyway.
- **Those buffers are PREMULTIPLIED ARGB8888**, which is why every
  colour is multiplied by its own coverage before being stored. This
  file already carried a note about a "dimmed" 40%-alpha scene rect
  that rendered BRIGHTER than the full-strength ones beside it for
  exactly this reason.
- **The shadow is a nine-slice, and its offset is DOWNWARD only.**
  `SHADOW_OFFSET` gives the bottom slices a lead-in of full-strength
  rows before their falloff; applying that same lead sideways hangs
  four columns of solid black off the right edge of every window,
  symmetric with nothing. It was a real bug in the first draft, and
  the reason `lead` is a parameter rather than a constant inside the
  sprite builder.
- **Shadow slices must reject pointer input**
  (`point_accepts_input`). Otherwise twenty translucent pixels around
  every window swallow clicks meant for whatever is behind them.
- **Focus is redrawn from `focus_toplevel()`, not from the commit
  handler.** A window that LOSES focus does not commit a frame just
  because it lost it, so it would keep looking focused until it next
  drew something of its own.
- **A control's hit target is its buffer's box**, so the dot sprite is
  16px with an 8px disc centred in it and the rest transparent. An 8px
  sprite would mean an 8px target. 16 is also the dot gap, so
  neighbouring targets meet exactly and never overlap.
- **Title-bar drag cannot go through `begin_interactive()`.** That
  function refuses a toplevel whose *surface* does not hold pointer
  focus — right for a client asking to be moved, and wrong here, since
  the pointer is over the compositor's own decoration and the client's
  surface never has pointer focus at all. The move is clamped to keep
  96px of window and the whole title bar inside the usable area:
  dragging is a thing a person does now, so putting a window somewhere
  unrecoverable is a thing a person can do now.
- **A GUI test that reports "nothing happened" is usually the test.**
  This one said so twice: QEMU's QKeyCode has `meta_l`, not `super`,
  so two Super+. runs sent an invalid keycode; and a foot window's
  title bar sits at y=142..173, not the y=176 the drag test grabbed —
  two pixels into the terminal. Measure the geometry off a screendump
  before concluding the code is wrong.

## Architecture: Mesa, and a default chosen by measurement

RFC 0025 (`docs/rfcs/0025-mesa.md`). EGL, GLESv2 and GBM, softpipe and
virgl, no LLVM. Before this there was no GL stack at all -- not a slow
one, none -- and no program wanting OpenGL could run here in principle.

- **Both renderers ship and the default is MEASURED.** wlroots'
  auto-detection picks gles2 whenever the DRM backend reports a render
  node (`render/wlr_renderer.c` gates the pixman branch on
  `!has_render_node`), on the assumption that a render node means
  hardware acceleration. In a plain QEMU it does not: virtio_gpu offers
  `/dev/dri/renderD128` and what answers is softpipe. Measured under
  identical load, novi-shell's own CPU over 20s: **pixman 363 ticks,
  gles2/softpipe 1998 -- 5.5x more.** Software rasterisation THROUGH a
  GL API is strictly more work than pixman drawing 2D directly. The
  default is `display.renderer = pixman` and it is a KEY, because on
  real hardware the answer inverts and nobody here can measure that.
- **`libgallium` is invisible to the dependency graph.** libEGL loads
  it by name at runtime, so nothing NEEDs it and `closure()` cannot
  reach it -- the same dlopen blind spot as libdrm_amdgpu. It is
  claimed by `PACKAGE_TABLE`, which is exactly why that table exists
  beside the graph.
- **Mesa is the first C++ in this image**, so libgallium names
  `libstdc++.so.6` and `libgcc_s.so.1` and nothing shipped them. They
  live in the toolchain's `lib64`, which musl's loader never searches
  (RFC 0015's trap again). RFC 0015's `gcc` package already shipped
  those exact paths, so they became their own `gcc-libs` package and
  `gcc` depends on it -- one path, one owner.
- **zlib moved from stage 21 into the library stage**, because
  libgallium links it and Mesa has to precede wlroots. A library built
  after its consumer is invisible in a warm tree and fatal in a clean
  one: the novi-launcher/fcft bug and the novi-panel/libnl bug, for a
  THIRD time. `21-imagelibs.sh` now fails loudly if zlib is missing.
- **`needs_exe_wrapper = true` in the meson cross file.** Meson
  otherwise auto-detects, correctly concludes it can run target
  binaries directly (this host has `/lib/ld-musl-x86_64.so.1` symlinked
  at the sysroot's libc), and runs them without the wrapper's
  `LD_LIBRARY_PATH` -- so a C++ target binary died on "Error loading
  shared library libstdc++.so.6" while g++ worked perfectly, reported
  as "Executables created by cpp compiler ... are not runnable".
  Exporting `LD_LIBRARY_PATH` globally was rejected: it would apply to
  the host's own glibc-linked meson, ninja and python.
- **Mesa's build needs Python `mako` on the BUILD HOST.** Checked up
  front, like `05-kernel.sh` checks for `depmod`.
- **`-Dglx=disabled` means no desktop `libGL`.** EGL + GLESv2 is what
  wlroots wants and is NOT enough for most existing OpenGL games. Do
  not let the word "Mesa" imply a gaming stack. (EGL itself DOES
  report `client APIs: OpenGL OpenGL_ES`, so the capability is there;
  what is missing is the `libGL.so.1` an existing program links
  against.)
- **`libGL.so.1` REQUIRES X11, and libglvnd does not change that.**
  Attempted and stopped: libglvnd 1.7.0 builds `src/GL` — the only
  place `libGL.so.1` comes from — `if with_glx`, and `with_glx`
  requires `dep_x11.found()`. So the roadmap item that says "add
  libglvnd for desktop libGL" is really "add libX11, libxcb, libXau,
  libXdmcp, libXext and xorgproto", in a distribution that has never
  had X, for a library whose GLX half can never work here. What glvnd
  gives WITHOUT X is `libOpenGL.so.0`, which nothing in this image
  links — and getting it is not additive: `-Dglvnd=enabled` makes Mesa
  ship `libEGL_mesa.so.0` as a vendor instead of `libEGL.so.1`, so
  glvnd's dispatch becomes the library THE COMPOSITOR loads. Mesa's
  own meson is fine with `-Dglvnd=enabled -Dglx=disabled`; libglvnd is
  the obstacle. See RFC 0025's roadmap item 3 for the full finding.
- **virgl ships UNVERIFIED, and so does everything else that needs a
  GPU.** Checked rather than assumed: this QEMU offers
  `virtio-gpu-pci` and no `virtio-gpu-gl`, there is no virglrenderer
  on the host, and the host has no `/dev/dri`. softpipe is the only
  driver here that has ever run. Anything claiming otherwise about
  this stack is claiming more than has been tested.
- **`$14` in POSIX sh is `$1` followed by `4`.** A benchmark reading
  utime+stime out of `/proc/<pid>/stat` with `set --` and `$14`
  silently measured the pid minus itself and reported 0 CPU ticks
  twice, which read as "the load never reached the compositor".
  `${14}`.

## Architecture: a GL client, and the third list

`novi-glinfo` (build/37) is the client half of RFC 0025. The compositor
was verified end to end and nothing at all was known about a CLIENT,
which takes a different path -- EGL's Wayland platform and buffer
sharing back to the compositor -- and is the path everything except
novi-shell will ever take.

- **It works, under BOTH renderers, and the reason matters more than
  the result.** A compositor needs a GL renderer to import a client's
  GPU buffers, so the obvious worry was that RFC 0025's measured-best
  default (`pixman`) made GL applications impossible. It does not
  here: softpipe has no GPU, so Mesa renders into shared memory and
  hands over an ordinary `wl_shm` buffer that any renderer can
  composite -- no dmabuf traffic appears in the log under either
  setting. **On real hardware that inverts**: a client would produce
  GPU buffers needing dmabuf import, which pixman cannot do. Expect
  `display.renderer = pixman` on a machine with a working driver to
  cost GL clients, not just compositor speed. Reasoned from the
  mechanism, not measured -- nothing here has a GPU.
- **`EGL client APIs` says `OpenGL OpenGL_ES`.** Desktop GL IS
  available through EGL despite `-Dglx=disabled`; what is missing is
  the `libGL.so.1` an existing program links against, not the
  capability. Do not repeat the stronger claim.
- **META_PACKAGES is a THIRD list a desktop client must be added to**,
  after `DESKTOP_BINARIES` and `PACKAGE_TABLE` -- and it is the one
  that fails SILENTLY. novi-glinfo was built, packaged, indexed and
  signed correctly and simply was not on the machine:
  `novi-glinfo: not found` on a desktop that had just installed the
  desktop. The other two fail loudly (a missing seed fires the
  straddle check; a missing table entry is a hard "no package owns
  these files"). pkgsplit now derives a check from the table -- every
  `OS`-category package must be named by some meta-package -- and
  refuses to run otherwise. Verified by removing the entry and
  watching it fail, because a check nobody has seen fail is a check
  nobody knows works.
- **`-Wl,-rpath-link` for the FOURTH time** (nftables, git/curl, the
  meson cross file, now here). `libEGL.so` names libgallium, libgbm,
  libglapi, libexpat, libdrm and libwayland-server in its DT_NEEDED,
  and `-L` does not resolve those: the link fails on `undefined
  reference to XML_ErrorString` and `wl_resource_post_error`, symbols
  belonging to libraries sitting in the rootfs, from a libEGL that
  exports none of them. The error names the wrong thing entirely.
  `lib-meson-cross.sh` sets this globally for meson builds; the client
  Makefiles link with `$(CC)` directly and so each one rediscovers it.

## Architecture: a browser, and the claim that went unchecked

RFC 0031 (`docs/rfcs/0031-web-browser.md`). `pkg install netsurf` —
NetSurf 3.11, HTML and CSS over real HTTP, **no JavaScript**.

- **`docs/PLATFORM-ROADMAP.md` said a browser "needs Rust and a large
  native dependency tree", and that was never checked.** NetSurf is C,
  builds with make, and needed **no new dependency at all**: curl,
  OpenSSL, libpng, zlib, expat and libwayland were already here, two of
  them only because RFC 0020 and RFC 0027 had put them there. The claim
  was true of a Chromium-class engine and got applied to the whole
  category, so the cheapest large feature this project has shipped sat
  unscheduled behind it. **A blocking claim in a roadmap deserves the
  same scepticism as a comment asserting a bug away.**
- **No JavaScript, and say so every time.** `NETSURF_USE_DUKTAPE=NO`.
  "Novi has a web browser" and "Novi can open most of the modern web"
  are different claims and only the first is true — a site that renders
  from script shows an empty page. Do not let the word "browser" imply
  the second, the same way RFC 0025 says not to let "Mesa" imply a
  gaming stack.
- **THAT IS A MEASURED DECISION NOW** (RFC 0031 roadmap 2, instrument
  at `tests/js-probe/`), and the reason is not the one the roadmap
  gave. It said an interpreter with no JIT is slow; **the problem is
  that the language Duktape implements is not the language the web is
  written in.** `let`, arrow functions, template literals, `class` and
  `for..of` are each a SyntaxError — and **a syntax error is a
  WHOLE-SCRIPT failure**, so one arrow function anywhere in a bundle
  means nothing in it runs. `Promise`, `fetch`, `XMLHttpRequest` and
  `localStorage` are all `undefined`, so a page cannot load anything
  after its initial HTML. Cost: **+1.34 MB (+52%)** on the binary, and
  an interpreter parsing hostile script in a browser with no sandbox
  and no CPU bound.
- **TWO THINGS SILENTLY DO NOTHING before any of that can be
  measured.** `NETSURF_USE_DUKTAPE=YES` is not enough —
  `enable_javascript` defaults to FALSE in NetSurf's own options — and
  the framebuffer frontend reads `Choices` off its RESOURCE path,
  `~/.netsurf/Choices`, **not** `~/.config/netsurf/Choices`, which is
  where it went first and where it did nothing at all.
- **A TCG GUEST IS 30x SLOWER THAN THIS HOST, measured rather than
  assumed.** The same 2M-iteration loop in CPython takes 4577 ms on
  the guest and 151 ms on the build host. Any timing taken in that VM
  needs dividing by something, and the honest way to find the divisor
  is to run the same workload in an interpreter that exists on both
  sides. Duktape's 9153 ms becomes ~305 ms of real hardware — within
  2x of CPython, and 60-150x off a JIT.
- **libnsfb binds `wl_shell`, which wlroots has never implemented.**
  Deprecated in 2016. Unpatched, the browser starts, binds a global
  that is not advertised, gets NULL and carries on: a running process
  that can never show a window and says nothing about why.
  `patches/netsurf-libnsfb-xdg-shell.patch` ports it, and the stage
  **fails the build** if the patch stops applying — the rule
  `23-e2fsprogs.sh` already applies to its musl patch.
- **The generated half of that patch is generated, not committed.**
  `wayland-scanner` produces ~88 KB of `xdg-shell-protocol.{c,h}` from
  the rootfs's own `xdg-shell.xml` at build time. A diff of machine
  output is not something anyone can review, and a derived answer
  cannot rot.
- **`CFLAGS=` on NetSurf's make command line DELETES NetSurf's own
  include paths.** Its buildsystem does `CFLAGS += …`, and a variable
  set on the command line overrides every assignment in the makefile,
  `+=` included; the build then dies on its own headers. They go in the
  **environment**. That is RFC 0021's wolfSSL `.config` trap one level
  out, and it caught this build too — including `nsgenbind`, the
  build-host tool, which needs `env -u CFLAGS -u LDFLAGS`.
- **The build directory is named after HOST and TARGET but NOT after
  the compiler.** The buildsystem derives `CC` from `HOST` only when
  its origin is `default`, and the browser's own makefile does not take
  that path — so the first attempt compiled everything with the build
  host's gcc. Naming `CC=`/`AR=` explicitly fixed the compiler and left
  glibc objects behind, and the musl link failed on `__snprintf_chk`
  and `__memset_chk`: **the error names the libc you are linking, not
  the one that built the object.** Extract the tree fresh.
- **`-Wl,-rpath-link` for the FIFTH time** (nftables, git/curl, the
  meson cross file, novi-glinfo, now here). `libcurl.so`'s `DT_NEEDED`
  names `libmbedtls.so.21` and `-L` does not resolve a shared library's
  own dependencies.
- **`NETSURF_USE_LIBICONV_PLUG=YES`** means "iconv is part of libc",
  which is true of musl; `NO` links `-liconv`, which does not exist
  here.
- **One process, two TLS stacks.** `netsurf-fb` NEEDs `libcurl.so.4`
  (built against mbedTLS, RFC 0020) *and* `libssl`/`libcrypto` (RFC
  0027, for certificate inspection). Not a rule broken — RFC 0020's
  rule is the BASE IMAGE and RFC 0006's is the TRUST PATH, and neither
  is touched — but worth stating: only curl's half has ever been put
  through this project's HTTPS verification triple.
- **The browser draws in Inter and JetBrains Mono**, via
  `NETSURF_FB_FONTLIB=freetype` — not the compiled-in bitmap face it
  shipped with first. The RFC called this "a bigger change than this
  RFC" and was wrong: freetype is a fontlib upstream already supports
  and has been in this build since stage 06 for fcft, so it is a new
  LINK and not a new dependency. `NETSURF_FB_FONTPATH` feeds
  `respaths`, and `fb_new_face()` resolves each name through
  `filepath_sfind()` against it, so the ten `NETSURF_FB_FONT_*` values
  are plain filenames.
- **A WEB PAGE IS NOT THIS UI, and that is why Inter now ships
  italics.** 09-foot.sh installed Regular/Medium/SemiBold only, with a
  comment saying "nothing in this UI is italic" — true of the
  desktop's own clients and irrelevant to a browser. `<em>`, citations
  and titles are italic constantly, so with no italic face NetSurf
  rendered every one of them identically to body text: **emphasis was
  invisible**, which is a correctness problem rather than a matter of
  taste. `Inter-Italic.ttf` and `Inter-SemiBoldItalic.ttf` were
  already in the zip that stage downloads. When a decision's stated
  reason is about one consumer, re-read it when a second consumer
  arrives.
- **There IS a serif now — Source Serif 4** (OFL-1.1, pinned 4.004,
  its own `fonts-source-serif` package). Before it, `font-family:
  serif` landed on Inter: a sans, silently, because every other face
  falls back to the one below it and this one had nothing below it.
  Only the sans-serif face is fatal when missing, which is why the
  gap degraded instead of crashing — and why it survived so long.
- **TWO faces, not four, and NetSurf decides that.** Its framebuffer
  frontend has `NETSURF_FB_FONT_SERIF` and `_SERIF_BOLD` and NO italic
  option — checked in `frontends/framebuffer/Makefile`, not assumed.
  So `<em>` in a serif paragraph renders upright (the frontend's
  limit, not a missing font), and an italic nothing can select would
  be the dead weight RFC 0007 says is not inert.
- **The serif is NOT a `novi-desktop` member.** Only the browser
  renders one, so it rides on `netsurf`'s `depends=` — a desktop that
  never draws a web page has no use for a serif.
- **All three font families ship their licence now.** OFL-1.1
  requires it to travel with the font and it was not travelling:
  Inter's `LICENSE.txt` and JetBrains Mono's `OFL.txt` sat unread in
  their zips for the life of both packages. Source Serif forced the
  question because its release asset contains font files and NOTHING
  ELSE — so the text is fetched separately, and the other two were
  fixed alongside it.
- **`fonts-inter` and `fonts-jetbrains-mono` are in `depends=` by
  hand, because NOTHING CAN DERIVE THEM.** pkgsplit reads
  `DT_NEEDED`, and a `.ttf` opened by path at runtime is in no ELF
  header — the libdrm `dlopen` blind spot (RFC 0007) in a different
  costume. Without them the package installs, the browser starts,
  cannot find its default font and exits.
- **A HOSTILE PAGE CANNOT CRASH IT AND CAN TAKE THE MACHINE DOWN**
  (`tests/hostile-pages/`, RFC 0031 roadmap 4). Sixteen deliberately
  awkward documents, zero SIGSEGVs — 40k nested divs, 20k unclosed
  tags, invalid UTF-8, a PNG claiming 65535×65535 — and **five of
  them never settle**, at ~100% CPU. Running those five for longer
  put QEMU at 110% CPU with 4.5–4.9 GB resident against a **4096 MB**
  guest, twice on two fresh boots, with the serial console
  unresponsive. Not a curiosity: one page, off the network, reaches a
  state a local shell cannot recover from.
- **"THE SHELL WAS STARVED BY THE CPU LOAD" WAS AN INFERENCE AND IT
  WAS WRONG.** The supervising script's 40-second kill never ran, and
  the obvious reading — CPU starvation — got written down before it
  was measured. Measured afterwards on the same 4-vCPU guest with an
  unrelated shell probe: **three** runaway browsers cost it nothing at
  all (17 centiseconds, the idle figure) and it took **eight** to slow
  it to 40–43. The takedown was MEMORY: several half-gigabyte pages
  plus one that grows without limit, on a guest with no swap, under
  which everything stalls including the kill. The distinction decides
  the fix — a CPU bound would not have helped. Third time in this file
  that a mechanism was stated confidently before being measured (the
  empty `TERM`, the resume that never completed, this).
- **The per-page table was impossible and is not any more, and the FIX
  is what made it possible.** Two attempts to measure peak memory one
  page at a time ended in the state above; under RFC 0031 roadmap 5's
  bound the harness is no longer racing what it measures. **A gap
  honestly recorded is a gap somebody can close** — and the thing that
  closed it was the thing the gap argued for.
- **The corpus is served from the GUEST's own loopback** (busybox
  `httpd` on 127.0.0.1), so a failure is the browser's and not a
  network's — and the control is a benign page rendering in 0.1s with
  its links laid out. Without that, "survived" could have meant a
  process sitting inert and every row in the table would be
  worthless. Same argument as every other probe in this file: a check
  that cannot distinguish working from absent is not a check.
- **THE BROWSER IS BOUNDED NOW** (RFC 0031 roadmap 5): `pkg install
  netsurf` puts a wrapper on PATH and the binary in `/usr/libexec` —
  1 GiB of address space through `s6-softlimit -a`, and nice 5. A
  bound somebody bypasses by typing the other name is not a bound,
  which is why the real binary moves rather than the wrapper taking a
  new name. Every step is an exec, so there is one pid and `ps` shows
  `/usr/libexec/netsurf-fb`.
- **RLIMIT_AS BOUNDS ADDRESS SPACE, SO THE NUMBER TO MEASURE IS
  `VmPeak`, NOT `VmHWM`.** On a process with mmap'd fonts and shm
  buffers those differ, and a bound picked off the resident figure
  would fire on pages that were never using that much memory.
- **NetSurf hitting the ceiling neither exits nor says anything** —
  measured, not assumed, and the RFC's own filing of the item had
  claimed it "has malloc failure paths". So what the bound converts an
  unrecoverable machine into is a HUNG WINDOW. Say that rather than
  "handles allocation failure".
- **`RLIMIT_CPU` IS NOT THE CPU HALF.** `s6-softlimit -t` exists and is
  the obvious reach; it is cumulative over the process's whole life,
  so it cannot say "this layout is taking too long" without killing a
  long browsing session that has done nothing wrong. `nice` is what
  ships instead, and a priority is not a bound: it keeps the rest of
  the machine usable and stops nothing.
- **A wrapper's `off` switch needs its OWN branch, and one of them
  could not fire.** `${VAR:-default}` substitutes for an EMPTY value as
  well as an unset one, so the `''` alternative in the validation
  `case` was unreachable — a branch reading as load-bearing that
  nothing could reach, exactly like the dead `::`-guard in RFC 0033's
  v6 validator. Provoking each branch on the host is what found it.
- **A green corpus is not a safety property, and the scripts say so
  on every run.** It finds crashes and hangs on shapes somebody
  thought of. It says nothing about memory disclosure, nothing about
  the shapes nobody thought of, and nothing about the absence of a
  sandbox — which is still true. Do not let "we tested it against
  hostile pages" become "it is safe to point at the web", the same
  way "Mesa" must not imply a gaming stack.
- **Generating 13 MB of pathological HTML in a shell loop takes
  minutes; in `awk` it takes 0.083 seconds.** And `printf '%s'
  '\200'` prints four characters, not a byte — the invalid-UTF-8
  page needs `printf '\200'` with the escape in the FORMAT string.
  Both were found by running the generator, not by reading it.

## Architecture: Python, and the module it does not have

RFC 0026 (`docs/rfcs/0026-python.md`). CPython 3.11.16 as the `python`
package — the first scripting language this system has ever had.

- **`ssl` comes from OpenSSL, which is a package (RFC 0027).** CPython's
  `_ssl` and `_hashlib` are written against OpenSSL *specifically* —
  mbedTLS (RFC 0020) and wolfSSL (RFC 0021) are both in this build and
  CPython has a backend for neither, and LibreSSL has been unsupported
  since CPython 3.10. It shipped without `ssl` first, on the vague
  reading of "no OpenSSL". **The precise reading is what matters and
  this project has now had to recover it three times**: RFC 0006 is
  about the TRUST PATH (checking a signature must not need TLS —
  `novi-verify` is still static TweetNaCl), RFC 0020 is about the BASE
  IMAGE (no TLS library in the console base — still true, checked with
  `find`). Neither forbids a package. RFC 0021 made the identical
  correction for wolfSSL. Get the rule right before invoking it.
- **A stub `ssl.py` that raises a friendlier error was rejected**, and
  still would be. It reads better once and lies permanently:
  `importlib.util.find_spec("ssl")` would start returning a spec, so
  code that feature-detects properly gets the wrong answer. A missing
  module should be missing.
- **`/etc/ssl/cert.pem` is a symlink shipped by `ca-certificates`, and
  without it Python verifies against NOTHING.** OpenSSL's default
  verify paths are `/etc/ssl/cert.pem` and the *hash-indexed*
  directory `/etc/ssl/certs`; the CA package ships one bundle file in
  that directory, which the hash lookup cannot use.
  `create_default_context().cert_store_stats()` returned `{'x509': 0}`
  with the store installed and correct. **curl is unaffected** (bundle
  path compiled in), which is exactly what makes it look like a Python
  bug. 143 certificates after the fix.
- **This system carries three TLS implementations now** — mbedTLS
  (curl, git), wolfSSL (wpa_supplicant), OpenSSL (Python) — each
  because its consumer accepts only it. All three are packages; the
  base image has none.
- **THE OpenSSL BUILD IS TRIMMED, AND IT IS NINE PERCENT** (RFC 0027
  roadmap 4). Stripped, like for like: libcrypto 6,137,328 →
  5,915,568, libssl 1,061,376 → **728,960**, the CLI 957,192 →
  913,704, and legacy.so's 142,120 gone — 739 KB, 8.9%, package 8.0M
  → 7.3M. **libcrypto barely moves (3.6%)**, because its weight is
  bignum, elliptic-curve and provider machinery rather than the
  algorithm tables; a third of libssl goes, which is DTLS, QUIC and
  the PSK/SRP suites. Expect single-digit percentages from an
  algorithm trim, not a different library.
- **WHAT THAT COSTS WAS ENUMERATED, NOT REASONED ABOUT.** `openssl
  ciphers -v` drops from **60 suites to 30**, which reads alarming
  until the two lists are diffed on a booted machine: **all thirty
  removed are `*-PSK-*` or `SRP-*`**, which need an out-of-band shared
  secret and appear nowhere on the public web. `hashlib` is unchanged
  at 19 algorithms, `ripemd160` included — it moved back into the
  default provider in 3.0.7, so `no-legacy` does not cost it.
- **The legacy provider was UNREACHABLE and shipped anyway.** The
  shipped `openssl.cnf` activates `default` and nothing else, so its
  142 KB could not be used without editing a config file nobody
  edits. And with it gone `make install` still creates an EMPTY
  `ossl-modules` directory, so the package's test had to become "is
  there anything in it", not `[ -d ]`.
- **`no-deprecated` is NOT in the list**, deliberately: it is the one
  entry that can break CPython's `_ssl` and `_hashlib`, and folding it
  into a size trim would make a build failure look like a packaging
  change.
- **THE FIRST PROBE COULD NOT TELL THE TWO BUILDS APART.** `openssl
  s_client -ssl3` answers "Unknown option" in BOTH — upstream already
  builds without the SSLv3 method — so the check that looked like it
  proved `no-ssl3` proved nothing. Diff the cipher list instead.
- **A SYMBOL COMPARISON ACROSS A VERSIONED ELF MUST STRIP `@VER` FROM
  BOTH SIDES.** Checking that NetSurf still resolves against the
  trimmed libraries (57 undefined OpenSSL symbols, all still
  exported, so no rebuild) took three attempts: `nm -D` prints
  `SYMBOL@VERSION` for an undefined symbol and `SYMBOL@@VERSION` for a
  defined one, so the first two runs reported every symbol missing.
  The probe was wrong, not the library — for the fourth or fifth time
  in this file.
- **COLLAPSING mbedTLS INTO OpenSSL WAS MEASURED AND REFUSED** (RFC
  0031 roadmap 3, RFC 0027 roadmap 2). Both items asserted it was
  worth doing; the numbers say the opposite, which is the whole reason
  to measure. Installed on the target: **mbedTLS 972 KB, OpenSSL
  8.0 MB** — 8.2x. And the dependency graph says who pays: `git` →
  `curl` → `mbedtls` and nothing else with TLS in it, so **a machine
  with git and no Python would go from 972 KB to 8.0 MB, +7 MB, for
  no capability it did not have.** The saving is under 1 MB and only
  where OpenSSL is already present anyway (`netsurf`, `python`). The
  maintenance argument is real and small, and its second half cuts the
  other way: **the smaller stack is the one on the HTTPS fetch path.**
  The choice was always one-sided — OpenSSL can never leave, because
  CPython's `ssl` accepts nothing else — so the only question was
  whether mbedTLS goes, and at 972 KB on that path it earns its place.
  Re-opening this needs a new NUMBER, not a new opinion.
- **What would change that answer is a TRIMMED OpenSSL**, which is a
  better item than the collapse was because it helps every machine
  that has OpenSSL rather than only the ones a collapse would touch.
  The build is near-stock (`no-tests`, `no-docs`, `enable-ktls`), so
  the legacy provider and the whole deprecated surface ship in that
  8.0 MB. Unmeasured — RFC 0027 roadmap 4, and do not assume a number
  for it.
- **The build host needs `python3.11`, not just any python.**
  Cross-compiling CPython RUNS Python during `make` (freezing
  importlib, generating C, byte-compiling the stdlib), and
  `--with-build-python` requires an exact major.minor match — the
  marshal format differs between minors. Checked up front like
  `depmod` and `mako`.
- **`harden_flags()` cannot be used here, and no LDFLAGS variable can
  carry `-pie`.** `Makefile.pre.in`'s `LDSHARED` and `BLDSHARED` both
  append `$(PY_CORE_LDFLAGS)` = `CONFIGURE_LDFLAGS` + `LDFLAGS_NODIST`,
  so every LDFLAGS-shaped variable reaches ~40 `-shared` links. **gcc
  given `-shared -pie` does not warn**: it drops the `-shared`, links
  an executable, and dies on `undefined reference to 'main'` from
  `Scrt1.o`. `LINKFORSHARED` is the only variable used solely on the
  two executable links, so `-pie` goes there — carrying its
  configure-chosen `-Xlinker -export-dynamic` through, not replacing
  it.
- **CPython prints missing modules and exits 0.** Correct for a
  language that runs everywhere, and exactly the failure shape this
  repo keeps getting caught by. `43-python.sh` diffs that list against
  the set it expects and reports the rest loudly — not fatally, since
  the module list shifts between point releases. Its first version
  reported twelve words of English as missing modules: the block ends
  with the sentence "To find the necessary bits, look in setup.py...",
  not a blank line, so a `sed` range to `/^$/` swallowed it.
- **`sys.implementation._multiarch` SAID `x86_64-linux-gnu` ON MUSL,
  AND THIS FILE SAID THAT WAS HARMLESS.** It said "it matters only
  when binary wheels become possible, and there is no pip". Binary
  wheels became possible -- pip shipped in the package the whole time
  (RFC 0026 roadmap 4) -- and the note stopped being true without
  anything announcing it. **Read a "harmless until X" note again when
  X arrives.**

  The cause is a bug in CPython's own configure: `PLATFORM_TRIPLET` is
  preprocessed out of `#if defined(__GLIBC__)` tests, which answer
  `x86_64-linux-gnu` on any Linux, and then corrected for musl by
  `case "$build_os" in linux-musl*)`. **`build_os` is the BUILD
  machine**, so a native musl build is corrected and a CROSS build to
  musl is not. It should read `host_os`; `43-python.sh` changes that
  one word in `configure` and in `configure.ac` beside it.

  What it costs: PLATFORM_TRIPLET becomes SOABI becomes `EXT_SUFFIX`,
  the only extension-module filename the import system looks for. A
  musllinux wheel ships `_speedups.cpython-311-x86_64-linux-musl.so`,
  and an interpreter claiming `-linux-gnu.so` **cannot see it at
  all** -- watched live: MarkupSafe installed its compiled module and
  silently ran the pure-Python fallback. A package with no fallback
  fails with ImportError after installing successfully. The stage
  asserts configure's own printed triplet, not the sed's exit status.
  After the fix: the same wheel's module imports and
  `markupsafe._escape_inner` is a `builtin_function_or_method` from
  `markupsafe._speedups`. **The first probe for that was the broken
  thing** -- `type(escape).__name__` reports `function` on a correct
  installation too, because MarkupSafe 3.x's `escape` is a Python
  wrapper around the C `_escape_inner`.
- **A CROSS-BUILT INTERPRETER REMEMBERS THE CROSS TOOLCHAIN, AND IT
  SHIPPED THAT WAY.** `_sysconfigdata_*.py` is what `setuptools` reads
  to compile a C extension, and the shipped package recorded
  `CC = 'x86_64-linux-musl-gcc'` (a program on no Novi machine) and
  `LDSHARED = '... -L/build/rootfs/usr/lib'` (a directory on the BUILD
  HOST) -- 207 lines of it, plus the whole of `config-3.11-*/Makefile`
  beside it. Every `pip install` without a musllinux wheel would have
  died on `gcc: not found`, and the mode where it did NOT die is
  worse: a machine with a `/build/rootfs` would have been handed that
  tree to link against. `43-python.sh` rewrites both files -- tools to
  native names, every private build prefix onto `/usr`, the CPython
  source directory onto the config directory the package installs --
  and regenerates the `__pycache__` copy, because a cached copy of the
  file just edited is the same bug wearing a different name.
  **Found by reading the artifact, not by running it.**
- **`\b` IS A WORD BOUNDARY AND `+` IS NOT A WORD CHARACTER**, so
  `s|...-c++\b|c++|` can never match at the end of
  `x86_64-linux-musl-c++`. The first version of that rewrite left
  `CXX` naming the cross compiler, silently, past a check that asked
  only about `gcc`. Two substitution lists now, and the assertion
  names every tool -- provoked by putting the cross name back.
- **NOVI COMPILES C EXTENSIONS FOR ITS OWN INTERPRETER** (RFC 0026
  roadmap 5), verified end to end: `pip install --no-binary :all:
  MarkupSafe` downloads the sdist, builds a wheel through
  `pyproject.toml`, installs a `_speedups...musl.so` compiled by the
  machine's own gcc, and `markupsafe._escape_inner` is a
  `builtin_function_or_method` from it. A locally built wheel is
  tagged `linux_x86_64` rather than `musllinux`, which is what every
  distribution's local build produces.
- **`pkg sync` FIRST on a console live boot.** The desktop entry runs
  `novi-live-desktop`, which syncs the on-media index; the plain
  console entry does not, so `pkg install python` answers
  `Package 'python' not found` on a medium that is carrying it.
- **`python3 -m venv` WORKS, with pip inside it**, and it is the
  answer to "pip writes into a directory pkg owns". The venv's pip
  installs from PyPI and the global `/etc/pip.conf` applies there too.
- **pip SHIPPED ALL ALONG.** `--with-ensurepip=no` decides whether pip
  is installed, not whether it is present: `ensurepip`'s bundled
  wheels (pip 24.0, setuptools 79.0.1, 3.3 MB) are part of the
  standard library, so `python3 -m ensurepip --default-pip` installs
  it offline in one command. The flag stays because pip writes into
  `/usr/lib/python3.11/site-packages`, which the `python` package
  owns -- a second package manager in pkg's territory is a decision
  somebody should take on purpose.
- **pip DOES NOT USE THE SYSTEM TRUST STORE.** It verifies against a
  vendored copy of certifi's bundle, so on a machine whose operator
  added a CA, `pip install` fails with a certificate error while
  `urllib.request.urlopen()` succeeds against the same host --
  measured, on a machine whose `ssl` module was perfectly happy. The
  same two-stores-disagreeing shape RFC 0027 found in reverse.
  `/etc/pip.conf` (shipped by the `python` package) points it at
  `/etc/ssl/certs/ca-certificates.crt`; `~/.config/pip/pip.conf` is
  read after it and therefore wins.
- **pip's TAG DETECTION WAS NEVER THE PROBLEM.** It reports
  `cp311-cp311-musllinux_1_2_x86_64` and no manylinux tag at all, so
  it will not select a glibc wheel. The interpreter was the thing
  lying about its libc, not the installer.
- **`idle3` is deleted from the staged tree, not merely unbuilt.**
  `make install` writes the launcher whether or not tkinter exists, and
  a command that cannot start is worse than a command that is absent.
- **When a test reports a bug the code says was fixed, check the test
  is running the artifact you think it is.** `pkg sync` failed on a
  live boot with `/run/live` missing while `/proc/mounts` showed it
  mounted — RFC 0003's buried-mount signature exactly. Half an hour
  went into mount IDs and `s6-linux-init -N` before the cause: the
  QEMU launcher pointed at a five-day-old `/build/initramfs.cpio.gz`
  rather than the `build/initramfs.cpio.gz` just written in the repo.
  The old image had the bug; the shipped one does not.

## Architecture: the up-arrow, and the three layers under it

RFC 0026 roadmap 2. `pkg install python` now brings `ncurses` and
`readline`, and the REPL has line editing, history and `curses`.

- **THIS WAS THREE PROBLEMS, NOT ONE, and the third was invisible.**
  ncurses and readline did not exist; no terminfo existed; and
  **nothing set `TERM`** — measured on a booted machine, `echo $TERM`
  on the console printed nothing at all, for the life of the project.
  The gettys pass a TERMTYPE argument now (`getty 38400 tty1 linux`,
  `getty 115200 ttyS0 vt100`) — base content, one word each, and
  nothing to do with the package.
- **WHAT AN EMPTY `TERM` COSTS WAS WRITTEN INTO FOUR DOCUMENTS BEFORE
  IT WAS MEASURED, AND IT WAS WRONG.** The claim was that the REPL
  would still print `^[[A`. It does not: readline's arrow keys are
  COMPILED-IN bindings rather than terminfo-derived, so history recall
  survives an empty TERM — checked both ways on a booted machine,
  which is the only reason it was caught. What does not survive is
  `curses`: `setupterm()` fails outright with *"could not find
  terminfo database"*, so half of what this item is for cannot work at
  all, and readline gets no cursor capabilities either
  (`tigetstr("cuu1")` returns nothing), which costs redisplay on a
  resize and multi-line editing rather than basic recall. Right in
  direction, wrong in mechanism — and a mechanism stated confidently
  is what someone later reasons from. **Measure before writing it
  down, not after.**
- **THE TERMINFO DATABASE IS NOT SHIPPED.** Upstream's is ~7 MB of
  entries for terminals nobody here has ever seen.
  `--with-fallbacks` compiles a named few into the library and
  `--disable-db-install` keeps the rest out. What that costs is exact:
  **a TERM with no fallback gets NOTHING** — ncurses fails to
  initialise rather than degrading — so the list is the terminals this
  system produces plus the ones a person arriving over ssh announces
  (`linux foot xterm-256color screen-256color tmux-256color vt100
  dumb`). The two halves are coupled: changing a getty's TERMTYPE
  without changing that list gives a description that cannot be found.
- **foot's entry is DERIVED, not copied.** This build host has no
  `foot` terminfo (`infocmp foot` fails), so the fallback generator
  would have produced nothing for the one terminal this desktop ships.
  foot's own source carries `foot.info` as a meson template with
  `@default_terminfo@` placeholders; the stage substitutes it, `tic`s
  it into a private database and points the generator at that. A
  hand-copied entry would be a second copy of foot's capabilities to
  keep in sync with foot.
- **A NEW STAGE HAD TO GO BEFORE AN EXISTING ONE, AND THE FREE RANGE
  IS AT THE END.** CPython detects readline and ncurses at CONFIGURE
  time, so this had to precede the Python stage; 01–39 were all taken
  and the free 40–49 sits after it. That is a gap in the numbering
  rule rather than a violation: the rule protects the 49/50 boundary
  between content and packaging and says nothing about ordering
  WITHIN content. python moved 38 → 41, novi-recon 39 → 42, ncurses
  took 40. Four files mentioned either number — the "about thirty
  files" warning is about the PACKAGING stages, which are named all
  over the prose; two content stages are cheap.
- **AND THAT RENUMBER LEFT 38 AND 39 FREE, which nobody noticed.**
  Vacating a number does not announce itself, so the next person
  reads "01–39 were all taken" above and believes it. sqlite (RFC
  0026 roadmap 3) needed to precede the Python stage too and could
  have taken 38 — it did not, because it links the readline BUILT AT
  40, so its order is ncurses → sqlite → python and 38 is too early.
  python moved again (41 → 43), novi-recon with it (42 → 44), sqlite
  took 41. **Count the free numbers before believing a sentence about
  them**, and remember that "free" and "usable here" are different
  questions once a stage has a build input.
- **readline is GPL-3.0-or-later and CPython's licence is not.** It
  ships as its own shared library, unmodified from the pinned
  tarball, with its `COPYING` in the package, and CPython's `readline`
  module links it dynamically — what every distribution does. The
  obligation is the one RFC 0031 learned about the OFL fonts: **the
  licence travels with the thing.** ncurses' ships the same way.
  libedit (BSD) was the alternative and was rejected: its readline
  emulation is incomplete in ways that produce a REPL which ALMOST
  works, which is the failure this item exists to end.
- **`readline`, `_curses` and `_curses_panel` came OFF
  `EXPECTED_MISSING`**, and that list is why it matters: it is what
  the build expects to be absent, so a name on it is a name nobody
  looks at. They also get a HARD check now — the sweep only warns, by
  design, because the module list shifts between point releases, and
  these three are the whole point of the stage.
- **Four things in this stage were assumed instead of read, and each
  one built cleanly first.** `libtinfow.so*` (the name a
  `--with-termlib=tinfo` build does not use); a `libform w.so*` with a
  space in it; `ncursesw/curses.h` (this build puts `curses.h` at the
  top of the include directory); and two `ln -sf` lines "fixing up"
  unsuffixed names, one of which **replaced a correct
  `libtinfo.so` with a dangling link** and made readline fail on
  `cannot find -ltinfow` — a library the stage had invented. The
  terminal library's name is read out of ncurses' own `tinfo.pc` now,
  and the header is found rather than named.
- **A WILDCARD THAT MATCHES NOTHING IS SILENT, and counting files does
  not catch it.** The package step checked that the total was above
  zero and passed with THREE of five patterns matching nothing — so
  `ncurses` shipped without `libtinfo`, the library `libreadline.so`
  NEEDs. Every pattern is checked individually now. Same bug as the
  tar extraction that shipped 393 MB of firmware with no iwlwifi.
- **The fallback check read the generator's INTENT, not its result.**
  `MKfallback.sh` writes a `fallback entries for: ...` comment
  straight from its argument list, so a name it failed to produce
  still appears there. What only a real entry produces is an
  `<name>_alias_data[] = "<name>|..."` line. The first version looked
  for the bare name in quotes and reported all seven missing on a
  build where all seven were present — the data reads
  `"linux|Linux console"`, not `"linux"`.
- **readline's `make install` leaves `libreadline.so.8.2.old`
  behind.** Dead weight is not inert (RFC 0007): it is bytes on every
  machine that installs this, and a second copy of a library for
  anything that reads the directory.

## Architecture: the database, and the SONAME upstream does not set

RFC 0026 roadmap 3. `build/41-sqlite.sh` — `pkg install sqlite`
brings the `sqlite3` CLI, and `pkg install python` now brings
`import sqlite3` with it.

- **SQLITE'S SHARED LIBRARY HAS NO SONAME BY DEFAULT, and that is
  upstream's deliberate choice.** autosetup's `sqlite-handle-soname`
  says "this project has no direct use for soname, so default to
  none". What it costs a distribution is that every consumer records
  the FILENAME it linked against: here that was `libsqlite3.so`, the
  development symlink, so the runtime package would have had to ship
  a dev symlink for anything to start, and an ABI bump would be
  invisible to the loader. `--soname=legacy` is `libsqlite3.so.0`,
  which is what every distribution passes — checked on the artifact
  with `readelf`, because the default is silent in both directions,
  and confirmed by deleting the flag and watching the check fire.
- **The amalgamation, not the source tree.** Upstream ships the whole
  library as ONE 9 MB translation unit; the "autoconf" bundle wraps it
  in a configure script (autosetup, NOT GNU autoconf despite the name)
  and adds `shell.c`. That is why a database engine costs one stage
  here and 1.4 MB installed.
- **The CLI's readline can silently not happen.** configure reports
  what it found and carries on either way, so the shell builds,
  installs and runs with no line editing at all — the "almost works"
  failure RFC 0026 roadmap 2 exists to have ended, arriving through a
  different door. The stage asks the BINARY (`readelf -d`), not the
  log. And it is not the build host's readline: `--with-readline-
  ldflags` names the cross-built one explicitly, because autosetup's
  probe searches the host's paths and a cross build that finds them
  links a library that cannot load on the target.
- **The features are chosen, not "everything".** FTS5, JSON, R*Tree,
  math functions, `SQLITE_ENABLE_COLUMN_METADATA` — what a Python
  program written elsewhere expects to find, because discovering
  `json_extract` is missing happens at runtime, in a query, on
  somebody else's machine. **ICU is NOT enabled**: a ~30 MB dependency
  this system does not have, for collations most programs never ask
  for.
- **SQLite is public domain and the `sqlite3` BINARY is not.** There
  is no licence text to travel with the library — but the CLI links
  GPL-3 readline, so the binary is a combined work under those terms.
  That is what every distribution ships, and it is fine here because
  `depends=readline` puts readline's `COPYING` on the machine: RFC
  0031's OFL rule, satisfied through the dependency rather than by a
  second copy.
- **`_sqlite3` came off `EXPECTED_MISSING` and onto the hard check**,
  beside `readline`, `_curses` and `_curses_panel`. That list is what
  the build expects to be absent, so a name on it is a name nobody
  looks at — and CPython prints its missing modules and exits 0.
- Verified on a booted machine: the CLI creating a table, an FTS5
  match, `json_extract`, an R*Tree query and `sqrt`; Python's
  `sqlite3` module 2.6.0 against library 3.53.4 doing the same;
  **and the up-arrow recalling the previous statement in the
  interactive shell** over a vt100 serial console, which is the half
  that could have been quietly missing.

## Architecture: novi-recon, and a licence that ended a plan

RFC 0028 (`docs/rfcs/0028-recon.md`). `pkg install novi-recon` — DNS,
WHOIS, TLS certificates, HTTP security headers, robots.txt, a
breached-password check and a TCP connect scan.

- **It exists because the tool to port could not be shipped.** The
  "God's Eye" repository's `LICENCE` is, in full, `Copyright 2022 PAVEL
  DAT. All rights reserved` — which grants nothing — and the other
  GitHub project of that name has no licence file at all (same effect)
  and is 136 lines of skeleton. **Check the licence before planning a
  port**, and especially before putting anything in a repository this
  project SIGNS: the signature is a statement that the contents are
  what we meant to ship.
- **Standard library only, and that is arithmetic rather than taste.**
  The original needs six PyPI packages (two wanting an API key) plus
  the nmap and httpie binaries, on a system with no pip. `depends=` is
  one word: `python`.
- **The DNS client is written out longhand**, and three things there
  are load-bearing: compression pointers must be followed and the
  chain BOUNDED (a two-byte packet can point a name at itself);
  `TC` means ask again over TCP, not report half an answer; the
  transaction ID is random and checked, or any host on the path can
  answer first. Two more found by running it: a long TXT record is
  always split into 255-byte chunks and reading only the first
  silently truncates SPF and DKIM, and **the root name renders as `.`,
  not the empty string** — a null MX is literally `0 .` and `0 ` reads
  as a parse failure.
- **There is no DNSSEC validation, and `dns` says so on every run.**
  Validation needs a trust anchor, a clock you believe and a chain
  walk. What the tool reports is the RESOLVER's claim, and **the AD
  bit in the QUERY is the load-bearing half** — measured against
  8.8.8.8, not assumed: with `RD` alone the response for a signed name
  comes back with AD clear, so without it the tool would have reported
  "not validated" about every domain on earth (RFC 6840 §5.7). `CD` is
  never set — it asks the resolver to skip validation. The verdict is
  three-valued (no answer is not "unvalidated"), only responses that
  carried an answer vote (a NODATA AAAA has nothing to validate), and
  every verdict names who made the claim, because AD is worth exactly
  the path to the resolver.
- **CSP `frame-ancestors` OVERRIDES `X-Frame-Options`.** A clickjacking
  check that reads only XFO gets both interesting cases backwards. The
  verdict is three-valued, because "framable by these specific origins"
  is a real answer a boolean cannot carry.
- **The tests run on the BUILD HOST and that is where the interesting
  cases are** — same argument as `novi-panel/icons-test.c`. A real
  resolver never sends a compression loop or a mismatched ID, and a
  live site exercises one row of the clickjacking table. DNS messages
  are built and parsed back; every verdict is a table. `whois_chain`
  takes an `ask` callable purely so the referral chase is testable
  without the internet.
- **A syntax error in Python is a runtime error.** `44-novi-recon.sh`
  parses the script with the target's exact major.minor before
  packaging, because otherwise the package builds, installs, signs and
  verifies perfectly and dies at the first invocation.
- **`novi-recon all <domain>` IS THE SWEEP, AND `ports` IS NOT IN
  IT.** Every check in it asks a third party about the target -- a
  resolver, a WHOIS server, the site's own TLS and HTTP endpoints,
  which is what a browser does. A port scan reaches for a machine's
  OTHER services, and this tool's own epilog says to point it only at
  systems you are authorised to test: a subcommand called "all" that
  quietly scanned would move that decision from the person to the
  tool, at the moment they are least likely to be thinking about it.
  `--ports` opts in. `pwned` is out for a duller reason -- it reads a
  password from stdin and knows nothing about a domain.
- **One check failing is a FIELD, not the end.** A WHOIS server being
  down must not throw away the DNS, TLS, header and robots findings
  gathered around it -- `novi-state` running each converge in a
  subshell, in a different costume. A partial sweep exits 0; only
  nothing-answered exits 1, because a non-zero status for "WHOIS was
  down" makes this unusable from a script.
- **THAT EXIT-1 BRANCH CANNOT BE PROVOKED AGAINST THE NETWORK**, which
  is why it is driven through `main()` in the host test: `cmd_dns`
  reports NXDOMAIN as a FINDING and returns normally, so a domain that
  does not exist still answers, and the only realistic all-failed
  machine is one with no resolver at all. A rule nobody can make fire
  is a rule nobody can rely on.
- **`render_all` composes the existing renderers**, and the test
  asserts it by COUNTING CALLS into a stand-in table -- a
  reimplementation would render the same report with none, so
  comparing the text could not tell the two apart.
- **THE CHAIN IS ON `_ssl`, NOT `ssl`.** `getpeercert()` decodes the
  LEAF and nothing else, so "the intermediates are not there" was
  never a gap in this tool -- it is all the public API offers.
  `_ssl._SSLSocket.get_verified_chain()` has them and was undocumented
  until CPython 3.13, so every step is behind a `getattr` and a
  missing getter produces `chain: null` with a reason. A recon tool
  that died three checks into a sweep because a private attribute
  moved is worse than one that never listed the chain.
- **CT NEEDED A DER WALK, because `get_info()` returns no
  extensions** -- checked, not assumed: `ssl` has no CT option and
  `_ssl` no SCT attribute. Three rules on that walk: **it is a parse,
  not a search** (the OID's bytes can occur inside a key or a serial,
  and the host test puts them in a SERIAL NUMBER to prove the
  difference); **it is for display, never for trust** (OpenSSL decided
  whether the chain verifies before any of it runs); and **presence is
  not validity**, said on every run, because an SCT is a log's signed
  promise and this tool holds no log keys. `None` is not `0` -- "no CT
  extension" and "an extension holding an empty list" are different
  things a CA did.
- **A FAILED VERIFICATION IS WHERE A READER MOST WANTS THE CHAIN, AND
  IT IS THE ONE PLACE THE TOOL CANNOT PRODUCE IT.** The handshake that
  failed left no connection to ask; reading it means connecting again,
  which is what `-k` does. Found on a booted machine where the guest
  does not trust this network's CA -- the chain section was absent and
  `ct` printed the bare word "unknown". Both say why now and name the
  flag. **The same test found a crash**: `cmd_tls` read
  `e.verify_message` unguarded, and OpenSSL's own raise is the only
  thing that sets it, so a re-raised or wrapped
  `SSLCertVerificationError` turned a REPORTED failure into an
  AttributeError traceback inside a sweep. Invisible live, because
  every real failure carried the attribute.
- **FIVE MALFORMED-INPUT CHECKS COULD NOT FAIL.** They asserted
  `count_scts(junk) is None`, which is also what a parser with its
  bounds checks deleted returns, because the damage surfaces as a
  `DERError` that `count_scts` swallows. Test the layer where a wrong
  answer is a wrong answer -- `der_tlv` -- and assert the WORDING: a
  truncated length and an indefinite one are both caught further down
  by "length runs past the end", so a type-only check stays green when
  the specific guard goes. Two more of the same shape: the
  not-a-SEQUENCE payload died a step later on a truncated tag either
  way, and the bad-total SCT list needed WELL-FORMED trailing bytes
  before deleting the total-length check changed the answer.
- **The cross-check's first version was the broken thing.** Comparing
  the extension walk against `openssl x509 -text` reported a mismatch
  on all three real certificates; the regex reading OpenSSL's output
  dropped every `: critical` header. They agree exactly. Second time
  in one feature that a probe, not the code, was wrong.
- **`sweep_host()` counts colons.** One is `host:port`; two or more is
  a bare IPv6 address, where splitting at the first leaves `2606` --
  which resolves to nothing while still looking like a host.
- **The installed shebang is `/usr/bin/python3`, not `/usr/bin/env
  python3`.** `env` costs a PATH search per invocation, and a `$PATH`
  that finds a different python3 first makes a system tool behave
  differently for different users. The repo copy keeps `env` so it runs
  out of a checkout.
- **`/etc/services` exists now, and the interesting part is not the
  naming.** BusyBox ships no such file, so `getservbyport(3)` answered
  nothing for the life of the project and `ports` printed bare
  numbers. 77 curated entries, base content, installed by
  `03-base.sh`. Three things to know before touching it:
  - **A PORT NAME IS NOT A POLICY.** Shipping the table is the moment
    `tcp dport ssh` starts working in `nft`, and RFC 0022's rule is
    that `/etc/novi/firewall.nft` names ports as NUMBERS — a rule
    resolved through a name table means something different on a
    machine whose table differs. That rule could not be written wrong
    before, because there was no table; `test-services.sh` enforces it
    now.
  - **musl's parser has two silent limits**, read out of
    `lookup_serv.c` and `getnameinfo.c` rather than assumed. Both
    readers use `fgets(line, 128, f)`, so a line of 128 bytes or more
    is SPLIT and its tail parsed as a record of its own; and
    `reverse_services()` skips a name of 32 bytes or more, so an
    over-long name resolves by NAME and stops resolving by PORT —
    half-working, in the direction nobody would test.
  - **Every failure mode is silent and looks like the feature
    working.** musl reports no malformed line, no duplicate, no
    over-long name: it skips and hands back a number, which is exactly
    what `ports` prints for a port that genuinely has none. That is
    why a data file with no code in it has 823 checks, each provoked
    by breaking the file and watching it fire.
  Aliases resolve ONE WAY — the forward lookup searches the whole
  line, the reverse copies the first field only, so `getservbyport(80)`
  is always `http` however many aliases follow. A port not in the
  table still prints as a number, which is the right answer: inventing
  a name for a port nobody registered would be the tool guessing.

## Architecture: the interface an automated actor uses

RFC 0029 (`docs/rfcs/0029-agent-interface.md`). `novi-agent describe`
is one JSON document saying what this machine is; `novi-agent do
<verb>` changes it within a declared list. Base image, ~21 KB of shell.

- **Reading is free, writing is declared.** `describe`/`capabilities`/
  `audit` are a formatted view of files any user can already read.
  `do` needs `agent.enabled = on` AND the verb in `agent.allow` —
  **two keys, not one**, which is RFC 0022's argument about
  `network.firewall.allow` verbatim: a machine that grants powers
  because a program was installed is a service registry with a policy
  file attached.
- **There is no `exec` verb and no `service.start`.** The first would
  be the absence of a boundary wearing a policy file; the second is
  drift by construction, and an agent that produces drift on purpose
  defeats the engine it is talking to. `test-agent-verbs.sh` fails the
  lint run if an `exec)`/`shell)`/`run)` branch ever appears — "we
  agreed not to" is not a mechanism.
- **`describe --text` is a VIEW of that document, not a second
  answer.** Each `describe_*` reads its sources once and branches on
  `$FMT` at the `printf` — one gatherer, two printers — so the drift
  that matters cannot happen. What remains is a *display* omission,
  and `test-agent-text.sh` catches it with no list of its own: every
  STRING value in the JSON must appear in the table. Strings and not
  numbers, because reformatting a number (`1998848 kB` → `15.7 GiB`)
  is the work the mode exists to do. `state`/`drift`/`health` are not
  re-rendered at all — the table runs `novi-state diff` and
  `novi-state health` and indents them, which is one renderer where
  reimplementing them would be two. And the test's own first probe
  could not fail: `*"sleep after"*"off"*` was satisfied by the word
  "off" further down the table, in the agent section's own message.
  Read a ROW, not the whole output.
- **`describe` COMPOSES and computes nothing.** State and drift from
  `novi-state --json`, verdicts from `health --json`, the interface
  from `/run/novi/network.device` (the file the service published, per
  RFC 0009 — never a second walk of `/sys/class/net`), packages from
  `pkg list`. A summary that computed its own answers would be a second
  source of truth about a machine whose architecture exists to have
  one. That is why `novi-state show`/`diff`/`health` gained `--json`.
- **`/usr/lib/novi/json.sh` is the ONE escaper**, sourced by both
  scripts. Two things in it are load-bearing and both were caught by
  the test rather than by reading: **backslash is escaped before
  quote** (the other order turns `"` into `\"` and then that backslash
  into `\\`, so the quote ends the string — the injection this
  exists to stop), and **tab/newline become a space BEFORE the length
  cap**, because `cut` appends a newline to input that had none and
  doing it after put a trailing space on every string this system
  emits. Valid JSON, silently wrong.
- **`.` is a SPECIAL BUILTIN.** Sourcing a missing file in ash ends the
  script immediately — status 2, nothing on stderr that anyone would
  connect to a missing library. Guard every `.` with `[ -f ... ]`.
  Found writing this feature's own test.
- **`f() { g "$1" && return 1; ... }` is a `set -e` trap.** The
  AND-list's own failure becomes the function's status, and whether
  that ends the script depends on whether the caller happened to put
  the call in a condition. Same for `x="$(helper)"` where the helper
  returns 1 for "this machine has no wifi" — an assignment from a
  failing command substitution ends the script. One `case`, and an
  explicit `return 0`.
- **`wifi.join` is the first verb that handles a SECRET, and THE
  REFUSAL PATH is the half that is easy to get wrong.** `cmd_do`
  captures `args="$*"` before it dispatches, so refusing the obvious
  mistake — `wifi.join <ssid> <passphrase>`, the secret in argv where
  every other verb puts its arguments — with `"$args"` would write
  that passphrase into a 0600 log **permanently, by the refusal meant
  to protect it**. A boundary that leaks what it guards while
  reporting a refusal is worse than no boundary. Every refusal in that
  branch audits a fixed string; the SSID is audited because an SSID is
  configuration. `packages/tests/test-agent-secrets.sh` asserts all of
  it and was confirmed by reintroducing the leak and watching it fail.
- **An SSID is rejected by CLASS, not by allowlist.** Every other
  argument is checked against an `[A-Za-z0-9._-]`-ish set; real SSIDs
  contain spaces and apostrophes, so that rule would refuse a large
  share of actual networks. No leading `-`, nothing empty, no control
  characters, 32 bytes (what 802.11 allows). And a **terminal on stdin
  is refused** — `novi-wifi` would prompt, so an agent reaching the
  verb by accident would hang rather than fail.
- **A verb that only adds a second path to an existing key should not
  exist.** `firewall.allow` was on the roadmap and was rejected:
  `network.firewall.allow` is a novi-state key, so `state.set` already
  reaches it, and a second writer with its own semantics is how RFC
  0022's "one list a person chose" stops being one list. Hold the next
  candidate to the same test — does it add a capability, or a second
  path to one that exists?
- **Refusals are audited**, at `/var/log/novi-agent.jsonl`, 0600, JSON
  lines so `audit` is a `tail` and not a formatter. A boundary that
  records only what it let through tells you nothing about what was
  tried — RFC 0016's rule about silent refusals.
- **`agent.rate` bounds an ACCIDENT and is not a security control.**
  Anything that can run `novi-agent do` can run `pkg` directly, so a
  limit here stands between nobody and nothing — say that wherever it
  is described, because a boundary people believe in is more dangerous
  than one they do not. What it buys is legibility: a buggy actor
  looping on one install becomes a run of `rate limit` refusals in the
  audit log, where a thousand successes say nothing (RFC 0016's silent
  refusal argument, from the other end).
- **ONLY ALLOWED CALLS COUNT toward the rate limit.** Counting
  refusals makes it self-sustaining — each refusal is a log line, so
  once tripped it stays tripped for a minute even if the caller
  stopped. A lockout wearing a rate limit's clothes, and it reads fine
  in a diff. **The test for it could not fail at first**: raising the
  limit and expecting one more call through passes either way. It
  needs a window where *allowed* is under the limit while
  allowed-plus-refused is over it. Introducing the bug on purpose is
  the only reason that was caught.
- **ISO-8601 UTC sorts LEXICALLY**, so "is this line inside the last
  minute" is a string comparison with no date parsing in a shell
  script. That property is most of what the audit format is worth.
- **`grep -c` prints the count AND exits 1 when the count is zero.**
  `grep -c … || echo 0` therefore emits `0\n0`, and every arithmetic
  test on it dies with "integer expression expected". `|| true`. Hit
  twice in one afternoon.
- **`agent.enabled`/`agent.allow`/`agent.rate` are read-at-use-time
  keys**, so the observer is the only place a typo surfaces. ONE unknown verb makes
  the whole `agent.allow` line report `unsupported`: reporting the rest
  as converged would hide `pkg.instal` from exactly the diff a person
  would look at.

## Architecture: the non-root path, and two correct halves

RFC 0032 (`docs/rfcs/0032-non-root-agent.md`). `services.novi-agentd =
on` puts an `s6-ipcserver` on `/run/novi/agent/sock` so a process that
is NOT root can drive RFC 0029's verb list. The privilege moves: the
big untrusted program runs as nobody in particular, a small reviewed
one holds root. What may be done is unchanged — `agent.allow` still
decides that.

- **The gate is `2750 root:agent`, and the setgid bit is the whole
  feature.** `s6-ipcserver` binds as root, so the socket is created
  `root:root`, and `-a 0660` on a `root:root` socket gives the `agent`
  group nothing. The first version had a correct `0750 root:agent`
  directory AND a correct `0660` socket mode and denied every member
  of the group it exists for — service up, service ready, `Permission
  denied`. A setgid directory hands its group to everything created
  inside it, sockets included (`bind()` goes through `vfs_mknod`), so
  the socket comes out `root:agent`. **Two correct halves that are
  wrong together is not something a diff shows**, and no host test
  could reach it: the test covers the handler's parser and this is the
  daemon's `chmod`. It took a boot.
- **BusyBox `setuidgid` DROPS supplementary groups; `s6-setuidgid`
  keeps them.** `setuidgid ai …` reports `groups=1000(ai)` and is
  denied by the socket; `s6-setuidgid ai …` reports
  `groups=104(agent),1000(ai)` and connects. The first reading of that
  denial was "the fix did not work" — it was the test tool, for the
  second time in this feature. A grant that IS group membership only
  reaches a process that actually carries the group, which constrains
  whatever launches an agent here and not just how it was tested.
- **The handler holds NO policy, and `wifi.join` is why.** Its socket
  refusal was written in `novi-agent-serve`, where it worked and left
  no trace: the handler exits before `novi-agent` runs, and
  `novi-agent` is the only thing that writes the audit log — so the
  attempt most worth recording was the one that vanished. RFC 0016's
  rule from an unwatched direction. It lives in `cmd_do` now, keyed on
  `NOVI_AGENT_VIA`, withholding the arguments like every other
  `wifi.join` exit. `novi-agent-serve` rejects only a request that is
  not a request (no credentials, no line, over 512 bytes, control
  characters).
- **`set -f` BEFORE `set -- $line`.** Unquoted expansion in a shell
  splits words *and* expands globs, so `state.set hostname *` would
  arrive as the contents of the handler's cwd. Verified on the booted
  machine, not only in the host test: the audit line reads `"args":
  "hostname *"`.
- **Identity comes from `SO_PEERCRED`** (`s6-ipcserver -p` →
  `IPCREMOTEEUID`), never from the request, and reaches the audit as
  `NOVI_AGENT_PEER_UID`. `id -u` would have recorded root for every
  request whoever made it — the one question an audit log exists to
  answer, with a single wrong answer. A `via` field separates "root at
  a shell" from "root through the socket", which a uid cannot.
- **`notification-fd` is 1, not the 3 every other service here
  declares**, because `s6-ipcserver -1` names the descriptor. Watching
  fd 3 would leave the service never ready and `s6-rc -u change`
  waiting out `timeout-up` on every start — RFC 0004's `s6-log -d3`
  bug with the mismatch on the other side. Caught by reading the flag.
- **`services.novi-agentd` is separate from `agent.enabled`**, off by
  default. Running the interface and exposing it to non-root callers
  are two decisions — RFC 0022's argument about
  `network.firewall.allow` for the third time.
- **`novi-agent send` exists because the incantation is not the
  interface.** Driving the socket by hand is `s6-ipcclient <path>
  s6-ioconnect` with the request on stdin, which works and which
  nobody would guess — and the audience for the non-root path is
  exactly the reader least likely to know skarnet's tool names. Same
  verbs, same spellings, same JSON as `do`. It refuses an argument
  containing whitespace rather than sending it: the protocol is one
  line split on whitespace, so it would arrive as two arguments and
  the verb would act on something it was never given.
- **"Absent" and "unreachable" are different problems and `test -S`
  cannot tell them apart.** For somebody outside `agent` the socket
  directory is not searchable, so the test fails exactly as it would
  if the daemon were off — and the first version told a non-member to
  turn on a service that was already running. Check `[ -d "$dir" ] &&
  [ ! -x "$dir" ]`: the directory is visible, the search bit is what
  is missing.
- **`init/services/novi-agentd/finish` is the only `finish` script in
  this repo**, and it unlinks the socket. `s6-ipcserver` leaves it
  behind, so a *stopped* daemon left a socket file that made `send`'s
  "is it running?" test say yes — and the caller got s6-ipcclient's
  raw `Connection refused` instead of the sentence naming the key
  that starts it. The run script's own `rm -f` before binding is the
  same removal from the other side.
- **The usage text is a THIRD list**, after `VERBS` and novi-state's
  `AGENT_VERBS`, and it had already drifted: `wifi.join` was
  dispatched, permitted, and unmentioned by `novi-agent` with no
  arguments. `test-agent-verbs.sh` checks all three now.

## Architecture: a window that stopped answering

RFC 0038 (`docs/rfcs/0038-unresponsive-windows.md`). novi-shell samples
two things about every mapped window every two seconds -- did its
client commit a surface, and how much CPU did its process burn -- and
judges a window **not responding** when the answers are "no" and "at
least half a processor" for ten seconds running.

- **RFC 0031 ITEM 6 SAID THIS NEEDED "a notion of progress NetSurf
  does not currently export", AND THAT IS TRUE OF NETSURF AND FALSE OF
  THE PROBLEM.** A Wayland client that is answering COMMITS SURFACES;
  one stuck in its own layout loop commits nothing. The compositor has
  had that signal for every client on the machine since it existed.
  Nothing had to be exported -- it had to be looked at. **Fifth
  roadmap item in this repository found to be wrong about what is
  already available**, and the second one in RFC 0031 specifically
  (after "a browser needs Rust and a large native dependency tree").
- **NEITHER FACT IS SUFFICIENT AND THAT IS THE WHOLE DESIGN.** Every
  idle editor on the machine commits nothing; every client that draws
  while it works burns CPU. Only the pair means anything, and the CPU
  half is also what makes it cheap -- one store per frame, a
  measurement five times a minute.
- **IT CANNOT TELL SLOW FROM STUCK, so it kills nothing.** From
  outside a process -- the only vantage point available -- a client
  laying out an enormous document is indistinguishable from one that
  never will. So the watchdog REPORTS and a person presses a key: a
  false positive costs one sentence on screen instead of somebody's
  unsaved work. The thresholds are generous for the same reason,
  set where a long computation inside a client's own process is rare
  rather than where a hang is caught soonest.
- **50%, not 90%.** The case this exists for is a layout loop on a
  machine with other work on it -- and `nice 5` on the browser (RFC
  0031 roadmap 5) makes a wedged browser LESS likely to hold a whole
  core, not more.
- **The CPU is per-PROCESS and the verdict is per-window**, so a
  client counts as making progress if ANY of its mapped windows
  committed. A program animating one window and blocked on another is
  working, and judging its second window wedged would be this code
  disagreeing with itself about one process.
- **The commit flags are cleared in a SECOND pass.** The judgement
  reads other windows' flags, so clearing one as the loop passes it
  would hide a sibling's progress from every window visited after it.
  Same shape as novi-panel reading the volume file inside
  `layout_taskbar()`.
- **A window this compositor cannot measure is never accused.** No pid,
  or no `/proc` entry, and it is permanently "making progress" -- the
  failure of the instrument must not read as a finding about the thing
  measured. `novi_procstat_cpu_percent()` returns -1 rather than 0 for
  the same reason, so the first tick after a window appears (no
  previous sample) cannot contribute to a verdict.
- **`Super+Shift+Q` HAS ONE RULE, and that is what makes it safe one
  shift from `Super+Q`**: ask the program to close, and signal it
  instead when the watchdog has already established it cannot hear the
  request. Pressed by accident on a healthy window it IS
  `window.close`, unsaved-changes prompt and all. Escalation is the
  person pressing it AGAIN (SIGTERM, then SIGKILL), never a timer --
  a timer would be guessing how long a dying program deserves.
  A recovery resets the stage.
- **A close request is per-window and a signal is per-process**, so
  force-quitting one wedged window of a program with several takes
  them all. Unavoidable: a client that cannot read its socket cannot
  act on a per-window request at all.
- **THE PID IS CHECKED BEFORE IT IS SIGNALLED.** A pid is a number the
  kernel reuses and this is the only place the compositor acts on one,
  as root. The process's start time (field 22) is recorded at map and
  compared before the signal; a change means a different process is
  wearing the number.
- **`/proc/<pid>/stat` CANNOT BE PARSED BY COUNTING FIELDS FROM THE
  LEFT.** Field 2 is the executable name in parentheses and the kernel
  neither escapes nor rejects what is in it -- `prctl(PR_SET_NAME)`
  lets a process name itself `R 1 1 1 1 1 1 1 1 1 1 999 888`, which is
  attacker-chosen text in exactly the case this watchdog exists for.
  Parse from the LAST `)`. `common/procstat-test.c` provokes both
  mistakes; **its `strchr` check could not fail at first**, because
  with `utime 700, stime 7` the misparse also lands on 707 -- the
  field it mistakes for utime happens to hold a 7.
- **NOTHING HERE REACHES A SHELL.** The notification's summary carries
  a window TITLE -- text a program rendering somebody else's document
  chose -- and `spawn()` hands its string to `/bin/sh -c`. A page
  titled `'; reboot #` would have been a remote command injection into
  the compositor, as root, delivered by the code that noticed the page
  was hostile. `notify_unresponsive()` forks and `execlp`s with an
  argv. The same title reaching `/run/novi/windows` goes through
  `novi_hist_sanitise()`, which DROPS control characters, so a newline
  cannot arrive to forge a second record.
- **Its own timer, not the idle tick.** That tick counts idleness and
  RETURNS EARLY from several branches (inhibited, waiting for a lock
  surface, having just suspended) -- a watchdog on it would stop
  watching in exactly the situations where nobody is looking at the
  machine. RFC 0030's theme watch made the same call.
- **`/run/novi/windows` is written ONCE AT STARTUP with a count of
  zero**, so an absent file means no compositor and a present one with
  `0` means nothing is wrong. Different answers, and a reader cannot
  otherwise tell them apart. Nothing wedged means no further I/O at
  all.
- **The notification names the LIVE binding**, looked up in the table
  novi-shell loaded rather than written into the string, and says "no
  key is bound to end it" when somebody has unbound it (RFC 0037).
- **No icon**, deliberately: this set has no glyph that means "wedged"
  and RFC 0024's rule is that an unknown name is no icon rather than a
  fallback. Borrowing `shield` would say something else confidently.
- **A BLANKED SCREEN IS NOT A FINDING, and only a booted machine was
  ever going to say so.** With the outputs off wlroots stops sending
  frame callbacks, so every well-behaved client stops committing --
  and the one window still burning CPU would be a client legitimately
  computing in the background, which is exactly the shape this looks
  for. The verdict FREEZES while blanked rather than clearing: a
  window already judged wedged still is, and clearing it would log
  that it had started drawing again about a dark screen. Sampling
  continues, so the first tick after the screen returns has a real
  delta rather than one spanning the whole blank period -- watched
  live: a window wedged for 74 seconds still read 74 after 25 seconds
  of blanking, then 78 and 102 once a keypress brought the screen
  back, with the CPU percentage moving throughout.
- **A HIDDEN WINDOW IS NOT A WEDGED WINDOW, and the roadmap item that
  filed this said it "does not misfire today".** It did, and a
  base-image client was enough to show it. `switch_workspace()` calls
  `wlr_scene_node_set_enabled(node, false)`, a disabled node never
  reaches `wlr_scene_output_commit()`, so nothing calls
  `wlr_surface_send_frame_done()` for it -- and a client that throttles
  on frame callbacks (nearly all of them) renders once more, requests a
  callback and waits forever. **Whether its process then goes quiet is
  up to what that process is DOING**, which is the step the item
  skipped: a terminal emulator with output to parse keeps working.
  Reproduced on the booted desktop -- `foot -e sh -c yes` reads
  `unresponsive 0` visible and **`window 10418 75 28 foot`**
  twenty-four seconds after Super+2, doing its job perfectly.
- **THE FIX IS "DID IT ASK TO DRAW", NOT "DID IT DRAW".**
  `wlr_surface_state.frame_callback_list` holds the callbacks a client
  has requested and this compositor has not fired; non-empty means the
  client is waiting on US, so whatever else is true it is not stuck.
  **One rule rather than a workspace branch**: the same reasoning
  covers minimize, and it stays correct for a VISIBLE window because a
  genuinely wedged client has already CONSUMED its callback -- we fired
  it, its handler never returned, the list is empty. Being on screen is
  not what makes the verdict valid; being answered is. Bounded, too:
  for a visible surface the list empties at every output commit, so it
  cannot survive the five consecutive ticks a verdict needs -- except
  while the outputs are off, which `server->blanked` already covers.
- **BOTH HALVES HAD TO BE WATCHED, because a change that silenced the
  watchdog entirely would have passed the first alone.** Hidden and
  fine: foot alive at pid 10419, `utime+stime` moving 2973+1248 ->
  3241+1389 over five seconds (~82% of a processor), verdict
  `unresponsive 0`. Visible and genuinely stuck: NetSurf on
  `unclosed-tags.html` off the guest's own loopback, `unresponsive 1 /
  window 12132 100 52 NetSurf`, still there at 84 seconds.
- **`/run/novi/windows` COULD NOT HAVE ANSWERED THE FIRST HALF ON ITS
  OWN.** It lists only WEDGED windows, so `unresponsive 0` is also what
  a desktop with no windows says -- a foot that had simply exited would
  have read as a pass, and one run did exactly that before the pid and
  tick counts were added. This file already records the same shape from
  the panel's side ("an absent file and one saying `unresponsive 0`
  draw the same nothing"); it bites a TEST just as hard.
- **`long-line.html` WAS JUDGED WEDGED AND THEN RECOVERED FOUR SECONDS
  LATER**, live, which is decision 2 happening rather than being
  argued: it was slow, not stuck, and this said the wrong thing about
  it for four seconds. The cost was one notification, which is the
  whole reason nothing here kills anything.
- **CLOSING THE FOCUSED WINDOW LEFT NOTHING FOCUSED**, for the life of
  this compositor, so the next binding that acts on "the focused
  window" silently did nothing until an Alt+Tab or a click. wlroots
  clears seat focus when the focused surface dies and
  `xdg_toplevel_unmap()` never handed it on --
  `minimize_toplevel()` and `switch_workspace()` had both always done
  so, which is what made it look deliberate. Found while testing RFC
  0038's force-quit, where it presented as the NEW key being broken.
  Fixed with the same MRU-first pick those two use, restricted to the
  ACTIVE workspace: closing a window must not carry somebody to
  another one, which is what `focus_toplevel()` does when handed a
  candidate living there.
- **THE SHORTCUT SHEET'S `_Static_assert` FIRED ON THE FIRST ROW ADDED
  SINCE IT WAS WRITTEN.** Twenty bindings at 32px rows is a 769px
  buffer against a 768px limit -- over by one pixel, on a 1366x768
  panel nobody here has. This file had recorded that the sheet was
  "one row from outgrowing" it and that was exact. `ROW_H_KEYS` is 30
  now (729px): one more row of headroom and no more, after which the
  answer is two columns or a scroll rather than another pixel.
- **THE PANEL DRAWS AN HOURGLASS NOW, AND ITS COLOUR IS THE
  ARGUMENT** (RFC 0038 roadmap 3, decision 13). text-secondary, like
  the muted speaker and the coffee cup -- not the warning colour the
  health glyph gets. Decision 2 is why: the watchdog cannot tell slow
  from stuck, so "this is taking a long time" is the strongest claim
  it can support, and `long-line.html` recovering four seconds after
  being judged is what that limit looks like in practice. A glyph
  that shouted would claim a certainty the code raising it has
  already refused.
- **NO NUMBER BESIDE IT, and that is a real difference from the
  bell.** A number next to an hourglass reads as a DURATION -- the
  exact quantity this glyph is about -- while what the compositor
  counts is windows. The Session panel names each one with its stall
  time.
- **It goes BETWEEN the health glyph and the coffee cup** so the
  three glyphs that open `novi-settings --panel session` are
  contiguous: a click landing between two of them still opens the
  window that explains whichever was aimed at. `status_layout()` is
  the one march the drawing, the taskbar's right-hand limit and the
  hit-test all read -- now four glyphs, same rule.
- **AN ABSENT `/run/novi/windows` AND ONE SAYING `unresponsive 0`
  DRAW THE SAME NOTHING, and they are different answers.** There is
  no glyph for "asked, and everything is fine", exactly as there is
  none for a healthy machine's services.
- **`row_extent()` CANNOT SEE A MISSING BAR, and the provocation is
  what found that.** The hourglass's diagonals END at the bars' own
  corners, so deleting a bar outright leaves ink at both ends of that
  row and leftmost-to-rightmost does not move by a pixel -- the check
  passed on a glyph with no bottom bar. What a missing or short bar
  leaves is a HOLE, so the row must also be ONE run. Fourth time in
  this file that a probe, rather than the code, was the broken thing.
- **A RUN COUNT NEEDS A THRESHOLD THAT MEANS "ink somebody can
  see".** Two strokes a couple of pixels apart still share
  antialiasing tails: at the 0.05 every other probe here uses, the
  row a quarter of the way down reads as ONE run while rendering with
  a visible gap. 0.35 -- what `show()` prints as `+`. The check it
  makes possible is the only one a **Z** fails: delete one diagonal
  and what is left has both bars, a narrow middle, ink at the centre,
  and 180-degree symmetry.
- **DECISION 10's "no icon" IS CLOSED, and drawing the panel glyph is
  what closed it.** That decision said the empty notification icon
  column was honest "until somebody draws the right glyph" -- and
  Lucide already had one: `hourglass`, the SAME two-bars-and-two-
  diagonals shape the panel now draws procedurally. Two pipelines
  agreeing (the panel's geometry in `novi-panel/icons.c`, the
  rasterised SVG set in `shared/icons/`), as `wifi` and `power`
  already do. An icon name is still matched against a fixed list and
  an unknown one is still no icon.
- **A NEW SHARED ICON IS FOUR LISTS, not one**: the vendored SVG plus
  its MANIFEST row, `shared/icons/icons.h`'s enum, `svg2icon.c`'s
  table (with a SIZE -- 24 for a notification column, 16 for chrome),
  and then every client's own name table -- novi-notifyd's
  `icon_by_name` AND novi-launcher's `resolve_icon_name`, which is
  what the history list reads. RFC 0034 already learned the second
  half of that the hard way: two rows out of three had an empty icon
  column because the launcher's table had never learned `drive` or
  `eject`.

## Architecture: the CLI gap, and a prefix chosen by an absence

RFC 0040 (`docs/rfcs/0040-gnu-userland.md`). `pkg install coreutils
bash` -- the full GNU tools under `/usr/gnu/bin`, ahead of the busybox
applets on a LOGIN shell's PATH and nowhere else.

- **`/usr/gnu/bin` IS A DESIGN MADE AROUND AN ABSENCE, not a
  preference.** `pkg install` extracted an archive over the root
  filesystem: no owner check, no conflict refusal, no backup --
  checked, not assumed. `/bin/ls` is a symlink to busybox, so a
  package shipping `/usr/bin/ls` would quietly take the name and
  **`pkg remove coreutils` would then DELETE it**, leaving a machine
  with no `ls` and no way for pkg to know. Times ~100 names. Teaching
  pkg about ownership was the right fix and was a change to the
  program that installs code as root -- not a side effect of adding a
  shell, which is why it became roadmap 1 rather than a patch in this
  stage. **It is done now and the prefix STAYS**: ~100 declared
  takeovers with ~100 saved originals is a worse answer than a prefix
  and a PATH entry, so what changed is that `/usr/gnu` is a choice
  rather than a requirement.
- **A LOGIN SHELL IS THE RIGHT SCOPE, and that is what makes
  prepending safe here.** `/etc/profile` is NOT what gives an s6
  service its PATH -- s6-linux-init-maker's `-p` is (`04-s6.sh`) -- so
  the drop-in reaches the person typing and nothing else. On a
  distribution where /etc/profile is the system's PATH this would be
  reckless. `/etc/profile` already sourced `/etc/profile.d/*.sh`, so
  the package needed no base change at all.
- **`/bin/sh` IS NEVER REPOINTED.** Every `#!/bin/sh` script here was
  written against busybox ash and `packages/pkg` depends on it
  (`set -o pipefail`). The declarative way to log in with bash already
  exists: `users.<name>.shell = /usr/gnu/bin/bash` (RFC 0005).
- **bash 5.3 NEEDS readline 8.3 AND THE LINKER IS WHAT SAID SO** --
  `rl_completion_rewrite_hook`, `rl_full_quoting_desired`. GNU pairs
  bash X.Y with readline (X+3).Y; this system pins 8.2 for CPython, so
  what ships is the matched pair, bash **5.2.37**. It links the
  PACKAGED readline (`--with-installed-readline`) rather than the copy
  it bundles: one library, one CVE to watch, one GPL-3 COPYING already
  travelling.
- **`-shared -pie` FOR THE THIRD AND FOURTH TIME, and gcc still does
  not warn.** bash's loadable builtins and coreutils' `libstdbuf.so`.
  bash's is worse: the top-level makefile prefixes that recursion with
  `-`, so **`make install` exits 0** having printed fourteen undefined
  references and `Error 2 (ignored)` in the middle of its output.
- **AND THE COREUTILS FIX NEEDED TWO GOES, because the second bug hid
  behind the first.** Filtering `-pie` out of the link got past
  `undefined reference to 'main'` and into `relocation R_X86_64_PC32
  against symbol 'stderr' ... recompile with -fPIC`: automake's
  compile rule is `$(src_libstdbuf_so_CFLAGS) $(CFLAGS)`, so
  upstream's own `-fPIC` comes FIRST and the hardening `-fPIE` wins. A
  target-specific variable fixes that one object.
- **A LINE-ANCHORED `sed` CANNOT SEE A CONTINUED MAKE RULE.** automake
  writes that LINK rule across two lines, so `$(LDFLAGS)` is on the
  second and the first fix "succeeded" by matching nothing. It is an
  appended override now (a later simple assignment wins in GNU make),
  and the check is on the ARTIFACT -- a `PT_INTERP` in `libstdbuf.so`
  would mean gcc had linked an executable again.
- **A PROGRAM IS NOT ALWAYS ONE FILE, and the floor checked the wrong
  half.** `stdbuf` is a launcher that `LD_PRELOAD`s
  `libexec/coreutils/libstdbuf.so`; the packaging swept `bin/` only,
  so it installed, ran, and answered `failed to find 'libstdbuf.so'`.
  It was on the floor list PRECISELY because it was the likeliest to
  go missing -- and the floor asserted the part that was there. Only a
  booted machine showed it.
- **WHAT IS IN THE PACKAGE IS DERIVED; WHAT MUST BE THERE IS A
  FLOOR.** Naming all 103 programs by hand fired on the second run:
  `chcon` and `runcon` need libselinux, which this system does not
  have. A hand-written list drifts from what the build produces --
  pkgsplit's argument -- so the sweep takes what was built and a short
  floor catches a build that lost something.
- **Five programs are deliberately NOT installed** (`kill`, `uptime`,
  `hostname`, `stty`, `arch`) because busybox ships them in the BASE
  and this package is additive. `bashbug` goes too: it mails through a
  `sendmail` this system does not have, and a command that cannot work
  is worse than one that is absent (RFC 0026's `idle3`).

## Architecture: the four tools that are not alike

RFC 0040 roadmap 4, `tests/textutils-gap/`. The item named `sed`,
`grep`, `awk` and `tar` in one breath and asked for *"a number, not an
opinion"*. The number says they are not alike.

- **52 constructs, 37 agree, 15 differ** -- each run under the shipped
  busybox AND under the GNU program, comparing output and exit status.
- **LOUD VERSUS SILENT IS WHAT DECIDES IT, not agree versus differ.** A
  busybox that errors is a bug report the person at the terminal gets
  for free. One that **exits 0 with different text** has quietly
  corrupted the output of a script that looked like it worked. Twelve
  of the fifteen are loud.
- **ALL THREE SILENT ONES ARE `sed`.** `\U` and `\L` emit a literal
  `U`/`L` instead of converting case, and `0,/re/` matches nothing.
  That is what earns sed a package and nothing else here does.
- **`awk` DOES NOT EARN ONE, which is not what anyone expected.** 14
  of 15 agree -- `gensub`, `strftime`, `ENVIRON`, regex `RS` and
  `length(array)` included. Only `asort` is missing. `tar` does not
  either: its three gaps (`--transform`, `--owner`/`--group`,
  `--sparse`) are packaging flags, while hardlinks, mtimes,
  `--exclude`, `--strip-components`, `-z` and `-J` all agree.
- **DEBIAN'S `awk` IS mawk**, so the first run compared busybox
  against mawk and reported `gensub` as a busybox WIN -- inverting the
  one conclusion those rows exist to reach. The probe names `gawk` and
  refuses to run without it. Read what `command -v awk` actually
  points at before calling a comparison "GNU".
- **A PIPELINE REPORTS ITS LAST COMMAND'S STATUS, for the fourth time
  in this file.** `printf | $T -z | tr` returned 0 with busybox's
  `unrecognized option: z` in the output, so two LOUD failures were
  counted as SILENT ones -- by the instrument built to measure exactly
  that distinction. `bash -o pipefail -c`.
- **ISOLATING THE TWO SIDES IS WHAT MADE THE TAR COLUMN MEAN
  ANYTHING.** They shared a directory, so the hardlink case failed
  under busybox with `File exists` -- left by the GNU run of the same
  case -- and read as a busybox limitation it is not. Giving each run
  a clean directory then exposed that seven tar cases had been
  chaining off the first case's `td`.
- **`--self-check` POINTS BOTH SIDES AT GNU AND MUST RETURN 52/52.** A
  harness that found a difference in every case would produce exactly
  this alarming table and nothing in the output would say so. Its own
  first shim was `#!/bin/sh` with `"${@:2}"`, which dash expands to
  nothing -- so the check that proves the harness can report agreement
  reported 0/52.

## Architecture: util-linux, and the commands that could never run

RFC 0040 roadmap 3, `tests/utillinux-gap/`. The item named util-linux
beside coreutils and bash and RFC 0040 scoped it out as *"its own
RFC"*. The measurement says there is no RFC to write.

- **91 util-linux programs; busybox provides 48 of those names and
  lacks 43.** Two questions, two instruments. `probe.sh` runs **31
  comparable cases** over the overlapping 48 -- **25 agree, 6 differ**;
  `inventory.sh` classifies the missing 43 against the GENERATED
  kernel config and the image -- **GAP 26, COVERED 12, CANNOT 5**.
- **EXACTLY ONE LOUD DIFFERENCE: `flock -w <timeout>` does not exist
  in busybox**, and there is no workaround (`timeout N flock …`
  releases the lock when it kills flock). Nothing in Novi's own code
  uses flock at all -- novi-state and novi-mount both take an `mkdir`
  lock precisely because busybox has none.
- **FIVE ARE CLASSED SILENT AND ONLY TWO ARE A WRONG ANSWER.** `blkid`
  omits `BLOCK_SIZE=`; `mountpoint` exits **32** where busybox exits
  **1** on the same verdict, so every `if mountpoint -q` works and only
  `[ $? -eq 32 ]` breaks. The other three differ **only in the wording
  of the error**, with both sides refusing. LOUD-versus-SILENT is the
  right axis (roadmap 4) and the classifier cannot tell a different
  *message* from a different *answer* -- read the rows, do not count
  them.
- **THE TWO GAPS ANYBODY WOULD REACH FOR ARE ALREADY ANSWERED.**
  `lsblk` and `lscpu` are both "what is this machine", and
  `novi-agent describe` reports CPU model and count, memory, firmware
  and every block device with size and removable flag, from `/proc`
  and `/sys` with nothing forked. What `lsblk` adds is the partition
  TREE, which is "extend `describe_hardware()`".
  `partx`/`addpart`/`delpart`/`resizepart` look like an installer gap
  and are not: busybox ships `partprobe` and `novi-install` calls it.
- **The cost was never only size**: util-linux would put a SECOND
  implementation of "what is mounted" and "what is on this block
  device" beside busybox's and beside novi-mount's. **Re-opening this
  needs a new NUMBER, not a new opinion** -- RFC 0027's rule for the
  mbedTLS collapse.
- **THE MEASUREMENT'S MOST USEFUL OUTPUT WAS NOT ABOUT util-linux.**
  Sixteen busybox applets here name kernel features this kernel does
  not have, twelve installed as commands that could never work: `ipcs`
  answered *"kernel not configured for message queues"* and `ipcrm`
  *"unknown errror in id (1)"* for the life of the project, beside
  `hwclock`, `rtcwake`, `nbd-client`, five `ubi*` and `vconfig`.
  Same complaint as `idle3`, `bashbug` and busybox's own `man`.
- **THE DECISION IS DERIVED, WHICH IS THE ONLY REASON IT IS SAFE.**
  `kernel/dead-applets` is a table of `<applet> <CONFIG_SYMBOL>
  <reason>`; `scripts/prune-dead-applets.sh` reads the **generated**
  config and CONVERGES each row against it. A list of removals would
  need editing by whoever next changes the kernel, with nothing to
  tell them.
- **IT RESTORES AS WELL AS REMOVES, and that is not symmetry for its
  own sake.** Without it "turning a symbol on brings the command back"
  is true only of a FULL build -- `03-base.sh` creates the symlinks and
  `--from 05` never reaches it -- so enabling `CONFIG_RTC_CLASS` and
  rebuilding the kernel gives a working RTC and no `hwclock`. Watched
  live: that is exactly what the RTC change did here. **Where the link
  goes is ASKED, not written down**: `busybox --list-full` prints each
  applet at the path busybox's own installer would use
  (`sbin/hwclock`, `usr/sbin/rtcwake`, `usr/bin/ipcs`), so the two
  cannot disagree.
- **IT RUNS IN `05-kernel.sh`, NOT `03-base.sh`, AND THEN AGAIN IN
  16.** 03 installs the symlinks but the answer comes from the
  generated config, which does not exist until 05 on a clean build --
  and re-running 03 afterwards puts every one of them back, which is
  the `/sbin/init` hazard exactly, so `16-s6-rc-db.sh` runs the same
  script as part of the repair it already does. One implementation,
  two callers.
- **NO GENERATED CONFIG IS NOT A LICENCE TO DELETE.** The script exits
  0 having done nothing when there is no `.config` yet: removing
  commands on no evidence is the curated-config trap one step earlier.
- **A NAME BUSYBOX DOES NOT BUILD IS DEAD WEIGHT IN A TABLE ABOUT DEAD
  WEIGHT**, and the test's first run found four -- `flashcp`,
  `flash_eraseall`, `flash_lock`, `flash_unlock` are MTD tools this
  busybox config does not compile, so those rows would have sat there
  forever doing nothing. The check is derived from the shipped binary.
- **`CONFIG_RTC_CLASS` WAS NOT SET, WHICH IS WHY `hwclock` WAS ON THE
  LIST -- AND IT IS SET NOW** (RFC 0040 roadmap 6). The early x86 CMOS
  read (`CONFIG_RTC_MC146818_LIB`) gives a plausible wall clock at boot
  so nothing looked wrong, and that is exactly what hid it: there was
  no `/dev/rtc0`, so a corrected time could not be written back to
  hardware and there was no RTC alarm to wake a suspended machine (RFC
  0035). Three symbols -- `RTC_CLASS`, `RTC_INTF_DEV` (what creates
  the device node) and `RTC_DRV_CMOS` -- because each is a separate
  thing that can be absent.
- **THE PROOF IS A WRITE THAT SURVIVES A REBOOT, not that `hwclock`
  printed a time.** With no `/dev/rtc0` it prints an error; on a
  read-only path it prints what a correct machine prints. Only a
  correction still there after a reboot tells the two apart. Watched:
  `date -u -s "2031-03-07 …"`, `hwclock -u -w`, `/proc/driver/rtc`
  reading `rtc_date: 2031-03-07`, and after a reboot `date -u` reading
  **Fri Mar 7 04:06:17 UTC 2031**.
- **busybox's `rtcwake` HAS NO `-m no` AND NO `-m disable`, and only a
  machine with an RTC could have shown it.** `-m no` arms the alarm
  and then writes the mode to `/sys/power/state` unconditionally, so
  the alarm IS set and the command exits 1 with `write error: Invalid
  argument`; `-m disable` prints the usage text. The remedy is checked
  rather than assumed -- `echo 0 > /sys/class/rtc/rtc0/wakealarm`
  disarms and writing an epoch second there arms. **A util-linux delta
  the host probe could not have found**, and not for the reason its
  exclusions name: it needs hardware neither the guest nor this build
  host had.
- **THE CURATED KERNEL CONFIG IS A SUBSET, AND ANSWERING FROM IT GAVE
  THREE WRONG LABELS.** `kernel/config-x86_64` is ~280 options, so a
  symbol it does not mention is NOT thereby off -- `CONFIG_SWAP` and
  `CONFIG_HOTPLUG_CPU` are both unmentioned and both `y`, and swap
  really works on a booted machine. Read
  `/build/sources/linux-*/.config`, or ask the running kernel.
- **THE FIRST pid NORMALISER ATE AN EXIT STATUS.** `chrt -p $$` prints
  `pid 2179's …`, noise the two runs cannot share, so the harness
  normalises it -- and the first version was `s/\b[0-9]{2,7}'?s?\b/`,
  any two-to-seven-digit number, which turned `mountpoint`'s `rc=32`
  into `rc=<pid>`: the one field the comparison turns on. It still
  reported a difference only because busybox's `rc=1` is one digit; a
  busybox exiting 33 would have compared EQUAL. **A normaliser wide
  enough to hide the noise is wide enough to hide the finding** --
  match the SHAPE the noise comes in, not "a number".
- **AND THE DEAD-APPLET TEST'S OWN FIXTURE COULD NOT FAIL.** It seeded
  symlinks pointing at a busybox that was never created, and the check
  was `[ -e ]` -- which FOLLOWS a symlink and is false for a broken
  one, so every applet read as "gone" whether or not the script had
  run. Seventh time in this file that the probe, rather than the thing
  probed, was the broken part. Both halves fixed: a real target, and
  `[ -L ] || [ -e ]`.

## Architecture: a `man` that could never have worked

RFC 0040 roadmap 2. `build/47-mandoc.sh`, `pkg install man`.

- **THE BASE HAS SHIPPED A `man` SINCE THE FIRST IMAGE AND IT COULD
  NOT DISPLAY A PAGE.** busybox's applet is a shell pipeline --
  `tbl | nroff -mandoc -rLL=78n -rLT=78n 2>&1 | col -b -p -x` --
  and busybox provides NONE of those three as applets (only `less`).
  A command that cannot work is worse than one that is absent (RFC
  0026's `idle3`), and this one had the additional cost of looking
  like the feature was there.
- **IT EXITS 0, AND PRINTS ITS OWN ERROR WHERE THE PAGE SHOULD BE.**
  That is the finding, and it is worse than "it fails": the nroff
  stage carries `2>&1` **into the pipe**, so a missing formatter's
  diagnostics go to stdout as page text, and the applet returns
  success having rendered none of the document. A caller testing the
  exit status is told it worked.
- **`tests/busybox-man/probe.sh` PROVES IT WITHOUT A VM**, on the
  shipped static binary in a chroot, which is RFC 0018's rule about
  BusyBox `fdisk` applied again. Two things it has to do that a naive
  run does not: **put a real page there first** (with no pages
  installed the applet answers "no manual entry" and never reaches
  its formatter, so a probe against the bare base proves nothing),
  and **capture stdout as well as stderr** -- a first reading that
  looked only at stderr saw `tbl` and `col` and concluded nroff was
  never invoked at all, because `2>&1` had put its line in the pipe.
  Shims standing in for the three helpers are what show the real
  argv; reading the strings in the binary gave the wrong chain.
- **THE BASE SHIPS 79 MAN PAGES IT HAS NEVER BEEN ABLE TO DISPLAY.**
  alsa-utils installs `/usr/share/man/man1/{aconnect,alsactl,amixer,…}`
  as BASE content, so this was never hypothetical -- there have been
  pages on every image since RFC 0011 and no way to read one. Measured
  on a booted machine before installing anything: `man alsactl` gives
  `sh: tbl: not found`, `sh: col: not found`, **exit 0**, and no page;
  after `pkg install man` the identical command renders it.
- **EVERY `man` INVOCATION WARNS UNTIL SOMEBODY RUNS `makewhatis`**,
  and that is the one thing still wrong. `outdated mandoc.db lacks
  <page> entry, run makewhatis <dir>` prints above the page --
  confirmed both ways, gone after `makewhatis`, back when the db is
  deleted. The page renders regardless and the message names its own
  remedy, which beats a silent failure, but a warning on every
  invocation is how a warning stops being read (`/init`'s
  twenty-two module lines). **It is deliberately not patched around**:
  a generated index cannot be package-owned, because
  `/usr/gnu/share/man` is shared by `coreutils` and `bash` and the
  second package to ship a `mandoc.db` there would be REFUSED by RFC
  0040 roadmap 1's own conflict check -- correctly. The fix is a
  post-install hook in `pkg`, which is roadmap 5.
- **mandoc, not groff.** One self-contained C program (532 KB
  stripped, ISC), which is what Alpine and OpenBSD ship. groff is C++,
  needs its own preprocessor chain, and would put a second formatter's
  worth of build on a system whose `man` pages are almost entirely
  mdoc and man macros anyway.
- **IT IS ONE BINARY UNDER FIVE NAMES, AND THE STAGING TURNED THAT
  INTO FIVE BINARIES.** mandoc dispatches on `argv[0]`, so `make
  install` leaves `mandoc`, `man`, `apropos`, `whatis` and
  `makewhatis` as one inode with a link count of 5 -- and **`cp -a`
  preserves a hardlink only among the sources of a SINGLE
  invocation**, so a `for` loop copying them one at a time silently
  produced five full copies. Measured both ways: **2944k for the loop
  against 608k for the one call**, i.e. 2.1 MB of duplicate binary on
  every machine that installs `man`. Dead weight is not inert (RFC
  0007) and nothing about the package looked wrong.
- **The links survive the whole real chain, which is why preserving
  them is worth anything.** Checked rather than assumed, with the
  shipped busybox: GNU tar create (`mkpkg`), busybox `tar -xzf`
  (`pkg`'s extract), and busybox `tar -cf - | tar -xf -` (`pkg`'s pipe
  into the root) all keep them -- 512k in, 512k out. `strip` keeps
  them too, because binutils copies in place rather than renaming when
  `st_nlink > 1`; that is what lets one `cp -a` come before the strip
  instead of needing the links rebuilt after it.
- **The assertion is DERIVED from the prefix**: any two names sharing
  an inode in `make install`'s output must still share one in the
  stage. A hand-written list of which names are links would be a
  second answer to a question mandoc's own install already gives.
  Confirmed by putting the loop back and watching it fire.
- **A SECTION-1 PAGE SHIPS ONLY IF ITS PROGRAM DOES**, which is
  `46-gnu.sh`'s rule for the coreutils pages applied here. mandoc's
  install writes `demandoc.1` and this package does not install
  `demandoc`, so `man demandoc` would have rendered the documentation
  for a command that is not on the machine -- the `idle3` complaint
  from the other side, and the more misleading direction of it.
  Sections 5 and 7 are copied unconditionally because they are FORMAT
  documentation (`mdoc`, `roff`, `tbl`, `man.conf`) and name no
  program: asking them the same question would delete the pages this
  package exists to let you read.
- **A SWEEP SAID THIS WAS THE ONLY ONE.** Every staged package checked
  for byte-identical files that are not hardlinked: `git` (153
  hardlinks), `binutils` (20) and `gcc` (13) all keep theirs, and
  Python's only duplicates are CPython's own `.opt-1`/`.opt-2`
  pycache variants, which are upstream's layout rather than a
  staging bug. Worth doing -- it is the difference between "fixed an
  instance" and "fixed the instance".
- **EVERY `configure` ANSWER IS SUPPLIED BY HAND, because `runtest`
  EXECUTES its probe.** mandoc's configure is a shell script that
  compiles a small program and then RUNS it -- which a cross build
  cannot do, so every answer would have come back "no" and mandoc
  would have built against a libc it invented (its own `strlcat`, its
  own `getsubopt`, no `wchar` support). `configure.local` is
  upstream's documented override and `runtest` skips any variable
  already set, so the file is the whole interface. Every value in it
  was read out of THIS musl with `nm` and `ls` rather than guessed.
- **`NEED_GNU_SOURCE` IS ONLY SET WHEN A TEST ACTUALLY RUNS**, so
  pre-seeding the answers means it never gets set -- `-D_GNU_SOURCE`
  goes in `CFLAGS` explicitly. A variable that a skipped test would
  have set is invisible in exactly the configuration that skips it.
- **IT IS THE FIRST REAL USER OF `replaces-files=`** (roadmap 1).
  mandoc installs `/usr/bin/man`, which is busybox's symlink, so the
  package declares the takeover, `pkg` saves the original, and `pkg
  remove man` puts the applet back. A mechanism built for binutils'
  `strings` that the very next package needed is a reasonable sign it
  was the right shape.
- **`MANPATH_DEFAULT` HAS TO NAME `/usr/gnu/share/man`.** The pages
  are in the coreutils and bash packages, which install under the
  prefix, so a mandoc built with the stock default would find nothing
  and report it as "no entry" -- the absence of a path reading as the
  absence of a page.
- **The pages are copied by asking whether the PROGRAM shipped.**
  `46-gnu.sh`'s man loop is keyed on `[ -f "${d}/files/…/bin/${base%.*}" ]`,
  so the derived sweep decides the pages too: a page for a program the
  build did not produce (`chcon`, `runcon`) does not ship, and nobody
  maintains a second list. Same argument as the binary sweep itself.

## Architecture: a process that cannot reach the machine

RFC 0039 (`docs/rfcs/0039-process-isolation.md`). `novi-sandbox` runs a
program with a root filesystem containing only the paths named on its
command line, its own process table, and a seccomp filter. `pkg install
netsurf` puts the browser behind it.

- **RFC 0031 SAID THIS THREE TIMES AND NEVER SCHEDULED IT**, and what
  it was waiting for was nothing. The kernel has carried `USER_NS`,
  `PID_NS`, `UTS_NS`, `NET_NS`, `SECCOMP` and `SECCOMP_FILTER` since
  its config was written; the seccomp and BPF headers are in the
  sysroot; busybox already ships `unshare`, `nsenter` and `setpriv`.
  **No new dependency at all** -- the same finding RFC 0031 made about
  the browser itself, one layer down, and the third time a blocking
  claim in this repository turned out to be a true statement about
  something else.
- **DEFAULT DENY, NAMED ON THE COMMAND LINE.** The new root is an
  empty tmpfs; a path nobody named is not there. The alternative --
  mount the real root and over-mount the sensitive parts -- is a
  denylist of DIRECTORIES, so every future package that puts something
  private somewhere new is a hole nobody opens a file to notice.
- **`CLONE_NEWUSER` IN THE SAME CALL AS THE REST.** An unprivileged
  process may create the other namespaces only as a side effect of
  creating a user namespace it owns; two separate `unshare()` calls
  fail with EPERM on the second. That is what keeps this out of the
  setuid business entirely.
- **THE NAMESPACE SET IS ASKED FOR, NOT ASSUMED, AND ONLY A BOOTED
  MACHINE SAID SO.** The first run on Novi's own kernel answered
  `EINVAL` -- not EPERM, which is the clue: a flag the kernel does not
  know. `/proc/self/ns/` had no `ipc`, because `CONFIG_IPC_NS` depends
  on `CONFIG_SYSVIPC` and this kernel deliberately omits it (RFC 0004
  found the same absence from the other end, in syslogd's `-C`).
  **`kernel/config-x86_64` had stated `CONFIG_IPC_NS=y` for a kernel
  that never had it** -- olddefconfig drops a symbol whose dependency
  is unmet, silently. A symbol this config states and the build
  discards is the same defect as one the build has to repair.
- **`MS_NODEV` MADE THE SANDBOX'S OWN `/dev` UNOPENABLE, and the
  evidence was three layers away.** Every bind got
  `MS_NOSUID|MS_NODEV`, including the six device nodes the program
  mounts itself -- and `MS_NODEV` means a node on that mount cannot be
  OPENED. `/dev/urandom` was present, correct and unreadable; what it
  looked like from outside was `NetSurf failed to initialise`, and one
  layer in, `curl_global_init failed`, because mbedTLS could not seed
  its DRBG. A hardening flag applied uniformly, disabling the one case
  that needed the exception. The flag is per-bind now.
- **A BIND MOUNT IS TWO OPERATIONS.** `MS_BIND|MS_RDONLY` in one call
  does NOT produce a read-only mount: the kernel takes the flags from
  the source and ignores the rest, so what you get reads as confined
  and is writable. The remount is what makes it true, and it must
  repeat `MS_BIND`. This is the classic mistake in every hand-written
  container and it is silent.
- **`pivot_root`, NOT `chroot`.** chroot leaves the old root reachable
  through any directory descriptor that survives it and through `..`
  from a directory outside the new tree.
- **THE MOUNTS HAPPEN AFTER A FORK because `CLONE_NEWPID` takes effect
  for CHILDREN.** The setup runs in a child that is PID 1 of the new
  namespace, which is also what makes the freshly mounted `/proc` show
  only the sandbox.
- **THE FILTER IS A DENYLIST AND THE FILE SAYS SO.** An allowlist is
  stronger and has to know every syscall the program and its libc will
  ever make; being wrong turns a working browser into a crash on a
  page nobody tested. Calling this "seccomp" and letting a reader
  supply the stronger meaning is the overclaim RFC 0025 warns about
  with the word "Mesa". `SECCOMP_RET_ERRNO(EPERM)` rather than
  `KILL_PROCESS`, because a killed process tells the person nothing.
- **THE ARCHITECTURE CHECK IN FRONT OF THE SYSCALL NUMBERS IS NOT
  DECORATION.** A syscall number is meaningless without knowing whose
  table it indexes, and a process entering through the 32-bit compat
  layer would be filtered against a table that is not its own.
- **NOT A NETWORK NAMESPACE by default**, and it says which of the two
  you got. A browser's job is the network; `--no-net` exists for
  programs with no such excuse.
- **BASE CONTENT, not part of the browser package**, on RFC 0031
  roadmap 5's argument for `s6-softlimit`: a confinement tool that
  arrives only with the browser is one nothing else can be put behind.
- **THE PROOF THAT THE DENIAL IS THE FILTER is `CapEff` beside
  `Seccomp`.** Inside, `/proc/self/status` reports
  `CapEff: 000001ffffffffff` -- every capability -- and `Seccomp: 2`,
  while `mount` returns permission denied and `mkdir` succeeds. A
  process holding CAP_SYS_ADMIN in its namespace refused `mount(2)` is
  refused by the filter and by nothing else.
- **A SANDBOXED PROCESS CANNOT BE SIGTERMed FROM OUTSIDE, AND `kill`
  RETURNS 0.** It is pid 1 of its own PID namespace, and the kernel
  gives such a process the protection it gives the machine's own init:
  a signal still at `SIG_DFL` coming from beyond the namespace is
  DISCARDED. Measured -- `kill` succeeded, the process was still there
  two seconds later, `kill -9` ended it. Three things follow, and none
  of them were obvious: the supervisor FORWARDS signals and makes the
  SECOND one SIGKILL (a first forward may be thrown away and from
  outside that is indistinguishable from a clean shutdown);
  `PR_SET_PDEATHSIG` is SIGKILL for the same reason; and RFC 0038's
  force-quit SKIPS its polite stage for such a window
  (`novi_procstat_is_ns_init()` reads `NSpid:`), because a stage that
  cannot fire and logs that it did is worse than no stage.
- **WITHOUT THAT FORWARDING IT LEAKED A RUNAWAY PER INVOCATION.**
  novi-sandbox forks and waits, so `kill <novi-sandbox>` ended the
  supervisor and left the child running with nobody waiting on it --
  watched live with a `sleep 300`, and the first real caller is a
  corpus of hostile pages run sixteen times in a row. A shell's Ctrl+C
  hid it: that signals the whole foreground process group, so both got
  it, and only a `kill` aimed at a pid exposed it.
- **`getppid()` IS 0 IN A NEW PID NAMESPACE**, so the standard
  `PR_SET_PDEATHSIG` race check -- compare `getppid()` against the pid
  captured before the fork -- can never pass and exits the child every
  time. The first build did exactly that, presenting as a supervisor
  exiting 125 with nothing on stderr. A pipe (child closes its write
  end, then tests for EOF) says the same thing without needing a shared
  namespace.
- **THE CORPUS UNDER IT IS THE SAME TABLE** (RFC 0039 roadmap 1,
  `tests/hostile-pages/README.md`): eleven survived, five spinning,
  zero died, CPU within a few points, and peak memory identical to the
  byte on every page that had stopped growing when it was sampled.
  **The sandbox does not change whether a page fails or what failing
  costs** -- what a layout engine allocates is its own heap and no
  mount list touches it. It changes what a page that fails can REACH,
  which that corpus cannot measure. A negative result, and the item
  had guessed otherwise.
- **THE HARNESS WOULD HAVE REPORTED THE WHOLE CORPUS HARMLESS.** The
  wrapper's job pid is `novi-sandbox`, blocked in `waitpid`: 0% CPU and
  848 kB of address space, on a page burning 98% of a core. An
  instrument that answers about the wrong process is worse than one
  that refuses to answer -- `run.sh` resolves the browser under the job
  pid now and prints `UNMEASURED` when it cannot find it.
- **A SAMPLE TAKEN WHILE THE NUMBER IS STILL MOVING IS NOT A
  COMPARISON.** One probe 13 seconds in showed `many-siblings.html` at
  312,948 kB unsandboxed against 273,928 kB sandboxed -- a 39 MB
  saving that does not exist. At 40 seconds both are 516,384 kB.
- **A BUSYBOX APPLET RUN AS `busybox httpd` HAS `busybox` AS ITS
  COMM**, so `pgrep httpd` and `pkill -x httpd` both miss it. Both
  harness scripts matched their own HTTP server by name and neither
  could find it; the symptom was `httpd: bind: Address in use` from a
  run whose previous line had just tried to clear the port. Match the
  command line.
- **THERE IS AN ALLOWLIST NOW, FOR ONE PROGRAM** (RFC 0039 roadmap 3).
  `novi-sandbox --profile recon` is deny-by-default with 48 syscalls,
  and `pkg install novi-recon` puts the tool behind it -- script in
  `/usr/libexec`, wrapper on PATH, RFC 0031 roadmap 5's shape. The
  browser keeps the denylist: nobody can enumerate what a layout
  engine will do, and novi-recon is the opposite case.
- **THE LIST IS DERIVED, AND THE BUILD DIFFS IT AGAINST THE
  MEASUREMENT.** `45-novi-sandbox.sh` builds a ptrace tracer
  (`/build/sandbox-test/novi-syscalls`, never installed -- the hostapd
  bargain); the list is the union over every subcommand plus the host
  test suite's error branches, recorded with its provenance in
  `novi-sandbox/profile-recon.syscalls`. `main.c` writes `SYS_recvfrom`
  because that is reviewable; the stage EXTRACTS that table, compiles
  it and diffs the numbers, because a transcription slip is silent in
  both directions -- a missing entry breaks one subcommand, an extra
  one is a hole. Provoked both ways (`-47`, `+101`).
- **`SECCOMP_RET_LOG` LOGS NOTHING ON THIS KERNEL.** It goes through
  `audit_seccomp()`, which without `CONFIG_AUDIT` is a no-op stub in
  `include/linux/audit.h` -- so the obvious way to learn a program's
  syscall set allows everything and records none of it. Checked in the
  config, not assumed. ptrace needs nothing from the config.
- **TRACE THE PROGRAM, NOT A SHELL AROUND IT.** The first union was
  taken with `sh -c 'echo … | novi-recon pwned'` under the tracer and
  collected the SHELL's `fork`, `wait4` and `dup2` -- in the one list
  where "it can spawn processes" must not arrive by accident. Redirect
  from a file.
- **`clone` COMES FROM EXACTLY ONE SUBCOMMAND** (`ports`, whose connect
  scan threads), so the filter accepts it only with `CLONE_THREAD`:
  `clone(2)` without that flag is `fork`. Verified by running the SAME
  probe twice with the same binds and only the filter changed: under
  `--profile recon` `threading.Thread` works and `os.fork()` is
  refused; under the denylist `threading.Thread` works and **`os.fork()`
  SUCCEEDS**. The difference is visible rather than argued, which is
  the whole case for the profile. `clone3` is on
  no list and so is EPERM'd, which is what stops the usual bypass, and
  that is a fact about THIS image: musl's `pthread_create` uses
  `clone(2)` where glibc has moved to `clone3`.
- **A PROFILE IS A PROGRAM'S, NOT A LANGUAGE'S.** `python3 -c 'import
  threading'` under `--profile recon` fails, and the one syscall it
  wants is **`getcwd`** -- `-c` puts the working directory on
  `sys.path` and novi-recon, exec'd by absolute path, never asks. It
  stays out: adding a syscall nobody measured is how a derived list
  stops being derived.
- **A DERIVED LIST IS STABLE HERE AND WOULD NOT BE ON A NORMAL
  DISTRIBUTION**, and that is worth saying because it is the argument
  for doing this at all: the libc, the interpreter and the kernel all
  come out of this build. musl reaches for `open` where glibc uses
  `openat`, and `stat` where glibc uses `newfstatat` -- neither number
  is in the list, and on a glibc system both would have to be.
- **RUN BOTH MODES OR YOU CANNOT READ THE RESULT.** Four novi-recon
  subcommands fail under the sandbox; they fail BYTE FOR BYTE
  IDENTICALLY with `NOVI_RECON_SANDBOX=off`, because this network
  blocks port 43 and intercepts TLS with a CA the guest does not
  trust. Without the second column that reads as a sandbox which broke
  four subcommands.
- **A BIND LIST IS A CLAIM ABOUT WHAT A PROGRAM NEEDS.** Both wrappers
  bound `/etc/nsswitch.conf`, which has never existed here --
  `18-network.sh`'s own comment says musl does not read it. The
  sandbox skips an absent path by design, so the only symptom was one
  `skipping ... (not present)` line per run: invisible for a GUI
  program, and the first line of output for a command-line one.
- **`--no-net` HAS A CALLER NOW: THE IMAGE VIEWER** (RFC 0039 roadmap
  4). novi-view decodes a stranger's PNG through libpng and zlib and
  has no business on a socket, so `pkg install novi-desktop` puts it
  behind `novi-sandbox --no-net`. Its BIND LIST IS BUILT AT RUNTIME,
  which no other wrapper here needs: the one file it reads is chosen
  when it starts. The path is resolved with `readlink -f` for two
  reasons -- the cwd inside is `/`, so a relative path resolves against
  the wrong directory, and a SYMLINK would be bound at its target and
  opened at its link name.
- **A MINIMAL `/dev` NEEDS `/dev/shm`.** musl's `shm_open(3)` opens a
  file under it, so a Wayland client asking for a buffer the usual way
  gets ENOENT from a directory that is not there -- surfacing as
  `failed to allocate shm buffer`, three layers from the cause. Its own
  tmpfs, never a bind of the machine's: shared memory is a channel, and
  binding the real one hands the sandbox a way to pass bytes to
  anything that can name a segment. **Two sandboxed programs walked
  past this gap** (NetSurf and novi-glinfo use memfd), which is why
  nobody reasoned their way to it.
- **A BIND DOES NOT FOLLOW A SYMLINK OUT OF WHAT IT BOUND.**
  `/usr/share/X11/xkb` is an ABSOLUTE link to
  `/usr/share/xkeyboard-config-2`, so binding `/usr/share/X11` leaves a
  dangling link -- an absolute link resolves against the SANDBOX's
  root. Bisected rather than guessed: either end alone segfaulted, both
  together worked. Bind both, and RESOLVE the target rather than
  writing it down (the `2` is a version).
- **A SANDBOX IS A MACHINE WITH THINGS MISSING, WHICH IS WHY PUTTING A
  PROGRAM IN ONE FINDS WHERE IT ASSUMED THEY WERE THERE.** On a first
  pass that is worth more than the confinement: this one found a
  SIGSEGV in six shipped clients (below), a missing `/dev/shm`, and a
  symlink nobody had thought about.
- **`novi-agent describe` HAS A `sandbox` SECTION, AND `novi-state`
  DOES NOT** (RFC 0039 roadmap 5, which asked for novi-state). Nothing
  converges a sandbox: a wrapper is what a package installed, not a key
  somebody set, so `diff` could never report it and `apply` could never
  fix it -- a row there would be permanently "converged" about
  something the engine does not control, the same reason `keys.conf` is
  not a `system.conf` key. `describe` is the document that says what
  this machine IS. **Ninth roadmap item corrected on contact rather
  than implemented as written.**
- **IT READS, IT DOES NOT RUN.** RFC 0029 decision 1 is that describing
  is free because it is a view of files any user can already read, and
  executing a program to ask about it would quietly end that. The exact
  answer -- the argv a wrapper builds with every runtime branch taken
  -- is `NOVI_SANDBOX_DESCRIBE=1 <program>`, which every wrapper
  honours through the one `run()` its exits go through, so it cannot
  drift from what actually execs.
- **NO LIST OF SANDBOXED PROGRAMS.** A fourth one appears because it is
  sandboxed, not because somebody remembered: the test is a `/bin/sh`
  script on PATH that invokes novi-sandbox. Watched live -- a fresh
  boot listed `novi-view` alone and `pkg install novi-recon` made the
  second row appear.
- **MATCH THE INVOCATION, NOT THE MENTION.** Every wrapper carries
  `command -v novi-sandbox … || run …` as its own installed-check, and
  that line comes FIRST -- so a reader taking the first match reported
  novi-recon as having no profile and novi-view as having the network.
  Two plausible machines, neither real, and only the host test caught
  it.
- **LANDLOCK IS THE SECOND LAYER, AND WHAT IT ADDS IS W^X** (RFC 0039
  roadmap 2). A bind mount cannot say "writable but not executable";
  Landlock grants EXECUTE on the `--ro` paths and never on the `--rw`
  ones. Measured, same file, same sandbox, one flag apart: `--rw` reads
  and writes and **cannot exec (EACCES)**; `--ro` reads and execs and
  **cannot write (EROFS)**. **Two layers, two errnos** -- neither can
  state the other's rule, which is the whole argument for both.
  `MS_NOEXEC` should follow on the mounts this program makes itself;
  doing both at once would have left a refusal nobody could attribute.
- **ASK FOR THE ABI, DO NOT ASSUME IT.**
  `landlock_create_ruleset(NULL, 0, LANDLOCK_CREATE_RULESET_VERSION)`
  answers with the version; `REFER` arrives at 2, `TRUNCATE` at 3,
  `IOCTL_DEV` at 5, and a ruleset naming a right the kernel does not
  know is EINVAL. Same rule as reading `/proc/self/ns`.
- **A DIRECTORY-ONLY RIGHT ON A FILE IS EINVAL, NOT IGNORED.**
  `READ_DIR`, the `MAKE_*` set, `REMOVE_*` and `REFER` are refused
  outright on a regular file -- and this sandbox binds plenty of single
  files (`/usr/bin/python3`, `/etc/resolv.conf`, the image a viewer was
  given), so granting the read-only set uniformly killed every
  sandboxed program with `landlock_add_rule: Invalid argument`, which
  names the call and not the reason. Mask by `S_ISDIR`.
- **LANDLOCK BEFORE SECCOMP, AND NO_NEW_PRIVS BEFORE BOTH.** After the
  filter the landlock syscalls are subject to it, and an allowlist
  profile derived from a program that never calls them -- every profile
  here -- answers EPERM to the sandbox's own last step.
- **THE CALLER'S BINDS GO ON LAST, because they were being buried.**
  They used to be applied before the private `/tmp`, the minimal `/dev`
  and `/proc`, so `--rw /tmp/work` was bound and then covered by the
  tmpfs on top: the mount existed, nothing could reach it, and the
  program said `nonexistent directory` about a path the caller named.
  **Third buried mount in this repository** (RFC 0003's `/run/live`,
  RFC 0018's ESP), and the first where the buried thing was something
  somebody asked for.
- **A `CONFIG_X=y` LINE IS A CLAIM, AND THIRTY-TWO OF THEM WERE
  FALSE.** olddefconfig drops a symbol whose dependencies are unmet, or
  that upstream renamed or removed, SILENTLY. `CONFIG_IPC_NS` did that
  and cost this program its first booted run; a sweep found 32 more --
  sixteen renamed or removed upstream, sixteen unreachable, four of
  those *select-only* and therefore meaningless in a config file. **One
  is `CONFIG_SECURITY_SELINUX`**, which needs `CONFIG_AUDIT`: SELinux
  has never been in this kernel while the config claimed it for the
  life of the project. `05-kernel.sh` diffs the curated file against
  the generated `.config` and FAILS on any `=y` that did not survive --
  derived, because a hand-written watch list would not have contained
  IPC_NS either. **The sweep changed nothing**: the generated `.config`
  is byte-identical apart from Landlock, which is what made it safe to
  do in the same pass.
- **MS_NOEXEC IS THE MOUNT HALF OF W^X, and it landed SECOND on
  purpose.** Landlock went in alone so a refusal could be attributed
  to it; this followed once that attribution was on record. Every
  mount novi-sandbox makes itself -- the root tmpfs, `/tmp`, `/dev`,
  the device binds and `/dev/shm` -- carries it, and so does every
  `--rw` bind. The `--ro` binds do NOT: that is where the program
  being sandboxed lives.
- **WITH BOTH LAYERS ON, THE ERRNO CANNOT SAY WHICH ONE ANSWERED.** A
  refused exec on a `--rw` path is EACCES from Landlock or from the
  mount, so the evidence for the mount half is `noexec` in the
  sandbox's OWN `/proc/self/mountinfo`, read from inside. Measured
  there: `/`, `/tmp`, `/dev`, `/dev/shm`, `/proc` and the `--rw` bind
  all `noexec`; `/bin`, `/lib`, `/usr` and the `--ro` bind not.
- **The check that matters is the three real callers, because
  `/dev/shm` is now noexec and both GUI clients allocate buffers
  through it.** novi-recon prints its usage under `--profile recon`,
  NetSurf renders the control page in 0.1 s, novi-view decodes and
  draws a PNG. A hardening flag applied uniformly is how `MS_NODEV`
  made `/dev/urandom` unreadable and cost a debugging round three
  layers from the cause.
- **RFC 0039's "There is no Landlock" paragraph was true when written
  and went stale in its own RFC.** It is struck through rather than
  deleted: "checked, not assumed" was the right habit and the answer
  changed. A reader finding the old sentence and believing it is the
  failure, not the sentence having been written.
- **`test-agent-sandbox.sh` DRIVES THE WRAPPERS THIS REPO SHIPS**,
  extracted from the build stages' `<<'WRAP'` heredocs, against the
  real reader -- a test about two things agreeing must not hold its own
  copy of either. **Its own negative check could not fail at first**:
  a script with no mention of novi-sandbox is rejected twice over, so
  breaking either filter left the answer right. The fixture that makes
  it real is one that MENTIONS the sandbox in a comment and never
  invokes it.

## Architecture: two ways to say "not now"

RFC 0036 (`docs/rfcs/0036-idle-inhibitors.md`).
`zwp_idle_inhibit_manager_v1` for programs, **Super+A** for people,
both feeding one decision in novi-shell's idle tick.

- **Shipping only the protocol would have changed nothing for
  anybody.** Nothing in this image speaks idle-inhibit — not foot, not
  NetSurf, not novi-view — so the compositor would have gained a
  global with no caller, which is the "speculative wiring for a
  hypothetical future client" novi-shell's own comments make a point
  of avoiding. The case people actually have is *"do not sleep, I am
  building"*, said at a terminal by somebody whose workload is a shell
  script with no window. **A protocol is not a feature until
  something calls it**, and RFC 0035's roadmap item got this wrong by
  framing the whole thing as a video player.
- **VISIBLE IS NOT MAPPED on a compositor with workspaces.** The
  protocol's own words are "only while this surface is visible"; a
  player left running on workspace 3 is mapped, is not on screen, and
  has no business keeping the panel lit. The test is
  `workspace == active_workspace && !minimized` — the same expression
  `switch_workspace()` drives the scene graph from, so the answer
  agrees with the screen instead of being a second opinion about it —
  asked of the **root** surface, because the protocol takes any
  `wl_surface` and a client may name a subsurface of its toplevel.
  A layer surface is asked whether it is mapped instead: it joins its
  list at CREATION rather than at map, so membership is not the mapped
  test there.
- **The count is recomputed every tick, on purpose.** A workspace
  switch or a minimize changes the answer with the inhibitor's client
  sending nothing at all, so a cached flag would need updating from
  `switch_workspace()`, `move_focused_to_workspace()`, minimize,
  unminimize, map and unmap — six places, one of which would
  eventually be missed, and the symptom is a machine that never
  sleeps. Twenty pointer comparisons every five seconds is cheaper
  than that risk.
- **A locked session honours no client inhibitor; Super+A survives
  it.** The visibility test answers "no" behind the lock surface
  anyway, but it is its own branch because the consequence is a
  security property rather than an accident of the arithmetic —
  otherwise any client still running holds a locked machine awake with
  nobody there. The person's toggle deliberately does not follow that
  rule: they pressed a key on this keyboard on purpose, and locking
  the screen to get coffee is the same person's other decision.
  Suspending mid-build because they stepped away is exactly what they
  pressed the key to avoid.
- **The clock is held at ZERO, not stepped over.** Letting `idle_ms`
  climb past a threshold that is being ignored means the screen goes
  dark the instant a player releases its inhibitor — at the moment
  somebody is looking at it, from a machine that spent two hours being
  told nobody was idle. An already-blanked screen is deliberately NOT
  woken by an inhibitor arriving: turning a display on is something a
  person does.
- **`/run/novi/idle` is key-value lines now**, not three positional
  numbers — a name per inhibitor is variable-length and positional
  fields cannot carry it. One writer, one reader, both in this
  repository: that is the moment to change a published format, and it
  will never be cheaper.
- **`awake` and `inhibit` are published as SEPARATE claims.** "A
  person pressed a key" and "a program asked" have different remedies,
  and a machine that will not sleep is a complaint whose only
  interesting part is which of them is happening. One combined count
  would hide it.
- **There is no key to switch inhibitors off, and `novi-power idle`
  is why.** The failure worth guarding against is a client that
  inhibits and should not; the remedy is knowing *which* client, not a
  flag nobody would find. An `app_id` is a stranger's string going
  into a file a shell reads, so it is capped and filtered — and
  offending characters become underscores rather than being dropped,
  because a name that silently loses characters stops matching the
  window it came from.
- **The panel draws ONE glyph for both askers, and that is not
  decision 1 being contradicted.** The file separates them because
  "somebody pressed Super+A" and "a program asked" have different
  remedies; the panel is where the question is RAISED, not where it is
  answered -- the health glyph has said "degraded" and left
  `novi-state health` to say which service since RFC 0014. A coffee
  cup, because it is what every other desktop that has this draws.
  Display-only: Super+A is the toggle and it is on the shortcut sheet,
  so a click that turned it off would be a second way to say one thing.
- **A glyph a PERSON toggles belongs at the outer end of the status
  march.** Every glyph there shifts the ones left of it when it
  appears; this is the only one that comes and goes on a keystroke, so
  on the outside it moves nothing else on the bar.
- **Adding a third status glyph found two bugs in the second.** The
  taskbar's right-hand limit was `net_x - gap` under a comment saying
  "the row stops where the status area starts" -- never true, since the
  volume and health glyphs are drawn AFTER the taskbar, so a long row
  ran under them and (as the same comment says of the network button)
  an entry drawn under an indicator still hit-tests as an entry. And
  the volume file was read inside `layout_taskbar()`, which `render()`
  calls after drawing those glyphs, so the speaker always showed the
  previous second's level. Harmless at 1 Hz, invisible in a
  screenshot -- and not harmless the moment a read decides a LAYOUT.
  `read_published_state()` does all three reads at the top of
  `render()` now, and `status_area_w()` derives the width from the same
  three flags the march consumes, so the drawing and the hit-test
  cannot disagree about a glyph.
- **`novi-agent describe` reports ABSENT, not zeros.** A machine with
  no compositor has no idle clock, and `{"seconds": 0, "awake":
  false}` says somebody just touched it -- a reading of an instrument
  that is not there. `{"present": false}` and stop.
- **A timeout that is off is `null`, never the `0` the file spells it
  with.** `"suspend_after": 0` reads as "suspends immediately", which
  is the exact opposite of the truth. (`novi-power idle` prints the
  document's own word, `off`, for the same reason.) And it is a
  `seconds_or_null()` rather than a test against `0`: **`json_num()`
  answers 0 for anything it cannot parse**, so `blank later` came out
  as `"blank_after": 0` -- a typo in the file becoming the strongest
  possible claim about the machine.
- **The `inhibit` count is not emitted beside the names**: it is the
  length of the array, and two spellings of one number is how they end
  up disagreeing. novi-shell publishes both because a person reading
  `novi-power idle` wants a count before a list.
- **A host-test probe can sit where the code cannot fail.** The "the
  polygon is closed" check on the cup probed its BASE -- which the loop
  over point pairs draws either way -- and passed with the closing
  segment deleted. The segment that closes 3 back to 0 is the LEFT
  WALL. Provoking each assertion is what found it, on a glyph that was
  correct: the check was the broken thing.
- **THE SESSION PANEL IS WHERE BOTH GLYPHS LEAD NOW** (RFC 0036
  roadmap 4). `novi-settings --panel session`, read-only on purpose:
  every row is either a `system.conf` key the System panel already
  edits or a thing a keystroke owns, and a second write path to a key
  the GUI already reaches is what RFC 0029 decision 10 refused for
  `firewall.allow`. It shows, and each row names where its thing is
  changed. **Clicking a glyph to OPEN what explains it is not the
  toggle decision 8 refused** -- that was a click that would have been
  a second spelling of Super+A.
- **THREE THINGS NOW HAVE TO AGREE ABOUT WHERE A STATUS GLYPH IS**:
  the drawing, the taskbar's right-hand limit, and the hit-test.
  `status_layout()` computes the leftward march ONCE and all three
  read it -- the file's own warning is that a hit-test disagreeing
  with the drawing by one glyph is a taskbar entry that responds to a
  click on a coffee cup, and that was written before anything here was
  clickable.
- **The idle row is a clock, so the panel polls -- and only while it
  is showing.** A 1000 ms `poll(2)` timeout rather than a timerfd: a
  fourth descriptor for a condition `poll` already expresses in its
  own argument, against a settings window that wakes every second to
  redraw a panel nobody is looking at. `pr == 0` is the news.
- **`--panel <name>` REFUSES an unknown name** instead of falling back
  to the default one. A typo'd panel that opens Account looks exactly
  like a working flag, and the glyph that opens the Account panel has
  not answered what was clicked on.
- **AN EMPTY DESKTOP IS WHAT MAKES THE NEXT SCREENSHOT MEAN
  SOMETHING.** Proving a click opens a window needs a frame with no
  window in it first -- Super+Q, screendump, then the click. Without
  it the "after" shot is equally consistent with the window that was
  already there, which is this repository's own rule about an
  observable that cannot answer the question.
- **The shortcut sheet was one row from outgrowing a 1366×768 panel.**
  `CARD_MAX_HEIGHT` is derived from the binding table, so adding a row
  grows the card, and `--keys` has no scroll by design (a reference
  list that hides rows is the defect that file was fixed for once
  already). Nothing enforced the height; a `_Static_assert` on
  `BUFFER_HEIGHT` does now, and was confirmed by putting `ROW_H_KEYS`
  back to 40 and watching the build stop.

## Architecture: themes, and the light one that finds bugs

RFC 0030 (`docs/rfcs/0030-themes.md`). `display.theme = <name>`; the
palette is a runtime table loaded from a plain-text file.

- **Colour is runtime; type, spacing and radius are NOT.** A theme that
  can move a 12px gap to 11 reintroduces exactly what §3 of the design
  language exists to forbid, in a place no reviewer looks.
- **The defaults are compiled into `common/theme.c`**, so a client that
  never loads a theme, or whose theme file is missing or garbage, draws
  what it always drew. The loader parses into a COPY and commits only
  on success: a half-applied theme (new background, old text colour)
  is the one outcome worse than not switching, because it can be
  unreadable.
- **A token is no longer a constant expression.** 31 file-scope
  `static const pixman_color_t X = NOVI_PIX(TOKEN);` became
  `#define X NOVI_PIX(TOKEN)`. Do not reintroduce one — the compiler
  says "initializer element is not constant", which does not explain
  itself.
- **The active theme is a published file** (`/run/novi/theme`,
  temp-and-rename), not an environment variable: a client started
  later has to be able to find out. Same argument as
  `/run/novi/network.device`. Clients read it at STARTUP, so a change
  reaches open windows only when they reopen — `apply` says so.
- **SHIP A LIGHT THEME, AND IT IS NOT FOR PREFERENCE.** Every dark
  palette can get the elevation order backwards and still look
  plausible; on a light ground the background layers get darker as
  they rise. `paper` found two bugs on its first run, both of which
  predate the RFC and neither of which any dark theme could surface:
  - novi-bg's hardcoded accent (see the palette audit's third grep);
  - **novi-shell's title bar wrapped an unsigned subtraction.**
    `NOVI_R()` yields an UNSIGNED int, so
    `NOVI_R(top) - (int)NOVI_R(card)` promotes the int back to
    unsigned and `231u - 255u` is ~4.29e9. On a dark palette the
    raised layer is always lighter, so the difference was always
    positive and this was invisible for the life of the file. Every
    title bar came out in bands of orange and red.
- **`novi-launcher --themes` (Super+T) SCANS the directory**, never a
  hardcoded list of four — a menu beside a directory of files is the
  drift this project keeps writing tests to prevent. Enter runs
  `set && apply` as ONE `/bin/sh` child: two spawns race, and
  `spawn_command()` splits on spaces and cannot express a sequence.
  `THEME_NAME_MAX` is 31 because `copy` is 32 — `-Wformat-truncation`
  caught that a longer name would be truncated in the field
  `apply_theme()` acts on and would apply A DIFFERENT THEME than the
  row selected.
- **EVERY LONG-LIVED WINDOW follows a switch now**, and the watch is
  ONE function rather than five copies. `novi_theme_watch()` /
  `_drain()` / `_close()` in `common/theme.c` is novi-bg's inline
  inotify, moved there when novi-files, novi-edit, novi-settings and
  novi-notifyd needed it (RFC 0030 roadmap 1) — and novi-bg calls it,
  which is what makes it the same code rather than a fifth copy. That
  roadmap item said "a re-render there is not one function call"; it
  is (`surface_draw_frame`, or `relayout` in novi-notifyd), and the
  claim went unchecked for as long as the item sat there.
  **novi-edit had no poll loop at all** — `wl_display_dispatch()` in a
  `while`, which has nowhere to put a second descriptor — so it got
  the prepare_read/read_events/cancel_read loop the others carry.
  A -1 watch fd needs no branch anywhere: `poll(2)` ignores it.
- **The COMPOSITOR was the last surface still on the old palette, and
  the worst one.** Server-side decorations are drawn by novi-shell,
  which read the theme once at startup — so with every client
  following a switch, each of their windows sat under a title bar in
  the previous theme. On `paper` that is a dark bar on a white window,
  drawn by the one program that cannot be told to restart. Two traps
  in fixing it: `refresh()` skips the bar redraw when width, focus and
  title are all as drawn (right, and exactly wrong here — the palette
  is not one of the three), and the **control-dot sprites are shared**
  and bake their colour in at creation, so they are remade ONCE before
  any window is repainted and swapped in only if both succeed.
- **The panel and the background follow a switch LIVE, by different
  mechanisms.** novi-panel already redraws at 1 Hz, so
  `novi_theme_reload()` is one `stat(2)` on a tick it had anyway; it
  records mtime and size BEFORE attempting the load, or a theme file
  that fails to parse is retried every tick — 86,400 file opens a day
  from one typo. novi-bg had NOTHING to poll and that was worth
  keeping, so it gets an **inotify** fd: one descriptor, zero wakeups.
  Two traps there: the watch is on the DIRECTORY because novi-state
  publishes by rename and a watch on the file follows the old inode
  into oblivion (`IN_MOVED_TO` is the event a rename produces); and
  the fd must be DRAINED on every wake whatever it says, because an
  unread inotify fd stays readable and the loop spins at 100% CPU —
  the same shape as the POLLPRI trap on `/proc/mounts`. Everything
  else picks the palette up at its next start.
- **The palettes have a HOST TEST now** (`common/theme-test.c`, run by
  `scripts/lint.sh` via `make -C common check`). It links the real
  loader rather than reimplementing the parser, and asserts §1's
  claims: the elevation ladder is monotonic, body text reaches WCAG AA
  on every ground it is drawn on, `accent.active` is darker than
  `accent` so a pressed control sinks, and each status colour is
  readable where it appears. Verified by breaking each invariant on
  purpose and watching it fire.
- **Writing that test corrected three dark-palette assumptions before
  it found a single bug**, which is the same lesson `paper` teaches
  about code:
  - **base → panel → card is the ladder; `bg.card-raised` is NOT its
    fourth rung.** theme.h says it is "a card on a card; hovered row"
    — a variant of card. On a light palette card is often pure white,
    so the hovered row can only go darker. Asserting one direction
    across all four fails a correct palette.
  - **"accent.hover is lighter" is dark-palette thinking.** On a light
    ground the more prominent colour is the darker one. Only
    `accent.active` has a fixed direction, and both kinds of palette
    agree on it.
  - **Contrast ratio is the wrong instrument for "are success and
    error distinguishable".** They are told apart by HUE and a correct
    pair sits at almost identical brightness (paper 1.29, axiom 1.65).
    Assert each is READABLE where drawn instead. Distinguishing them
    for a colour-blind reader is a real problem a ratio cannot speak
    to — which is why the panel pairs its health colour with a glyph.
- **A token with no consumer can still be wrong, and that is the best
  time to fix it.** White on paper's accent measured 3.74:1, under AA;
  white is already the lightest `text.on-accent` can be, so the accent
  moved (`#0d9488` → `#0c8578`). Nothing draws `NOVI_TEXT_ON_ACCENT`
  yet — so the bug was latent, and would have shipped an unreadable
  badge on one theme the day something used it.
- **A theme swatch is two rects, not an icon.** `draw_icon()` blends a
  monochrome glyph in one colour and cannot express a ground plus an
  accent, which is the whole information a swatch carries.
- **A theme in `/etc` SHADOWS a shipped one of the same name.**
  `novi_theme_dirs` is `/etc/novi/themes` then
  `/usr/share/novi/themes`, and the order is ONE ARRAY in theme.c that
  every reader walks -- the loader, and novi-launcher's picker, which
  will not offer a name twice. Same argument as `keys.conf`: `/usr` is
  the distribution's and a package upgrade overwrites it; `/etc` is
  yours. A file that parses to nothing counts as a MISS and falls
  through, so an empty override does not strand the desktop on
  whatever it had.
- **Shadowing REPLACES, it does not patch.** The loader starts from
  the BUILT-IN palette, so a two-line `/etc/novi/themes/paper.theme`
  gives those two colours over *axiom's* values and not over the
  shipped `paper`'s. Watched live: a brown base and panel with axiom's
  accent. Right rule -- a file inheriting from a shipped one of the
  same name would be a diff whose base can change under it -- and
  exactly the thing somebody will expect the other way round.
- **Eight of the nine checks for that could not see the shipped
  order.** They pass the test's own two directories, because the
  interesting behaviour is which of a pair wins and the real pair are
  absolute target paths -- so swapping the two entries in `theme.c`
  left every one of them passing while every client looked in
  `/usr/share` first. The ninth asserts the array. A test that
  parameterises the thing it is checking stops checking the value the
  product actually uses.
- **`usr/share/novi` is no longer claimed wholesale by novi-launcher**
  in pkgsplit's `DATA_FILES`. That list is walked in full for every
  entry rather than first-match, so a parent and a child both listed
  put the same file in two packages. Named subdirectories:
  `usr/share/novi/apps` (launcher), `usr/share/novi/themes`
  (novi-themes).

## Architecture: the keys, and the sheet that lists them

`common/keybindings.h` is every keyboard shortcut this desktop has,
once. novi-shell DISPATCHES from it; `novi-launcher --keys` (Super+/)
DISPLAYS it.

- **Undiscoverable keys are unusable keys.** Every binding lived only
  in novi-shell's own switch statement, so a person who booted this
  image had no way to learn Alt+Space, Super+L or Super+Escape short of
  reading the source. GNOME and Pop!_OS both ship exactly this window;
  it was the most conspicuous thing missing from this desktop.
- **A sheet maintained separately from the bindings drifts, and a
  drifted sheet is worse than none** -- it is a document that
  confidently tells you the wrong key. Same argument as
  `restore-build-inputs.sh` restoring what the MANIFEST names rather
  than "everything except a blocklist": a derived answer cannot rot.
  So there is no display-only row. The two workspace rows carry
  `NOVI_BIND_DIGIT_RANGE` and drive dispatch like every other row,
  rather than sitting beside a hand-written special case.
- **A shortcut sheet reachable only by a shortcut is a bootstrapping
  paradox.** It is also `usr/share/novi/apps/shortcuts.app`, so the
  Apps button reaches it with a mouse and no prior knowledge -- which
  is the entire audience. That is the KDE lesson (never hide a feature
  behind only the thing it documents); the grouping and type discipline
  are elementary's; the sheet itself is GNOME's and Pop!_OS's.
- **Matching is exact-modifiers-then-subset, and neither pass alone
  works.** Subset alone cannot tell Super+3 from Super+Shift+3, so
  moving a window to a workspace would merely switch to it. Exact alone
  breaks Alt+Shift+Tab, which most layouts deliver as `ISO_Left_Tab`
  with the shift bit ALSO set. Letters are compared through
  `xkb_keysym_to_lower()` so Caps Lock does not need a second row.
- **`NOVI_BIND_WHEN_LOCKED` is on the row, not in a branch.** "Which
  keys work on the lock screen" is a security question, and one
  answered by control flow three functions away is one nobody re-reads.
- **The header may depend only on what BOTH binaries have.**
  novi-launcher links xkbcommon and no wlroots, so the modifier bits
  are ours and novi-shell maps them onto `WLR_MODIFIER_*` at the point
  of comparison.
- **The sheet's rows are 32px, not the launcher's 40.** Sixteen 40px
  rows plus header and shadows come to ~780px, which does not fit a
  1366x768 laptop -- a very common panel nobody would think to test on.
  `CARD_MAX_HEIGHT` is taken over BOTH modes, because the sheet has
  more rows and shorter ones, so neither count nor height alone gives
  the right answer.

## Architecture: the keys are a file now

RFC 0037 (`docs/rfcs/0037-user-editable-keybindings.md`).
`/etc/novi/keys.conf` is `<action> = <binding>`; `common/keys.c`
applies it over the compiled table and BOTH binaries load it.

- **RFC 0001 promised this in its own words and it was never true.**
  "novi-shell's bindings live in a plaintext config file a user can
  edit directly" -- they were compiled-in constants for the life of
  the project, which made the one part of a desktop people reliably
  want to change the one part they could not. A promise in an RFC is
  a claim about the code like any other; check it before repeating it.
- **The sheet's text is GENERATED now, and the hand-written strings
  are deleted.** `novi-launcher --keys` renders every row through
  `novi_keys_format()` from the binding that will actually fire,
  because an override file is a new way to produce exactly the drift
  `keybindings.h` exists to prevent. Deleting the nineteen literals
  was safe only because the formatter reproduced all of them
  character for character first -- including `Alt + Shift + Tab` for
  the `ISO_Left_Tab` row and `Print Screen` for `XKB_KEY_Print`.
- **AN UNKNOWN MODIFIER WORD IS A REFUSAL, NOT A SKIP.** `Ctrl+Q` is
  the case: this compositor has no control modifier, so ignoring the
  word binds the shortcut to **Q alone** -- a line that silently does
  something far worse than what it says.
- **A collision unbinds the LATER row.** Dispatch stops at its first
  match, so "earlier wins" happens whether or not anybody decides it;
  the decision is that the shadowed row reads `(unbound)` instead of
  going on advertising a key it can never win.
- **A line that cannot be parsed leaves ITS row alone.** Refusing the
  whole file over one typo takes nineteen working shortcuts away from
  somebody who is already confused. Same for an action name this
  build has never heard of: counted, not fatal, because one file is
  read by whatever novi-shell is installed.
- **Base content, NOT part of the novi-shell package.** `pkg`
  overwrites a package's files on upgrade, and this is a file whose
  whole purpose is to be edited -- the same reason `system.conf` and
  `pkg.conf` are base.
- **Not a `system.conf` key either.** Nothing converges a keyboard
  shortcut: novi-shell reads the file when it starts and that is the
  mechanism. Nineteen keys that cannot drift, in the document whose
  point is drift, with `apply` having nothing to do for any of them.
- **`keybindings.h` was not self-contained.** It used `xkb_keysym_t`
  while including only `xkbcommon-keysyms.h`, which has the constants
  and not the type; it compiled because every consumer happened to
  include `xkbcommon.h` (or wlroots) first. A header that only works
  second breaks the first time somebody includes it first.
- **`novi.keys=off` is honoured IN THE LOADER, not in the
  compositor.** A file read at startup can lock somebody out of their
  own desktop, so it needs `novi.state=off`'s escape hatch -- and if
  novi-shell honoured it while novi-launcher did not, the hatch itself
  would produce the wrong-key sheet everything else here rules out.
- **The shipped `keys.conf` is a THIRD list**, checked both ways by
  the host test: every action in the table is named in the file, and
  every action the file names exists. It is also the only place a
  person learns what an action is called.
- **THE KEYS PANEL IS THE FOURTH PANEL, and `keys.conf` is the one
  file the System panel cannot reach** — it is not a `system.conf`
  key, because nothing converges a shortcut. Unlike RFC 0033's
  wired-network item, that made it a real gap rather than a second
  path. `novi_keys_write()` lives in `common/keys.c` beside the
  loader, and **a commented line is not a match**: the shipped file is
  87 lines of which every one is a comment, so a matcher that skipped
  the `#` would rewrite an example in place and uncomment it. Removal
  deletes rather than comments out; a duplicate live line is dropped
  (the loader is last-wins, so writing above a stale line leaves the
  file and the desktop disagreeing); a refused write leaves the file
  byte for byte as it was.
- **The binding is TYPED, not captured, and that is forced.**
  novi-shell grabs Super+<anything> before a client sees it, so a
  "press the shortcut you want" prompt would have the compositor close
  the Settings window when somebody pressed Super+Q at it.
- **"Yours" comes from the FILE, not from a comparison.**
  `novi_keys_is_set()` asks whether there is a live line, because
  setting a shortcut to what it already was is a real thing somebody
  does and only the file can say so.
- **A SAVED FLAG SHADOWED EVERY LATER ANSWER.** `render_keys` built
  its own footer and never drew `state->status`, so `keys_report`'s
  sentences went nowhere -- and the chain reached `keys_written`
  first, which meant that once you had saved once, a REFUSED write
  reported nothing at all: the file was correctly untouched and the
  panel said "Saved". Found by typing `Ctrl+Q` at a booted machine and
  screenshotting it, for the fifth time in this file. Two lines now: a
  STANDING one (a line the loader threw away, a shadowed shortcut, or
  the restart reminder) and an ANSWER to what you just did. A fact
  about the file and a reply to a keystroke cannot share a line.
- **A read in the DRAW is a read per row per frame.**
  `render_keys` asked `novi_keys_is_set()` for each visible row, which
  is a file open and a full parse fourteen times a frame at whatever
  rate a held arrow key repeats. `keys_refresh()` fills a `keys_mine[]`
  once instead. Same mistake as novi-panel reading the volume file
  inside `layout_taskbar()`: a read belongs where state is gathered,
  not where it is drawn.
- **Two of the writer's tests could not fail on the guard they
  name.** A spec carrying a newline or a `#` is refused by
  `novi_keys_parse()` before the writer's own check sees it — found
  by deleting that check and watching both still pass. They assert
  the behaviour, which is what matters; the guard stays because what
  may appear in a binding and what may appear on a line of this file
  are different questions. Both the code and the test say so.
- **CI installs `libxkbcommon-dev` for the host test.** The parser
  turns "Return" into a keysym with `xkb_keysym_from_name()`; the
  alternative is a hand-copied table of xkbcommon's, and a test that
  skips itself where the header is missing skips itself exactly where
  it would have caught something.

## Architecture: nothing reaped the compositor's children

`spawn()` forked and never waited, and novi-shell installed no SIGCHLD
handler, so **every** launcher, symbol picker, screenshot, power menu
and terminal left a zombie for the life of the session. The comment in
`spawn()` actively said otherwise -- that `setsid()` meant the child's
"lifetime isn't tied to being a direct child novi-shell has to reap" --
which is wrong: setsid changes the SESSION, not the parent. A comment
asserting the bug away is how it survived.

Invisible while spawning was a rare, deliberate act. The volume keys
changed the arithmetic: they spawn on every press, so the leak went
from a handful per session to one per keystroke. **Measured on a booted
machine: twelve presses of volume-up produced exactly twelve zombies;
after the fix, fifteen presses produced none.**

- **A handler with `waitpid(WNOHANG)`, not `signal(SIGCHLD, SIG_IGN)`.**
  SIG_IGN is shorter and also works, but it makes every future
  `waitpid()` in the process fail with ECHILD -- a trap laid for
  whoever next wants a child's exit status.
- **The handler LOOPS.** Signals are not queued, so several children
  exiting together deliver one SIGCHLD; reaping a single child leaks
  the rest, which for a key that repeats is the same bug more slowly.
- `SA_RESTART` so the event loop's `poll()` resumes instead of
  returning EINTR, and `errno` is saved and restored around the reap.

## Architecture: the QEMU test harness lies quietly

`send-key` returns an error for an unknown QKeyCode and **the harness
was discarding the response**, so an invalid keycode pressed NOTHING
while the test read an unchanged screen as "the feature is broken".
That produced three separate false failures on bindings that were fine,
and cost more time than any real bug in the same session.

- **The names are not the obvious ones**: `shift`, `ctrl`, `alt` (NOT
  `shift_l`/`ctrl_l`/`alt_l`), `dot` (NOT `period`), `meta_l` (NOT
  `super`, which CLAUDE.md already recorded and which is the same trap
  a second time). `spc`, `ret`, `esc`, `print`.
- **Make the harness raise on a QMP error.** This is the fix that
  generalises; the keycode list will be got wrong again.
- **Modifiers do not persist across separate QMP commands.** Holding
  one in `input-send-event` and pressing the key in a second call
  delivers an unmodified keypress -- verified by watching plain `2`s
  arrive in a terminal where `@` was expected. Send the whole chord in
  one command, or use `send-key` with all its keys at once.
- **Check the observable answers the question.** "Did the window move
  to another workspace" was first tested by looking at the TASKBAR,
  which lists every toplevel regardless of workspace and therefore
  could not have shown the difference either way.
- The screenshot key writes `/root/screenshot-*.bmp`, not `.png` --
  a test that globbed `*.png` reported a working binding as broken.
- **A fifo driving `-serial mon:stdio` needs a PERMANENT writer.**
  `printf … > fifo` closes the write end when it finishes, the fifo
  hits EOF, and qemu's stdio monitor **quits** -- which from the log
  looks exactly like a boot that hung at `Loading initramfs...`, and
  was debugged as one for twenty minutes. Hold it open
  (`sleep 100000 > fifo &`) for the life of the VM. And check the
  qemu process is still alive before believing a frozen log.

## Architecture: a launcher has to answer "what is installed"

`novi-launcher` showed nothing on an empty query and exactly one match
once you typed. Its own comment defended that as matching the
calculator's one-result display, with "exactly one real app (foot) to
ever produce more than one match against".

- **The count was never the problem.** A launcher that shows nothing
  until you type cannot tell you what the machine has, and a bare
  cursor on a bare card is a puzzle rather than an invitation. Empty
  query lists everything; typing filters.
- **One kind-tagged `struct result`, not three parallel lists.** The
  selection is one index, and the keyboard should not have to know
  whether it is moving through apps, a calculator answer or symbols.
- **The card grows inside a FIXED surface** rather than resizing its
  own layer surface per keystroke — that would be a
  set_size/commit/configure round trip per character, which is both
  flicker and a protocol dance to get wrong.

## Architecture: the palette drifts unless something checks

`common/theme.h` was adopted by half the clients and the other half
kept private palettes — found by `grep`ing every client for
`0x[0-9a-f]{8}` literals, not by looking at screenshots.

- **Two clients had invented a SECOND ACCENT.** `novi-settings`
  defined its accent and its focus ring as `0xff8ab4f8` (Google's
  blue), and `novi-launcher` used the same value for result rows. The
  desktop answered "which thing is active?" in teal everywhere and in
  blue in those two, and it looked deliberate enough that no
  screenshot review caught it.
- **`NOVI_PIX()` exists because hand-written `pixman_color_t` literals
  get the expansion wrong**, and two more files had it: `0xe0` written
  as `0xe000` rather than `0xe0e0`. Never write one by hand.
- **Map by ELEVATION, not by nearest hex.** novi-edit's canvas is
  bg-card (the sheet), its gutter and status bar are bg-panel (chrome
  beside it), its cursor line is bg-card-raised (a row lifted off that
  sheet). Choosing the token whose *meaning* fits keeps the answer
  stable when a token's value changes.
- **The audit is two greps, and the second one exists because the
  first missed the worst case.** Run both whenever a client is added:

  ```sh
  CLIENTS="novi-panel novi-files novi-edit novi-view novi-settings
           novi-lockscreen novi-launcher novi-notifyd novi-bg
           novi-screenshot novi-shell common"
  # packed 0xAARRGGBB
  grep -rn '0x[0-9a-fA-F]\{8\}' --include=*.c --include=*.h $CLIENTS
  # hand-written pixman_color_t, whose channels are only FOUR hex digits
  grep -rn '\.red *=' --include=*.c --include=*.h $CLIENTS
  ```

  Named directories rather than `novi-*/`: that glob also sweeps
  `novi-gpt`, whose eight-hex constants are a CRC polynomial and GPT
  header fields. A hit is a question, not a verdict — an alpha mask or
  a format constant is fine; a colour is not.

  **A THIRD grep, added by RFC 0030**, because the first two missed
  the most visible surface on the desktop:

  ```sh
  # a colour written as three separate bytes
  grep -rn '0x[0-9a-fA-F]\{2\}, 0x[0-9a-fA-F]\{2\}, 0x[0-9a-fA-F]\{2\}' \
      --include=*.c $CLIENTS
  ```

  novi-bg's background gradient carried `{ 0x2d, 0xd4, 0xbf }` under a
  comment that said `/* NOVI_ACCENT */`, so the desktop behind every
  window kept its teal glow on every palette while the panel above it
  switched correctly. A colour written as separate bytes looks nothing
  like a colour to either of the other two greps.

  The eight-hex grep alone reported novi-panel clean while it held
  **five** hand-written `pixman_color_t` literals, every one of them
  with the shift bug, including the accent for the taskbar's active
  entry and the Apps button's hover. The panel is the most-looked-at
  surface on the desktop and its accent had been slightly darker than
  every other accent for the whole life of the file, under a comment
  that said "same tokens as the apps label". **A four-hex channel does
  not look like a colour to a grep for colours.**

## Architecture: notifications, and a surface that never came back

RFC 0024 (`docs/rfcs/0024-notifications.md`). `novi-notify` in the
base image, `novi-notifyd` drawing toasts on the desktop.

- **A UNIX DATAGRAM socket, and specifically not a FIFO.** A FIFO is
  the one transport a shell script could have used with no C at all —
  and `open(O_WRONLY)` on a FIFO with no reader blocks FOREVER. The
  largest caller is a uevent handler, where that stops the kernel's
  hotplug queue (RFC 0012). Not a stream either: a stream needs
  `connect()` to succeed, so a daemon mid-startup would make senders
  block or fail on timing. Datagram means one message is one message.
- **Not D-Bus, for the third time** — RFC 0009 (iwd), RFC 0023
  (udisks2), now this. `org.freedesktop.Notifications` is a D-Bus
  interface; what is needed is "hand a short string to a program that
  may not be running", which is eighty lines.
- **The sender is base and the daemon is a package**, because the
  things with something to say (`novi-mount`, `novi-eject`) are base
  tools that run on machines with no desktop. `novi-notify` always
  writes to syslog too: on a console-only machine that line is the
  whole feature.
- **A separate client, not a second surface in novi-panel.** A socket
  bug that kills this process costs a toast; the same bug inside the
  panel costs the taskbar and the clock.
- **UNMAPPING A LAYER SURFACE IS A ONE-WAY DOOR.** Attaching a NULL
  buffer when the stack emptied is the documented way to stop
  occupying a rectangle, and it does not come back: the surface needs
  another configure round before the compositor will accept a buffer,
  so the next toast attached one to a surface that was not ready and
  wlroots dropped it. Nothing drew, ever, and nothing said so — daemon
  running, socket bound, syslog full. A screenshot found it. The
  surface now stays mapped for life and click-through is
  `wl_surface_set_input_region()` over exactly the cards, which is
  better than unmapping ever was: the GAPS between cards pass clicks
  through too.
- **Everything on that socket is untrusted text.** The biggest sender
  is novi-mount announcing a volume by its filesystem label — a string
  off a stranger's stick — and the socket is world-writable by design
  (an unprivileged program has as much business notifying as root
  does, and there is no session bus to arbitrate). Control characters
  are dropped, lengths capped, urgency and icon matched against fixed
  lists. An unknown icon name is *no icon*, not a fallback and not an
  error.
- **Critical never expires.** Something that matters enough to be
  called critical should not vanish while the person is looking away.
  novi-mount uses it for exactly one thing: a volume yanked while
  mounted.
- **`DESKTOP_BINARIES` in pkgsplit is NOT `PACKAGE_TABLE`** — a new
  desktop client goes in both. Adding it to the table alone leaves it
  seeded as a base binary, so its libraries get pinned into the base
  while the table's sweep moves them out, and the straddle check fires
  on fourteen unrelated libraries: a correct error pointing nowhere
  near the cause.

## Architecture: a toast that is gone is not a thing that happened

RFC 0034 (`docs/rfcs/0034-notification-history.md`). `novi-notifyd`
keeps the last fifty and republishes them to
`/run/novi/notifications`; `novi-launcher --notifications` (Super+N,
and an Apps-grid entry) shows them. RFC 0024 built the toast and
stopped, which made the whole mechanism unreliable for the one thing
it is for: telling you something while you are busy with something
else.

- **A published FILE, not a second socket.** novi-launcher is started
  fresh by the keypress, so a socket it would have had to be listening
  on before the notification arrived is no use to it. Same argument as
  `/run/novi/health`, `/run/novi/theme` and `/run/novi/network.device`.
  Rewritten entire (temp-and-rename) rather than appended: the bound
  and the atomicity in one move, where an appender needs a separate
  trimmer that can disagree with it.
- **Tab separated with NO escaping, and that is safe by
  construction.** Every field from outside has been through the
  sanitiser, which DROPS control characters rather than escaping them
  — so a tab cannot reach the file. RFC 0024 made that call for the
  toast; this is a second reason it was right. The sanitiser is now
  ONE function in `common/notifications.c`: two copies would be one
  edit away from a format where a summary somebody chose shifts every
  field after it.
- **The urgency is a word and the icon is a name**, never enum values.
  A file in `/run` is read by a different program, possibly a
  different build, and a number meaning "critical" only because both
  sides agree on an enum's order breaks silently the day someone
  inserts a value. An icon name this build does not know is NO ICON —
  RFC 0024's existing rule.
- **Summary and body are separate fields on the row**, bold then
  muted. Packing them into `primary` (64 bytes, against a 160-byte
  body) drew `-Wformat-truncation`, and it was right: most of the body
  was thrown away before layout saw it. That warning has caught a real
  loss in this repo three times now. The row splits its width —
  summary up to HALF, body the rest — so a long summary cannot push
  the body off the row, which is the case where the list stops
  answering its own question.
- **Twelve rows, and it says what it is not showing.** Fifty at 32px
  is a 1600px card. The launcher's existing "N more" strip reports the
  remainder, so this is a bounded card rather than the silent-elision
  bug class.
- **An empty list says WHY**, and `card_h` gets a row's height so the
  sentence is inside the card instead of below its bottom edge. Two
  different answers — nothing has happened, or the daemon was never
  told anything — and a bare cursor distinguishes neither.
- **Enter does nothing, deliberately.** The sender told us a summary
  and a body, not an action; inventing one means guessing intent from
  text, which is wrong about a tenth of the time and unexplainable
  every time.
- **It does not survive a restart**, and that is honest: `/run` is a
  tmpfs and the history is what this daemon has seen.
- **The screendump found what reading the code did not.** Two rows out
  of three had an empty icon column, because novi-launcher's
  `resolve_icon_name()` is the table for `.app` descriptors and knew
  `package` but not `drive` or `eject`. That is NOT the "unknown icon
  name is no icon" rule working — that rule is about names nobody
  defined, not names this table never learned — and a column empty
  twice and full once reads as a rendering bug. **When a GUI change
  looks right in the code, screenshot it**, for the fourth time in
  this file.

## Architecture: the bell, and what "read" had to mean

RFC 0034 shipped a notification history and no way to know there was
anything in it. The panel draws a bell and a count when there is.

- **"Read" is ONE TIMESTAMP**, the `when` of the newest entry the
  list has shown. novi-launcher writes it; the panel counts what is
  newer. That is the whole notion the RFC said it did not have.
- **Two files, one writer each.** novi-notifyd owns
  `/run/novi/notifications` and never reads the marker; novi-launcher
  owns `/run/novi/notifications.seen` and never writes the history;
  the panel reads both and writes neither. A "seen" column in the
  history would put two programs on one file.
- **The marker is taken BEFORE the search filter.** The launcher
  re-reads the file on every keystroke, and what you have seen is the
  list the window showed -- not what survived what you typed. Taking
  it after would leave everything else unread forever the moment
  somebody filtered.
- **There is a one-second blind spot and it is written down.** A
  notification arriving in the same second as the newest one on
  screen counts as seen. The alternative is a marker that is a count
  as well as a time, and two numbers about one moment can disagree.
- **A bell AND a number, not a dot.** "One thing happened" and
  "eleven things happened" are different states of a machine. Mono
  face, like the clock: it is a machine value, not language.
- **`-Wformat-truncation` was right again** (fourth time here): an
  `int` does not fit in an eight-byte label. The fix is the CLAMP it
  points at, not a wider buffer -- `novi_hist_unread()` counts lines
  in a file another program wrote, so a number wider than the list can
  hold is not a count of anything.
- **CLEARING IS A SECOND MARKER, NOT A VERB ON THE SOCKET.** Ctrl+L
  in the list writes `/run/novi/notifications.cleared` and the list
  hides everything at or before it. A `clear` control message was the
  obvious design and is wrong: that socket is world-writable by design
  (RFC 0024), so it would let any process on the machine empty
  somebody's notification list. A marker the READER owns cannot be
  reached by a sender at all.
- **Clearing writes BOTH markers.** `cleared` hides the rows; `seen`
  has to move with it or the bell goes on counting entries the list no
  longer shows.
- **The clear mark is the newest entry the window LOADED**, never the
  wall clock -- which is not reachable in that handler anyway, because
  the Wayland event's `time` parameter shadows `time(3)` and is a
  millisecond counter rather than a date. A notification arriving in
  the same second and read by nobody must not be swept up.
- **Dismissing ONE is not built on a timestamp**, and that is a
  limit rather than laziness: a timestamp says "everything before
  here" and cannot say "that one", and two notifications in the same
  second share a `when`. It needs entry ids, which is a change to the
  file two programs exchange.
- **The host test's probe was wrong twice before the glyph was.** The
  bell's "rim is wider than the dome" check counted INKED COLUMNS,
  which on an outline glyph at the dome's centre row is two strokes --
  so a rim narrower than the dome still counted wider and the check
  passed with the overhang removed. Measure an EXTENT (rightmost minus
  leftmost). Provoking each assertion is the only thing that finds
  this class of mistake.

## Architecture: the keys above the number row

`novi-volume` (base image) over `amixer`, bound to the XF86Audio*
keysyms by novi-shell, with a speaker glyph in the panel. ALSA had
been in this image since RFC 0011 and the only way to change the
volume was to type a mixer control name at a shell.

- **NEVER hardcode `Master`.** This file already recorded that QEMU's
  emulated USB audio card invents `Audio Output Volume Control` where
  `alsactl init` expects `Master Playback Volume`. A tool assuming the
  standard name works on every real machine and fails on the only one
  this project can test on, which is the worst way round.
  `pick_control()` prefers Master/PCM/Speaker/Headphone and otherwise
  takes the first control ALSA reports with `pvolume` in its
  Capabilities — a control with only `pswitch` is a mute toggle with
  nothing to turn.
- **`amixer` inside the `while read` loop needs `</dev/null`.** Any
  child that reads stdin inside a loop fed by a pipe eats the loop's
  own input; the symptom is a control list that ends early for no
  visible reason.
- **Volume-up unmutes; volume-down does not.** Pressing the loud key
  on a muted machine means "I want to hear this"; pressing the quiet
  key does not, and unmuting on the way down makes the quiet key
  briefly loud. Verified both ways.
- **`set N` does not always read back N, and that is ALSA.** A
  percentage is a position in the card's own raw range, so `set 40` on
  a 64-step control lands on 41. `refresh` prints what the card holds,
  never what was asked for.
- **Media keys fire WHILE LOCKED**, unlike every other binding in
  `handle_keybinding()`. Changing the volume discloses nothing and
  unlocks nothing; refusing it means you cannot silence a machine you
  have just locked and walked away from. Both halves were tested, and
  the second is the one that could have gone wrong quietly: three
  volume presses on the lock screen, then the **plain** password
  unlocked on the first try — so the keys were swallowed, not typed
  into the password field.
- **The panel reads `/run/novi/volume`, and never forks amixer.** Same
  published-state arrangement as the network interface (RFC 0009) and
  the health verdict (RFC 0014); the panel repaints once a second and
  a fork per repaint is what that pattern exists to avoid. The cost is
  that `amixer` run by hand is not reflected until the next
  `novi-volume` call. `rc.init` publishes once after `alsactl restore`
  so the indicator exists before the first keypress — without it the
  glyph appears the first time somebody changes the volume, which
  reads as a bug in the indicator rather than as the absence of a
  reading.
- **Display only, like the health glyph.** Every click on this bar
  OPENS something (Apps, settings, the power menu); a click that
  toggled mute would be the one control there that changes the machine
  instead of showing it.
- **`mkvm.sh --display none` now attaches a sound card** on QEMU's
  null audio backend. Without one the only thing a headless run can
  check is that the code correctly says "no sound card", which is the
  one answer that proves nothing.
- **The icon host test earned its keep again**, and on both axes this
  time: the glyph bled into the top and bottom border rows, then into
  the left column, and the border assertion caught each in turn — a
  speaker clipped flat just reads as a boxy speaker. It also failed on
  a *bad probe of mine*: the muted cross reaches as far right as the
  outer arc, so "muted draws no arc" probed at the arc's rightmost
  point can never fail. Probe at 45 degrees instead.

## Architecture: the places sidebar, and polling /proc/mounts

RFC 0023's addendum. `novi-files` shows Home, Filesystem and a DEVICES
section that appears and vanishes as media comes and goes.

- **`poll()` on `/proc/self/mounts` has two traps stacked.** It reports
  **POLLPRI**, never POLLIN — a poll set up for POLLIN waits forever
  while the sidebar silently never updates. And **POLLPRI stays
  asserted until the file is read again**, so a loop that wakes,
  redraws and polls again without re-reading spins at 100% CPU:
  silent, and visible only as a hot laptop.
  `novi_places_watch_drain()` is that read; every wake calls it first.
- **Volumes come from `/proc/mounts`, not from listing `/run/media`.**
  A directory can be there with nothing mounted on it, and the sidebar
  would offer a place that is an empty directory.
- **Mount points are octal-escaped in `/proc/mounts`** (`\040` and
  three others). `My\040Stick` is not a path, and this code does not
  get to assume novi-mount's `safe_name()` is the only thing that ever
  mounts anything under `/run/media`.
- **The sidebar selection is preserved by PATH, not by index.** A
  volume unmounting shifts everything below it up one, and an
  index-preserving refresh moves the cursor onto a *different* volume
  — which matters when the next keystroke might eject it.
- **Ejecting the volume you are standing in leaves it first.**
  novi-eject refuses a busy mount and the window's own cwd is what
  makes it busy, so without this a file manager could never eject the
  stick it was showing and would blame the user's own window.
- **`^E` works only from the sidebar**: from the file list it would
  have to guess which volume was meant, and a key that ejects
  something you were not looking at is not a convenience.
- **New icons go through `shared/icons/tools/svg2icon`**, vendored at
  the same pinned Lucide commit, never hand-transcribed. Lucide
  renamed `home` to `house`: `icons/home.svg` is a 404 at that commit.
- `novi_text_truncate()` lives in `common/text.c` now — two clients
  need it, and two copies is how they end up truncating differently.
- **`wl_pointer` v5 aborts the client on a NULL listener slot.**
  Version 5 added `frame`, `axis_source`, `axis_stop` and
  `axis_discrete`; libwayland does not treat a missing handler as "not
  interested", it kills the client with *"listener function for opcode
  5 of wl_pointer is NULL"* — immediately, because `frame` follows
  every pointer event group. novi-files binds `wl_seat` at 5 for the
  KEYBOARD (`repeat_info` arrived in 4); novi-panel binds 1 and needs
  none of them, so its five-entry listener is the wrong thing to copy.
- **The sidebar's row geometry lives in `layout_places()`, not in
  `render()`**, because the hit-test needs the same arithmetic and two
  copies disagreeing by one row means clicking eject on a volume you
  were not pointing at.
- **`row_at()` must reject a y past the last entry**, or a click in the
  empty space below a short listing selects whatever index the
  arithmetic produced.
- Double-click uses the timestamp `wl_pointer.button` carries, not a
  clock read in the client — the latter measures when the client got
  round to the event, not when the button went down.

## Architecture: removable media

RFC 0023 (`docs/rfcs/0023-removable-media.md`). Plug in a stick, it
appears at `/run/media/<label>`; `novi-eject` takes it out.

- **The kernel could not read most sticks, and that was the real
  blocker.** `CONFIG_EXFAT_FS` and `CONFIG_NTFS3_FS` were off. Windows
  and macOS format anything over 32 GB as exFAT, and any drive that
  has lived on Windows is NTFS — so automount without them fails on
  most media that exists, with "unknown filesystem type", which reads
  as a broken stick. NTFS3 is Paragon's read-write driver, not the
  ancient read-only `ntfs` upstream removed in 6.9; the two are one
  letter apart in Kconfig.
- **`blkid` says `ntfs`; the driver is `ntfs3`.** The allowlist said
  `ntfs3` and the detected type said `ntfs`, so every NTFS volume
  would have been refused *by code whose list claimed to support it*.
  Found by running `blkid` over a real `mkfs.ntfs` image while
  building the test media — not by reading the code, twice.
  `mount_type()` returns the mount type from the same function that
  decides support, so the two cannot drift.
- **Almost all of `novi-mount` is deciding whether to touch the device
  at all**, because every wrong answer there is serious. Removable is
  two tests, not one (a USB hard disk reports `removable=0` — the
  *medium* is not removable, the *device* is). "Already mounted"
  covers root, `/boot`, the ESP and the live medium in one check with
  no list to keep in sync. `/etc/fstab` is matched on the device node,
  `LABEL=` **and** `UUID=`, because fstab may use any of the three.
- **A filesystem label is attacker-controlled text about to become a
  directory name.** Filtered to `[A-Za-z0-9._-]`, truncated, and a
  leading dot is *rejected rather than stripped* — `..` survives the
  character filter because dots are in the keep set. Verified with an
  ext4 image whose superblock label reads `../../etc`: it mounts as
  `/run/media/sdd`. Same call as novi-wifi on an SSID.
- **An allowlist of filesystems, never `mount -t auto`.** A filesystem
  driver parsing a hostile image is one of the larger attack surfaces
  a kernel has.
- **`nosuid,nodev` always; `noexec` deliberately not.** `noexec` would
  block running a script from a stick — which this project's own
  installer does from the live medium — and the attack it stops needs
  the attacker already running code here. udisks2 makes the same call.
- **`novi-mount remove` is lazy and `novi-eject` is not, and that is
  the entire difference between them.** `remove` runs when the device
  is already gone, where a plain `umount` blocks on writeback to
  hardware that is not there. `eject` runs while it is still present,
  where a busy mount means a program is genuinely still writing and
  detaching the tree underneath it would lose exactly the data the
  command exists to protect. It refuses instead.
- **`storage.automount` has no converger**, like `power.lid`:
  novi-mount reads it at event time. So `converge_key` never runs to
  reject a typo and the *observer* has to — an unusable value reports
  as drift rather than sitting in the document looking converged while
  sticks silently failed to mount.
- **The uevent handler backgrounds the call** (RFC 0012's rule —
  mounting is exactly the thing that can block), which makes two
  partitions on one stick race. `novi-mount` takes an `mkdir` lock;
  there is no `flock` in BusyBox ash. The stale-lock case checks
  whether the PID inside still exists rather than using a timeout, or
  a handler killed mid-mount would wedge automount until reboot,
  silently.
- **`CONFIG_ISO9660_FS` is now stated in the curated config** instead
  of being force-enabled by `05-kernel.sh` behind its back. A symbol
  the build has to repair is a symbol the config should state.

## Architecture: shutdown, and why it used to hang

RFC 0013 (`docs/rfcs/0013-power-events.md`).

- **`down-signal = SIGHUP` and `timeout-down` on the gettys are
  load-bearing, not tuning.** `getty` execs `login` execs the shell, so
  the process s6 supervises IS the interactive shell — and an
  interactive shell ignores SIGTERM by definition. With `timeout-down`
  unset (= wait forever), `s6-rc -bDa change` stopped at
  `service getty-ttyS0: stopping` and never returned, and
  `s6-linux-init-shutdownd` waits on that script with a plain
  `wait_pid()` and no timeout of its own — so it never reached the
  SIGTERM/SIGKILL sweep or `reboot(2)`. **The machine could not shut
  down while anyone was logged in**, which is always. SIGHUP is the
  correct signal (a getty going away is a hangup); the timeout is the
  backstop.
- **Nothing caught that for the entire life of the project** because
  every QEMU test ran `poweroff` and then killed the VM ten seconds
  later. When a test issues a command, it has to observe the command's
  *effect* — the same lesson as `s6-rc -a list` reporting "up".
- **A new longrun that could outlive SIGTERM needs `timeout-down`.**
  Anything holding a tty, a login session, or a shell child is in that
  category. Nothing else may be allowed to hang stage 3.
- **`/etc/acpi/PWRF/00000080` and `/etc/acpi/LID/00000080` are named by
  busybox acpid's compiled-in table**, not by us. Rename either and
  acpid runs nothing — silently, with the button back to doing nothing.
- **`power.lid` / `power.button` have no converger and no observer.**
  `novi-power` reads them at event time, so they cannot drift and
  `apply` has nothing to do. But that also means `converge_key` never
  runs to reject a typo, so the *observer* reports an unusable value as
  `unsupported` — permanent drift the machine cannot fix, which is the
  truth. Any future read-at-use-time key needs the same treatment.
- **The power button stops being delivered after an S3 resume in
  QEMU**, and it is not ours: acpid keeps the same PID and fds, reading
  the evdev node directly returns 24 bytes before the suspend and 0
  after, and `/sys/firmware/acpi/interrupts/ff_pwr_btn` shows the
  status bit latched (`EN` → `EN STS`) with the counter not
  incrementing. Do not "fix" this by restarting acpid on resume — the
  event never reaches the input layer at all.

## Architecture: an idle machine, and a resume nobody has seen

RFC 0035 (`docs/rfcs/0035-idle-suspend.md`). `power.suspend =
<seconds> | off`, read at use time by novi-shell on the idle tick it
already had for `power.blank`, spawning `novi-power suspend`.

- **OFF by default, where `power.blank` is 600.** Turning a display
  off is undone by moving the mouse; suspending is undone only by a
  working wake path on hardware nobody here has tested.
- **The idle clock is reset AT THE TRIGGER, not after the resume**,
  and this is the whole bug the feature is about. The compositor's
  clock does not advance while the kernel is frozen, so on resume
  `idle_ms` is still over the threshold and the very next tick
  suspends again — a machine that cannot be woken, from code that
  reads correctly. Resetting first also removes the need for an
  "already suspending" latch: the threshold is the debounce.
- **`power.suspend.lock` is ON by default**, the opposite call from
  `power.suspend` itself: an idle suspend is by definition the one
  path that fires with nobody standing over the machine. And it WAITS
  FOR THE LOCK SURFACE TO MAP — spawning novi-lockscreen and freezing
  in the same breath is a race the machine loses, because the resume
  then shows the desktop for as long as the client takes to come up,
  which is the whole thing the lock was for. `server->locked` already
  flips on map, so there is a real answer to wait on.
- **If the lock screen does not appear it does NOT suspend**, and
  logs why. "Lock, then suspend" done without the first half is not a
  degraded version of it — it is the one outcome the key exists to
  prevent. A machine left awake is recoverable by anyone who walks up
  to it; one that suspended unlocked is not. The retry is a full
  timeout away, or a broken lock screen writes a log line every five
  seconds forever.
- **A LID-CLOSE SUSPEND LOCKS NOW** (RFC 0035 roadmap 1), and what
  unblocked it was publishing rather than guessing. novi-power runs
  from acpid on a machine that may have no compositor, and locking
  means starting a Wayland client — so **novi-shell publishes
  `/run/novi/display`** (`WAYLAND_DISPLAY`, `XDG_RUNTIME_DIR`,
  temp-and-rename, unlinked on a clean exit). A base tool assuming
  `wayland-0` is the split-brain that item was left open for; the file
  is either there and authoritative or absent, and absent means there
  is nothing to lock.
- **`power.lid.lock` SUSPENDS EITHER WAY, and `power.suspend.lock`
  does not. That is why they are two keys.** An idle suspend fires
  with nobody there, so refusing without the lock costs a machine left
  awake on a desk, which anyone walking up to it can fix. A closed lid
  is a machine in a BAG: refusing there trades a shoulder-surfing risk
  for a thermal one on hardware nobody can see, which is the failure
  RFC 0013 handled the lid for in the first place. It waits ~6 s and
  then sleeps regardless, saying in the log which happened.
- **It waits for the COMPOSITOR's `locked 1`, not for the process to
  exist.** novi-lockscreen refuses to run at all without a password,
  and a running-but-unmapped client is the same race novi-shell's own
  suspend path waits out. Only the lid path locks — a power button is
  pressed by somebody standing there.
- **A machine with NO PASSWORD never idle-suspends** with the lock on,
  and that is two correct behaviours composing into a surprising one:
  novi-lockscreen refuses to run without a password (a lock nobody can
  open is an unusable machine) and the compositor refuses to suspend
  without the lock. The live image is exactly that machine. Verified
  both ways — no password: three ticks of waiting, one ERROR, no
  suspend, retried a full timeout later; after `passwd root`: the last
  frame before the machine went down is the lock screen, and the next
  poll found the guest suspended.
- **QEMU's q35 has disabled S3 since 6.1**, so `mem` falls back to
  s2idle: the vCPU halts with no ACPI wake path and QMP
  `system_wakeup` has nothing to inject. `mkvm.sh` passes `-global
  ICH9-LPC.disable_s3=0` now, after which `/sys/power/mem_sleep` reads
  `s2idle [deep]`.
- **And the resume STILL does not complete under TCG.** Measured
  rather than assumed: 258 non-black pixels of console before the
  suspend, 0 after `system_wakeup`, 0 more after typing six characters
  at the emulated keyboard, while QEMU reports the VM "running". This
  container has no `/dev/kvm`.
- **The check that made that finding usable was running the SAME
  suspend from a console with no compositor**, which behaves
  identically. Without it the honest reading was "this feature wedges
  the machine", and the fix would have gone to something that was not
  broken. **When a new feature appears to break the machine, run the
  thing underneath it on its own before believing the feature did it.**
- **"Nothing happened" proves nothing on a guest that never resumed.**
  A 25-second observation that the machine did not re-suspend looked
  like proof of the reset above and was worthless: a wedged guest also
  does not re-suspend. That claim is reasoning from the mechanism now,
  and says so.

## Architecture: two ways a check can lie about a build

Both of these cost real time in one session, and both produced output
that read as success.

- **`bash build/NN-foo.sh` FOR A STAGE NUMBER THAT DOES NOT EXIST
  PRINTS ONE LINE, AND A PIPED GREP EATS IT.** novi-shell is
  `07-novi-shell.sh`; `12` is novi-screenshot. Running
  `bash build/12-novi-shell.sh 2>&1 | grep -E 'error|warning|installed'`
  produces NOTHING — the shell's own "No such file or directory" does
  not match the pattern — which is exactly what a clean build looks
  like. The stale binary beside it then had the right size and an
  old timestamp nobody read. **Check the artifact for the thing you
  changed** (`strings … | grep -c` for a new literal), not the
  command's silence: the same rule this file already states about
  hardening flags, one level out.
- **`pkill -f <pattern>` MATCHES THE SHELL RUNNING IT.** A compound
  command that mentions the pattern anywhere — even in a later
  argument — kills itself, and the harness reports exit 144 with the
  rest of the command silently not run. It also makes `pgrep -f qemu`
  answer "alive" about a VM that died hours ago, because the match is
  the grep's own command line. Use `pkill -x` on the binary name, or
  check `ps -p` on a pid you captured.

## Architecture: "up" is not "working"

RFC 0014 (`docs/rfcs/0014-service-health.md`). `s6-rc -a list` saying a
longrun is up means *supervised and wanted up*, and that has now hidden
four bugs (syslog and the network readiness race in RFC 0004,
wpa_supplicant in RFC 0009, acpid after a resume in RFC 0013) — every
one of them on a machine `novi-state diff` called converged.

- **`novi-state health` answers this; `diff` deliberately does not.**
  Two reasons, and the second is the important one. (1) A longrun that
  has just started is indistinguishable from one that keeps dying, so
  folding this into `observe_service` would make boot convergence
  restart the service it just started — RFC 0004's race, from a new
  direction. (2) A crash-looping service *matches the document*: it is
  declared on and the engine is keeping it up. Drift means "apply can
  fix it", and `apply` cannot fix a bug in a run script — so `diff`
  would never reach zero on that machine and the drift signal would
  become useless for everything else.
- **`s6-svstat -o up,wantedup,ready,updownfor` and `s6-svdt` are the
  primitives**, and both shipped with s6 from the start — nothing had
  ever called them.
- **The death tally alone is not the signal.** A service that died once
  last week and has been up since is fine. It is the tally *together
  with* the current run's length: `CRASHLOOP` is deaths > 0 and up for
  under 60s.
- **`NOTREADY` is the RFC 0004 syslog bug as a category**: up for over
  60s having never signalled the readiness it declares.
- `diff` and `boot` print a note without changing exit status. The boot
  check is deliberately incomplete — it runs seconds after `s6-rc
  change` returns, so a service about to crash-loop may not have died
  yet. It reports what is already true, not what is about to be.

## Architecture: something finally reads the health signal

RFC 0014 built `novi-state health` and **nothing read it for the rest
of the project's life** — the roadmap listed "something should consume
this" from the day it shipped, and it survived every round of work
since, including several that went looking for gaps. `init/services/health`
is that consumer.

- **A service, not a panel timer.** The check forks `s6-svstat` and
  `s6-svdt` once per supervised service — about twenty processes. That
  is nothing at a shell prompt and far too much on a Wayland client's
  event loop, which novi-panel repaints from once a second. So the same
  arrangement RFC 0009 uses for the network interface: the service does
  the work and publishes to `/run/novi/health`, the panel reads a file.
  A second observer written in C inside a client is the parallel truth
  novi-state exists to abolish.
- **Polling is safe here, and that is a property of the checker rather
  than luck.** `service_health()` will not say CRASHLOOP unless a
  service has actually died, nor NOTREADY until it has been up a minute
  without signalling readiness it declares. So a 30-second sample
  cannot catch a healthy service mid-start and call it broken — which
  is precisely the mistake this whole feature exists to stop making.
- **The file is written to a temp name and renamed.** A reader on its
  own schedule must never see half a line.
- **The service declares no `notification-fd`.** Nothing observes its
  readiness, and declaring one it never signals would make it NOTREADY
  to its own check after sixty seconds. RFC 0015 found exactly that
  firing on every service that never declares readiness.
- **A toast on the TRANSITION, an indicator while it is true.** The
  toast says "this just happened"; re-announcing an unchanged problem
  every thirty seconds is how a notification stops being read. Normal
  urgency, not critical — critical never expires (RFC 0024) and the
  persistent signal is the panel's job.
- **The indicator was deliberately not clickable**, unlike the two
  buttons beside it, for as long as there was no service UI to open --
  and a panel item that opens a terminal is not a thing this desktop
  does. **There is somewhere now**: `novi-settings --panel session`
  (RFC 0036 roadmap 4), which shows the failing service names from the
  same one-line file. The health glyph and the coffee cup both open
  it; the bell and the speaker deliberately still do not, because the
  bell already has a key that goes where it leads and the speaker has
  no audio panel yet.
- **Recovery is not instant, and a test that expects it to be is
  wrong.** A service that has just come back from dying reads
  CRASHLOOP for sixty seconds by design, so the indicator clears about
  a minute and a half after the fix, not immediately. The first
  recovery test waited 36 seconds, saw `degraded`, and would have been
  read as the indicator sticking forever.

## Architecture: the native toolchain

RFC 0015 (`docs/rfcs/0015-native-toolchain.md`). `pkg install
novi-devel` puts gcc, binutils, make and the musl headers on a running
Novi, which compiles and runs its own C and C++.

- **Cross-native is not cross.** `02-toolchain.sh` builds
  `--host=this-machine --target=novi`; `28-native-toolchain.sh` builds
  `--build=this-machine --host=novi --target=novi`. Hence
  `--with-sysroot=/` (baked in — on the machine running this compiler
  the root filesystem *is* the sysroot) with
  `--with-build-sysroot=${SYSROOT}` (where those headers live here), and
  `--disable-bootstrap` (a bootstrap has to *run* the compiler, and
  these binaries do not run on the build host).
- **`depends=` in a MANIFEST is COMMA-separated.** `pkg` splits it with
  `tr ',' '\n'`. `mkpkg`'s header comment said spaces for a long time,
  and a package written from it built fine, indexed fine, and failed at
  install naming the whole list as one imaginary package. `mkpkg` now
  rejects a space in `depends` outright — same argument as the index
  format forbidding `|` rather than escaping it.
- **musl's linker searches `/lib:/usr/local/lib:/usr/lib` and nothing
  else.** GCC installs its runtime libs to `/usr/lib64`, so
  `libstdc++.so.6` shipped where nothing looks: C worked perfectly and
  C++ died at exec. Anything installing to `lib64` on this target needs
  moving.
- **`--disable-gprofng`** — it calls `fopen64`/`fseeko64`/`ftello64` and
  musl 1.2.4 dropped the LFS64 aliases. Same breakage as e2fsprogs in
  RFC 0008; not worth a patch for a profiler nobody asked for.
- **The toolchain is packages, never the base image** (~270 MB
  installed, 98 MB compressed). It ships in the repository on the ISO
  because until a repository is published that medium is the only
  mirror there is.
- **`pkgconf`, not freedesktop pkg-config**, and installed under both
  names — every `configure` script looks for `pkg-config`. pkgconf is
  plain C where the original wants glib. Its `--with-pkg-config-dir` /
  `--with-system-libdir` must be set to the TARGET's paths at configure
  time, or it bakes in the build host's prefix and finds nothing on the
  machine that runs it — the same class of mistake as binutils'
  `--with-sysroot`.
- **Headers and `.pc` files are a package (`novi-headers`), not base
  content.** The split had been moving libwayland/libinput/libwlroots
  out and leaving 5.6 MB of their headers behind, describing an API the
  console-only base could not link against even in principle. They now
  go through `DATA_FILES` in `pkgsplit.py`, and `novi-devel` depends on
  them — so a compiler and something to compile against arrive
  together. One package rather than a `-dev` per library is deliberate
  coarseness; doing it properly means deriving ownership from each
  `.pc` file's `-lfoo`, not hand-maintaining a second table.
- **"Novi can compile C" is not "Novi can rebuild itself."** That needs
  autotools, git, Python and a kernel build, none of which are packaged.
  Do not overstate this one.

## Architecture: the clipboard, and what a selection anchor means

`common/clipboard.c` is the whole of it — core-Wayland
`wl_data_device_manager`, which novi-shell already creates. No new
protocol: copying in foot and pasting in novi-edit only works if both
ends speak the standard thing, and they do.

- **Pasting what you yourself copied never goes near the wire.** It
  cannot: answering our own `wl_data_offer` means our own `send`
  callback has to run, and that needs the event loop we would be
  sitting inside, blocked on the pipe. That is a deadlock, not a slow
  path, which is why the module keeps its own copy of what it put on
  the clipboard and returns that.
- **A selection dies with the process that owns it — so novi-shell
  keeps a copy.** That is the protocol, not a bug in any client: copy in
  the editor, close the editor, paste anywhere, and on a bare Wayland
  desktop you get nothing. The two fixes are a manager speaking
  `zwlr_data_control_v1` or the compositor holding the text; novi-shell
  does the second, because the seat is already there and a clipboard
  buffer is not UI, so RFC 0001's "UI belongs in a client" rule does not
  reach it. It watches `seat->events.set_selection` (the selection
  having *changed*, including to nothing — not `request_set_selection`,
  which is a client asking), keeps up to 1 MB of text, and re-offers it
  as a compositor-owned source when the selection empties.
- **Neither half of that may block**, and both are on the compositor's
  own event loop for it. A blocking read from a client's pipe freezes
  every window on the screen; so does a blocking write of a megabyte
  into a 64 KB pipe whose reader is slow. That is most of the length of
  the code.
- novi-launcher's symbol picker still stays resident after its window is
  gone (`novi_clipboard_serving()`), and should: persistence hands the
  text over when the owner *exits*, which is not a reason to exit before
  the compositor has read it.
- `flush` before closing our end of the paste pipe: the fd is handed to
  the compositor when the request actually goes out, not when it is
  queued.

**Every mutation of the document drops the selection**, and that is an
invariant, not tidiness. An anchor is a position in the document as it
was when the selection started, and every routine that reads a
selection indexes `lines[]` with it. Undo restored a *shorter* document
without clearing the selection; the anchor kept pointing at a line that
no longer existed; the next `^C` read off the end of `lines[]` and the
editor died with `SIGSEGV addr=0`. The same anchor left live while
typing also made a phantom selection that grew one character per
keystroke. `sel_active()` additionally range-checks the anchor, so the
next way of getting this wrong shows up as "nothing is selected"
instead of as a crash.

The crash was found by giving novi-edit a temporary SIGSEGV handler
that printed a breadcrumb, booting it, and reading the screendumps —
one of which showed the phantom highlight on a line index that no
longer existed. Two rounds of reasoning about the code had failed to
find it. **When a GUI bug survives careful reading, screenshot it.**

## Architecture: a compositor answers when the client is ready

`zxdg_decoration_manager_v1` arrives *before* the client's first commit
— that is the correct order, and foot and everything else do it. But
answering it means sending a configure, and a configure cannot go to an
xdg_surface that has not been committed yet: wlroots logs `A configure
is scheduled for an uninitialized xdg_surface` and drops it.

That fired on **every window this compositor ever opened**, and nothing
looked broken, because the mode is re-sent with the real configure at
initial commit and clients end up server-side decorated anyway. Which
is exactly what made it worth fixing: a per-window ERROR that means
nothing is how a log stops being read — the same argument as `/init`'s
twenty-two meaningless `Could not load module` warnings a boot.

`server_new_xdg_decoration()` now holds the answer in a small
per-decoration struct with a `surface.commit` listener and gives it once
the surface is initialised. Any future compositor-to-client reply has
the same constraint: **before the initial commit there is nobody to
configure.**

## Architecture: installation splits `grub-install` in half

RFC 0003 (`docs/rfcs/0003-installation-and-persistence.md`). The installed
userland is a static BusyBox with no GRUB tooling, so `packages/novi-install`
cannot run `grub-install`. The work is split by what actually needs a build
host:

- **Generate** (`scripts/mkiso.sh`, build host): `grub-mkimage` produces
  `core.img` with the prefix `(hd0,msdos1)/boot/grub` baked in; that plus
  `boot.img` and the i386-pc module set are staged into `/novi-boot` on the
  ISO.
- **Place** (`packages/novi-install`, target): `dd` `boot.img` into the MBR's
  first **446** bytes (never 512 — 446..509 is the partition table you just
  wrote), `dd` `core.img` from sector 1, `cp` the modules to
  `/boot/grub/i386-pc`.

The baked-in prefix is a real coupling between the two scripts: it fixes MBR
partitioning, partition 1, and GRUB under `/boot/grub`. Changing the layout
means regenerating `core.img`, not just changing the installer.

Three things worth knowing before touching this:

- **The partition starts at sector 2048 to create the post-MBR gap**, not for
  alignment aesthetics. `core.img` (~278 sectors) lives in sectors 1..2047.
  `novi-install` refuses to write a `core.img` that doesn't fit rather than
  discovering the overlap later as filesystem corruption.
- **`/init` has two boot paths now**, and they share one
  `finalize_and_switch()` for the handoff (move `/dev`,`/proc`,`/sys`,`/run`,
  mount `/tmp`, find init, `switch_root`). The disk path is taken when `root=`
  is present and `boot=live` is not. That guard is load-bearing: the ISO's own
  menu entries pass *both* `boot=live` and `root=live:/dev/disk/by-label/NOVI`,
  so without it a live boot on a machine with Novi installed would take the
  disk path.
- **Bind-mount `/run/live` AFTER `mount --move /run /newroot/run`, never
  before.** Binding first and then moving the initramfs's own `/run` on top
  buries the bind — the mount still exists, nothing can reach it, and
  `/run/live` simply doesn't exist in the booted system. That was live for as
  long as the bind had existed and nothing noticed, because nothing needed the
  live media after boot until the installer did.

The installer sets the target's hostname with `novi-state set` (via
`NOVI_STATE_FILE`), not `sed` — same reason as everything else: `state_set`
is the one edit that preserves the document's comments and ordering.

## Architecture: a static address, and a resolver with two writers

RFC 0033 (`docs/rfcs/0033-static-addressing.md`). `network.address =
192.168.1.50/24` and `network.gateway`. Before this the network
service ran `udhcpc` unconditionally, so a machine on a segment with
no DHCP server could not be given an address by the document at all.

- **It is a MODE of the existing service, not a second service.**
  `network.address = dhcp` (the default, and what an absent key means)
  execs udhcpc; a CIDR configures the interface here. One service,
  because RFC 0009's `pick_interface()` already answers "which
  interface" and a second implementation of those rules would drift —
  the panel-indicator mistake again.
- **`network.dhcp` now names the SERVICE, not the protocol.** A
  machine can have `network.dhcp = on` and run no DHCP client. The key
  predates static addressing; renaming it would silently ignore the
  key in every `system.conf` already committed to a repository, which
  is worse than a name that needs one sentence of explanation. Both
  `system.conf` and novi-state's key list carry that sentence.
- **A bare address is REFUSED, never assumed to be /24.** The prefix
  decides which hosts this machine believes are local, and the failure
  from guessing is not an error — it is a machine that reaches some
  destinations and not others.
- **The validator is pedantic because the value becomes an argument to
  `ip addr add`.** Four octets exactly; a leading zero rejected (`010`
  is eight to an octal reader and ten to a decimal one); and **a
  leading dot rejected explicitly, because field splitting DROPS the
  empty field it produces** and a naive four-octet count passes
  `.1.2.3`. All textual, none of it needs a machine — so it is a host
  test (`packages/tests/test-network-static.sh`, 40 checks).
- **`/run/novi/resolv.conf` has ONE writer now**
  (`/usr/lib/novi/resolv.sh`), shared by the lease script and the
  static path. The rule — a declared `network.dns` beats the lease,
  `auto` asks for the lease's answer — is a policy, and the static
  path's first draft had its own copy that had already lost the
  `search` line. Same argument as `json.sh` being the one escaper, and
  the same `[ -f ... ]` guard, because `.` is a special builtin.
- **It returns non-zero when nothing supplied a server, AND writes the
  file anyway.** With a static address there is no lease, so
  `network.dns = auto` — the shipped default — means no resolver at
  all; the service says so on startup. Writing nothing instead would
  leave a stale resolver from the previous configuration looking
  current.
- **`exec sleep infinity`, not `tail -f /dev/null`.** A static address
  is held by the kernel: there is nothing to supervise, but a longrun
  whose run script returns is one s6 restarts forever. `sleep
  infinity` is one nanosleep and zero wakeups; busybox `tail -f` polls
  once a second forever for a file that will never change.
- **`init/services/network/finish` is not optional.** udhcpc's `-R`
  cleans up after itself; a static address is held by the kernel and
  nothing removes it — so `network.dhcp = off` left the machine still
  answering on its address, and switching back to `dhcp` left the old
  address beside the new lease with `diff` reporting converged. It
  reads the spec the service PUBLISHED, not the declared value: by the
  time a stop happens the document may say something else, and what
  must come off is what actually went on.
- **`/run/novi/network.ip` finally has a reader.** The lease script had
  always written the held address and NOTHING had ever read it. It is
  `novi-agent describe`'s `address` field now — "what did you declare"
  and "what is on the wire" are different questions, and an agent
  asking a machine what it is wants the second.
- **THE WIRED HALF WAS NEVER "a text file", and RFC 0033's own
  roadmap said it was.** The System panel lists every declared key and
  edits values inline, so `network.dhcp`, `.interface`, `.address`,
  `.gateway` and `.dns` have been reachable from the GUI since that
  editor landed — five consecutive rows, screendumped. A Wired section
  in the Network panel would be a second write path to keys the GUI
  already reaches: RFC 0029 decision 10's test, which `firewall.allow`
  failed for the same reason. The WiFi panel is not the counter-example
  it looks like — it exists because a passphrase is deliberately not a
  `system.conf` key, so there was no other path. **Third roadmap item
  in this repository found to be wrong about what is already built**,
  after RFC 0002's `packages.*` and RFC 0030's "a re-render is not one
  function call". Check the code before believing an item.
- **IPv6 IS TWO KEYS, NOT ONE THAT TAKES BOTH FAMILIES** (RFC 0033
  roadmap 1). Forced rather than chosen: dual-stack is the ordinary
  case, so a machine has to declare a v4 address AND a v6 address at
  once, and one key whose meaning depends on the shape of its value
  could only express one. The vocabulary differs deliberately --
  **there is no `dhcp`**, because DHCPv6 is a different protocol the
  shipped client does not speak, and a word that reads as supported
  and does nothing is worse than its absence. `auto` is SLAAC, which
  the kernel does unaided.
- **THE v6 SETUP RUNS BEFORE THE DHCP BRANCH, and that placement is
  the whole reason dual-stack works.** `exec udhcpc` never returns, so
  anything after it runs only on a machine with a STATIC v4 address --
  the v6 keys would have been silently ignored on every DHCP machine.
  `./finish` has the same shape from the other end: it checks the v6
  half first and separately, because a machine on DHCPv4 with a
  declared `address6` reaches it with `ADDRSPEC=dhcp` and the v4
  early-exit would have skipped the v6 cleanup.
- **A SYSCTL OUTLIVES THE PROCESS THAT SET IT**, so `auto` sets
  `disable_ipv6=0` and `accept_ra=1` rather than doing nothing. Without
  it a machine that went `none` → `auto` reports converged with IPv6
  still dead -- the bug `./finish` exists to prevent on the v4 side.
  And the flush is BY SCOPE -- global AND site -- because flushing
  every v6 address takes the LINK-LOCAL with it, which the kernel
  generated and neighbour discovery needs. `scope global` alone was
  the first version and left a SLAAC address behind on a booted
  machine: slirp advertises `fec0::/64`, deprecated site-local, which
  the kernel labels `scope site`. Two answers on the interface is the
  thing turning advertisements off is meant to prevent.
- **THE HAND-WRITTEN CASE LIST IS NOT THE VERIFICATION.** `ip addr
  add` parses with `inet_pton`, so `inet_pton` is the oracle, and
  comparing against it found two real bugs the list had missed
  (`1.2.3.4::` and `::1:`, both accepted). The corpus is GENERATED --
  every group count with a `::` at every position, dotted quads in
  every position, colon torture -- 3530 cases, zero disagreements.
  Provoking each rule then found ONE GUARD THAT COULD NOT FIRE: a
  second `::` in the tail is already refused by the empty-group rule,
  so that check was dead code reading as load-bearing, and was
  removed.
- **Leading zeros are FINE in v6 and not in v4.** `0001` is 1 to every
  reader because hex has no octal convention, so `valid_ipv6` must not
  inherit `valid_ipv4`'s rule -- which is why they are two functions
  and not one with a branch. A test provokes exactly that mistake.
- **`novi-state apply | tail -5` reports `tail`'s status.** A refusal
  test read `exit=0` from that pipeline and nearly concluded `apply`
  swallowed the failure; it exits 1. This file already records the
  same trap from a build stage — that is twice.

## Architecture: services, readiness, and the log

RFC 0004 (`docs/rfcs/0004-networking-and-system-logging.md`). Three traps
here, all of which cost real time and all of which generalize past the
services that hit them:

- **s6-rc's "up" for a longrun means "supervised and wanted up", not
  "running".** A service that dies on every start still shows in
  `s6-rc -a list`. That is how `syslog` crash-looped invisibly for as long
  as it existed: its `run` passed `s6-log -d3` ("notify readiness on fd 3")
  while the service declared no `notification-fd`, so fd 3 was closed and
  s6-log could never notify. Never conclude a service works from
  `s6-rc -a list`; check that it did its job.
- **A longrun anything else observes needs `notification-fd`.**
  `s6-rc change` returns as soon as a longrun is *started* otherwise, and
  `rc.init` runs `novi-state boot` the moment it returns. `network` without
  a readiness notification lost that race: convergence observed
  `network.interface` as `unknown`, called it drift, and restarted the
  service it had just started — **burning a generation on every boot**.
  Generations must mean "the system actually changed here".
- **`s6-log` is a per-service logger, not a system log daemon.** It reads
  its *stdin*; as a standalone service with no producer it is a log file
  with no writers (a zero-byte `current`, forever). `syslog` now runs
  BusyBox `syslogd` (owns `/dev/log`, writes `/var/log/messages`) and
  `klog` runs `klogd`.

Two smaller ones:

- **No `-C` on syslogd.** With `-C` BusyBox syslogd logs to a SysV shm ring
  *instead of* the file, and this kernel has no `CONFIG_SYSVIPC` — so
  logging silently goes nowhere. Verified: `logread` → "can't find syslogd
  buffer: Function not implemented".
- **`modprobe` the dependency modules by name before the drivers that need
  them.** `modprobe virtio_net` alone left eight `Unknown symbol
  net_dim / net_failover_create (err -2)` lines per boot from racing load
  attempts, despite a correct `modules.dep` and a driver that ended up
  working.

The DHCP hook writes the resolver to `/run/novi/resolv.conf`
(`/etc/resolv.conf` is a symlink to it) and never touches the hostname: a
lease is runtime state, and the hostname has exactly one writer,
`novi-state`.

## Architecture: re-running a build stage must be safe

RFC 0005 surfaced two bugs of the same shape, and the shape is the point:
**a stage that is correct in `01..05` order can be destructive on a re-run,
and both of these produced images that failed at boot with no build-time
signal at all.**

- `03-base.sh`'s "strip everything" pass ran `--strip-all` over every ELF in
  the rootfs. On a `.ko` that removes `.symtab` and the module becomes
  permanently unloadable. Harmless on a clean build (no modules exist yet);
  on a re-run after `05-kernel.sh` it kills every module in the image — all
  22 `modprobe` calls in `/init` failed, including `virtio_blk`, so no
  `/dev/vda`, no live medium, PANIC. `/lib/modules` is now excluded.
- BusyBox's `make install` creates `/sbin/init` → busybox. `04-s6.sh` deletes
  it before installing s6-linux-init, so ordering saved a clean build; a
  re-run of 03 handed PID 1 back to BusyBox and the next boot died with
  "can't run '/etc/init.d/rcS'". Stage 03 now removes that symlink at the
  source, and `16-s6-rc-db.sh` checks `/sbin/init` and repairs it.

A third case, the mirror image of those two: **a stage can be correct in a
warm tree and broken from scratch.** `novi-launcher` (stage 08) links
`fcft`, which stage **09** built. Its Makefile said so out loud — "all
already built for foot (build/09-foot.sh), no new dependency" — which
was true in the tree it was written in and false in build order. A
genuinely clean `bash build.sh` stopped at stage 08 with
`cannot find -lfcft`, and nothing noticed because building from an
empty `/build` is rare and CI compiles nothing. The font libraries now
live in `06-wayland.sh` with the rest of the shared stack: a library
more than one client links belongs in the library stage, not inside
whichever application happened to need it first.

So when touching any build stage, ask both questions: what does it do to
artifacts a *later* stage owns (`--from NN` exists and people use it),
and does it depend on anything a later stage produces? The second is
invisible in every tree except a clean one.

**A stage that cross-compiles a client calls `require_desktop_headers`
first** (`build/00-versions.sh`). 51-desktop-split.sh removes the
headers, so in any tree where a full build has run, rebuilding one
client stops with four "No such file or directory" lines and no clue.
The line it prints instead names `scripts/restore-build-inputs.sh`.
That guard exists because chaining a rebuild into `50-repo.sh` without
checking it succeeded packaged a rootfs with no desktop in it, and
51-desktop-split.sh then deleted from the base exactly what that empty
manifest described — no desktop in the image AND none in the
repository. **Never chain `50-repo.sh` after an unchecked build.**

**`50-repo.sh` now REFUSES to run on an already-split rootfs**, and that
guard exists because the comment above did not stop it happening.
pkgsplit computes the desktop from what is *in* the rootfs, so running
50 after 51 has taken the desktop out asks a question whose honest
answer is "nothing leaves the base": an empty manifest, a repository
holding one meta-package, and a 95 MB-smaller ISO with no desktop
anywhere — no error, because an empty answer is a valid answer.
`bash build.sh` never trips it; re-running stages by hand does. The
recovery is the stages, in order: **`bash build.sh --from 06 --to 49`,
then `bash build.sh --from 50`.**

**That range used to say `--to 29`, and it silently shipped a broken
desktop.** Content stages grew past 29 — novi-notifyd and novi-bg are
36, novi-glinfo is 37 — so `--to 29` rebuilt most of the desktop and
none of those, and the split stage had already deleted them from the
rootfs. The
repository came out with 51 packages instead of 54, and **the
`novi-desktop` meta-package's derived `depends=` simply omitted the
three that were missing**: no error, because pkgsplit's META_PACKAGES
check asks "is every OS package named by some meta-package", which is
the opposite question. `pkg install novi-desktop` would have reported
success and produced a desktop with no wallpaper and no notifications.
Count the packages (`ls /build/repo/*.pkg.tar.gz | wc -l`) after any
hand-run recovery — **55 as of `fonts-source-serif`; the 54 above is
what that incident's repository should have held, not a number to
check against today.** A count written down is a number that rots the
moment somebody adds a package, so treat it as "the same as last
time", never as a constant. And **when a stage number is written into
a document, the document is now something that can rot** — this line
did, and so did the identical line inside `50-repo.sh`'s own
already-split guard, which is the copy someone actually follows
because they are already in trouble when they read it. Both name the
whole content range now (`--to 49`) rather than the highest stage that
happens to exist, which is what stops this particular line needing an
edit every time a stage is added.

pkgsplit refuses an absent member instead of dropping it, and that
check has a **host test** (`tools/pkgsplit/test_pkgsplit.py`, run by
`scripts/lint.sh`) rather than only an error message nobody has seen.
That split exists for a specific reason: provoking it for real costs
a full content rebuild, because 50 wipes the repository before
pkgsplit runs *and* refuses outright on an already-split rootfs — so
"break it and watch" is a ninety-minute experiment. The test was
confirmed by reverting the function to the old silent filter and
watching it fail.

**`--from 06 --to 49` DOES NOT REBUILD A BASE SCRIPT.** The recovery
range above is about the desktop, and `packages/novi-power`,
`novi-state`, `novi-wifi`, `novi-mount`, `pkg` and the rest of the
base userland are installed by stages BELOW it — `novi-power` by
`03-base.sh`, at `install -D -m 755`. So editing one of those scripts
and then following the documented recovery ships the OLD copy, and the
symptom is not a build error: `novi-power idle` printed the usage text
for a subcommand that was right there in the repo. The compositor half
of the same change was live in the same image, which is what makes it
confusing — one half of a feature updated and the other silently not.
Re-run the stage that owns the file (`bash build/03-base.sh`, then
`16-s6-rc-db.sh`, which exists to repair `/sbin/init` after exactly
that), or check `grep -c <the-new-thing> /build/rootfs/usr/bin/<script>`
before believing a rebuild reached it.

**`restore-build-inputs.sh` does not give you a tree every stage can
run in.** It restores headers and `.pc` files, not target *binaries*
that live in packages — so `09-foot.sh` aborts at
`chroot ${ROOTFS} /usr/bin/fc-cache` with "No such file or directory",
because fontconfig's tools went out with the split. `set -e` catches
it correctly and the stage exits 127; the fix is a real
`bash build.sh --from 06 --to 49`, not a hand-copied binary. (That
127 was briefly misread as "the stage swallowed a failure" because
the command had been piped to `tail`, which is the pipeline's exit
status. **Check a stage's real status before accusing it of hiding
one.**)

**`restore-build-inputs.sh` launders stale files forward.** It restores
headers and `.pc` files *from the packages*, so anything that was in a
package once stays in every package built from that restored tree,
even after the stage that produced it stopped producing it. A clean
06..29 rebuild put 440 headers in `/usr/include`; the restored tree had
543. The clean number is the right one — treat a manifest that shrinks
after a real rebuild as a correction, not a regression.

**`50-repo.sh` WIPES `/build/repo`, so `52-toolchain-repo.sh` has to run
again after it.** `build.sh` gets this right because it runs the stages
in order; running 50 and 51 by hand and stopping does not. The only
symptom is an ISO that is 95 MB smaller and has no `novi-devel` in its
repository — no error, and nothing says which packages a repository
was *supposed* to contain. Check the size, or count
`ls /build/repo/*.pkg.tar.gz | wc -l` — **against what the last full
run produced, never against a number written here.** This sentence
said "(37, not 31)" for long enough that both numbers were wrong; the
count is 55 today and will be wrong again the next time somebody adds
a package.

**And do not repair a broken `/build` by hand.** Extracting packages back
over the rootfs to recover build inputs, then deleting what does not
belong with an ad-hoc `rm` loop, produces a tree nobody can reason
about — including an image that reached s6-linux-init and never started
stage 2, with no error anywhere, resisting several rounds of bisection.
Re-running the stages in order fixed it in one pass and would have been
faster from the start. The stages are the recovery mechanism; that is
what they are for.

## Architecture: HTTPS, and a correction about WPA3

RFC 0020 (`docs/rfcs/0020-https.md`). mbedTLS, curl and a Mozilla CA
bundle, **as packages** — no TLS *library* reaches the base image from
this work, which is the whole reason it was allowed.

- **RFC 0009 said mbedTLS was the way to WPA3. It is not, for
  wpa_supplicant 2.11.** That tree offers `CONFIG_TLS` values of
  openssl, gnutls, wolfssl, internal, linux and none, and
  `grep -rli mbedtls` over the whole tarball returns nothing. WPA3
  needed **wolfSSL**, which RFC 0021 then did. Both RFCs now say so;
  a wrong claim repeated in a roadmap is how the wrong work gets
  scheduled.
- **The CA bundle is hash-pinned, and it is only the second thing
  here that is.** The first is TweetNaCl, because it verifies package
  signatures; a CA bundle is a list of parties whose word is accepted
  about who a server is, so a modified one means every HTTPS
  connection is validated against a set somebody else chose. Pinning
  needs a *dated* `cacert-YYYY-MM-DD.pem`, not the rolling file.
- **curl refuses `--without-ssl` alongside `--with-mbedtls`** —
  "conflicting parameters". Naming the backend IS the exclusion.
- **`--build` must be given explicitly to curl's configure.** Its
  "checking run-time libs availability" test is guarded by
  `if test "x$cross_compiling" != xyes`, and with only `--host`
  autoconf did not conclude it was cross-compiling: it compiled a
  program, tried to *run* it, and failed the build with "one or more
  libs available at link-time are not available run-time" naming
  `-lmbedtls`. Name both triples.
- **`-Wl,-rpath-link` again**, and that is twice now (33-nftables.sh
  was the first). Linking git pulls in `libcurl.so`, whose
  `DT_NEEDED` names `libmbedtls.so.21`; `-L` alone gave five
  "undefined reference to `mbedtls_ssl_conf_ca_chain`" from a library
  that exports every one of them.
- **The proof that HTTPS verification works is a triple, not a
  success.** Untrusted certificate refused → the same CA appended to
  the bundle → the same clone succeeds → a self-signed certificate for
  the same name still refused. Any one of those alone cannot
  distinguish "verification works" from "nothing works".

## Architecture: git and ssh, and the blocklist that rotted

RFC 0019 (`docs/rfcs/0019-git-and-ssh.md`). `pkg install git` — over
ssh and locally, never https.

- **OpenSSH is built `--without-openssl`**, which is the only reason
  it is in this image at all (RFC 0006's argument for `novi-verify`,
  RFC 0009's for `CONFIG_TLS=internal`). The cost is ed25519 keys
  ONLY — no RSA, ECDSA, certificates, FIDO or PKCS#11 — and that is
  worth stating wherever this is described rather than leaving to be
  discovered against an old server.
- **git was built `NO_CURL=1`** and no longer is: RFC 0020 made the
  TLS decision on its own and git now has `https://` remotes through
  curl and mbedTLS, all three as packages.
- **`NO_REGEX=NeedsStartEnd`**: musl's `regexec()` has no
  `REG_STARTEND`. git's own `#error` names the exact flag, which is
  the kindest way an upstream can handle a libc difference.
- **`--without-zlib-version-check` is a cross-compile necessity.**
  OpenSSH's check compiles a program that calls `zlibVersion()` and
  *runs* it; cross-compiling it cannot, so it concludes "zlib too old"
  about zlib 1.3.1. Same shape as skalibs' run-time sysdeps: any
  autoconf test that must execute its own output is a wall.
- **OpenSSH 9.8 split the daemon.** `sshd` is only the listener now
  and execs `sshd-session` from a compiled-in `/usr/libexec` path;
  `make sshd` alone gives you a daemon that accepts a connection and
  dies with "sshd-session does not exist or is not executable". sshd
  is built here as the *test peer* and never installed — the hostapd
  bargain from RFC 0009.
- **`restore-build-inputs.sh` now restores what the MANIFEST names,
  not "every package except a blocklist".** The blocklist was correct
  until the repository gained a package that was neither desktop nor
  toolchain: `git` and `openssh` were cheerfully installed into the
  console base image, and the next `50-repo.sh` failed with pkgsplit's
  straddle check — `usr/lib/libz.so.1 stays, usr/lib/libz.so moves` —
  because a base binary suddenly linked zlib. The error was correct
  and pointed nowhere near the cause. `50-repo.sh` already writes
  `repo-desktop-files.list`; restoring exactly those paths is a
  derived answer that cannot rot, and a blocklist is one that has to
  be updated by whoever adds the next package, with nothing to tell
  them.

## Architecture: full-disk encryption, and BusyBox fdisk's default

RFC 0018 (`docs/rfcs/0018-full-disk-encryption.md`).
`novi-install --encrypt` makes a LUKS2 root; the initramfs asks for the
passphrase.

- **`CONFIG_CRYPTO_XTS` was the one hole.** `DM_CRYPT`, AES, AES-NI,
  SHA-256 and the AF_ALG user API were all set; XTS — the mode LUKS2's
  default `aes-xts-plain64` needs — was unmentioned, which means `n`.
  dm-crypt was present and could not have opened the container
  cryptsetup creates by default. Same shape as RFC 0016's
  `NF_TABLES_INET`.
- **`cryptsetup` is ONE STATIC BINARY**, and the four static libraries
  it links (`popt`, `json-c`, `libuuid`, `libdevmapper`) never reach
  `${ROOTFS}` — they live in `/build/crypt-deps`. Two reasons: the
  initramfs is a different root filesystem and a dynamic build means
  shipping a loader and a library list into it that can rot; and
  pkgsplit never sees a `.a` or a header it has no `PACKAGE_TABLE`
  pattern for. `34-cryptsetup.sh` **fails the build** if
  `cryptsetup.static` has a `PT_INTERP`.
- **The crypto backend is `kernel`** — AF_ALG. Every other backend
  cryptsetup offers is a library this image has refused to carry
  (OpenSSL, gcrypt, NSS, nettle), which is the whole argument for
  `novi-verify` in RFC 0006.
- **BusyBox `fdisk`'s default first sector for a new partition is 63**
  — the start of the disk — not the first free sector after the
  partitions that already exist, which is what util-linux offers and
  what anyone writing the keystrokes expects. Taking the default
  produced a partition 2 of 63..2047: 992 KB, overlapping the post-MBR
  gap. cryptsetup refused it with "keyslots area is very small" and
  "Cannot wipe header", naming neither the size nor the cause. Give
  every sector explicitly. **This class of bug is testable without a
  VM**: the shipped BusyBox is a static x86_64 binary, so
  `printf '…' | /build/rootfs/bin/busybox fdisk -u <12G sparse file>`
  reproduces it in a second.
- **The BIOS encrypted layout needs its own `core.img`.** The prefix is
  baked in at `grub-mkimage` time; `(hd0,msdos1)/boot/grub` is right
  when partition 1 IS the root filesystem and wrong when partition 1 is
  `/boot`. `mkiso.sh` generates `core-boot.img` with prefix
  `(hd0,msdos1)/grub` beside it.
- **Mount the boot partition BEFORE the ESP.** `/boot/efi` lives inside
  `/boot`; mounting the ESP first and the boot partition on top of it
  buries the ESP mount — the same shape as `/run/live` in RFC 0003.
- **`cryptsetup` flushes input when it takes the terminal**
  (`tcsetattr(TCSAFLUSH)`), so a passphrase typed in the same
  millisecond the prompt appears is discarded, echoed in the clear, and
  simply ignored. That is a *test harness* problem, not a product one —
  a person types seconds later — but it cost a debugging round: give an
  automated test a pause after the prompt.
- **`00-versions.sh` exports `SOURCES`, and that is a name makefiles
  use.** LVM2's `make.tmpl` has `OBJECTS = $(SOURCES:%.c=%.o)` and its
  top-level makefile never assigns it, so the environment came straight
  through and the build died with `make: *** /build/sources: Is a
  directory. Stop.` — naming our own export and no part of LVM2.
  `env -u SOURCES make …`. Any autotools tree with a plain `SOURCES`
  can hit this.

## Architecture: the panel's network indicator

RFC 0009's roadmap item, done. `novi-panel` shows wired / wifi with
signal bars / offline, and clicking it opens `novi-settings`.

- **`/proc/net/wireless` does not exist on this system.** It is
  created by cfg80211's wireless-extensions compatibility layer and
  `CONFIG_CFG80211_WEXT` is off — checked in `kernel/config-x86_64`,
  not assumed, because the failure mode is an indicator that silently
  shows no signal on every machine forever. nl80211
  (`NL80211_CMD_GET_STATION` → `NL80211_STA_INFO_SIGNAL`) is the
  interface that exists. libnl was already in the base image for
  wpa_supplicant, so this is a new *link*, not a new dependency, and
  pkgsplit leaves the library in the base and derives nothing extra
  for the package.
- **The panel reads the interface the service PUBLISHED, never its
  own walk of `/sys/class/net`.** `/run/novi/network.device` and
  `network.wifi.device` hold the resolved name each service actually
  chose (not the `auto` spec — that is `network.interface`, a
  different file for a different question). A second walk would be a
  second answer to a question that has one, and RFC 0009's
  `pick_interface()` has real rules (wired first; a radio is a
  `phy80211` link, not a name) that a panel reimplementing them would
  drift from.
- **`carrier`, not `operstate`.** `operstate` reports "unknown" for
  plenty of working interfaces. Reading `carrier` on an
  administratively down interface fails with EINVAL rather than
  returning 0 — the kernel refusing to guess — which lands as "no
  link", the right answer either way.
- **The netlink call is synchronous, with a 200 ms `SO_RCVTIMEO`.** A
  local kernel dump answers in microseconds, so this is not RFC 0017's
  situation (a child process taking seconds) — but it sits on the
  Wayland event loop, and "no reason to hang" is not a guarantee.
- **`novi-panel/icons.c` is pure geometry with a HOST test
  (`make -C novi-panel check`, run by `scripts/lint.sh`), and that
  split exists because of a specific blind spot.** The fan's lit-element
  mask is `(1u << bars) - 1u`; mac80211_hwsim reports −30 dBm and
  nothing else, so a live boot only ever draws four bars — and a mask
  bug draws four bars correctly anyway, since `0xF` is `0xF` however
  you got there. The host test renders every state and asserts the
  invariants; it immediately found the fan's origin dot being clipped
  flat by the icon box, which the live screenshot did not show.
- **Get the sign right on icon-local Y.** The RJ45 glyph's first
  version passed `cy + 1.5` where the SDF wanted a centre, drawing a
  perfectly clean jack upside down with its latch tab off the top.
  Screenshotting it is what found it — the repo's standing advice
  about GUI bugs, applied to a five-line function.
- **Battery is deliberately absent, not forgotten.** QEMU emulates
  none, so it could be written and could not be verified.

## Architecture: a GUI that runs something slow

RFC 0017 (`docs/rfcs/0017-wifi-in-the-desktop.md`). `novi-settings`'
Network panel scans, joins and forgets WiFi networks, and it is the
first client here that had to run a subprocess taking *seconds*.

- **The panel is a front-end to `novi-wifi` and `novi-state`, like
  every other panel.** It does not open `/etc/novi/wifi.conf`, walk
  `/sys/class/net`, or run `wpa_cli` — same argument as the System
  panel shelling out to `novi-state set`. Three verbs were added to
  `novi-wifi` for it: `add <ssid> --stdin`, `scan --tsv`, `iface`.
- **A passphrase goes down a pipe, never in argv.**
  `/proc/<pid>/cmdline` is world-readable for as long as the process
  lives.
- **`scan --tsv` puts the signal FIRST.** An SSID may contain spaces,
  so a trailing field cannot be found by counting from the left — the
  padded human table is unparseable for that reason, and a GUI parsing
  a table meant for people breaks the first time somebody puts two
  spaces in their router's name. Tabs and newlines in an SSID are
  dropped, not escaped (an SSID is attacker-controlled text off the
  air); same call the package index makes about `|`.
- **`job_start`/`job_pump` is the async runner**, and three details in
  it are load-bearing: the pipe's read end is `O_NONBLOCK` (a blocking
  second read sleeps until the child produces more — freezing the
  window for the length of the scan); the poll watches `POLLHUP` as
  well as `POLLIN` (a child that prints nothing and exits produces
  only a hangup, and waiting for `POLLIN` alone leaves the window
  saying "Scanning..." forever); and the main loop uses libwayland's
  `wl_display_prepare_read`/`read_events`/`cancel_read` protocol —
  `cancel_read` on **every** path that does not read, poll errors
  included, or the next `prepare_read` blocks forever.
- **`set_status` copies now.** It used to store the pointer, which was
  fine while every caller passed a string literal; this panel reports
  what a child process just said, from a buffer the next job
  overwrites.
- **The proof that the loop is not blocked is a panel switch mid-scan**,
  not a "Scanning..." label. The label is drawn synchronously by the
  keypress that started the job and would appear either way; a
  different panel rendering while the child is still running could
  not.

## Architecture: sshd, and the port that does not open itself

RFC 0022 (`docs/rfcs/0022-sshd.md`). `openssh-server` as a package,
`services.sshd`, and a second declared key for the hole.

- **The host key is generated on first start, in
  `init/services/sshd/run`, and exists nowhere in the image.** A
  distribution that ships a host key ships the same one to every
  machine that installs it — anybody holding the ISO can then
  impersonate any of them. Nothing in `novi.iso` and no package
  contains one. `ssh-keygen -A` is not used: this OpenSSH has no
  OpenSSL, so ed25519 is the only key type that can exist, and naming
  it beats printing two failures.
- **`network.firewall.allow` is a SEPARATE key from `services.<name>`,
  and that is the design, not an oversight.** Deriving the holes from
  the enabled services is one key instead of two and it is what people
  expect; it is also a firewall that opens itself because a daemon
  started, which is a service registry with a policy file attached.
  The set of things reachable from the network has to be one list a
  person chose.
- **The cost of that split is a machine you cannot reach and no
  explanation, so `novi-state` prints one.** It is *not drift* — both
  keys are exactly as declared, so `diff` cannot report it and `apply`
  cannot fix it. `firewall_hole_note()` says it from both commands.
  `LISTENING_SERVICES` exists only to produce that sentence; nothing
  in it opens anything.
- **Ports are numbers, never names.** `nft` resolves `ssh` through
  `/etc/services`, which BusyBox does not ship — a name would work on
  the build host and fail on the machine.
- **Declared and observed port lists are compared canonically**
  (sorted numerically per protocol), or `22, 80` would report eternal
  drift against `80,22` and `apply` would rewrite the same ports every
  run. When they match, the observer echoes the *declared* string back
  verbatim so the document's own formatting is never "corrected".
  Firewall off means the key is inert, not drifted — same call
  `network.interface` makes with the network service down.
- **`EARLY_KEYS` is `network.firewall network.firewall.allow`, in that
  order.** The ruleset reload empties the sets, so filling them first
  would fill sets that are about to be replaced.
- **`PermitRootLogin no`, not `prohibit-password`.** `/etc/shadow`
  ships `root::`. `PasswordAuthentication yes` is safe *only because*
  of what sits behind it, and the load-bearing half is not the one you
  would guess: **OpenSSH refuses a locked account outright, with a key
  too.** `allowed_user()` checks the `!` in shadow before any
  authentication method is tried, so an account novi-state created,
  owning a valid `authorized_keys`, gets `Permission denied
  (publickey,password)` until someone runs `passwd`. Verified live —
  it denied this RFC's own first test run. A freshly opened port 22
  therefore has nobody who can authenticate at all.
- **No `UsePAM no` in sshd_config.** Built `--without-pam`, sshd does
  not know the keyword and prints `Unsupported option UsePAM` on every
  start and every `sshd -t`. A line whose only effect is a warning
  about itself is worse than the absence it documented.
- **`exec sshd` is not enough: sshd re-execs itself and demands an
  absolute `argv[0]`.** `exec sshd -D -e` gave `sshd requires
  execution with an absolute path` once a second forever, from a
  binary whose `sshd -t` had just called the config perfect. PATH was
  fine (04-s6.sh puts `/usr/sbin` on it) — it is `argv[0]` sshd
  objects to.
- **A longrun that declares readiness must also declare
  `timeout-up`.** This service had `notification-fd` and none, so with
  the package absent its `exit 1` became a crash loop and `s6-rc -u
  change` waited FOREVER: `novi-state apply` hung, the console with
  it, and boot convergence would have hung the boot. `network` and
  `wifi` had always bounded it; this one broke the pattern. The
  corollary to "a longrun anything observes needs notification-fd".
- **A `sed` range whose start line also matches the end pattern does
  not end on that line.** `/elements = {/,/}/` ran on to the set's own
  closing brace, and a greedy `.*` captured `22 } ` — so the firewall
  observer called a perfectly correct set unparseable, `diff` reported
  permanent drift and `apply` rewrote the same port three times.
  `[^}]*`, not `.*`.
- **The service definition is base content; the binaries are a
  package.** s6-rc does not check that a run script's program exists,
  so it is inert until `pkg install openssh-server` — the seatd /
  novi-shell arrangement from RFC 0007.
- **Readiness means the host key exists**, not that a socket is bound.
  sshd says nothing when it starts listening, and claiming otherwise
  is the RFC 0014 mistake again. The host key is the one precondition
  anything else can race on.
- `sshd`, `/var/empty` and the UID are base content for the same
  reason `/etc/passwd` is repo content: a UID and a directory mode are
  baked into a squashed image, so they are build-time facts.

## Architecture: the firewall, and the exec the kernel could not make

RFC 0016 (`docs/rfcs/0016-declarative-firewall.md`). `network.firewall
= on` in `system.conf`, one policy file at `/etc/novi/firewall.nft`,
converged by `novi-state` — no daemon, because the kernel holds the
ruleset.

- **`CONFIG_STATIC_USERMODEHELPER=y` was set and
  `/sbin/usermode-helper` did not exist.** That routes every
  usermode-helper call the kernel makes — `request_module()` above all
  — through one compiled-in path, so **no kernel-initiated module
  autoload had ever worked**, for the life of the project. Invisible
  because every module this image loads is named by something in
  userspace (`/init`'s list, `novi-hwdetect`, `novi-hotplug`); it
  surfaced only when nf_tables tried to autoload `nft_ct` and the
  failure came back as `Could not process rule: No such file or
  directory`, which reads like a missing file and is a missing exec.
  `novi-umh/main.c` is the missing half: the kernel leaves the helper
  it meant to run in `argv[0]`, so it is a filter (allowlist, one
  entry, `/sbin/modprobe`) and not a dispatcher. Refusals go to
  `/dev/kmsg` — the bug was a silent exec failure, and a silent
  refusal is the same bug in a different hat.
- **It has to be in the initramfs too.** Different root filesystem,
  same compiled-in path. Same argument as `/dev/fd`.
- **Each `write()` to `/dev/kmsg` is its own kernel log record.**
  Composing one line out of three writes put the reason in one record
  and the path in the next, so `dmesg | grep novi-umh` showed
  `novi-umh: refused ` with nothing after it — precisely the
  information the message exists to carry. Build the line, write once.
- Verified by pointing `/proc/sys/kernel/modprobe` at a script that
  would `touch /tmp/PWNED` and making the kernel want a module: three
  refusals in `dmesg`, naming the path, and no `/tmp/PWNED`.
- **`novi-state boot --early` exists because boot convergence is too
  late for a firewall.** The full pass runs after `s6-rc change`
  returns — correct for everything whose convergence *is* a service
  transition — by which point `network` holds a lease and any declared
  service that listens is listening. Measured, not supposed: the table
  appeared a second or two after the login prompt. `EARLY_KEYS` is
  `network.firewall` and the membership rule is that converging the
  key must need nothing from s6-rc. It is deliberately not a general
  "apply one key" flag; partial convergence on demand is how a client
  ends up owning half the document.
- **`nft -f` is additive, so the converger deletes the table first.**
  Reloading after an edit that *removed* a rule would otherwise leave
  the removed rule in place. And `nft delete table` on a table that
  does not exist is an error, so turning the firewall off has to
  tolerate it being off already — the one case convergence must treat
  as success.
- **The observer reports `unsupported`, not `off`, when `nft` is
  missing.** A machine that cannot filter is not a machine that is not
  filtering, and `off` would let `diff` call it converged.
- **`-L` is not enough to link against a library in `${ROOTFS}`.**
  `nft` pulls in `libnftables.so`, whose `DT_NEEDED` names
  `libnftnl.so.11`; the linker must *find that file* to resolve
  transitive symbols, and the cross-gcc's sysroot is `${SYSROOT}`.
  The five "undefined reference to `nftnl_expr_alloc@LIBNFTNL_11`"
  read like a libnftnl too old to have them, and `readelf` showed all
  five exported by the library that had just been installed.
  `-Wl,-rpath-link` is the fix, as `build/lib-meson-cross.sh` already
  knew.

## Architecture: the kernel was hardened and the userland was not

`kernel/config-x86_64` sets `STACKPROTECTOR_STRONG`, `RANDOMIZE_BASE`,
`STRICT_KERNEL_RWX`, `FORTIFY_SOURCE` and `INIT_ON_ALLOC_DEFAULT_ON`.
Every binary it was protecting was built with **none** of it: `type=EXEC`
(so kernel ASLR could not apply), no `__stack_chk_fail`, no `BIND_NOW`,
and no optimisation at all — which also means `_FORTIFY_SOURCE` would
have been a no-op even if it had been set.

`harden_flags()` in `build/00-versions.sh` is the one place that sets
it, and the client stages call it next to `require_desktop_headers`.
**Not** applied to the static binaries (BusyBox, `novi-verify`): static
PIE is a different flag with different failure modes in PID 1's path,
and widening it is its own change with its own boot test.

Three things this turned up that generalise:

- **`CFLAGS` reached the compile and `LDFLAGS` reached nothing.** Every
  Makefile here linked with `$(CC) $(CFLAGS) -o $@ …` and never named
  `$(LDFLAGS)`, so `-pie` and `-z now` were dropped while
  `-fstack-protector-strong` went through. The binaries looked hardened
  if you checked only for a stack canary. **Check the artifact, not the
  flags you think you passed** — `scripts/check-hardening.sh` does, and
  `50-repo.sh` runs it before packaging, which is the last moment every
  first-party binary is still in the rootfs.
- **`readelf … | grep -q` under `set -o pipefail` reports a false
  failure.** grep exits on the first match, readelf takes SIGPIPE, and
  pipefail turns that into a non-zero pipeline. The first version of
  the checker called three binaries unhardened while `readelf -s` by
  hand showed the symbol twice. Read each file's headers into a
  variable once instead.
- **`-O0` hides `-Wformat-truncation`.** Turning on `-O2` surfaced three
  real `snprintf` truncations that had been invisible for the life of
  the project, one of which silently cut a `.app` descriptor's `exec=`
  line — registering an application whose command could not run, with
  nothing anywhere saying why.

Verified the way it has to be: `novi-edit` loaded at three different
addresses across three runs on a booted machine. A flag being set is
not ASLR; a different address every time is.

## Architecture: what the machine says it is

`/etc/os-release` is a relative symlink to `/usr/lib/os-release`, which
`03-base.sh` **generates** from `00-versions.sh`. It had never existed
— found by a clean build, after the README had documented its exact
contents as fact for as long as the file had not been written.

Generated, not repo content under `rootfs/etc/`, and that is the
opposite call from `passwd`/`group`/`shadow` deliberately: those hold
policy (fixed GIDs, the root password field) that should show up in a
diff, while every field here is already a variable one file away. A
second copy is only somewhere for the version to go stale, which is
exactly what happened to the README.

`/usr/lib` is one of pkgsplit's `LIB_DIRS`, so a new file there is
worth a thought — this one is safe because the sweep only claims files
matching a `PACKAGE_TABLE` pattern, and `os-release` matches none, so
it stays in the base.

## Architecture: users, and where secrets are not

RFC 0005 (`docs/rfcs/0005-users-and-accounts.md`).

`rootfs/etc/{passwd,group,shadow}` are repo content installed by
`03-base.sh`, not heredocs: fixed GIDs (a squashed image's baked-in file
modes depend on them) and the root password field are policy, and policy
should show up in a diff. Their comment headers are safe — musl skips
unparseable lines in all three, verified with a static musl
`getpwnam()`/`getgrnam()` binary in a chroot.

`users.<name>.shell` is the anchor key: declaring it creates the account,
`absent` removes it. **Removing an account never deletes the home
directory** — removing an account is a configuration change, deleting
someone's files is not.

**Configuration is declared; secrets are not.** No password hash goes into
`system.conf`, which is world-readable and which this project tells people to
commit to git. `/etc/shadow` (0600), `passwd`, `novi-settings`' Account
panel and `novi-install --user` are the only writers. Accounts created by
convergence start locked.

`cmd_apply` converges in **passes** (bounded to 3), not one sweep, because
keys are not independent: `users.X.groups` is not applicable until
`users.X.shell` has created the account, and `state_keys` is sorted so
`.groups` is visited first. One sweep left an account created with no
groups and the next `diff` reporting drift the apply had just been asked to
fix. Add a domain with an internal dependency and the passes handle it; do
not encode ordering in the sort.

## Architecture: the package trust root

RFC 0006 (`docs/rfcs/0006-package-repository-and-signing.md`).

`pkg` downloads code and runs it as root, so the chain has to hold end to
end: **one Ed25519 signature over the index, and every package's SHA-256
inside that index.** `pkg sync` verifies the signature with `novi-verify`
before believing a line of it; `pkg install` re-checks each archive's hash
before unpacking — cached archives included, because "we downloaded this
once" says nothing about what is in the file now.

Things not to undo:

- **`novi-verify` is static, and TweetNaCl is hash-pinned in
  `build/01-fetch.sh`.** It is the only pinned source in the project. Every
  other dependency is trusted for where it comes from; this one *is* the
  trust root, so a modified TweetNaCl means signatures verified by an
  implementation an attacker chose.
- **A missing signature is not weaker than a wrong one.** Both fail, and the
  decision lives in exactly one function (`verify_signature`). Two places
  that decide it is how one of them ends up more permissive.
- **The mirror fetch hooks into `locate_pkg()`, not `cmd_install`** — so
  dependency resolution and `pkg update` reach the network through the same
  verified path instead of growing their own copies.
- **AND FOR A LONG TIME THAT HASH CHECK WAS ONLY ON THE MIRROR PATH.**
  `fetch_from_mirror` hashed everything it handled, including a cached
  copy, under a comment saying so in as many words. It was true of that
  function and **false of the program**: `locate_pkg` searches
  `/var/cache/pkg/archives` and the on-media repository FIRST and
  returned a match from either without hashing it — so the verifying
  path was the one taken only when nothing local matched, and a
  modified archive in the cache was unpacked as root with a correctly
  signed index sitting beside it naming a different hash. A comment
  asserting the property is not the property, and this is the one path
  where that is trust rather than tidiness. `archive_matches_index()`
  is the single implementation now; `packages/tests/test-pkg-cache-hash.sh`
  fails 7 of its 13 checks against the old code, one of them by
  installing a file whose contents are `echo pwned`.
- **A cached copy that fails is DELETED; one in a repo directory is
  SKIPPED.** The cache is derived data this tool owns, so refetching is
  right. A repo directory is somebody's media — possibly read-only, and
  never ours to edit. Either way the archive is not installed.
- **An archive the index says nothing about is not blocked.** There is
  no published hash to check it against, and refusing would make an
  unindexed local repository unusable rather than safer. Whether there
  is a signed index at all is `pkg sync`'s question, not this one's.
- **It was found by accident, which is the uncomfortable part**:
  rebuilding a package at the SAME version and watching the old bytes
  install from the cache on a machine whose index had just been
  re-synced. Nothing about the symptom looked like security; it looked
  like a stale build.
- **`/etc/novi/pkg.conf` is deliberately not `system.conf`.** A mirror is a
  bootstrap parameter; `novi-state` cannot fetch a package from a setting it
  is in the middle of applying.
- **`pkg sync` refreshes the index; `pkg update` upgrades packages.**
  Different operations, different names, on purpose.
- The index format forbids `|` in every field rather than escaping it. An
  escaping scheme in a format parsed by `read` is a bug waiting to happen.
- **The index carries `valid-until` inside the signed blob, and it is checked
  AFTER the signature** (RFC 0010). A signature says genuine, not current;
  an unverified header is a string an attacker chose, so refusing on it
  before verifying would be a free denial of service. `sync` refuses a stale
  index, `update` only warns — sync is where a replayed index arrives.
- **`locate_pkg` asks the index which version it wants.** Without that it
  matched `<name>-*.pkg.tar.gz` against the cache, so `pkg update` printed
  "Upgrading 0.1.0 -> 0.2.0" and then installed 0.1.0 again from the archive
  the previous install had cached. The decision and the action disagreed and
  only the decision was printed.
- **Version comparison is `sort -V`, never `=`/`!=`.** A string comparison
  says 1.9.2 is newer than 1.10.0, which is the kind of wrong that ships a
  downgrade. An older version in the index is refused loudly, not silently:
  repositories do legitimately roll back a release.

## Architecture: who owns this file

RFC 0040 roadmap 1. `pkg install` refuses a path another package
owns, refuses a path nothing owns, and takes over an unowned one only
on an explicit `replaces-files=` in the MANIFEST -- saving the
original so `pkg remove` puts it back. `packages/tests/test-pkg-conflicts.sh`.

- **IT EXTRACTED A TARBALL OVER THE ROOT FILESYSTEM WITH NO OWNER
  CHECK AT ALL**, no conflict refusal and no backup. Measured before
  writing a line: zero paths are shared between the 60 packages
  (pkgsplit derives them) and **exactly one package overlays base
  content** -- `binutils` ships `usr/bin/strings` where the base has a
  busybox symlink. So `pkg install novi-devel` took the name silently
  and `pkg remove binutils` DELETED a command the base image had.
- **`replaces-files`, NOT `replaces`.** `packages/pkg-format.md`
  already documents `replaces` with the conventional dpkg meaning
  ("packages this supersedes on upgrade") and NOTHING IMPLEMENTS IT --
  along with `provides` and `conflicts`. Taking a well-known name for
  a different idea is how a reader ends up confidently wrong.
- **THE SAME TABLE SAID `depends` WAS SPACE-SEPARATED.** It is
  comma-separated, `mkpkg` refuses a space outright, and CLAUDE.md
  already records a package written from that belief failing at
  install. The wrong row was still in the FORMAT SPEC, which is the
  document somebody writing a package actually reads.
- **A DECLARED TAKEOVER IS ONLY WORTH HAVING BECAUSE IT IS
  REVERSIBLE.** The harm was never the overwrite; it was that the
  machine could not be put back. A symlink records `link <path>
  <target>`; a regular file is copied aside. Watched live: `link
  usr/bin/strings ../../bin/busybox`, then on removal `restored
  usr/bin/strings -> ../../bin/busybox` and `strings` runs again.
- **`--overwrite` IS THE OPERATOR'S, AND DELIBERATELY NOT SOMETHING A
  MANIFEST CAN ASK FOR.** A package saying `replaces-files=` declares
  one path and saves it; a person typing `--overwrite` is answering
  for whatever is in the way. Reusing the existing `force` parameter
  (which means "install even though this version is here") would have
  made a reinstall quietly also a permission to clobber.
- **`grep` EXITS 1 WHEN IT MATCHES NOTHING, and the caller assigns
  from a command substitution** -- which ends a `set -e` script. So
  the first unowned path killed pkg mid-install with nothing on
  stderr: the refusal this function exists to print never printed, and
  a DECLARED takeover died the same way. CLAUDE.md already recorded
  that trap from novi-agent. `|| true` and an explicit `return 0`.
- **A REFUSED INSTALL MUST LEAVE NO DATABASE ENTRY.** The first
  version created `$PKG_DB/<name>` before deciding, so a refused
  package left a registered-looking directory that `pkg list` and the
  owner index would both have counted. The records are staged in
  `$PKG_TMP` and move into place only once the answer is "install".
- **AND THE CHECK EXPOSED A PRE-EXISTING BUG THAT HAD BEEN CORRUPTING
  THE DATABASE.** `$PKG_TMP/extract` is only cleaned on the SUCCESS
  path, and the "already installed at this version" early return skips
  it -- so the next `tar -xzf` in the same invocation merged into a
  directory still holding the previous package's tree. `find` then
  recorded the LEFTOVERS as this package's files, and `pkg remove`
  would have deleted another package's files. It surfaced as `openssh
  would overwrite usr/lib/libsqlite3.so.0 (owned by sqlite)` about an
  openssh archive containing no such file: **the check was right about
  what it was shown, and what it was shown was wrong.**
- **THE PROBE FOR THAT COULD NOT FAIL AT FIRST.** `PKG_TMP` is
  `/tmp/pkg.$$`, so leftovers only survive WITHIN one invocation --
  the first version of the check used two separate `pkg install` calls
  and passed with the bug put back. One invocation installing an
  already-present package and then another reproduces it, which is
  also how it happened live: one `pkg install a b c ...` over six
  packages, several already there.

## Architecture: the four scripts pkg runs as root

RFC 0040 roadmap 5, `packages/tests/test-pkg-lifecycle.sh`.

- **THE HOOK ALREADY EXISTED AND THE ROADMAP ITEM ASKED FOR IT.** `pkg`
  has run `scripts/{pre,post}-{install,remove}` as root since it was
  written, `mkpkg` packs them and `pkg-format.md` documents them.
  **Eleventh roadmap item in this repository found to be wrong about
  what is already built** -- and the first where the person who filed
  the item made the mistake the same day. Check the code before
  believing an item, including one you just wrote.
- **NOTHING HAS EVER SHIPPED ONE**, which is why the mechanism was
  unexercised and why the next two defects had survived.
- **THE SPEC WAS WRONG ABOUT THE ARGUMENTS, IN THE WORST DIRECTION.**
  It said all four receive "one argument: the package version". The
  install pair got `<name> <version>`; the remove pair got only
  `<name>`. So a script written from the document treats `$1` as a
  version and is handed a name -- silently, as root. All four take
  `<name> <version>` now: with zero users the INTERFACE could still be
  corrected rather than the document, and that will never be cheaper
  again (RFC 0036's argument about `/run/novi/idle`).
- **THE ONE WORKED EXAMPLE CALLED TWO COMMANDS THAT EXIST NOWHERE
  HERE** -- `ldconfig`, which **musl does not ship at all** because its
  dynamic linker has no cache, and `gtk-update-icon-cache` on a system
  with no GTK. The example in a format spec is the thing people copy.
- **ONLY `pre-install` IS FATAL, and the table did not say so.** It
  runs before anything has moved, so refusing leaves the machine
  exactly as it was; the other three run once files are already on or
  off the disk, where aborting would leave a half-installed package --
  worse than either outcome. Right design, undocumented, in
  root-executed code.
- **A SCRIPT RUNS UNATTENDED AT BOOT.** `packages.<name>` means boot
  convergence can install a package, so "runs as root at install time"
  includes "as root, at boot, with nobody reading it". The spec says to
  prefer shipping a file over running code, and to keep what runs
  idempotent because an upgrade runs it again.
- **`scripts/` is copied into the install database**, because
  `pre-remove` runs long after the archive is gone. If that copy stops
  happening the remove pair silently never runs again -- which is a
  check in the suite.
- **THE MAN INDEX IS DERIVED, AND THAT IS WHY IT DOES NOT USE THE
  HOOK.** A per-package script means `man`, `coreutils` and `bash` each
  carrying a copy of one `makewhatis` call, and the FOURTH package to
  ship a page getting a stale index because nobody remembered --
  pkgsplit's argument and novi-sandbox's "no list of sandboxed
  programs". `pkg` notes the man roots a package installed into and
  refreshes them; what it learns is ONE rule with ONE entry, inert on
  any machine without `makewhatis` (every machine that has not
  installed `man`), off the trust path, unable to fail an install.
- **A PREBUILT INDEX WAS RULED OUT BY MEASUREMENT.** `mandoc.db` is
  per-DIRECTORY -- a booted machine had one under `/usr/share/man` and
  one under `/usr/gnu/share/man` -- `/usr/gnu/share/man` is shared by
  coreutils and bash so the second to ship a db there is refused by
  pkg's own conflict check, and `/usr/share/man` settles it alone: the
  base image's 79 alsa-utils pages live there, so a db built at
  package-build time is stale about pages no package owns.
- **AND THE FIRST VERSION WAS BROKEN IN THE ORDER PEOPLE WILL ACTUALLY
  USE.** It refreshed only the directories an invocation TOUCHED, so
  `pkg install coreutils` (no formatter yet, correctly a no-op) then
  `pkg install man` (touches `/usr/share/man` and nothing else) left
  the GNU tree unindexed and `man ls` still warning -- the exact defect
  the work exists to remove, surviving in the common case. So a man
  root an INSTALLED package owns that has **no db at all** joins the
  pass: derived from the install database rather than from a manpath,
  bounded (it runs only when something already put pages on the
  machine) and self-limiting (a directory indexed once has a db).
  Verified booted: `pkg install man` produces BOTH dbs, the second for
  a directory that install never touched, and `man ls` renders with no
  warning line.
- **THE ACCUMULATOR IS A FILE, NOT A VARIABLE, and that is forced.**
  `cmd_install` installs DEPENDENCIES inside a `printf | while`
  pipeline, which is a SUBSHELL -- a variable would silently keep only
  the top-level package's directories and lose every dependency's.
  Same trap as novi-state's observer cache and `packages/pkg`'s own
  earlier one. Provoked: swapping the file for a variable fails the
  dependency check.
- **ONCE PER INVOCATION, NOT PER PACKAGE**, because makewhatis re-reads
  every page in the directory. **And the first check for that could not
  fail**: it installed ONE package, where the two are the same number,
  so moving the call into `install_pkg_file` left it green. It takes a
  package plus a DEPENDENCY both shipping into one directory -- which
  is also the case that exercises the subshell.
- **The first version special-cased `PKG_ROOT` and skipped**, which was
  over-clever in the direction that hides things: the test harness's
  doctored copy sets `PKG_ROOT` to a temporary tree, so the feature was
  unreachable in the one place that could check it. It uses the
  `${PKG_ROOT:-}` prefix now, like every other path in the program.

## Architecture: /dev/fd, and testing the image not the shell

`/dev/fd` did not exist on the shipped image — devtmpfs does not create it
and nothing else did. BusyBox ash implements `< <(process substitution)`
through `/dev/fd/N`, so every one in `packages/pkg` failed with
`can't open /dev/fd/64: no such file`, and **not fatally**: dependency
resolution printed the error and carried on having resolved nothing, so
`pkg install foot` fetched foot and silently skipped `fcft`.

`pkg`'s own comment said process substitution was "verified working against
the real busybox binary this repo builds" — and it was, on a *host* that has
a `/dev/fd`. **Testing the shell answered a different question than testing
the image.** When a construct depends on the runtime environment, the
verification has to happen inside a booted Novi.

`rc.init` now creates `/dev/fd`, `/dev/stdin`, `/dev/stdout` and
`/dev/stderr` (so does the initramfs, so its emergency shell behaves like
the real system), *and* `pkg` no longer uses process substitution anywhere:
the loops that must run in the parent shell write a temp file and read it
back. The trust-critical path should not depend on a shell extension.

## Architecture: the base/desktop split is computed, not listed

RFC 0007 (`docs/rfcs/0007-base-desktop-split.md`). The base image is
console-only; the desktop is 25 packages, and the installation medium
carries the signed repository at `/novi-repo`.

`tools/pkgsplit/pkgsplit.py` decides what leaves, from the ELF dependency
graph — `closure(NEEDED)` from the desktop binaries minus `closure(NEEDED)`
from everything else that ships — and **fails the build** if anything
staying behind still links against something moving out. Inter-package
`depends=` lines are derived the same way. Do not replace this with a
hand-written list: that is how a split rots, one library at a time.

Three things it is important not to break:

- **The graph is not the only input, because it cannot see `dlopen`.**
  libdrm loads `libdrm_amdgpu`/`libdrm_nouveau`/`libdrm_radeon` by name at
  runtime and `libwayland-egl` has no in-image consumer, so nothing NEEDs
  them and the first split left all four in a "console-only" base. So:
  the graph finds what is *reachable*, `PACKAGE_TABLE` claims what is
  *ours*, and anything claimed that the base does not need moves too. A
  file matching no pattern is a hard error, never a guess.
- **`build/51-desktop-split.sh` deletes exactly what `50-repo.sh`
  packaged**, from the manifest 20 wrote. One source of truth, or the two
  drift and the image ends up broken or still fat. Re-running the
  content stages (`--from 06 --to 49`) puts the files back; that
  ordering is what `build.sh` does. **The whole range, not `06..14`** —
  this line said that until the renumber, and desktop clients reach 37,
  so following it would have restored part of the desktop and quietly
  left the rest out, which is how the 51-package repository shipped.
- **The s6 service definitions for `seatd`/`novi-shell`/`graphical` stay
  in the base** even though their binaries do not. s6-rc does not check
  that a run script's binary exists, so a declared-off service pointing at
  a not-yet-installed binary is inert, not broken — and a machine that
  installs `novi-desktop` can then just flip the key.
- **A library's three names must move or stay as a unit, and one stray
  utility in `/usr/bin` is enough to break that.** libpng's `make
  install` puts `pngfix` and `png-fix-itxt` in the base; they are not
  desktop binaries, so their closure pinned `libpng16.so.16` and
  `libz.so.1` into the base while the sweep moved
  `libpng16.so.16.43.0` and `libz.so.1.3.1` out with the desktop. The
  base kept two dangling symlinks, the packages shipped without the
  only names anything records, and — because `owner` is keyed on
  basename — `novi-view`'s derived `depends=` silently lost `libpng`
  and `zlib` too. Everything built, indexed, signed and installed;
  `pkg install novi-desktop` reported success; the viewer died at exec
  with `Error loading shared library libpng16.so.16`. pkgsplit now
  fails the build on a straddling sibling group, and `21-imagelibs.sh`
  does not install utilities nobody asked for. **Do not put anything in
  the image that nothing asked for** — in a split computed from what
  the base needs, dead weight is not inert, it votes.
- **`closure()` used to stop at every soname symlink.** A symlink has no
  ELF header, so `readelf -d` returns nothing and the walk ended at
  `libfoo.so.N` without ever reading the file it points at. It survived
  because the `PACKAGE_TABLE` sweep drags table-owned libraries along
  regardless — but it made the reachability answer wrong, which matters
  the moment anything reasons about it. It follows links now.

Two smaller ones:

- `novi-install` installs the desktop **in a chroot**, not with `pkg`'s
  `PKG_ROOT`. `PKG_ROOT` relocates where files land but *not* the install
  database, so a `PKG_ROOT` install writes the target's files and the live
  system's database — an installed machine that does not know what it has.
- The shipped `pkg.conf` says `mirror = /run/live/novi-repo`, which is the
  installation medium. `novi-install` comments it out on the target unless
  given `--mirror`, or every installed machine gets a `pkg sync` that fails
  pointing at a directory nobody chose.

**A network interface is not "the first thing in /sys/class/net that is
not lo".** A kernel with `CONFIG_IPV6_SIT` creates `sit0`, a tunnel
pseudo-device, and it sorts before `eth0` — confirmed live: "network:
using sit0", then udhcpc broadcasting DISCOVER forever down a tunnel with
no link. `pick_interface()` requires `/sys/class/net/*/type` to be 1
(ARPHRD_ETHER).

## Architecture: two root slots, and a condition that tested the reason

RFC 0041 (`docs/rfcs/0041-atomic-updates-and-rollback.md`).
`novi-install --ab` lays out a shared boot area, TWO root slots and a
shared state partition. **Nothing updates or rolls back yet** -- the
machine boots from slot A and slot B is empty. BIOS and UEFI, opt-in.

- **A PARTITION TABLE IS WRITTEN ONCE, which is why the empty slot
  exists now.** Splitting state out without reserving slot B would give
  a machine that can never gain A/B without a reinstall -- the same as
  not having done it. That is why RFC 0041's roadmap items 1 and 3 are
  one item.
- **`/var` DOES NOT MOVE WHOLESALE**, and the RFC said it did before
  anybody read `packages/pkg`. `/var/lib/pkg/installed` is the install
  database and **describes the slot's own contents**; sharing it would
  give the running system a database about the OTHER slot -- a machine
  that lies to `pkg`, to `novi-state diff` and to `novi-agent
  describe`. The split is by NAMED SUBTREE: `/home`, `/var/log`,
  `/var/lib/novi-state`, `/var/lib/alsa` and `/var/cache/pkg` shared;
  `/var/lib/pkg` slot-local. `/var/cache/pkg` is safe to share
  precisely because RFC 0006 hashes every archive against the signed
  index before unpacking.
- **THE SUBTREES ARE MOVED, WITH AN EMPTY DIRECTORY LEFT AS THE BIND
  TARGET -- not symlinked.** A boot where the state partition does not
  mount then leaves `/var/log` as an empty directory rather than a link
  into nothing.
- **A SEPARATE `/boot` IS A FACT, NOT A REASON, and three places tested
  the reason.** `core.img` selection and `kernel_grub_prefix()` both
  asked `$ENCRYPT`, because RFC 0018's encrypted layout was the only
  reason there had ever been for a separate `/boot`. `--ab` is the
  second. With the old condition an `--ab` install writes `core.img`,
  whose prefix is `(hd0,msdos1)/boot/grub`, onto a disk whose partition
  1 IS `/boot` -- GRUB looks for `/boot/boot/grub` and the machine does
  not boot, from an installer that reported success. `separate_boot()`
  is the one predicate now. **A condition that tests why instead of
  what breaks the moment a second why turns up.**
- **THE A/B SHAPE IS RFC 0018's ENCRYPTED SHAPE WITHOUT THE
  ENCRYPTION**, so most of the bootloader work was already done:
  `mkiso.sh` already generates `core-boot.img` with the
  `(hd0,msdos1)/grub` prefix. The only genuinely new GRUB work left is
  `loadenv`, which is **not** in the module list `grub-mkimage` bakes
  in -- so a boot cannot be steered from userland at all today.
- **ENCRYPTED INSTALLS ARE REFUSED, and that is the honest outcome.**
  Under A/B the slots AND the state must all be inside encryption, and
  carving three volumes out of one LUKS container is what LVM is for:
  this system has no LVM and no `dmsetup` (checked -- `34-cryptsetup.sh`
  links libdevmapper into one static `cryptsetup`). `/home` in the
  clear for somebody who typed `--encrypt` would be a silent, serious
  regression.
- **AN OPTION THAT CONTRADICTS ANOTHER SHOULD NOT NEED A VALID DISK TO
  SAY SO.** The `--ab --encrypt` refusal first lived inside
  `cmd_install`, after the "is that a block device" test, so it
  answered `/dev/null is not a block device` -- true, and not the
  problem the person has. `validate_options` runs before anything looks
  at a disk. Found by a host test that had no disk to give it.
- **Verified by an install and a reboot** (QEMU/TCG; no physical
  hardware): vda1..vda4 labelled `NOVI_BOOT`/`NOVI_ROOT_A`/
  `NOVI_ROOT_B`/`NOVI_STATE`, root on vda2, `/boot` on vda1, `/state`
  on vda4 with `/home` and `/var/log` bound out of it and writable, and
  **`mount | grep -c /state/var/lib/pkg` = 0**.
- **UEFI IS THE SAME LAYOUT WITH THE ESP IN PLACE OF `/boot`, and it
  needed NO bootloader work at all.** `novi-gpt --slot-mib N` writes
  the fourth entry -- the "two layouts" contract decision 3 asked to be
  written down -- and everything else follows: the removable-media path
  puts `BOOTX64.EFI` and `grub.cfg` on the ESP, which is already
  shared, so unlike BIOS there is no second `core.img` and no prefix to
  get wrong. Separately installed and rebooted under OVMF, same disk
  size, same verdict: `NOVI_ESP`/`NOVI_ROOT_A`/`NOVI_ROOT_B`/
  `NOVI_STATE`, `root=LABEL=NOVI_ROOT_A`, `/state` on vda4 with the
  binds live and writable, slot B unmounted, and the pkg count 0 again.
- **A THIRD HARNESS BUG, AND IT REPORTED A WORKING MACHINE AS DEAD.**
  The UEFI reboot phase searched the whole serial log from byte zero
  for `login:` -- which the LIVE medium had printed an hour earlier --
  so it matched instantly, typed `root` into GRUB's menu, and then
  timed out waiting for a shell prompt that was ten lines further down
  the same file. The installed system had booted, resolved
  `LABEL=NOVI_ROOT_A` to `/dev/vda2` and printed its login prompt while
  the harness declared it broken. **An instrument that reads stale
  output answers a question about the past**, and the answer arrives
  looking like a finding about the present. Every wait takes a byte
  offset.
- **TWO HARNESS BUGS, BOTH THE SAME FAMILY AS EVERY OTHER ONE IN THIS
  FILE.** Waiting for `INSTALL_RC=` matched the console's ECHO of the
  command rather than its output, so the copy was cut off mid-way and
  the reboot went into the wreckage -- which presented as "the
  installed system booted" followed by every probe timing out. Wait for
  the installer's own last line. And sending credentials on a timer let
  the probes race the login prompt, producing a column of `Password:`;
  wait for `root@<hostname>`, which appears in the shell prompt and in
  nothing else.

## Architecture: a boot that can be steered from userland

RFC 0041 roadmap 2. `loadenv` is baked into all three GRUB images, an
`--ab` grub.cfg reads `novi_slot` out of the environment block, and
`packages/novi-grubenv` writes that block from the running system.
`packages/tests/test-grubenv.sh`, 49 checks.

- **`grub-editenv` IS NOT ON THIS SYSTEM, AND THE MISSING HALF IS A
  SCRIPT.** The environment block is a fixed 1024 bytes: the signature
  `# GRUB Environment Block\n` byte for byte, then `name=value` lines,
  then `#` padding (GRUB skips a line beginning `#`, which is what
  makes padding work). That is a format, not a program, so the answer
  is the same split RFC 0003 already made for `grub-install` --
  generate on the build host, place on the target. Base content in
  `/usr/sbin`, because a machine whose update went wrong is exactly the
  machine that cannot install a package to fix it.
- **THE PATH IS DERIVED FROM WHERE grub.cfg IS, NOT FROM
  `/sys/firmware/efi`.** Those answer different questions: the firmware
  node says how this machine booted, and what is wanted is where its
  GRUB reads -- and GRUB looks for grubenv beside grub.cfg, at the
  prefix baked into core.img or bootx64.efi. A UEFI machine whose ESP
  did not mount (fstab says `nofail`) still has `/sys/firmware/efi` and
  has nowhere GRUB will read; writing a block into a directory nothing
  reads is the silent failure the ordering avoids. It refuses instead.
- **`load_env` NAMES THE VARIABLES IT WILL ACCEPT.** Called bare it
  imports EVERYTHING in the file into GRUB's environment, `prefix` and
  `root` included -- so a block somebody appended to could redirect the
  bootloader itself. `load_env novi_slot`, guarded by
  `[ -s ${prefix}/grubenv ]` so a missing or truncated block is silence
  rather than an error on a machine that is fine, with `novi_slot=a`
  set beforehand: an unset variable reads as slot A, which is the right
  answer to "I cannot tell".
- **EVERY WAY TO GET THE FORMAT WRONG IS SILENT, and the first one bit
  immediately.** Without a newline between the last variable and the
  padding, GRUB reads a record with no terminator and **DISCARDS it** --
  from a file that is 1024 bytes, carries the right signature and looks
  correct in an editor. So the oracle is `grub-editenv` reading what we
  wrote and us reading what it wrote, never a second implementation of
  `envblk.c` in the test. CI installs `grub-common` for it, on the
  argument `libxkbcommon-dev` already won.
- **A `die` INSIDE A PIPELINE DOES NOT END THE SCRIPT.**
  `printf ... | write_block "$f"` put the writer in a SUBSHELL, so its
  `exit 1` ended only the subshell and the caller went on to print
  "wrote" about a file it had not touched -- a refused write reporting
  success. The body is an argument now. **Putting the pipe back to
  check the test catches it found a second reason**: `create` passes an
  empty body, and `body="$(cat)"` with nothing on the other end reads
  the TERMINAL and hangs forever. No amount of reading would have shown
  that; one provocation did.
- **AND THE NEWLINE GUARD COULD NOT FIRE.**
  `case "$value" in *"$(printf '\n')"*)` -- a command substitution
  strips trailing newlines, so the pattern was `**` and it refused
  every value, including every correct one. The same dead branch as
  RFC 0031's unreachable `''` case. Count the newlines instead.
- **`strings` CANNOT SEE INTO `core.img`.** grub-mkimage LZMA-
  compresses the i386-pc payload, so grepping the artifact for
  `loadenv` returns nothing whether or not the module is there --
  another probe that answers a different question. What proves it is
  RECONSTRUCTION: the same module list with `loadenv` produces a file
  byte-identical to the shipped one, 284 sectors against 278 without.
  The post-MBR gap is 2047 sectors, so six is affordable, and
  `novi-install` already refuses a `core.img` that does not fit.
- **THE OTHER SLOT IS A MENU ENTRY, NOT ONLY A VARIABLE.** If the slot
  grubenv names will not boot there is no userland to run
  `novi-grubenv` in, so without an entry the recovery path for a failed
  update is a rescue medium. Verified: picking it booted slot A while
  `novi_slot` still read `b` -- a menu choice is a one-off and does not
  rewrite the document, the same separation novi-state keeps between
  the running system and the declared one.
- **Verified by three boots of one disk** (QEMU/TCG; no physical
  hardware), with nothing changed between them but 1024 bytes:
  `novi_slot=a` gives `Novi Linux (slot A)` and
  `root=LABEL=NOVI_ROOT_A`; after `novi-grubenv set novi_slot=b` the
  menu says `(slot B)` and `/init` resolves `LABEL=NOVI_ROOT_B` to
  `/dev/vda3`; the escape-hatch entry then returns to slot A. Boot 2
  gets no further than resolving the device because slot B is a
  formatted filesystem with nothing in it until roadmap item 4 -- that
  is the steer working, not failing.
- **A machine with ONE slot is byte-unchanged.** No `load_env`, no
  `novi_slot`, three menu entries and a plain title, because a
  `load_env` with no grubenv and no second slot is wiring with nothing
  on the other end. The grubenv is still written, so `novi-grubenv`
  behaves the same everywhere -- 1 KiB, and a machine that later gains
  a use for it does not need the file to appear from somewhere.

## Architecture: two firmware paths, one installer

RFC 0008 (`docs/rfcs/0008-uefi-and-journalled-root.md`). `novi-install`
detects firmware from `/sys/firmware/efi` — the kernel's own record of how
it got here — and branches:

| | table | bootloader | grub.cfg | needs `search` |
|---|---|---|---|---|
| UEFI | GPT via `novi-gpt` | self-contained `BOOTX64.EFI` on the ESP | on the ESP (`/EFI/BOOT`) | yes |
| BIOS | MBR via BusyBox `fdisk` | `boot.img` + `core.img` in the gap | on the root fs | no |

Things not to undo:

- **`novi-gpt` exists because BusyBox `fdisk` cannot create a GPT** (it
  reads one, it cannot write one), and the target has no sfdisk/sgdisk/
  parted. It writes exactly one layout on purpose: a tool that can express
  every layout is a tool that can express the wrong one. The two classic
  GPT bugs are handled explicitly — GUIDs are byte literals in GPT's
  mixed-endian order, and the header CRC covers `header_size` bytes with
  the CRC field zeroed, not the sector.
- **An ESP on an MBR label was considered and rejected.** Plenty of
  firmware boots it, OVMF included — which is the problem: it would pass
  here and fail on someone's laptop.
- **`/EFI/BOOT/BOOTX64.EFI`, not a vendor dir + NVRAM entry.** The
  removable-media path needs no `efibootmgr`, no writable EFI variables,
  and survives firmware forgetting its boot order.
- **e2fsprogs installs `mke2fs.e2fsprogs`, beside BusyBox's applet, never
  over it** — and `blkid`/`findfs`/`fsck`/`uuidgen` are deliberately NOT
  installed, because `mkinitramfs.sh` parses BusyBox `blkid`'s exact
  output. Its musl patch (`#define llseek lseek` defines the wrong name;
  musl 1.2.4 dropped the LFS64 aliases) fails the build loudly if it stops
  applying.
- **`CONFIG_NLS_CODEPAGE_437` and friends are load-bearing.**
  `FAT_DEFAULT_CODEPAGE=437` was set with every `NLS_*` symbol unset, so
  `mount -t vfat` failed with "Unable to load NLS charset cp437" — no ESP,
  no UEFI install, and a quietly broken vfat fallback in the initramfs.
- **`rc.init` runs `mount -a`.** Nothing on this system had ever read
  `/etc/fstab`: s6-linux-init stage 1 mounts the kernel filesystems and
  stops, so the installer's fstab was documentation. Confirmed live —
  `/boot/efi` was an empty directory on a working UEFI install.

**UEFI is fast in QEMU, contrary to a belief this repo carried for a
while.** OVMF on `q35` **without USB controllers** reaches a login in ~17
seconds; the old "OVMF is pathologically slow" note had bisected the
slowdown to xhci and then never re-tested without it. Always pass
`-vga none` when screendumping a compositor, too — `-machine pc` adds a
std VGA device and `screendump` defaults to device 0.

## Architecture: WPA3, and what "no TLS in the base" actually forbade

RFC 0021 (`docs/rfcs/0021-wpa3.md`). `CONFIG_TLS=wolfssl`, and SAE
verified against a WPA3-only AP.

- **The base image already linked a TLS implementation, and had from
  the start.** `CONFIG_TLS=internal` is not "no crypto" — it is ~200 KB
  of AES, SHA, RSA, bignum and a TLS 1.2 handshake compiled into
  wpa_supplicant. RFC 0009's rule was *no OpenSSL*; RFC 0006's was
  *checking a package signature must not need a TLS stack*
  (`novi-verify`, still static, still the only thing on that path).
  Neither said the supplicant may not have crypto. So this swaps
  200 KB nobody has reviewed for 1.4 MB that is audited and
  maintained — a rehousing of attack surface, not a widening. Get the
  rule right before invoking it: the vague version of it would have
  blocked this forever.
- **wolfSSL is built in `25-wifi.sh`, not a stage of its own.** The
  novi-launcher/fcft rule is about a library built in a *later* stage
  than its consumer; wolfSSL's only consumers are wpa_supplicant and
  hostapd, built in this same stage, so there is no ordering hazard.
  The day something else links it, it moves.
- **Autotools, not cmake, and it is not cosmetic.** cmake's
  `WOLFSSL_WPAS` is NOT the same define set as autotools'
  `--enable-wpas`, which also turns on `OPENSSL_EXTRA` and ~20 others
  (`HAVE_SECRET_CALLBACK`, `HAVE_KEYING_MATERIAL`, `KEEP_PEER_CERT`
  …). With the cmake flag, `tls_wolfssl.c` failed on fourteen errors —
  `SSL_OP_NO_TLSv1` undeclared, implicit declarations of
  `wolfSSL_get_client_random` and friends. Use the switch upstream
  maintains rather than reconstructing the list.
- **`CFLAGS`/`LIBS` go into the generated `.config`, which is a
  makefile fragment** (`CFLAGS += …`). Passing `CFLAGS=` on the `make`
  command line *replaces* everything upstream's makefiles put there.
  Same trap as RFC 0009's exported `LDFLAGS`, one level in.
- **`ieee80211w=1`, not `=2`.** SAE requires PMF, so without it a WPA3
  AP refuses to associate at all; `=2` would have made every WPA2 AP
  unjoinable. One block with `key_mgmt=WPA-PSK SAE` joins whichever
  the AP offers, and both halves are tested — a WPA3-only AP
  (`sae_require_mfp=1`) and a WPA2-only AP, with the same block.
- **`sae_password=` is the plaintext passphrase on disk, unavoidably.**
  SAE derives from the passphrase, not from the PBKDF2 PSK, so there
  is no one-way transform to store. `/etc/novi/wifi.conf` was already
  0600 and root-only for this reason. `novi-wifi add --wpa2-only` is
  the escape hatch: `psk=` only, no plaintext, no WPA3.
- **`wpa_passphrase`'s output ends with `}`, so appending to it puts
  keys at file scope.** Three SAE keys landed outside the block,
  wpa_supplicant refused the file, and `novi-wifi status` reported
  *"the supplicant is not running"* — a message about a service,
  produced by a syntax error in a config file. `add_network_block`
  drops the brace, appends, restores it, and `die`s rather than
  editing blind if the last line is not `}`.

## Architecture: WiFi, and the second secret store

RFC 0009 (`docs/rfcs/0009-wifi.md`).

- **wpa_supplicant links no OpenSSL**, and that is the rule — not "no
  crypto". It was `CONFIG_TLS=internal` and is `CONFIG_TLS=wolfssl`
  since RFC 0021; see that section below. iwd was rejected because its
  control interface is D-Bus.
- **WPA3 was impossible under internal TLS** and is the reason for the
  swap: SAE/OWE need EC crypto internal does not implement, and
  turning them on linked cleanly right up to `undefined reference to
  crypto_ec_get_prime`. RFC 0009 named mbedTLS as the way in and was
  wrong (RFC 0020 found there is no mbedTLS backend in 2.11 at all).
- **`network.wifi` and `network.wifi.interface` are all that is declared.**
  Passphrases live in `/etc/novi/wifi.conf` at 0600, in wpa_supplicant's
  own format, managed by `novi-wifi`. Same rule as `/etc/shadow`:
  configuration is declared, secrets are not.
- **Wired beats wireless** in `pick_interface()`, and a wireless device is
  one with `/sys/class/net/*/phy80211` — the kernel saying what it is, not
  a name starting with `wl`.
- **hostapd is built by `25-wifi.sh` and never installed.** It is the test
  peer; verification runs two `mac80211_hwsim` radios, one AP one station,
  with a real handshake between them. It needs `CONFIG_TLS` set
  explicitly too — its default backend is OpenSSL and it does not ask.

**`s6-rc -a list` reporting a longrun "up" has now hidden three separate
crash-loops** (RFC 0004's `syslog`; here, `wpa_supplicant -s` rejected
because `CONFIG_DEBUG_SYSLOG` was not compiled in, printing usage and
exiting while `novi-state diff` reported the machine converged). When a
service does not do its job, check `s6-svstat` and
`/run/uncaught-logs/current`, never the service list. Making `diff` itself
notice this is on RFC 0009's roadmap and is deliberately not done yet: the
obvious implementation reintroduces the boot race RFC 0004 fixed.

**And a shell trap worth not repeating:** `case "${#var}" in ?|??|???)` does
not test length — `${#var}` is the length *rendered as a string*, so `"13"`
matches the two-`?` pattern. That rejected every WiFi passphrase between 10
and 99 characters. Use an arithmetic test.

## Architecture: cross-toolchain bootstrap order

`build/00-versions.sh` is sourced by every `build/*.sh` script and exports
`BUILD_DIR=/build` (hardcoded absolute path, **not** derived from the repo
checkout location) plus `SOURCES`/`TOOLS`/`SYSROOT`/`ROOTFS` under it. This
decoupling is a recurring source of bugs: any script that needs a
repo-relative path (a config file, `kernel/config-x86_64`, etc.) must
compute it itself —
`SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"`
— never assume `${BUILD_DIR}/../whatever` reaches the repo; it reaches
`/whatever`. `03-base.sh` and `05-kernel.sh` do this correctly; `mkiso.sh`'s
`ROOTFS_DIR`/`KERNEL_IMAGE` defaults still don't (see Build commands above).

`build/02-toolchain.sh`'s phase order is load-bearing, not arbitrary:
binutils → **gcc stage 1a, compiler only** (`--without-headers`,
`all-gcc`/`install-gcc` — do not build `all-target-libgcc` yet) → Linux
kernel headers into the sysroot → **musl headers-only install**
(`make install-headers`, no compile) → **gcc stage 1b** (`all-target-libgcc`
now that a real `<stdio.h>` exists) → **musl full build** (both static and
shared — never pass `--disable-static`; the static base userland and
several skarnet packages need `libc.a`, not just `libc.so`) → gcc stage 2
(full, shared, musl-linked). Building `all-target-libgcc` before musl
headers exist fails with `stdio.h: No such file or directory`; building
musl shared-only breaks anything that needs to link statically.

## Architecture: the skarnet (s6) package family

`skalibs`, `execline`, `s6`, `s6-rc`, `s6-linux-init` share one configure
template with real gotchas when not using `--enable-slashpackage` (this repo
doesn't):

- `--with-<pkgname>=DIR` (e.g. `--with-execline=`, `--with-s6=`,
  `--datadir=`) is **not a recognized option in any of these scripts** — a
  generic `--with-*|--*dir=*` catchall silently no-ops anything it doesn't
  know, so passing it produces no error and no effect. Only
  `--with-lib=`/`--with-dynlib=`/`--with-include=`/`--with-sysdeps=` are
  real, and `--with-lib`/`--with-dynlib` accumulate across repeated flags.
  Find each dependency's true install path from its own `package/deps-build`
  file and pass it explicitly (`build/04-s6.sh`'s `build_skarnet()` does
  this for skalibs/execline/s6).
- Without `--enable-slashpackage`, skalibs installs static libs to
  `$prefix/lib/$package` (i.e. `usr/lib/skalibs`) but shared libs to the
  flat `$prefix/lib` (i.e. `usr/lib/`) — `libdir` and `dynlibdir` are
  different directories. Every downstream package needs both flags pointed
  at the right one, or linking fails with `cannot find -lskarnet`.
- Cross-compiling skalibs: any sysdep check that needs to *run* a compiled
  test binary (not just compile it) refuses to autodetect and fails
  configure outright. Only two exist in skalibs
  (`devurandom`, `posixspawnearlyreturn`) — supply
  `--with-sysdep-devurandom=yes --with-sysdep-posixspawnearlyreturn=no`
  (the latter is correct for musl's `vfork()`-based `posix_spawn()`).
- The pinned versions in `00-versions.sh` are not guaranteed mutually
  compatible — skarnet enforces strict version pairing and a skew can
  surface as a plain compile error (e.g. s6-2.12.0.2's `s6-socklog.c`
  predates a skalibs API change to `socket_recv46()`). `build_skarnet()`
  takes an optional 4th arg, a shell command `eval`'d after extraction and
  before configure, for exactly this kind of narrow source patch — prefer
  it over bumping versions across the whole stack, which risks cascading
  into new incompatibilities.

## Architecture: BusyBox and kernel config quirks

- BusyBox's vendored Kconfig is an older kbuild snapshot: it has no
  `olddefconfig` target (that's Linux-kernel-only) — use
  `oldconfig </dev/null` for non-interactive defaults instead.
- BusyBox's `tc` applet (`networking/tc.c`, CBQ support) references kernel
  `pkt_sched.h` structures removed from modern Linux UAPI headers years ago;
  it's disabled in `.config` rather than patched, since it's not needed to
  boot.
- `kernel/config-x86_64` is a curated ~280-option config, not a full
  `defconfig` — deliberately, to keep the kernel small (`docs/PLATFORM-ROADMAP.md`
  §4 has the reasoning: build against open device-class standards, not
  chase every vendor path). It reaches real hardware drivers (`amdgpu`,
  `i915`, `mac80211` WiFi), not just QEMU's virtio set — but it also leaves
  some boot-critical symbols (`BINFMT_ELF`, `TTY`, `SERIAL_8250`,
  `BLK_DEV_INITRD`) completely unmentioned rather than explicitly set.
  `05-kernel.sh` forces those before `olddefconfig` rather than trust
  Kconfig's default inference for anything that critical.
- `config/busybox.config` (a repo-provided minimal BusyBox config) doesn't
  exist yet — `03-base.sh` falls back to `make defconfig` until one is
  committed.
- `make modules_install` needs `depmod` (package `kmod`) on the **build
  host** to generate `modules.dep`/`modules.alias`. If it's missing, the
  step only *warns* — `set -e` doesn't catch it — and silently ships a
  kernel with a complete `.ko` tree but no dependency/alias metadata, so
  `modprobe`/udev-triggered auto-loading can't find any module (including
  `virtio_blk`, built as a module here, not built-in). `05-kernel.sh`
  checks for `depmod` up front and fails loudly instead.

## Build-host scripts are bash; on-target scripts are sh

`/bin/sh` is **dash** on Debian and Ubuntu, and dash does not support
`set -o pipefail`. `packages/mkpkg` carried `#!/bin/sh` plus
`set -euo pipefail` and a comment asserting that "bash or dash ... both
support it", so it failed with `set: Illegal option -o pipefail` on
exactly the build host this project documents, and worked only where
`/bin/sh` happened to be bash. It is `#!/bin/bash` now.

`packages/pkg` keeps `#!/bin/sh` *and* keeps `pipefail`, correctly: it
runs on-target under BusyBox ash, which this repo's own busybox build
does support it on (verified with the shipped binary, not assumed).
Different runtime, different answer — which is why the two are separate
scripts. When adding either kind, ask which shell will actually run it.

Lint is `bash scripts/lint.sh`, the same command CI runs.

## Shellcheck signal-to-noise

`shellcheck build/*.sh scripts/*.sh` reports many `SC2086` (unquoted
variable expansion) findings across the whole `build/` directory — this is
a pre-existing, repo-wide style pattern, not a regression to fix reflexively
when touching a file. Treat it as a known baseline; focus review on new
warnings a change introduces.

## Contribution conventions

Conventional Commits (`docs/branch-strategy.md`, `CONTRIBUTING.md` have the
full type/scope list). **PRs target `main`** — `docs/branch-strategy.md`
describes a `develop` integration branch that does not exist yet, and
says so at the top. Architectural
changes — new init subsystems, package format changes, kernel/toolchain
baseline changes, introducing a desktop/GUI stack — require an RFC first
(`CONTRIBUTING.md` § RFC Process; drafts live in `docs/rfcs/`).
