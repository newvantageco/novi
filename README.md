# Novi Linux
## *One source of truth for your whole machine.*

From scratch. musl libc. s6 init. No bloat.

[![Lint](https://github.com/newvantageco/novi/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/newvantageco/novi/actions/workflows/shellcheck.yml)
[![Build & Test](https://github.com/newvantageco/novi/actions/workflows/build-test.yml/badge.svg)](https://github.com/newvantageco/novi/actions/workflows/build-test.yml)
[![Security](https://github.com/newvantageco/novi/actions/workflows/security-scan.yml/badge.svg)](https://github.com/newvantageco/novi/actions/workflows/security-scan.yml)
[![License: GPL v2](https://img.shields.io/badge/License-GPLv2-blue.svg)](LICENSE)

> **Status: pre-alpha.** Boots, installs, and runs a desktop — in QEMU.
> It has never been booted on physical hardware. Everything below is
> verified, and "verified" means verified in a virtual machine.

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
│   └── 06..25-*.sh           ← Wayland stack, desktop, pkg, novi-state,
│                                installer, networking, signed repo, split,
│                                e2fsprogs, novi-gpt, wifi
├── novi-shell/               ← the compositor (RFC 0001)
├── novi-panel/               ← top bar + taskbar
├── novi-launcher/            ← Alt+Space search / symbol picker
├── novi-settings/            ← Settings app
├── novi-lockscreen/          ← Super+L session lock
├── novi-screenshot/          ← PrintScreen capture
├── novi-verify/              ← Ed25519 verifier (package trust root)
├── novi-gpt/                 ← GPT writer, for UEFI installs (RFC 0008)
├── tools/pkgsplit/           ← computes the base/desktop split (RFC 0007)
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
│   ├── novi-wifi             ← WiFi credentials, 0600 (RFC 0009)
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
    rsync cpio file mksquashfs xorriso grub-common grub-pc-bin grub-efi-amd64-bin mtools kmod \
    sbsigntool openssl
```

## Build

To run it in a VM you need three more packages beyond the list above:

```bash
sudo apt install -y qemu-system-x86 ovmf qemu-utils
```

Then, from a clean checkout:

```bash
bash build.sh                 # everything: toolchain → kernel → desktop → toolchain packages
bash scripts/mkiso.sh         # → build/novi.iso   (builds the initramfs if missing)
bash scripts/mkvm.sh          # boot it in QEMU/KVM
```

That is the whole flow — `mkiso.sh` and `mkvm.sh` take no arguments and
their defaults are correct.

**Budget for it.** A first build is a few hours (the cross-toolchain and
the native GCC dominate), downloads about 4 GB of sources including 1.4 GB
of linux-firmware, and leaves roughly 13 GB under `/build`. `/build` is a
hardcoded absolute path, not relative to your checkout.

```bash
bash build.sh --base-only     # stop after the kernel: bootable console, nothing else
bash build.sh --from 15       # resume; stages are discovered, so NN is just a number
```

**Do the short build first.** `--base-only` stops after the kernel and
gets you a bootable console ISO in a fraction of the time, which proves
your host has every tool the pipeline needs before you commit hours to
the full run. `mkiso.sh` warns that there is no package repository to
put on the image and builds the ISO anyway, which is what you want here.

```bash
bash build.sh --base-only && bash scripts/mkiso.sh && bash scripts/mkvm.sh
```

**One gotcha worth knowing:** `mkiso.sh` reuses an existing
`build/initramfs.cpio.gz` and only builds one when it is missing. After
any change under `init/` you need both steps, or you will boot the old
one and wonder why nothing changed:

```bash
bash build/16-s6-rc-db.sh                                   # regenerate the s6-rc database
bash scripts/mkinitramfs.sh --output build/initramfs.cpio.gz
bash scripts/mkiso.sh
```

### Building from Windows

There is no Windows build — this cross-compiles a Linux toolchain, a
libc and a kernel, and it needs a Linux kernel to do it. **WSL2 works**,
and was checked against what the build actually requires: no loop
devices anywhere (the usual WSL blocker), but it does need `chroot`
into the target rootfs (`09-foot.sh` runs `fc-cache` inside it) and
`mknod` for the initramfs device nodes. Both are fine in WSL2 as root.

```powershell
wsl --install -d Ubuntu          # then reboot, set up your user
```

Then, inside the Ubuntu shell:

```bash
sudo -i                          # the build needs root: chroot and mknod
git clone <your-repo-url> /root/novi && cd /root/novi
# ... the apt install line from above ...
bash build.sh && bash scripts/mkiso.sh
cp build/novi.iso /mnt/c/Users/<you>/Downloads/
```

**Clone and build inside the WSL filesystem, never under `/mnt/c`.**
`/mnt/c` is DrvFs: `mknod` fails there, permissions and case-sensitivity
do not behave, and it is slow enough to turn a long build into an
unbearable one. Copying the finished ISO out to `/mnt/c` at the end is
fine — that is one file.

Budget the disk in WSL's virtual drive, not your repo folder: `/build`
is an absolute path, so it lands inside the Linux filesystem and wants
~13 GB.

A Linux VM on Windows (VirtualBox, VMware, Hyper-V) works equally well
and is more predictable if you would rather not deal with WSL. Give it
4+ vCPUs, 8 GB of RAM (GCC is the memory-hungry part) and a 60 GB
thin-provisioned disk.

If you build inside a VM and want to *test* inside the same VM, that is
QEMU inside a VM. Three ways, in order of preference:

1. **Copy the ISO out to the host and boot it as a second VM.** No
   nesting, full speed, and it is closest to how the image will really
   be used.
2. **Enable nested virtualisation** on the build VM (VirtualBox: *Enable
   Nested VT-x/AMD-V*; Hyper-V:
   `Set-VMProcessor -ExposeVirtualizationExtensions $true`; VMware:
   *Virtualize Intel VT-x/EPT*), and `mkvm.sh` will pick up `/dev/kvm`
   and say so.
3. **Do nothing.** `mkvm.sh` detects the missing `/dev/kvm`, warns, and
   falls back to software emulation. It boots; it is just slow.

On a headless VM use `--display none`, which puts the serial console on
your terminal — every test in this project was run that way.

### Testing it

```bash
bash scripts/mkvm.sh                    # live boot, SDL window
bash scripts/mkvm.sh --display none     # headless, serial on your terminal
bash scripts/mkvm.sh --disk             # attach a qcow2 and test the installer
bash scripts/mkvm.sh --disk --no-iso    # boot the installed disk afterwards
```

Log in as `root` (no password on the live image). Things worth trying:

```console
novi-state show                   # the machine's declared configuration
novi-state diff                   # has anything drifted from it?
novi-state health                 # are the services actually running?
novi-hwdetect --report            # what hardware was found, what loaded
pkg install novi-desktop          # the Wayland desktop, offline from the ISO
pkg install novi-devel            # gcc, make, pkg-config, headers
novi-install install --disk /dev/vda   # install to the qcow2 (with --disk)
```

#### From Windows, with the ISO you copied out

Any of VirtualBox, VMware Workstation Player or Hyper-V will boot it —
the image is a hybrid ISO and supports both BIOS and UEFI. Give it
**4 GB of RAM**: the live system unpacks a squashfs into an overlay in
memory.

- **Hyper-V**: use Generation 2 for UEFI, and **turn Secure Boot off**
  (Settings → Security). `bootx64.efi` is signed with a key this
  project generated itself, which no firmware trusts — that is stated
  plainly in RFC 0011 and it is not a bug you are hitting.
- **VirtualBox**: works as-is for BIOS boot; tick *Settings → System →
  Enable EFI* to exercise the UEFI path instead.

Writing the USB stick: use **Rufus in DD mode**, or balenaEtcher (which
does DD by default). This is a hybrid ISO — an "ISO mode" write that
repacks the filesystem will not produce a bootable stick.

One thing worth separating: booting a *physical USB stick* inside a VM
is possible but fiddly on every hypervisor. Test the ISO file in the VM,
and keep the USB stick for real hardware — which is the test that
actually tells us something new.

Output: `/build/rootfs/` · ISO: `build/novi.iso` (~424 MB)

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
fails its signature and the previous one is kept. The index also
carries a `valid-until` **inside the signature**, because a signature
says *genuine*, not *current* — without it, someone serving you an old
but validly-signed index can hold you at a version with a known hole
forever. All of that is verified, not asserted — see
[RFC 0006](docs/rfcs/0006-package-repository-and-signing.md) and
[RFC 0010](docs/rfcs/0010-repository-freshness-and-upgrades.md).

WiFi works the same way — the network is declared, the passphrase is
not:

```console
$ novi-wifi add my-network              # prompts; never echoes; 0600
$ novi-state set network.wifi on && novi-state apply
```

`system.conf` says *that* this machine uses WiFi. `/etc/novi/wifi.conf`
says *which* networks, at mode 0600. `novi-state diff` can tell you the
supplicant should be running; it cannot tell anyone your passphrase.
WPA2 only for now — see [RFC 0009](docs/rfcs/0009-wifi.md).

**It tries to work on hardware it has never seen.** Nothing in this
system used to load a driver it had not been told about in advance —
three hardcoded `modprobe` lists, all written against QEMU, which is a
fine way to boot a VM and close to useless on a laptop.
`novi-hwdetect` does what udev's builtin does instead: the kernel
publishes a `modalias` string next to every device it enumerated, and
handing each one to `modprobe` matches devices to drivers with no list
to maintain. It runs in the initramfs *before* the root device is
searched for, because the alternative is an emergency shell on any
machine with a storage controller nobody anticipated.

```console
$ novi-hwdetect --report
novi-hwdetect: probed 70 device alias(es), loaded 3 module(s)
```

The image also carries 699 MB of curated firmware (Intel/AMD GPUs,
Intel/Atheros/MediaTek/Realtek/Broadcom WiFi, `regulatory.db`, Intel
SOF audio, AMD microcode), ALSA with `alsactl init` at boot — the
default state of a fresh sound card is *muted*, so without it a working
audio path is silence — and `novi-power` for battery, AC and cpufreq,
with `power.governor` declared like everything else.

It notices devices that arrive *later*, too. A `/sys` walk answers
"what is in this machine" once and is then over, so a supervised
listener on the kernel's uevent socket applies the same rule to
whatever gets plugged in — a headset, a dock's ethernet, a memory
stick:

```console
$ grep hotplug: /var/log/messages
hotplug: added sound/card1
hotplug: unmuting sound card 1 (alsactl init)
hotplug: added block/sda (sda)
```

See [RFC 0012](docs/rfcs/0012-hotplug.md). Automounting a stick is
deliberately not done yet: the mechanism is there, the *policy* is a
real decision (read-write risks a corrupted stick on an unclean pull,
read-only makes it useless), and a half-made choice there loses
someone's files.

The lid and the power button do something now, and what they do is
declared like everything else:

```console
$ novi-state set power.lid ignore     # suspend | poweroff | ignore
```

Wiring that up turned up a bug that had been there since the very
first milestone: **this system could not shut down while anyone was
logged in.** `getty` execs `login` execs the shell, so the process s6
supervises is the interactive shell — which ignores SIGTERM by
definition — and with no `timeout-down` the shutdown waited for it
forever. Every `poweroff` had been a hard power cut. Nothing caught it
because every test issued `poweroff` and then killed the VM ten
seconds later without checking. See
[RFC 0013](docs/rfcs/0013-power-events.md).

And it can now tell you when a service is lying to it. `s6-rc` saying
a service is "up" only means *supervised and wanted up* — a distinction
that had hidden four separate bugs here, each on a machine that
reported itself fully converged:

```console
$ novi-state health
syslog  ok up-1403s
klog    CRASHLOOP 3-deaths-up-5s
network NOTREADY up-75s
```

That is deliberately a different question from `novi-state diff`, and
a different exit code: a crash-looping service *matches* the declared
state, and no amount of applying fixes a bug in a service's own
script. See [RFC 0014](docs/rfcs/0014-service-health.md).

**And it builds its own software now.** Every binary here used to exist
because it was cross-compiled somewhere else — which meant the only
machine that could add software to Novi was a machine not running Novi:

```console
$ pkg install novi-devel          # gcc, binutils, make, musl headers
$ gcc -dumpmachine
x86_64-linux-musl
$ gcc -O2 -o hello hello.c && ./hello
hello from a novi-built binary
```

Offline, from the signed repository on the installation medium. That is
not the same as rebuilding the distro — autotools, git and Python still
aren't packaged — but it is the prerequisite for all of it. See
[RFC 0015](docs/rfcs/0015-native-toolchain.md).

**Stated plainly: none of it has been run on a physical machine yet.**
Every claim in this repository is QEMU-verified, and §21 is exactly the
part QEMU cannot answer. See
[RFC 0011](docs/rfcs/0011-hardware-enablement.md).

And because installed software is just another declared key, it rolls
back like everything else:

```console
$ novi-state set packages.foot absent && novi-state apply
$ novi-state rollback        # foot comes back, from the mirror
```

**The base image is console-only.** `/usr/lib` in it holds three
libraries and nothing else: `libskarnet` for s6, `libnl` for the WiFi
supplicant, and `libasound` for audio — each one there because a
console system genuinely needs it. The desktop is packages: eleven
programs — compositor, panel, launcher, settings, terminal, text
editor, file manager, image viewer, lock screen, screenshot tool and
the font — plus the Wayland/wlroots stack they link. The installation
medium carries the signed repository, so installing it needs no network
at all:

```console
$ pkg install novi-desktop        # from the ISO, no network
```

Which files leave the base is **computed** from the ELF dependency
graph, not listed by hand, and the build fails if anything left behind
still links against something being moved out — see
[RFC 0007](docs/rfcs/0007-base-desktop-split.md).

Build your own repository with `bash build/30-repo.sh` and serve the
directory over HTTP, or point `mirror` at a local directory. There is
no default public mirror: there is no public Novi repository yet, and
pointing a package manager at a host that does not exist is worse than
pointing it at nothing.

## The applications

The desktop's programs are first-party and written against raw
xdg-shell, drawing with pixman and fcft — there is no GUI toolkit on
this system, because adding one is a decision with an RFC behind it and
nobody has made it yet.

**`novi-edit`** is a text editor with the two properties an editor has
to have before it can be trusted with a config file. It has undo and
redo (`^Z`/`^Y`), as whole-document snapshots on a bounded budget
rather than an operation log — a snapshot puts back precisely what was
there by construction, and the failure mode of a wrong inverse
operation is silent corruption of somebody's file. And `^Q` on a
modified buffer asks before discarding, rather than throwing the work
away on one keypress. Selection is shift-arrows and `^A`; saving is
atomic (temp file, `fsync`, `rename`) and preserves the original's
mode, so a config file at 0600 does not come back 0644.

**`novi-files`** browses, and changes things. Enter opens a file in the
right program — `.png` goes to the viewer, everything else to the
editor, and the row icon is derived from that same decision so it
cannot disagree with what Enter will do. `F2` renames and refuses a
name that already exists, rather than silently replacing it the way a
bare `rename(2)` would. Delete removes a file or an empty directory on
`y`; a directory with things in it counts the tree first and asks

```
delete 'project' and 214 files in 31 folders?   type yes:
```

There is no trash on this system and no undo in that program, so the
confirmation names what is about to go, and a count that could not be
finished refuses the delete instead of guessing.

**`novi-view`** displays PNG, BMP and PPM, sniffing the format from the
magic bytes rather than the extension, and decoding *before* it opens a
window — so an unreadable file prints a line and exits rather than
flashing up an empty one.

**Copy and paste work between programs**, over core-Wayland
`wl_data_device_manager` — the same mechanism foot speaks, because that
is the only way copying in a terminal and pasting in an editor can
possibly work. And the selection outlives the program that made it:
copy in the editor, close the editor, paste anywhere. That is not free
— a Wayland selection belongs to the client that set it and dies with
it — so novi-shell keeps its own copy and re-offers it when the owner
exits, reading and writing on the compositor's event loop because a
blocking pipe in the compositor freezes every window on the screen.

## Install it

The ISO is a live system with the installer on it. Boot it, log in, and:

```console
$ novi-install list
==> Candidate target disks
  -> /dev/vda  75 MiB  [live media -- not a candidate]
  -> /dev/vdb  8192 MiB

$ novi-install install --disk /dev/vdb --hostname my-machine \
      --user alice --set-root-password --profile desktop
```

That gives you a partitioned disk, a real writable root filesystem, and
GRUB in the MBR — a machine that remembers, which is what makes
`novi-state`'s generations and rollback mean anything.

The installed boot menu includes a **"skip declared-state
convergence"** entry (`novi.state=off`), so a `system.conf` that locks
you out is one menu selection away from a normal boot.

`--profile desktop` (the default) installs the desktop packages from
the medium into the target and declares them, so the machine boots
into a graphical session on its first boot with no network involved.
`--profile console` skips it.

`--user` creates the account *while installing* — with a password, in
`wheel`/`video`/`input`/`audio`/`seat` — and then declares it in the
new machine's `system.conf`, so the account is part of the document
that governs the machine rather than a fact about it nobody wrote down.
Passwords are the one thing deliberately kept out of that document; see
[RFC 0005](docs/rfcs/0005-users-and-accounts.md).

**Both firmware paths work.** The machine's own firmware decides which,
and `--firmware` overrides it:

| | layout | bootloader |
|---|---|---|
| UEFI | GPT: 512 MiB ESP + ext4 root | `BOOTX64.EFI` on the ESP |
| BIOS | MBR: one ext4 partition at sector 2048 | `boot.img` in the MBR, `core.img` in the gap |

The root filesystem is real **ext4 with a journal** — an unclean
shutdown replays a log instead of fscking the whole disk. BusyBox can
neither write a GPT nor make a journal, so Novi ships `novi-gpt` (a
small static GPT writer) and e2fsprogs' `mke2fs`. See
[RFC 0008](docs/rfcs/0008-uefi-and-journalled-root.md) and
[RFC 0003](docs/rfcs/0003-installation-and-persistence.md).

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
- [x] Console-only base; the desktop is packages (RFC 0007)
- [x] UEFI/GPT install + journalled ext4 root (RFC 0008)
- [x] WiFi (`network.wifi`, `novi-wifi`, WPA2, RFC 0009)
- [x] Real upgrades + index freshness (`pkg update`, `valid-until`, RFC 0010)
- [x] Hardware enablement (`novi-hwdetect`, firmware, ALSA, power, RFC 0011)
- [x] Hotplug — devices that arrive after boot (`novi-hotplug`, RFC 0012)
- [x] Lid, power button, and a shutdown that finishes (RFC 0013)
- [x] `novi-state health` — "up" is not "working" (RFC 0014)
- [x] Native toolchain — Novi compiles its own C and C++ (RFC 0015)
- [x] Applications — text editor, file manager, image viewer, with undo,
      real file operations, and a confirmation that names what it will delete
- [x] A clipboard that works between programs, and outlives the one that filled it
- [ ] **Boot it on real hardware** ← next, and nothing here replaces it
- [ ] A published repository + offline release key
- [ ] A Microsoft-signed shim (real Secure Boot); WPA3 (needs mbedTLS)
- [ ] Automount + `novi-eject`; idle-suspend and low-battery; Mesa
- [ ] More state domains: keybindings, static IP
- [ ] Boot splash

See [`docs/PLATFORM-ROADMAP.md`](docs/PLATFORM-ROADMAP.md) for the full
platform roadmap — package/app model, update tracks, hardware, desktop,
gaming, developer, enterprise, security, and governance strategy.
