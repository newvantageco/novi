# Novi Linux
## *One source of truth for your whole machine.*

From scratch. musl libc. s6 init. No bloat.

---

### The idea

On every other Linux desktop, the GUI and your config files are two
separate, unreconciled truths. Click a toggle in Settings and it
vanishes into a binary keystore — ungreppable, unversioned, absent from
your dotfiles, unknown to the config file that supposedly governs the
same thing. Edit the config file and the GUI has no idea. Nothing can
tell you what actually changed.

NixOS and Guix fix that by removing the GUI and handing you a
functional programming language instead.

**Novi's answer: clicking a toggle and editing a text file are the same
operation, on the same file.**

```console
$ cat /etc/novi/system.conf          # this IS your system's config
hostname = novi
network.dhcp = on
network.dns = auto
services.novi-shell = off

$ novi-state diff                    # has anything drifted?
==> system matches declared state

$ novi-state set services.novi-shell on
  -> declared: services.novi-shell = on
  -> run 'novi-state apply' to make it so

$ novi-state apply                   # the desktop starts existing
==> snapshot saved as generation 0001
  -> services.novi-shell: off -> on
==> applied 1 change(s)

$ novi-state rollback                # and stops. reversibly.
```

One plain-text file. Real `diff`. Real rollback. Every setting visible,
greppable, and committable to git.

And the Settings app is a front-end to *that same file* — it shows you
which settings the running system doesn't currently match, writes your
changes back into the file (comments and all), and picks up edits you
made in `$EDITOR` a moment ago. Not a hidden copy. The same document.

The machine **boots into** that file too, so it governs your system
rather than just describing it. If a declared state ever locks you out,
`novi.state=off` in the bootloader skips convergence and gives you a
normal boot back.

See [`docs/rfcs/0002-declarative-system-state.md`](docs/rfcs/0002-declarative-system-state.md).

---

## Project Structure

```
novi/
├── build.sh                  ← run this to build everything
├── build/
│   ├── 00-versions.sh        ← OS identity + all package versions
│   ├── 01-fetch.sh           ← download all sources
│   ├── 02-toolchain.sh       ← cross-compiler (binutils + gcc + musl)
│   ├── 03-base.sh            ← BusyBox userland + rootfs layout
│   ├── 04-s6.sh              ← s6 supervision stack
│   ├── 05-kernel.sh          ← Linux kernel
│   └── 06..20-*.sh           ← Wayland stack, desktop, pkg, novi-state,
│                                installer, networking, signed repo
├── novi-shell/               ← the compositor (RFC 0001)
├── novi-panel/               ← top bar + taskbar
├── novi-launcher/            ← Alt+Space search / symbol picker
├── novi-settings/            ← Settings app
├── novi-lockscreen/          ← Super+L session lock
├── novi-screenshot/          ← PrintScreen capture
├── novi-verify/              ← Ed25519 verifier (package trust root)
├── init/
│   ├── s6/
│   │   ├── stage1            ← PID 1 (mounts vfs, hands to stage2)
│   │   └── stage2            ← start s6-rc, launch supervision tree
│   └── services/
│       ├── getty-tty1/run    ← supervised login terminal
│       ├── network/run       ← DHCP client (RFC 0004)
│       ├── syslog/run        ← syslogd: /dev/log + /var/log/messages
│       └── klog/run          ← kernel ring buffer → syslog
├── kernel/
│   └── config-x86_64         ← 280+ options, uname -r shows 6.x.x-novi
├── packages/
│   ├── pkg                   ← package manager
│   ├── mkpkg                 ← package builder
│   ├── novi-state            ← declarative state engine (RFC 0002)
│   ├── novi-install          ← disk installer (RFC 0003)
│   ├── mkrepo                ← repository index builder + signer (RFC 0006)
│   └── pkg-format.md         ← package format spec
└── scripts/
    ├── mkinitramfs.sh        ← initramfs builder
    ├── mkiso.sh              ← bootable hybrid ISO (GRUB + squashfs)
    └── mkvm.sh               ← QEMU/KVM test launcher
```

## Build Requirements (Linux build host / WSL2)

```bash
sudo apt install -y \
    build-essential gcc g++ make \
    curl tar xz-utils bzip2 \
    bison flex texinfo libelf-dev \
    bc libssl-dev python3 \
    libmpc-dev libmpfr-dev libgmp-dev \
    rsync cpio file mksquashfs xorriso grub-common grub-pc-bin grub-efi-amd64-bin mtools kmod
```

## Build

```bash
bash build.sh                 # every stage: toolchain → kernel → desktop → installer
bash build.sh --base-only     # stop after the kernel: bootable console, nothing else
bash build.sh --from 15       # resume a build you already got past stage 14
```

