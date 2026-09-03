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
greppable, and committable to git — with a graphical Settings app
writing that same file, not a hidden copy of it.

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
│   └── 06..15-*.sh           ← Wayland stack, desktop, pkg, novi-state
├── novi-shell/               ← the compositor (RFC 0001)
├── novi-panel/               ← top bar + taskbar
├── novi-launcher/            ← Alt+Space search / symbol picker
├── novi-settings/            ← Settings app
├── novi-lockscreen/          ← Super+L session lock
├── novi-screenshot/          ← PrintScreen capture
├── init/
│   ├── s6/
│   │   ├── stage1            ← PID 1 (mounts vfs, hands to stage2)
│   │   └── stage2            ← start s6-rc, launch supervision tree
│   └── services/
│       ├── getty-tty1/run    ← supervised login terminal
│       └── syslog/run        ← structured logging (s6-log)
├── kernel/
│   └── config-x86_64         ← 280+ options, uname -r shows 6.x.x-novi
├── packages/
│   ├── pkg                   ← package manager
│   ├── mkpkg                 ← package builder
│   ├── novi-state            ← declarative state engine (RFC 0002)
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
bash build.sh
```

Output: `/build/rootfs/`  
ISO: `scripts/mkiso.sh` → `novi.iso`  
Test: `scripts/mkvm.sh` → QEMU with KVM

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
- [ ] Settings writes through `novi-state` instead of straight to `/etc`
- [ ] More state domains: packages, users, network, keybindings
- [ ] Boot-time convergence (apply declared state at boot)
- [ ] Package repository
- [ ] Installer
- [ ] Boot splash

See [`docs/PLATFORM-ROADMAP.md`](docs/PLATFORM-ROADMAP.md) for the full
platform roadmap — package/app model, update tracks, hardware, desktop,
gaming, developer, enterprise, security, and governance strategy.
