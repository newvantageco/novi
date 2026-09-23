# RFC 0041 — atomic root updates, and a way back

**Status:** Design. **Nothing here is implemented.** Every number below
was measured on this build; every claim about what exists was checked
in the tree rather than remembered.
**Depends on:** RFC 0003 (installation and the `/init` boot paths),
RFC 0006 (the signed index and the trust path), RFC 0007 (the
base/desktop split, and `PKG_ROOT` vs a chroot), RFC 0008 (the two
firmware layouts), RFC 0018 (the encrypted layout)

> **Summary.** `docs/PLATFORM-ROADMAP.md` §3 names atomic root updates
> with rollback as *"the piece that doesn't exist yet"*, leaves the
> mechanism open between A/B slots and a snapshotting filesystem, and
> says that choice blocks `mkiso.sh`/`mkinitramfs.sh`. This decides it:
> **A/B root slots on ext4, updated by `chroot <inactive> pkg update`
> and activated by a bootloader variable.** The snapshotting
> alternatives are rejected for reasons specific to this system, and
> the decision comes with a precondition that does not exist yet and
> has to be built first.

## Motivation & Problem Statement

`pkg` upgrades files in place, on the running root, as root. A failed
upgrade — a power cut between two packages, an archive that unpacks
over a library something else is mid-exec on, a package that installs
correctly and does not work — leaves a machine in a state nothing can
describe and nothing can undo.

**`novi-state`'s generations are not this, and it is worth being exact
about why.** RFC 0002's generations snapshot *observed state*: the
hostname, which services are up, which packages the database says are
installed. `rollback` re-converges the machine to that. It cannot
restore a binary, because it never had one — and the one thing an
update breaks is binaries. The two mechanisms are complementary and
neither substitutes for the other.

So the machine has a declarative description of what it should be and
no way back to what it *was*.

## What is actually here

Measured on this build, not recalled:

| | |
|---|---|
| unpacked rootfs | **792 MB** |
| the same tree as squashfs (zstd) | **300 MB** — 2.6x |
| `mkfs.btrfs` on the target | **absent**; `btrfs-progs` is in no package |
| `mkfs.ext2/3/4`, `mkfs.vfat`, `mkfs.minix` | present (RFC 0008) |
| kernel: `BTRFS_FS`, `OVERLAY_FS`, `SQUASHFS` | `y` |
| kernel: `DM_VERITY`, `DM_SNAPSHOT`, `BLK_DEV_DM` | `m` |
| installed layout, UEFI | GPT: ESP 512 MiB + **one** ext4 root |
| installed layout, BIOS | MBR: **one** ext4 root (or `/boot` + LUKS root) |
| `grub.cfg` on an installed machine | **three static `menuentry` blocks** |
| GRUB's compiled-in modules | `biosdisk part_msdos ext2 normal linux configfile search` — **no `loadenv`** |

**The kernel is not the blocker, and that is the fourth time a
blocking claim in this repository turned out to be about something
already present** (RFC 0031's browser, RFC 0039's namespaces, RFC 0038's
notion of progress). Every mechanism §3 contemplates is already
compiled in. What is missing is userland, layout and a bootloader
variable.

## Decisions

### 1. A/B root slots, because they are the only option that leaves `pkg` in charge.

Three candidates, and the third is the seductive one.

**btrfs subvolumes and snapshots.** Rejected. It needs `btrfs-progs` —
a new upstream of real size, with its own dependencies — and it puts a
filesystem this project has never booted from underneath the one mount
that must always succeed. The kernel driver being present is not the
cost; the userland and the new failure surface on the root filesystem
are.

**Squashfs generations with a persistent overlay.** Rejected, and this
is the one worth arguing with, because it fits the machinery here
better than anything else. `/init` **already** implements both halves:
squashfs + overlayfs for the live path and a plain ext4 root for the
installed one, sharing `finalize_and_switch()`. `mkiso.sh` already
produces the image. A generation would be a **file** of 300 MB rather
than a partition, so the number of generations would be bounded by
free space instead of by a partition table chosen at install time —
three of them cost less than one A/B pair.

It is rejected because of what it does to the update *model*, not to
the disk. A squashfs generation can only be produced by building an
image, and `mksquashfs` is a build-host tool that is in no package. So
either the distribution ships whole images — and `pkg` stops being how
the base is updated, becoming a second mechanism for applications only
— or the target builds its own, which is a new dependency and a
900 MB-scratch operation on a machine that may not have the room.
**The first is a real architecture and it is not this one.** RFC
0006's signed index, RFC 0020's freshness checking and RFC 0007's
derived split are all built around packages being how software
arrives. Demoting that for the base would be a larger change than §3 is
asking for, and it should not happen as a side effect of wanting
rollback.

