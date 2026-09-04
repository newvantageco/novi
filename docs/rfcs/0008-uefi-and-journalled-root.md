# RFC 0008: UEFI Installation and a Journalled Root

- **Status:** Draft. Implemented and QEMU-verified on both firmware
  paths; see "Verification".
- **Labels:** `rfc`
- **Author:** platform readiness work (`docs/PLATFORM-ROADMAP.md` §18)
- **Requires:** RFC per `CONTRIBUTING.md` — this adds an on-disk layout,
  a new base-image dependency, a kernel config change, and a boot step.

---

## Motivation & Problem Statement

RFC 0003 shipped an installer with two limitations stated up front:
BIOS/MBR only, and a journal-less ext2 root. Both have been sitting
there since, and between them they mean **Novi cannot be installed on a
typical machine, and should not be trusted with data on one.**

- **UEFI.** Essentially every machine built since about 2012 boots UEFI
  by default. BIOS/MBR-only is not a missing convenience; it is "this
  operating system does not install on your laptop". Everything else
  built so far — the state engine, the package system, the desktop
  split — is worth nothing if it cannot get onto a disk.
- **The journal.** BusyBox's `mke2fs` writes ext2. On a VM that is
  merely untidy. On real hardware it means an unclean shutdown — a
  power cut, a held power button, a kernel panic — turns into a full
  fsck of the whole filesystem and a genuine risk to data, where a
  journalled filesystem replays a few seconds of log at mount time and
  carries on. That is a correctness gap, not a missing feature.

UEFI was deferred once before on the grounds that OVMF was
"pathologically slow" in this project's test sandbox. That turned out
to be wrong: the slowdown had been bisected to USB controller emulation
and never re-tested without it. **A UEFI boot of the ISO reaches a
login prompt in 17 seconds.** The blocker was a stale belief, which is
worth writing down.

## Proposed Design

### `novi-gpt`, because BusyBox cannot write a GPT

BusyBox's `fdisk` creates MBR labels only — it *reads* a GPT and cannot
write one — and the installed system is a static BusyBox with no
`sfdisk`, no `sgdisk` and no `parted`.

`novi-gpt` is a small static C program that writes exactly one layout:

```
GPT
  part 1  NOVI_ESP    512 MiB   EFI System        C12A7328-...
  part 2  NOVI_ROOT   the rest  Linux filesystem  0FC63DAF-...
```

**Deliberately not a general partitioner.** A tool that can express
every layout is a tool that can express the wrong one, and this runs at
the exact moment a disk is being repartitioned.

The alternative considered and rejected was an ESP on an **MBR** label
with partition type `0xEF`. Plenty of firmware boots that, OVMF
included — which is precisely the problem. It would have passed the
test here and failed on somebody's laptop, and "works on my emulator"
is not a claim this project should make about the program that
partitions your disk.

GPT is small, rigid and completely specified, so writing it is bounded
work with an unambiguous right answer — and one that can be checked by
tools that did not write it.

Two details that are the classic GPT bugs, so they are handled
explicitly:

- **GUID byte order is mixed-endian** (first three fields
  little-endian, last two big-endian). The two type GUIDs are spelled
  out as byte literals rather than assembled from strings at runtime: a
  literal cannot get the order wrong twice.
- **The header CRC covers exactly `header_size` bytes with the CRC
  field zeroed**, not the whole sector.

### e2fsprogs, installed beside BusyBox rather than over it

`build/23-e2fsprogs.sh` cross-compiles e2fsprogs and installs
`mke2fs.e2fsprogs`, `e2fsck`, `tune2fs`, `resize2fs`, `dumpe2fs` and
`mke2fs.conf`, plus `fsck.ext{2,3,4}` and `mkfs.ext{2,3,4}` symlinks.

**Selectively, not with `make install`.** e2fsprogs also builds
`blkid`, `findfs`, `fsck`, `uuidgen` and `logsave`, all of which
BusyBox already provides as applets that other parts of this system are
written against — `scripts/mkinitramfs.sh`'s live-media search parses
BusyBox `blkid`'s exact output format. Silently swapping those out
underneath would be a change nobody asked for, in code nobody would
think to re-check.

The new binary is `mke2fs.e2fsprogs`, not `mke2fs`, for the same
reason: BusyBox's applet keeps working for anything that only needs an
ext2, and nothing that used to work starts behaving differently because
this stage ran. The installer asks for the journalled one by name, and
falls back with a loud warning if it is absent — an ext2 root is worse
than ext4 and much better than no install.

`mke2fs.conf` is not optional. Without it `mke2fs` has no idea what
"ext4" means as a feature set.

**One narrow source patch, for musl.** `lib/blkid/llseek.c` picks its
`my_llseek` implementation from what the libc offers; glibc lands on
`lseek64`. musl 1.2.4 removed the LFS64 aliases, so there is no
`lseek64` and no `llseek`, and the remaining branch reads
`#define llseek lseek` — which defines the wrong name, and the file
does not compile. On x86_64 that function is dead code anyway
(`blkid_llseek()` returns through plain `lseek()` because `off_t` is
already 64-bit); it still has to compile. Fixing the name is the
smallest correct change. The build fails loudly if the patch stops
applying.

### The kernel had no character sets

`CONFIG_FAT_DEFAULT_CODEPAGE=437` was set and **every `NLS_*` symbol
was unset**, so `mount -t vfat` would have failed with "Unable to load
NLS charset cp437" — the EFI System partition could not have been
mounted at all. `CONFIG_NLS`, `NLS_CODEPAGE_437`, `NLS_ISO8859_1` and
`NLS_UTF8` are now in `kernel/config-x86_64`.

