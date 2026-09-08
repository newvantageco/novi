# RFC 0023 — Removable media, and the sticks people actually own

**Status:** Implemented
**Depends on:** RFC 0011 (hardware), RFC 0012 (hotplug), RFC 0002 (declared state)

> **Summary.** Plug in a USB stick and it appears at
> `/run/media/<label>`. `novi-eject` takes it out safely.
> `storage.automount = on` in `system.conf` is the switch, and the
> kernel gained exFAT and NTFS3 — because automount that can only read
> ext4 and FAT is automount that fails on most of the sticks in
> circulation.

## Motivation & Problem Statement

RFC 0012 built the hotplug path: the kernel's uevent stream reaches
`novi-hotplug`, which loads a driver for whatever arrived. Plug in a
USB stick today and all of that works — `usb-storage` loads, the SCSI
layer enumerates it, `/dev/sdb1` appears, `dmesg` says so.

And then nothing happens. There is no way to get at the files without
knowing the device node, knowing the filesystem type, and typing a
`mount` command with the right options. For the everyday user this
project claims to be for, "I plugged in my USB stick and nothing
happened" is not a rough edge; it is the thing not working.

It is also the last big piece of *ordinary desktop* behaviour missing.
Networking, WiFi, audio, power, the firewall, ssh, git and a package
manager are all here. A file manager is here. What is not here is the
step between plugging something in and the file manager being able to
show it.

## Proposed Design

### The kernel could not read most sticks

Before any of the userland: `CONFIG_EXFAT_FS` and `CONFIG_NTFS3_FS`
were both off, and that alone would have made this feature a
disappointment.

Windows and macOS format anything over 32 GB as **exFAT** by default.
Any external drive that has lived on a Windows machine is **NTFS**.
Between them that is most removable media that exists. Mounting one
without these drivers fails with "unknown filesystem type", which
someone reasonably reads as a broken stick rather than as a missing
kernel option.

Both are in-tree and small. NTFS3 is Paragon's driver, read-write,
in-tree since 5.15 — not the ancient read-only `ntfs`, which upstream
removed in 6.9. `UDF` (DVDs, and some large-format media) and
`ISO9660` went in at the same time.

`ISO9660` is worth a note of its own: it had been *force-enabled by
`05-kernel.sh`* with a comment saying the curated config never
mentions it. That is the same class of thing this repo already calls
out — a config that leaves boot-critical symbols unstated — and a
symbol the build has to repair behind the config's back belongs in the
config. It is stated now.

### `novi-mount`, and the four questions it has to get right

`packages/novi-mount add <dev>` is called by `novi-hotplug` when a
block device appears. It is not a daemon; there is nothing to run
continuously. The kernel says a device arrived, this decides, and then
it is over — the same shape as `nft` holding the firewall with nothing
behind it (RFC 0016), and as busybox `uevent` being the listener
rather than something of ours (RFC 0012).

Almost all of the code is deciding **whether to touch the device at
all**, because every wrong answer there is serious:

- **Is it removable?** Two tests, because neither alone is enough. A
  USB hard disk reports `removable=0` — the *medium* is not removable,
  the *device* is — so the sysfs path is also checked for a USB, MMC
  or FireWire ancestor. A hot-plugged SATA disk in a server backplane
  matches neither and is left alone.
- **Is it already mounted?** That single check covers the root
  filesystem, `/boot`, the ESP and the live medium in one, without a
  list of special cases to keep in sync with the installer.
- **Is it in `/etc/fstab`?** Matched on the device node, `LABEL=` and
  `UUID=`, because fstab may use any of the three. A filesystem
  somebody has said where to put does not also get automounted
  somewhere else.
- **Is it a whole disk that has partitions?** Then the partitions are
  arriving as their own uevents and the disk itself is not a
  filesystem. (A stick formatted superfloppy-style, with no partition
  table, *is* — and is handled.)

### What gets mounted, and how

An **allowlist of filesystems**, never `mount -t auto`. The kernel will
try an image as anything it has a driver for, and a filesystem driver
parsing a hostile image is one of the larger attack surfaces a kernel
has. The list is what people plug in, not what the kernel can be
talked into — the same argument as `novi-umh`'s one-entry allowlist
and `novi-gpt` writing exactly one layout.