**A/B slots on ext4.** Chosen. No new dependency: `mkfs.ext4` is
already here, ext4 is already the root filesystem, and — the part that
decides it — **the update mechanism already exists and is verified.**
`novi-install` populates a target by `chroot`ing into it and running
`pkg`, which is exactly what updating an inactive slot is. Not
`PKG_ROOT`: RFC 0007 already records that `PKG_ROOT` relocates where
files land but *not* the install database, which would produce a slot
whose contents and whose database disagree.

The honest cost is disk: two slots is 100% of the OS, fixed at install
time, and two is all you get. Every A/B system accepts that, and on a
792 MB OS it is about 1.6 GB.

### 2. The precondition does not exist, and it is the first thing to build.

**State has to leave the slot.** Today one ext4 partition holds `/usr`,
`/etc`, `/var` and `/home` together. Switch slots with that layout and
you lose every log, every package installed since the slot was made,
every file in a home directory — which is not a rollback, it is a
restore from an old backup nobody asked for.

So the layout becomes: two OS slots, plus a shared partition carrying
at least `/var` and `/home`. That is a change to the rootfs layout
contract, which is exactly what §3 predicted would block
`mkiso.sh`/`mkinitramfs.sh`, and it is separable: it can be built,
installed and booted **before** any A/B machinery exists, and it is
worth having on its own.

`/etc` is the hard case and is deliberately left open here. It is
per-machine configuration that a person edits (`system.conf`,
`keys.conf`, `wifi.conf`), so it looks like state — and it is also
what a package upgrade needs to be able to change. Splitting it wrong
is how an update stops being able to fix a broken default. Whatever is
decided, `novi-state` makes the question smaller than it is elsewhere:
the parts of `/etc` that matter are a document the machine can
regenerate.

### 3. Activation is a bootloader variable, and GRUB cannot do it today.

`grubenv` plus `load_env`/`save_env` is the mechanism, and the
measurement above is that **`loadenv` is not in the module list
`grub-mkimage` bakes into `core.img`** — a one-word change to
`mkiso.sh`, but a real one, and it has to be made for both firmware
paths because BIOS and UEFI carry different prefixes (RFC 0008).

The three static `menuentry` blocks `novi-install` writes become
slot-parameterised, and the rollback rule is the one every A/B system
converges on: **boot the new slot once on trial, and let something
that ran successfully clear the trial flag.** A machine that does not
get that far comes back on the old slot by itself. What counts as
"successfully" is a judgement this system is unusually well placed to
make, because `novi-state health` already answers it (RFC 0014) — but
that is a decision for the implementing RFC, not an assumption here.

### 4. `pkg` should not learn about slots.

It already has everything: it installs into a root it is `chroot`ed
into, it resolves from a signed index, and it verifies every archive
against that index (RFC 0006). Teaching it a second notion of "where
the system is" would put slot logic on the trust path, which is the
one place in this project that stays as small as it can be.

The slot machinery belongs in a tool beside it — `novi-install`'s
sibling — and in `/init`, which already chooses between two root
assemblies and would be choosing between three.

## What this is not

**It is not implemented, and no part of it has been booted.** This RFC
is a decision and a measurement, not a feature. Nothing in the tree
changes as a result of merging it.

**It is not a delivery mechanism.** How an update is fetched, how
often, and what a "track" means on the wire are RFC 0010's and §3's
questions. This is only about applying one atomically and undoing it.

**It is not dm-verity.** A cryptographically verified root is a
different property from a revertible one, it needs the image to be
read-only, and it interacts with the squashfs option this RFC rejects.
Worth its own RFC if anybody wants it; noting only that `DM_VERITY=m`
is already in the kernel.

**It does not make the base immutable.** After an A/B switch the
running root is still writable and `pkg` still works on it. That is a
deliberate limit: immutability is a separate promise, and making it
here would smuggle in the model decision this RFC just declined.

## Roadmap

1. **Split state out of the root.** `/var` and `/home` onto their own
   partition, in `novi-install`, `/init` and the fstab it writes, for
   all three layouts (UEFI, BIOS, encrypted). Bootable and verifiable
   on its own, and every candidate mechanism needs it. Settle `/etc`
   here, with the argument written down.
2. **`loadenv` in `core.img` and in `bootx64.efi`**, and a `grubenv`
   the installed system can write. Small, and nothing else can start
   until a boot can be steered from userland.
3. **Two slots at install time**, with the second left empty. Still one
   bootable system; the layout is just ready.
4. **`chroot <inactive> pkg update`**, then a switch, then a boot from
   the new slot, then a switch back — watched on a booted machine,
   because a rollback nobody has performed is a rollback nobody has.
5. **The trial-boot rule**, and what clears it. `novi-state health`
   is the obvious candidate and the obvious trap: a machine that is
   degraded for an unrelated reason must not roll back an update that
   was fine.
6. **What it costs on a small disk**, measured rather than assumed —
   including what happens when the shared partition is full and the
   inactive slot cannot be written.
