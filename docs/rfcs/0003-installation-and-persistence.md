# RFC 0003: Installation and Persistence

- **Status:** Draft. Implemented and QEMU-verified end to end; see
  "Verification".
- **Labels:** `rfc`
- **Author:** platform readiness work (`docs/PLATFORM-ROADMAP.md`)
- **Requires:** RFC per `CONTRIBUTING.md` — this adds an on-disk layout
  contract, a second boot path in the initramfs, and a bootloader
  installation mechanism.

---

## Motivation & Problem Statement

Before this RFC, Novi could boot and it could not be kept.

The ISO ran entirely in RAM: `scripts/mkinitramfs.sh`'s `/init` found
the live medium by label, mounted `live/filesystem.squashfs` read-only,
stacked a **tmpfs** overlay on top of it, and `switch_root`'d into the
result. Everything a person did in that session — a package installed,
a password set, a `novi-state apply` — lived in the overlay's upperdir,
which is RAM, and was gone at the next power cycle. There was no
installer of any kind: `scripts/` held `mkinitramfs.sh`, `mkiso.sh`,
`mkvm.sh` and `setup-github.sh`, and nothing else.

That makes everything else in the project provisional. `novi-state`'s
whole argument is that `/etc/novi/system.conf` is a document you own,
edit, commit to git and boot into — but a system that forgets the file
at every reboot cannot demonstrate any of that. Generations, rollback,
and boot convergence are all claims about *time*, and a live ISO has no
time. Persistence is not a feature alongside the others; it is the
precondition for them meaning anything.

### The constraint that shapes the design

An installer normally leans on the build host. `grub-install` is a
compiled program that reads the target filesystem's type, generates a
`core.img` containing exactly the modules needed to read it, and writes
both stages to the disk. Novi's installed userland is a **static
BusyBox and a POSIX shell**. There is no GRUB tooling on the target and
there is not going to be: shipping the GRUB build system inside a
distro whose entire premise is a small, auditable base would be
self-defeating.

So the question is not "how do we run grub-install on the target" but
"what part of what grub-install does actually needs a build host".

## Proposed Design

### Split grub-install across build time and install time

`grub-install` does two separable things:

1. **Generate** `boot.img` and a `core.img` with a prefix baked in.
   This needs `grub-mkimage` and the GRUB module set — build-host
   tools.
2. **Place** those two images on the disk (446 bytes into the MBR, then
   the post-MBR gap) and copy the module directory onto the target
   filesystem. This needs `dd` and `cp`.

BusyBox has `dd` and `cp`. So step 1 moves to **ISO build time**
(`scripts/mkiso.sh`), and its output is staged inside the ISO at
`/novi-boot`:

```
/novi-boot/boot.img        512 bytes; only the first 446 are used
/novi-boot/core.img        ~139 KiB, prefix (hd0,msdos1)/boot/grub
/novi-boot/i386-pc/*.mod   the module set core.img will load
```

Step 2 becomes `packages/novi-install`, which is a shell script.

The prefix `(hd0,msdos1)/boot/grub` is baked in at generation time, and
that is what fixes the on-disk layout below: MBR partition table,
partition 1, GRUB under `/boot/grub`. It is a real coupling between
`mkiso.sh` and `novi-install`, and it is deliberate — the alternative
is discovering the layout at install time, which needs the tool we
specifically do not have.

### On-disk layout

```
sector 0          MBR: GRUB boot.img (bytes 0..445) + partition table
sector 1..2047    post-MBR gap: core.img  (~278 sectors used of 2047)
sector 2048..end  partition 1, type 83, bootable, ext2, LABEL=NOVI_ROOT
```

Starting the partition at 2048 is not cosmetic 1 MiB alignment. It is
what creates the gap `core.img` occupies. A partition at the historical
sector 63 would leave room for roughly 31 KiB and the bootloader would
overwrite the filesystem, or vice versa.

`novi-install` refuses to write a `core.img` that does not fit in 2047
sectors rather than discovering the overlap later as filesystem
corruption.

### Finding the root filesystem

By **label**, never by device node. `/dev/sda` and `/dev/vda` are the
same disk seen through different controllers; moving a disk between
machines, or QEMU between `if=virtio` and `if=ide`, renames it. The
label does not move. The generated `grub.cfg` passes
`root=LABEL=NOVI_ROOT`, `/etc/fstab` names the same label, and the
initramfs resolves it by scanning `blkid` output.