**`nosuid,nodev`, always.** A setuid binary or a device node on a stick
someone found in a car park is the oldest trick there is. **Not
`noexec`**, and that is a decision: it would block running a script
from a stick, which people legitimately do — this project's own
installer runs from removable media — and the attack it stops requires
the attacker to already be running code on the machine. udisks2 makes
the same call.

**A failed read-write mount falls back to read-only** rather than
failing. A dirty NTFS volume or a stick pulled mid-write will refuse
`rw`; the data is still readable, and nothing about mounting it `ro`
makes the corruption worse. The log line says which happened.

### `/run/media/<label>`, and the label is not to be trusted

A filesystem label is text off a stick somebody else formatted. It can
contain a slash, a newline, a leading dot, or two hundred characters —
and it is about to become a directory name.

`safe_name()` filters it down to `[A-Za-z0-9._-]`, truncates to 64,
and **rejects anything starting with a dot** rather than stripping it:
`..` survives the character filter (dots are in the keep set), and a
hidden directory under `/run/media` is a volume nobody can find.
Anything that does not survive falls back to the device name, which is
always safe. Filtered rather than escaped — the same call `novi-wifi`
makes about an SSID and the package index makes about `|`.

Verified with a real ext4 image whose superblock label field was
written as `../../etc`: it mounts as `/run/media/sdb`, not anywhere
near `/etc`.

Two sticks both labelled `USB` is the normal case, not a rare one, so
a collision gets a `_2` suffix. An empty directory left behind by a
previous mount is reused rather than suffixed.

### `novi-eject`, and why it is not the same as unplugging

`novi-mount remove` runs when the device is **already gone**. It can
only limit the damage: `umount -l`, because a plain `umount` blocks on
writeback to hardware that is no longer there.

`novi-eject` runs while the device is **still there**, and that is the
whole reason it exists as a separate program. "Safely remove" is not
folklore: a write to a stick returns as soon as it is in the page
cache, and the stick's controller may take seconds to finish an erase
block. `sync`, then `umount` — **not** lazy, because a busy mount here
means a program is genuinely still writing and detaching the tree
underneath it would lose exactly the data this is meant to protect —
then `echo 1 > /sys/block/<disk>/device/delete` so the kernel stops
the device and the light goes out.

The power-down is best-effort and says so. The unmount is what
protects the data; a device that stays powered is untidy, not
dangerous. Reported either way, because a "safely remove" that quietly
did half the job is how people learn to ignore it.

### `storage.automount`

```
storage.automount = on | off
```

**On by default**, and the argument is the firewall's in reverse. RFC
0016 turned the firewall on by default because "a firewall you have to
discover is a firewall nobody has". The same reasoning says automount
should be on: it is what every other desktop does, and a machine where
plugging in a stick does nothing reads as broken rather than as
careful. What makes it defensible is what makes the firewall
defensible — it is one line in a file you own.

It has **no converger and no observer of live state**, exactly like
`power.lid` and `power.button` (RFC 0013): `novi-mount` reads it when
a device arrives, so there is no daemon holding it, it cannot drift,
and `apply` has nothing to do. Turning it off takes effect on the next
device rather than the next reboot. And because `converge_key` never
runs for it, the *observer* has to reject a typo — an unusable value
reports as drift rather than sitting in the document reading as
converged while sticks silently failed to mount. `unsupported` rather
than `off` when `novi-mount` is missing, for the same reason
`network.firewall` distinguishes those.

### Nothing in the uevent handler may block

RFC 0012's rule, and mounting is exactly the thing that could break
it: a slow stick, a dirty volume, or a device that has stopped
answering. So `novi-hotplug` backgrounds the call, like `alsactl`.

Backgrounding creates its own problem — two partitions on one stick
produce two uevents in the same millisecond — so `novi-mount` takes a
lock. `mkdir` is the atomic primitive every shell has; there is no
`flock` in BusyBox ash. The stale-lock case is handled by checking
whether the PID inside it still exists rather than by a timeout,
because a handler killed mid-mount would otherwise wedge automount
until the next reboot, silently.

## Alternatives Considered

- **udisks2.** The standard answer, and it is a D-Bus service. RFC
  0009 rejected iwd for the same reason: a message bus daemon in a
  base image whose entire point is not having one.
