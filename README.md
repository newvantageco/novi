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
console system genuinely needs it. The desktop (compositor, panel,
launcher, terminal, fonts, and the whole Wayland/wlroots stack) is 25
packages, and the installation medium carries the signed repository, so
installing it needs no network at all:

```console
$ pkg install novi-desktop        # 25 packages, ~7 seconds, from the ISO
```

Which files leave the base is **computed** from the ELF dependency
graph, not listed by hand, and the build fails if anything left behind
still links against something being moved out — see
[RFC 0007](docs/rfcs/0007-base-desktop-split.md).

Build your own repository with `bash build/20-repo.sh` and serve the
directory over HTTP, or point `mirror` at a local directory. There is
no default public mirror: there is no public Novi repository yet, and
pointing a package manager at a host that does not exist is worse than
pointing it at nothing.

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
- [ ] **Boot it on real hardware** ← next, and nothing here replaces it
- [ ] A published repository + offline release key
- [ ] A Microsoft-signed shim (real Secure Boot); WPA3 (needs mbedTLS)
- [ ] Automount + `novi-eject`; idle-suspend and low-battery; Mesa
- [ ] More state domains: keybindings, static IP
- [ ] Boot splash

See [`docs/PLATFORM-ROADMAP.md`](docs/PLATFORM-ROADMAP.md) for the full
platform roadmap — package/app model, update tracks, hardware, desktop,
gaming, developer, enterprise, security, and governance strategy.