### The second boot path in the initramfs

`/init` grew a disk-root path that runs *before* the live-media search:

```
root= given, and boot=live absent   ->  mount that filesystem rw at
                                        /newroot, hand off. No squashfs,
                                        no overlay, no tmpfs.
otherwise                           ->  the existing live path.
```

Both paths end in one shared `finalize_and_switch()` — moving
`/dev`, `/proc`, `/sys`, `/run` across, mounting `/tmp`, locating a
usable init, `switch_root` — so the two cannot drift apart in the
handoff, which is the part that is fiddly and the part nobody re-reads.

`boot=live` is what keeps the two apart, and it earns its keep: the
ISO's own menu entries pass **both** `boot=live` and
`root=live:/dev/disk/by-label/NOVI`. Without the guard, a live boot on
a machine that also has Novi installed would take the disk path on the
strength of that `root=`. The `live:` prefix is *also* rejected
explicitly, so a hand-edited command line that drops `boot=live` still
does the right thing rather than panicking.

### Why ext2, and what that costs

BusyBox's `mke2fs` writes ext2. There is no journal. The kernel mounts
it through the ext4 driver (`CONFIG_EXT4_USE_FOR_EXT2=y` in
`kernel/config-x86_64`), so `mount` reports `ext2` and the code path is
the modern one, but an unclean shutdown means a full fsck rather than a
journal replay.

This is a real limitation, stated here rather than left to be
discovered after a power cut. Fixing it means building e2fsprogs into
the rootfs — a genuine dependency addition, worth doing, out of scope
for a first installer.

### Installing from `/`, not from the squashfs

`novi-install` copies the *running* root, not the squashfs image it
came from. The running root is the overlay, so whatever the person
changed during the live session — a root password, a `novi-state set`,
a package — is part of what gets installed. That is what a live
installer is for. The alternative (unpack the pristine squashfs) would
silently discard the session, which is exactly the class of
"confidently did the wrong thing" this project keeps trying to avoid.

The copy is a `tar` pipe with `/proc`, `/sys`, `/dev`, `/run`, `/tmp`
and `/mnt` excluded. `/mnt` matters more than it looks: the target
filesystem is mounted under it during the copy, so including it would
copy the destination into itself and never terminate.

### Hostname goes through novi-state

Setting the installed system's hostname does **not** `sed` the config
file. It runs `novi-state set` with `NOVI_STATE_FILE` pointed at the
target's copy, because `state_set` is the operation that preserves the
document's comments and ordering (RFC 0002's first invariant). An
installer that reformats the file people are told they own would
undercut the claim on first contact.

`/etc/hostname` is written directly as well, so the very first boot
comes up named correctly even before boot convergence runs.

### The recovery menu entry

The generated `grub.cfg` has three entries: normal, verbose, and
**"skip declared-state convergence"**, which passes `novi.state=off`.
RFC 0002 promises that a declared state which locks you out is
escapable from the bootloader. That promise is only real if the escape
hatch is in the menu that ships, not in documentation telling people to
type it themselves at 2am.

## Alternatives Considered

**Write the MBR partition table by hand with `dd` and `printf`.**
Deterministic and dependency-free, but it reimplements a partitioner in
shell, in a script whose failure mode is destroying a disk. BusyBox
`fdisk` driven by the keystrokes a person would type is less clever and
more auditable. It was verified against this repo's own static BusyBox
rather than assumed.

**Ship `grub-install` in the rootfs.** Rejected: it drags in the GRUB
build system and a dynamic-library surface the base image does not
otherwise have, to run once per machine, ever.

**Persist the live overlay's upperdir to a partition instead of
installing.** This is the "persistent live USB" model. It keeps the
squashfs in the loop forever, so the installed system is permanently a
diff against an image it can never update, and `novi-state`'s
generations would sit on top of a second, invisible layering mechanism
with different semantics. Two overlapping notions of "what changed" is
precisely the problem this project exists to not have.