This had also been quietly breaking the initramfs's vfat fallback for
live media, which nobody had noticed because the ISO9660 path always
matched first.

### One boot menu, two places to put it

`write_grub_cfg()` produces the same menu for both firmware paths; only
where it lands differs, because each GRUB image has its own baked-in
prefix:

| | image | prefix | grub.cfg | needs `search` |
|---|---|---|---|---|
| BIOS | `core.img` in the post-MBR gap | `(hd0,msdos1)/boot/grub` | on the root fs | no |
| UEFI | `bootx64.efi` on the ESP | `/EFI/BOOT` | on the ESP | yes |

The UEFI image is **self-contained** — every module embedded — so the
installer copies exactly one file and there is no module directory to
keep in sync. The BIOS half cannot do that: `core.img` has to stay
small enough for the 2047-sector gap, which is why the two differ.

It goes to `/EFI/BOOT/BOOTX64.EFI`, the removable-media path every UEFI
implementation looks for without being told, rather than a vendor
directory plus an NVRAM boot entry. That means the install needs no
`efibootmgr`, no writable EFI variables, and works on firmware that has
forgotten its boot order — which is most firmware, eventually.

### Firmware is detected, not asked

`/sys/firmware/efi` exists if and only if the kernel was started by UEFI
firmware. It is the kernel's own record of how it got here, not a guess
from hardware, so it is the default. `--firmware uefi|bios` overrides
it. Getting this wrong produces a disk the machine cannot boot, and the
person installing is unlikely to find out until they remove the medium.

## Alternatives Considered

**Ship `sfdisk` or `parted`.** util-linux and parted are both
substantial builds, dragging in libraries this base image exists to
avoid, to run once per machine ever. The property actually needed is
"write one known GPT layout".

**Hand-write the GPT in shell with the `crc32` applet.** Possible, and
a genuinely bad idea: partition-table code whose failure mode is a
destroyed disk should be in a language with types, and should be
testable byte-for-byte.

**Keep ext2 and add `e2fsck` at boot.** Fixes the symptom (a corrupt
filesystem) rather than the cause (no journal), and costs a full disk
scan on every unclean boot instead of a log replay.

## Implementation status

- `novi-gpt/main.c`, `build/24-novi-gpt.sh`
- `build/23-e2fsprogs.sh`, e2fsprogs pinned in `00-versions.sh`/`01-fetch.sh`
- `kernel/config-x86_64` — NLS character sets
- `scripts/mkiso.sh` — generates and stages `bootx64.efi`
- `packages/novi-install` — firmware detection, GPT/ESP path, ext4,
  split bootloader install, ESP in fstab, `--firmware`, `--esp-mib`
- `init/skel/rc.init` — `mount -a`

### A bug this surfaced

**Nothing on this system had ever read `/etc/fstab`.** s6-linux-init's
stage 1 mounts the kernel-owned filesystems and stops, so the fstab the
installer writes was documentation rather than configuration.
Confirmed live on the first successful UEFI install: `/boot/efi`
existed as an empty directory and the ESP named in fstab was simply not
mounted. A kernel update would have written the new image into the root
filesystem and left the firmware booting the old one.

`rc.init` now runs `mount -a` — guarded on the file existing (the live
image has no fstab) and tolerant of failure (a machine must still boot
when a data partition someone added has gone missing). `mount -a` skips
what is already mounted and honours `noauto`, so the root and the
pseudo-filesystems listed for documentation are no-ops.

## Verification

QEMU. UEFI runs are OVMF on `q35` **without USB controllers** — that is
the whole difference between "17 seconds" and the sandbox being unusable
for UEFI, and it is why this work was possible at all.

- **`novi-gpt` checked against tools that did not write it.** util-linux
  `partx` reads both partitions with the right offsets, sizes and
  names; an independent parser confirms the primary header CRC, the
  entry-array CRC and the backup header CRC, the protective MBR's
  `0xEE` type, and both type GUIDs byte for byte.
- **e2fsprogs' `mke2fs` makes a real ext4**: `has_journal`,
  `metadata_csum`, `e2fsck` clean, and `blkid` reports `TYPE="ext4"`.
- **UEFI install and UEFI boot from disk.** Booted the ISO under OVMF
  (`/sys/firmware/efi` present, so genuinely UEFI and not a CSM
  fallback), installed to a blank disk, and cold-booted from that disk
  with the ISO detached: `novi-efi`, `/dev/vda2` mounted ext4,
  `dumpe2fs` showing `has_journal` and `journal_checksum_v3`, the ESP
  mounted at `/boot/efi` with `BOOTX64.EFI` and `grub.cfg` on it, 25
  packages, the desktop services up, `alice` with her declared groups,
  and `novi-state diff` clean. A marker file survived a further cold
  boot.
- **The BIOS path is unregressed** — same installer, same disk layout
  as RFC 0003, re-verified end to end.

## Roadmap

- **Secure Boot.** `BOOTX64.EFI` is unsigned, so a machine with Secure
  Boot enabled will refuse it. Signing needs a shim, a key enrolled by
  someone, and a policy decision about whose key.
- **Kernel updates on the ESP.** Nothing writes the ESP after install.
  A `boot.*` state domain would be the consistent way to express it.
- **`fsck` on boot.** A journal makes it rare, not never. The initramfs
  would need `e2fsck`.
- **More than one root layout.** No swap, no separate `/home`, no
  encryption. Each is a real request and each is a change to
  `novi-gpt`'s single layout — which is the tradeoff that tool made on
  purpose.