Output: `/build/rootfs/`  
ISO: `scripts/mkiso.sh` → `novi.iso`  
Test: `scripts/mkvm.sh` → QEMU with KVM

## Software

`pkg` fetches from a **signed** repository. The index carries every
package's SHA-256, so one Ed25519 signature authenticates the whole
thing — verified on the machine by `novi-verify`, a ~60 KB static
binary built on TweetNaCl, because this base image has no OpenSSL, no
GnuPG, and no certificate-validating TLS.

```console
$ pkg sync
==> Syncing index from http://repo.example/novi/x86_64
  -> signature on the repository index verified
==> index updated: 8 package(s) available

$ pkg install foot
  -> sha256 verified: foot 1.9.2
  -> Installing dependencies...
==> Installing fcft (2.5.1)
==> Installing foot (1.9.2)
```

A tampered package fails its hash and is discarded; a tampered index
fails its signature and the previous one is kept. Both are verified,
not asserted — see [RFC 0006](docs/rfcs/0006-package-repository-and-signing.md).

And because installed software is just another declared key, it rolls
back like everything else:

```console
$ novi-state set packages.foot absent && novi-state apply
$ novi-state rollback        # foot comes back, from the mirror
```

Build your own repository with `bash build/20-repo.sh` and serve the
directory over HTTP. There is no default mirror: there is no public
Novi repository yet, and pointing a package manager at a host that does
not exist is worse than pointing it at nothing.

## Install it

The ISO is a live system with the installer on it. Boot it, log in, and:

```console
$ novi-install list
==> Candidate target disks
  -> /dev/vda  75 MiB  [live media -- not a candidate]
  -> /dev/vdb  8192 MiB

$ novi-install install --disk /dev/vdb --hostname my-machine \
      --user alice --set-root-password
```

That gives you a partitioned disk, a real writable root filesystem, and
GRUB in the MBR — a machine that remembers, which is what makes
`novi-state`'s generations and rollback mean anything.

The installed boot menu includes a **"skip declared-state
convergence"** entry (`novi.state=off`), so a `system.conf` that locks
you out is one menu selection away from a normal boot.

`--user` creates the account *while installing* — with a password, in
`wheel`/`video`/`input`/`audio`/`seat` — and then declares it in the
new machine's `system.conf`, so the account is part of the document
that governs the machine rather than a fact about it nobody wrote down.
Passwords are the one thing deliberately kept out of that document; see
[RFC 0005](docs/rfcs/0005-users-and-accounts.md).

v1 is BIOS/MBR only and one journal-less ext2 partition. Those limits
and the reasoning are in
[`docs/rfcs/0003-installation-and-persistence.md`](docs/rfcs/0003-installation-and-persistence.md).

## Stack

| Component | Choice | Why |
|---|---|---|
| libc | musl 1.2.5 | ~600KB, no legacy baggage |
| init / PID 1 | s6-linux-init | Minimal, composable |
| Supervision | s6 + s6-rc | Dependency-aware, instant restarts |
| Scripting | execline | No shell escaping bugs |
| Userland | BusyBox (static) | Single binary, ~1MB |
| Kernel | Linux 6.10.3-novi | tinyconfig + custom, 280+ options |
| Compiler | GCC 14.2 + musl | Full C/C++ cross-compiler |
| Packages | pkg / .pkg.tar.gz | Custom minimal format |

## OS Identity

```
NAME="Novi"
VERSION="0.1.0"
ID=novi
VERSION_CODENAME=Axiom
PRETTY_NAME="Novi Linux 0.1.0 (Axiom)"
HOME_URL="https://novilinux.org"
```

`uname -r` → `6.10.3-novi`

## Next

- [x] Desktop layer (Wayland compositor, panel, launcher, lock, settings)
- [x] Declarative system state (`novi-state`, RFC 0002)
- [x] Settings is a front-end to the same file (System panel, live drift)
- [x] Boot-time convergence — the machine boots into the declared state
- [x] Installer + on-disk persistence (`novi-install`, RFC 0003)
- [x] Networking + real system logging (`network.*`, syslogd/klogd, RFC 0004)
- [x] Real users (`users.*`, account database, installer accounts, RFC 0005)
- [x] Signed package repository (`pkg sync`, `novi-verify`, `packages.*`, RFC 0006)
- [ ] Split the desktop out of the base image ← next
- [ ] More state domains: keybindings, static IP, WiFi
- [ ] UEFI/GPT install, journalled root
- [ ] Boot splash

See [`docs/PLATFORM-ROADMAP.md`](docs/PLATFORM-ROADMAP.md) for the full
platform roadmap — package/app model, update tracks, hardware, desktop,
gaming, developer, enterprise, security, and governance strategy.
