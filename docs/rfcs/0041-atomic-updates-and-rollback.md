# RFC 0041 — atomic root updates, and a way back

**Status:** Design, with **roadmap item 1 implemented for BIOS and
verified on a booted machine** (QEMU/TCG; **no physical hardware**).
Nothing updates or rolls back yet. Every number below was measured on
this build; every claim about what exists was checked in the tree
rather than remembered.
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

**`/var` CANNOT MOVE WHOLESALE, and this RFC said it could.** The
sentence above and roadmap item 1 below originally read *"`/var` and
`/home` onto their own partition"*, which was written from the shape of
the problem rather than from the tree. `/var/lib/pkg/installed` is the
install database — **it describes the slot's own contents**, and under
A/B the two slots legitimately hold different package sets, because
updating the inactive one is the entire point. Share it and the running
system's database claims the versions in the *other* slot while its
files are its own. That is worse than having no rollback: it is a
machine that lies about what it has, to `pkg`, to `novi-state
diff`, and to `novi-agent describe`.

Checked in the tree rather than remembered (`packages/pkg` lines 31-49,
and `/var` on the built image), `/var` is three different things:

| | |
|---|---|
| **slot-local** | `/var/lib/pkg` — the slot's own manifest and index |
| **shared state** | `/var/log`, `/var/lib/novi-state` (RFC 0002's generations are machine history and must outlive a switch), `/var/lib/alsa`, and `/home` |
| **shared cache** | `/var/cache/pkg` — safe to share precisely because RFC 0006 hashes every archive against the signed index before unpacking it, so a shared cache cannot be a shared vulnerability, and not sharing it would mean re-downloading an update the other slot already fetched |
| **neither** | `/var/tmp`, `/var/run` — ephemeral, and `/var/run` is already a symlink into the `/run` tmpfs |

So the split is by named subtree, not by top-level directory. That is
more work than the original sentence implied and it is the actual
shape of the problem.

`/etc` is the hard case and is deliberately left open here. It is
per-machine configuration that a person edits (`system.conf`,
`keys.conf`, `wifi.conf`), so it looks like state — and it is also
what a package upgrade needs to be able to change. Splitting it wrong
is how an update stops being able to fix a broken default. Whatever is
decided, `novi-state` makes the question smaller than it is elsewhere:
the parts of `/etc` that matter are a document the machine can
regenerate.

### 3. The three layouts are not three instances of one job, and the encrypted one has no answer yet.

Item 1 originally said *"for all three layouts (UEFI, BIOS,
encrypted)"*, as though the difference were bookkeeping. Read in the
tree, it is not:

- **BIOS/MBR** is the easy one: `novi-install` drives BusyBox `fdisk`
  with the keystrokes a person would type, and a third primary
  partition is three more lines — with RFC 0018's warning still
  standing, that BusyBox `fdisk`'s default first sector is 63 and
  every sector must be given explicitly.
- **UEFI/GPT** needs `novi-gpt` to write a fourth entry. That is a
  modest change to a small, well-specified program — but it changes
  the tool's stated contract, which is *"Deliberately NOT a general
  partitioner. It writes one layout, the one novi-install needs. A tool
  that can express every layout is a tool that can express the wrong
  one."* (RFC 0008). The new contract is "two layouts", and it should
  be written down as deliberately as the first was. **Done**:
  `--slot-mib N` selects the second, the header says so, and the
  program still refuses to express anything else.
- **Encrypted (RFC 0018)** has no answer here at all, and this is the
  finding. The layout is a plain `/boot` plus a LUKS root. Under A/B
  the two slots AND the shared state must all be inside encryption —
  `/home` on an unencrypted partition would be a silent, serious
  regression for anybody who typed `--encrypt`. Carving three volumes
  out of one LUKS container is what LVM is for, and **this system has
  no LVM and no `dmsetup`**: `34-cryptsetup.sh` builds libdevmapper
  into a private prefix and links it into exactly one static
  `cryptsetup` binary, which is all that is installed.

  The candidates are a new LVM2 dependency (and a second thing that
  must work before root mounts), a second LUKS volume unlocked by a
  keyfile inside the already-unlocked root (which then lives in a slot,
  so both slots must carry it and a rollback must not lose it), or a
  second passphrase prompt. None is obviously right.

  **So encrypted installs get no A/B in the first cut, and the
  installer should say so rather than produce a layout that cannot
  later grow one.** That is the same call this project made about
  `--encrypt` itself, about `libGL` and about DHCPv6: ship where it
  works, name the gap exactly, and do not let a word imply a capability
  that is not there.

### 4. Activation is a bootloader variable, and GRUB cannot do it today.

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

### 5. The layout has to be laid out ONCE, so items 1 and 3 are one item.

A partition table is written at install time and changed by
reinstalling. Splitting state out *without* also reserving the second
slot produces a machine that can never gain A/B without a reinstall —
which is the same as not having done it. So "split state out" and "two
slots at install time" are one change, and the roadmap below says so.

Working the layout through end to end then produced the useful part:
**the A/B shape is RFC 0018's encrypted shape with the encryption
removed**, and most of the bootloader work that looked new is already
done.