**UEFI first.** UEFI needs GPT, an ESP, and a signed or at least
present `bootx64.efi`, all of which `mkiso.sh` already produces for the
ISO. It is the right long-term default. It is not first because OVMF is
pathologically slow in this project's test sandbox, and an unverified
installer is worth less than no installer.

## Implementation status

Implemented:

- `scripts/mkiso.sh` — stages `boot.img`, `core.img` and the i386-pc
  module set into `/novi-boot` on the ISO. Warns, rather than fails, if
  the host has no GRUB tooling; the ISO still boots live.
- `scripts/mkinitramfs.sh` — disk-root boot path, shared
  `finalize_and_switch()`, and a fix for the live-media bind mount
  (below).
- `packages/novi-install` — `list` and `install`. Partition, format,
  copy, fstab, hostname, kernel + initramfs, bootloader.
- `build/17-novi-install.sh` — installs it into the rootfs, after
  checking that BusyBox actually has the applets it depends on.
- `build.sh` — now discovers and runs every `build/NN-*.sh` stage
  instead of stopping at 05.

### A bug this work surfaced

`/init` bind-mounted the live medium to `/newroot/run/live` and then,
several lines later, did `mount --move /run /newroot/run`. The move
buried the bind: the mount still existed, nothing could reach it, and
`/run/live` did not exist in the booted system at all. It had been that
way for as long as the bind had existed, and nothing noticed because
nothing had ever needed the live medium after boot.

The installer needs it — the kernel, the initramfs and the staged GRUB
artifacts are only there — so it surfaced immediately, as
`ERROR: no initramfs found at /run/live/boot/initramfs.cpio.gz`. The
bind now happens after the move.

## Verification

Run in QEMU (`-machine pc`, SeaBIOS, virtio-blk, serial console), not
reasoned about:

1. **Live boot, install.** Booted the live system with a blank 8 GiB
   qcow2 attached. `novi-install list` correctly identified the live
   medium and excluded it. `novi-install install --disk /dev/vdb
   --hostname novi-disk --yes` ran to completion: partition created at
   sector 2048, `blkid` reported `LABEL="NOVI_ROOT" TYPE="ext2"`, the
   system copied, `/etc/novi/system.conf` line 21 became
   `hostname = novi-disk` with the file's comments intact, and 278
   sectors of `core.img` went into the gap. The MBR's first bytes read
   `eb 63 90` — GRUB's `boot.img`.

2. **Boot from the disk.** Detached the ISO. SeaBIOS → GRUB from the
   MBR → the generated menu → kernel. Reached a login prompt as
   `novi-disk`. `mount` reported `/dev/vda1 on / type ext2 (rw,noatime)`
   — a real writable root, no overlay. `novi-state diff` reported
   "system matches declared state", so boot convergence ran correctly
   on the installed system.

3. **Persistence across a power cycle.** Wrote a marker file, `sync`,
   `poweroff`. Cold-booted again: the marker was still there.

4. **Live boot is not regressed.** Booted the ISO through SeaBIOS/GRUB
   *with the installed disk also attached*. The live path was taken
   (`overlay on / type overlay`, `/dev/vda on /run/live type iso9660`),
   the installed disk did not hijack it, and `/run/live/novi-boot` and
   `/run/live/boot` were both reachable — the bind-mount fix.

## Roadmap

- **UEFI/GPT.** An ESP with `bootx64.efi`, GPT with a BIOS boot
  partition for hybrid. `mkiso.sh` already builds the EFI half.
- **A journal.** e2fsprogs in the rootfs, real ext4.
- **A `disk.*` state domain.** Right now the installer is the one piece
  of system configuration that does *not* go through `novi-state`,
  because it runs before there is a system to declare. An installed
  machine's layout should still be *describable* in `system.conf` even
  if it is not convergeable.
- **Guided/TUI mode.** `novi-install install --disk` is deliberately
  the whole interface for now; a menu belongs on top of a verified
  non-interactive core, not underneath an unverified one.
- **Users during install.** Related to, and blocked on, the `users.*`
  state domain from RFC 0002's roadmap: today the installed system
  inherits the live session's `/etc/passwd` and `/etc/shadow`, which
  means root-only.

## Impact

Novi is installable. Every claim `novi-state` makes about generations,
rollback and booting into a declared state now has a machine that
remembers, which is the difference between a demo and an operating
system.