- **autofs.** `CONFIG_AUTOFS_FS` is even enabled. But autofs mounts on
  *access* to a known path, and the question here is the opposite one
  — what appeared, and what should it be called.
- **`mount -t auto`.** One line instead of an allowlist, and it hands
  a hostile image to whichever driver claims it.
- **Mounting under `/media`.** `/run` is a tmpfs, which is the correct
  lifetime: these mounts cannot survive a reboot, so their mount
  points should not either.
- **Mounting as the desktop user rather than root.** The right answer
  eventually, and it needs a session concept this system does not have
  yet. `uid=0,gid=0,umask=022` on the FAT-family filesystems is the
  interim: readable by everyone, writable by root.

## Verification

A VM with an xhci controller, and six real filesystem images created
with real `mkfs` tools on the build host, hot-plugged one at a time
through QMP `device_add usb-storage` — the kernel path a physical
stick takes, not a loop device.

| media | expected |
|---|---|
| vfat, label `NOVI_FAT` | mounts at `/run/media/NOVI_FAT`, writable |
| ext4, label `NOVI_EXT4` | mounts, writable |
| exFAT, label `NOVI_EXFAT` | mounts — the new kernel option |
| NTFS, label `NOVI_NTFS` | mounts via `ntfs3` |
| ext4, label `../../etc` | mounts at `/run/media/sdd`, and `/etc` is untouched |
| swap, label `NOVI_SWAP` | refused — *"sda holds 'swap', which this system does not mount"* |
| 16 MB of `/dev/urandom` | not mounted, and silently: `blkid` finds no filesystem, which is the ordinary state of a blank partition and not something to log about |

Plus, each of these observed rather than assumed:

- `/proc/mounts` shows `nosuid,nodev` on a mounted stick.
- `device_del` on a **mounted** stick leaves no stale mount, no stale
  directory and no hang — the kernel logs `EXT4-fs (sda): shut down
  requested` and `/run/media` is clean a moment later.
- `storage.automount = off` ignores the next device and says so in the
  log; turning it back on and running `novi-mount add sdb` by hand
  mounts the stick that was already plugged. That pair is the
  read-at-event-time semantics demonstrating themselves.
- `novi-state diff` is clean with the key set either way, because
  there is nothing to converge.
- Two sticks with the **same** label get `/run/media/NOVI_FAT` and
  `/run/media/NOVI_FAT_2`, each with its own contents; ejecting one
  leaves the other mounted and removes only its own directory.
- Ejecting a volume something still has a file open on **refuses**
  — *"is busy — something still has a file open there"* — and leaves
  it mounted, rather than lazily detaching the tree out from under the
  writer.
- The live medium mounts at `/run/live` (iso9660, from `/dev/sr0`) and
  root is the overlay; neither ever appears under `/run/media`.

### A bug found by making the test media before writing the test

`blkid` reports NTFS as `TYPE="ntfs"`. The driver is `ntfs3`. The
allowlist said `ntfs3` and the type from blkid said `ntfs`, so every
NTFS volume — every external drive that has ever been near Windows —
would have been refused as an unsupported filesystem *by code whose
list said it was supported*. Running `blkid` over a real `mkfs.ntfs`
image is what showed it; reading the code did not, twice.

`mount_type()` now returns the mount type from the same function that
decides support, so an entry cannot be added to the list without
saying what to mount it as.

## Impact

- **Kernel:** exFAT, NTFS3, UDF and ISO9660 stated in the curated
  config. ~250 KB.
- **Base image:** `novi-mount` and `novi-eject`, both shell.
- **`novi-state`:** one new key, `storage.automount`.
- **`novi-hotplug`:** two backgrounded calls.

## Still not done

- **No file-manager integration.** `novi-files` has no places sidebar,
  so a mounted volume is discoverable by typing a path or running
  `novi-mount list`. That is the obvious next piece and it is a UI
  change, not a plumbing one.
- **No desktop notification** that something was mounted, because
  there is no notification system.
- **No per-user mounts.** Everything is mounted as root; see the
  alternatives above.
- **No encrypted removable media.** RFC 0018 built LUKS for the root
  filesystem; a LUKS stick would need a passphrase prompt from a
  uevent handler, which is a design question, not an omission.
- **Never run on physical hardware**, like everything else here. The
  USB path is emulated xhci with emulated mass storage.
