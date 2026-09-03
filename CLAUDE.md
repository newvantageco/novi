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

Full pipeline: `bash build.sh` (runs `build/01-fetch.sh` through
`build/05-kernel.sh` in order). Each stage can also be run standalone
(`bash build/0N-*.sh`) but stages depend on prior stages' output in
`/build/{sources,tools,sysroot,rootfs}` — see Architecture below for why
`/build` is hardcoded and unrelated to the repo checkout path.

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
through `novi-state`, not straight to `/etc`.** `novi-settings` writing
`/etc/shadow` directly is a known, tracked exception awaiting exactly
that fix (RFC 0002's roadmap) — not a pattern to copy.

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