| | MBR/BIOS | GPT/UEFI |
|---|---|---|
| p1 | `/boot`, shared | ESP, shared |
| p2 | root slot A | root slot A |
| p3 | root slot B | root slot B |
| p4 | state, shared | state, shared |

A **shared boot partition is what makes rollback work at all**, and it
is not an optimisation: `grub.cfg`, `grubenv` and *both* slots' kernels
have to live somewhere that either slot can boot from. Put `/boot`
inside a slot and rolling back to A means A's `grub.cfg` has to already
list B's kernel — a coupling that breaks the first time the two slots
disagree about what a kernel is called.

On BIOS that shape already exists and already has its bootloader
image: `mkiso.sh` generates **`core-boot.img` with the prefix
`(hd0,msdos1)/grub`** beside the ordinary `core.img`, precisely because
RFC 0018's encrypted layout needs a separate `/boot`. An A/B install
uses it unchanged. On UEFI the ESP is already the shared boot area and
already holds `grub.cfg` (RFC 0008). So the only genuinely new
bootloader work is decision 4's `loadenv`.

MBR gives exactly four primary partitions and this uses all four. That
is a real ceiling — no room for a fifth thing later without an extended
partition or a move to GPT everywhere — and it is worth stating now
rather than discovering it.

### 6. `pkg` should not learn about slots.

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

1. **Lay out the whole thing at once** — shared `/boot` or ESP, two
   root slots, shared state — because a partition table is written once
   (decision 5). The second slot stays empty and the machine boots from
   the first, so this is one bootable, verifiable change that does not
   yet update anything. State splits by NAMED SUBTREE rather than by
   top-level directory — see decision 2. `/home`, `/var/log`,
   `/var/lib/novi-state`, `/var/lib/alsa` and `/var/cache/pkg` onto a
   shared partition mounted at `/state` with `bind` entries in fstab;
   **`/var/lib/pkg` stays in the slot**, because it is the slot's own
   manifest. Bootable and verifiable on its own, and every candidate
   mechanism needs it. Settle `/etc` here, with the argument written
   down.

   **BIOS/MBR and UEFI/GPT only** — see decision 3. The encrypted
   layout keeps today's single root until the LUKS question has an
   answer, and `novi-install` should refuse `--encrypt` together with
   whatever flag asks for the new layout rather than quietly producing
   one that cannot grow slots.

   Two mechanisms were checked against the shipped BusyBox before being
   relied on, RFC 0018's rule about testing the artifact rather than
   the idea: **`mount -a` honours a `bind` entry from fstab** and
   accepts `nofail` (verified in a scratch tree with the static binary
   this repo builds, watching a marker file appear through the bind),
   and **`rc.init` runs `mount -a` before `s6-rc-init`**, so the binds
   are in place before any service starts — which is what `/var/log`
   needs and what would otherwise have been a race nobody saw until
   syslog wrote to the wrong filesystem.

   **DONE FOR BIOS AND FOR UEFI, EACH VERIFIED BY AN INSTALL AND A
   REBOOT.**
   `novi-install --ab` is opt-in: without it every layout is exactly
   what it was. On a 20 GB disk it produced `NOVI_BOOT`,
   `NOVI_ROOT_A`, `NOVI_ROOT_B` and `NOVI_STATE` on vda1..vda4, and
   the machine booted from slot A with:

   ```
   /dev/vda2 on /          ext4     <- slot A, 3.9G
   /dev/vda1 on /boot      ext4     <- shared
   /dev/vda4 on /state     ext4     <- shared state, 11.2G
   /dev/vda4 on /home      ext4     <- bind
   /dev/vda4 on /var/log   ext4     <- bind
   ```

   `/home` and `/var/log` are writable, `/state` holds them, slot B is
   formatted and not mounted, and the check that matters —
   `mount | grep -c /state/var/lib/pkg` — is **0**, with the package
   database in the slot where it belongs.

   **The boot is itself the proof of the bootloader half.** Three
   places tested `$ENCRYPT` where they meant *"is partition 1 the boot
   partition"*, because RFC 0018's encrypted layout had been the only
   reason for a separate `/boot`. With the old condition this install
   would have written `core.img`, whose prefix is
   `(hd0,msdos1)/boot/grub`, onto a disk whose partition 1 IS `/boot`
   — GRUB would have looked for `/boot/boot/grub` and nothing would
   have booted. `separate_boot()` is one predicate for the fact now.
   Found by reading, before the install; confirmed by the install.

   30+4 host checks (`packages/tests/test-install-ab.sh`), each
   provoked. The four-partition sequence is driven through the shipped
   static BusyBox on a sparse file, and asserts that no partition
   starts at sector 63 — RFC 0018's trap, and the reason every sector
   is given explicitly.

   **UEFI is the same layout with the ESP in place of `/boot`**, and
   `novi-gpt --slot-mib N` writes the fourth entry. The tool's contract
   is now "two layouts" and says so in its own header — the change
   decision 3 asked to be written down as deliberately as the first
   one. On the same 20 GB disk, under OVMF:

   ```
   /dev/vda2 on /          ext4     <- slot A, 3.9G
   /dev/vda1 on /boot/efi  vfat     <- the ESP, shared
   /dev/vda4 on /state     ext4     <- shared state, 11.2G
   /dev/vda4 on /home      ext4     <- bind
   /dev/vda4 on /var/log   ext4     <- bind
   ```

   `NOVI_ESP`, `NOVI_ROOT_A`, `NOVI_ROOT_B` and `NOVI_STATE` on
   vda1..vda4; `root=LABEL=NOVI_ROOT_A` on the command line; slot B
   formatted and unmounted; `mount | grep -c /state/var/lib/pkg` is
   **0** again. `BOOTX64.EFI` and `grub.cfg` are on the ESP, which is
   the whole bootloader half here: the removable-media path needs no
   NVRAM entry and no second `core.img`, so unlike BIOS there is no
   prefix to get wrong (RFC 0008).

   **The harness lost that boot before it found it, and the failure
   read as a machine that would not come up.** The reboot phase
   searched the whole serial log from byte zero for `login:`, which the
   LIVE medium had printed an hour earlier — so it matched instantly,
   typed `root` into GRUB, and reported a timeout waiting for a shell
   on a system that had in fact booted and was sitting at its prompt in
   the same log. Every wait takes a byte offset now. Same class as the
   QEMU harness discarding `send-key` errors: **an instrument that
   reads stale output answers a question about the past**, and the
   answer looks like a finding about the present.

   **Still to do here:** the encrypted layout (decision 3), and `/etc`.
