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
the file exists. **01–39 build content into the rootfs; 40+ package it.**
That gap is deliberate: everything that puts a file in the image has to
run before `40-repo.sh` computes the base/desktop split from what is
there. The packaging stages used to be 30/31/32 with content filling
20–29, and twice a new stage had nowhere legal to go — a base binary
built after the split would ship, but pkgsplit would have computed the
split without it, which is a trap rather than a rule. Two stages may not share a number and `build.sh` refuses
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
- `bash build/05-kernel.sh` — Linux kernel using `kernel/config-x86_64`
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
- `bash build/40-repo.sh` — build and sign the first-party package
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
- `bash build/41-desktop-split.sh` — **destructive**: removes the packaged
  desktop from `/build/rootfs`, leaving a console-only base (RFC 0007).
  Must run after 20; re-running 06..14 puts the files back
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
- `bash build/35-devtools.sh [openssh|ca|curl|git|repo|all]` — the ssh
  client, the CA bundle, curl and git (RFC 0019, RFC 0020), staged
  into `/build/stage-devtools` and published by
  `43-devtools-repo.sh`. Packages, never base. Also builds `sshd`
  into `/build/ssh-test/` as the test peer, deliberately not into the
  image
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
- **The indicator is deliberately not clickable**, unlike the two
  buttons beside it. There is no service UI to open, and a panel item
  that opens a terminal is not a thing this desktop does. When
  somewhere exists for it to lead, it should lead there.
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
first** (`build/00-versions.sh`). 41-desktop-split.sh removes the
headers, so in any tree where a full build has run, rebuilding one
client stops with four "No such file or directory" lines and no clue.
The line it prints instead names `scripts/restore-build-inputs.sh`.
That guard exists because chaining a rebuild into `40-repo.sh` without
checking it succeeded packaged a rootfs with no desktop in it, and
41-desktop-split.sh then deleted from the base exactly what that empty
manifest described — no desktop in the image AND none in the
repository. **Never chain `40-repo.sh` after an unchecked build.**

**`40-repo.sh` now REFUSES to run on an already-split rootfs**, and that
guard exists because the comment above did not stop it happening.
pkgsplit computes the desktop from what is *in* the rootfs, so running
40 after 41 has taken the desktop out asks a question whose honest
answer is "nothing leaves the base": an empty manifest, a repository
holding one meta-package, and a 95 MB-smaller ISO with no desktop
anywhere — no error, because an empty answer is a valid answer.
`bash build.sh` never trips it; re-running stages by hand does. The
recovery is the stages, in order: `bash build.sh --from 06 --to 29`,
then 40, 41, 42.

**`restore-build-inputs.sh` launders stale files forward.** It restores
headers and `.pc` files *from the packages*, so anything that was in a
package once stays in every package built from that restored tree,
even after the stage that produced it stopped producing it. A clean
06..29 rebuild put 440 headers in `/usr/include`; the restored tree had
543. The clean number is the right one — treat a manifest that shrinks
after a real rebuild as a correction, not a regression.

**`40-repo.sh` WIPES `/build/repo`, so `42-toolchain-repo.sh` has to run
again after it.** `build.sh` gets this right because it runs the stages
in order; running 40 and 41 by hand and stopping does not. The only
symptom is an ISO that is 95 MB smaller and has no `novi-devel` in its
repository — no error, and nothing says which packages a repository
was *supposed* to contain. Check the size, or check
`ls /build/repo/*.pkg.tar.gz | wc -l` (37, not 31).

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
  console base image, and the next `40-repo.sh` failed with pkgsplit's
  straddle check — `usr/lib/libz.so.1 stays, usr/lib/libz.so moves` —
  because a base binary suddenly linked zlib. The error was correct
  and pointed nowhere near the cause. `40-repo.sh` already writes
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
  `40-repo.sh` runs it before packaging, which is the last moment every
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
- **`build/41-desktop-split.sh` deletes exactly what `40-repo.sh`
  packaged**, from the manifest 20 wrote. One source of truth, or the two
  drift and the image ends up broken or still fat. Re-running stages
  06..14 puts the files back; that ordering is what `build.sh` does.
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
