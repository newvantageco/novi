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
the file exists. `--base-only` stops after the kernel (01–05: bootable
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
- `bash build/20-repo.sh` — build and sign the first-party package
  repository into `/build/repo` (RFC 0006); serve that directory over HTTP
  and point a machine at it with `mirror =` in `/etc/novi/pkg.conf`
- `bash build/25-wifi.sh` — libnl, wpa_supplicant, `iw`, `novi-wifi`
  (RFC 0009); also builds hostapd into `/build/wifi-test/` for the hwsim
  test harness, deliberately not into the image
- `bash build/23-e2fsprogs.sh`, `bash build/24-novi-gpt.sh` — real `mke2fs`
  (journalled ext4) and the GPT writer UEFI installs need (RFC 0008)
- `bash build/21-desktop-split.sh` — **destructive**: removes the packaged
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

- The GUI's `novi-state` calls **block the Wayland event loop**. Fine
  for a `set` (one awk pass) or an `apply` (a couple of s6-rc
  transitions); not fine once a domain converges something slow, like a
  package install. There's a comment at the call site.
- `observe_service()`'s live-service-list cache **must be primed from
  the parent shell** (`service_cache_load`), never lazily inside the
  function: callers use `have="$(observe_key …)"`, and a command
  substitution is a subshell, so the assignment would be discarded.
  Same subshell trap `packages/pkg` hit for real.
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

**And do not repair a broken `/build` by hand.** Extracting packages back
over the rootfs to recover build inputs, then deleting what does not
belong with an ad-hoc `rm` loop, produces a tree nobody can reason
about — including an image that reached s6-linux-init and never started
stage 2, with no error anywhere, resisting several rounds of bisection.
Re-running the stages in order fixed it in one pass and would have been
faster from the start. The stages are the recovery mechanism; that is
what they are for.

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
- **`build/21-desktop-split.sh` deletes exactly what `20-repo.sh`
  packaged**, from the manifest 20 wrote. One source of truth, or the two
  drift and the image ends up broken or still fat. Re-running stages
  06..14 puts the files back; that ordering is what `build.sh` does.
- **The s6 service definitions for `seatd`/`novi-shell`/`graphical` stay
  in the base** even though their binaries do not. s6-rc does not check
  that a run script's binary exists, so a declared-off service pointing at
  a not-yet-installed binary is inert, not broken — and a machine that
  installs `novi-desktop` can then just flip the key.

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

## Architecture: WiFi, and the second secret store

RFC 0009 (`docs/rfcs/0009-wifi.md`).

- **wpa_supplicant is built with `CONFIG_TLS=internal`**, so it links no
  OpenSSL. The base image has none and `novi-verify` exists so it stays
  that way. iwd was rejected because its control interface is D-Bus.
- **No WPA3**, and that is a decision, not an omission: SAE/OWE need EC
  crypto that internal TLS does not implement (it links to
  `undefined reference to crypto_ec_get_prime`). mbedTLS is the named way
  in. It connects to WPA3 routers in transition mode, not to WPA3-only
  networks.
- **`network.wifi` and `network.wifi.interface` are all that is declared.**
  Passphrases live in `/etc/novi/wifi.conf` at 0600, in wpa_supplicant's
  own format, managed by `novi-wifi`. Same rule as `/etc/shadow`:
  configuration is declared, secrets are not.
- **Wired beats wireless** in `pick_interface()`, and a wireless device is
  one with `/sys/class/net/*/phy80211` — the kernel saying what it is, not
  a name starting with `wl`.
- **hostapd is built by `25-wifi.sh` and never installed.** It is the test
  peer; verification runs two `mac80211_hwsim` radios, one AP one station,
  with a real WPA2 handshake between them. It needs `CONFIG_TLS=internal`
  too — its default backend is OpenSSL and it does not ask.

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