2. **`loadenv` in `core.img` and in `bootx64.efi`**, and a `grubenv`
   the installed system can write. Small, and nothing else can start
   until a boot can be steered from userland.

   **DONE, AND VERIFIED BY THREE BOOTS.** `loadenv` is in all three
   images; an `--ab` grub.cfg reads `novi_slot` out of the environment
   block; and `novi-grubenv` writes that block from the running system.
   The demonstration is one disk and three boots with nothing changed
   between them but 1024 bytes:

   | | menu title | kernel command line |
   |---|---|---|
   | boot 1, `novi_slot=a` | `Novi Linux (slot A)` | `root=LABEL=NOVI_ROOT_A` |
   | boot 2, after `novi-grubenv set novi_slot=b` | `Novi Linux (slot B)` | `root=LABEL=NOVI_ROOT_B` |
   | boot 3, "the other root slot: A" chosen at the menu | — | `root=LABEL=NOVI_ROOT_A` |

   Boot 2 reached `/init` and resolved `LABEL=NOVI_ROOT_B` to
   `/dev/vda3`, which is as far as it can get: slot B is a formatted
   filesystem with nothing in it until item 4. That is the steer
   working, not failing.

   **THE OTHER SLOT IS A MENU ENTRY, NOT ONLY A VARIABLE.** If the slot
   grubenv names will not boot, there is no userland to run
   `novi-grubenv` in — so without an entry the recovery path for a
   failed update would be a rescue medium. Boot 3 is that entry, and it
   left `novi_slot` reading `b`: a menu choice is a one-off and does
   not rewrite the document, which is the same separation `novi-state`
   keeps between the running system and the declared one.

   **`grub-editenv` IS NOT ON THIS SYSTEM AND SHOULD NOT BE.** The
   environment block is a fixed 1024 bytes — a byte-exact signature,
   `name=value` lines, `#` padding — so the missing half is a script,
   not a package. `novi-grubenv` is base content in `/usr/sbin`, and
   the installer calls it rather than writing the format a second time.
   RFC 0003 already splits `grub-install` into "generate on the build
   host" and "place on the target"; this is that split for the
   environment block.

   **`load_env` NAMES THE VARIABLES IT WILL ACCEPT.** Called bare it
   imports everything in the file into GRUB's environment, `prefix` and
   `root` included — so a block somebody appended to could redirect the
   bootloader itself. The whitelist form reads `novi_slot` and nothing
   else, guarded by `[ -s ${prefix}/grubenv ]` so a missing or
   truncated block is silence rather than an error message on a machine
   that is fine. An unset `novi_slot` reads as slot A, which is the
   right answer to "I cannot tell".

   **EVERY WAY TO GET THIS FORMAT WRONG IS SILENT**, which is why it
   has 49 host checks against GRUB's own reader rather than against a
   second implementation of `envblk.c`. The first bug it found was in
   its own subject: a missing newline between the last variable and the
   padding produced a file that was 1024 bytes, had the right
   signature, looked right in an editor, and made GRUB **discard that
   variable**. `grub-editenv` reading it is what said so.

   **`strings` CANNOT SEE INTO `core.img`** — grub-mkimage LZMA-
   compresses the i386-pc payload — so the obvious check that the
   module went in proves nothing. What proves it is reconstruction:
   the same module list with `loadenv` produces a file byte-identical
   to the shipped one, and without it a 278-sector image instead of a
   284-sector one. The post-MBR gap is 2047 sectors, so the six it
   costs are affordable, and `novi-install` already refuses a
   `core.img` that does not fit (RFC 0003).
3. *(folded into item 1 — see decision 5. A partition table is written
   once, so reserving the second slot cannot be a later step.)*
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
