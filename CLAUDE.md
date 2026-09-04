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
- `bash scripts/mkiso.sh` — squash rootfs + GRUB hybrid ISO (defaults assume
  `${REPO_ROOT}/rootfs` and `${REPO_ROOT}/kernel/vmlinuz`, but the actual
  build output lives at `/build/rootfs` and `/build/rootfs/boot/vmlinuz-<ver>`
  — pass `--rootfs`/`--kernel` explicitly until those defaults are fixed)
- `bash scripts/mkvm.sh [--disk]` — boot the ISO in QEMU/KVM
- `novi-install install --disk DEV` (on the booted live system) — install to
  disk (RFC 0003)
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

When touching any build stage, ask what it does to artifacts a *later* stage
owns. `bash build.sh --from NN` exists and people will use it.

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

## Shellcheck signal-to-noise

`shellcheck build/*.sh scripts/*.sh` reports many `SC2086` (unquoted
variable expansion) findings across the whole `build/` directory — this is
a pre-existing, repo-wide style pattern, not a regression to fix reflexively
when touching a file. Treat it as a known baseline; focus review on new
warnings a change introduces.

## Contribution conventions

Conventional Commits (`docs/branch-strategy.md`, `CONTRIBUTING.md` have the
full type/scope list). PRs target `develop`, not `main`. Architectural
changes — new init subsystems, package format changes, kernel/toolchain
baseline changes, introducing a desktop/GUI stack — require an RFC first
(`CONTRIBUTING.md` § RFC Process; drafts live in `docs/rfcs/`).
