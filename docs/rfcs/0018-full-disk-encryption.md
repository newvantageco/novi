# RFC 0018 — The disk you can lose

**Status:** Implemented
**Depends on:** RFC 0003 (installation), RFC 0008 (UEFI/GPT), RFC 0016 (usermode helper)

> **Summary.** `kernel/config-x86_64` has had `CONFIG_DM_CRYPT` since it
> was written and the image has never contained a program that could
> create or open a container — the same shape of gap RFC 0016 found in
> the firewall. This adds LUKS2 to the base image, an `--encrypt` flag
> to `novi-install`, and a passphrase prompt in the initramfs.

## Motivation & Problem Statement

Everything this project has done about security so far protects a
machine that is running: a firewall, a signed package chain, a small
TCB, compile-time hardening. None of it protects a laptop somebody
walks off with. On a stolen Novi disk today, `/etc/shadow`, every
WiFi PSK in `/etc/novi/wifi.conf`, and every file anybody ever saved
are readable by mounting it.

That is also the one security property a normal person actually asks
for by name, and the roadmap's own §18 entry lists encryption as
outstanding.

## Proposed Design

### One flag

```
novi-install install --disk /dev/sda --encrypt
```

It prompts for the passphrase twice, LUKS2-formats the root partition,
and installs into it. Everything else about the install is unchanged.

There is deliberately no `disk.encrypted` key in `system.conf`.
Encryption is a property of a partition that was created once and
cannot be converged to: `novi-state apply` cannot encrypt a mounted
root filesystem in place, so a key that could never be made true would
be a lie in the document. `cryptsetup luksDump` is where the answer
lives.

### Two layouts, because GRUB has to read something

The kernel and the initramfs cannot live inside the thing the
initramfs unlocks. So each firmware path grows one unencrypted place
for them:

| | unencrypted | encrypted | GRUB reads the kernel from |
|---|---|---|---|
| UEFI | p1 ESP (vfat) | p2 LUKS2 → ext4 root | the ESP |
| BIOS | p1 ext4, mounted `/boot` | p2 LUKS2 → ext4 root | p1 |

Unencrypted means unencrypted: **the kernel, the initramfs and the boot
menu are readable and modifiable by anyone with the disk.** This
protects data at rest against theft. It is not protection against
somebody who can write to the disk and hand it back — that needs
Secure Boot with keys the firmware trusts, which RFC 0011 already says
this project does not have.

The BIOS layout needs a second `core.img`. Its prefix is baked in at
`grub-mkimage` time, and the unencrypted layout's is
`(hd0,msdos1)/boot/grub` — correct when partition 1 *is* the root
filesystem and wrong when partition 1 is `/boot` itself. `mkiso.sh`
therefore generates `core-boot.img` with prefix `(hd0,msdos1)/grub`
alongside it, and `novi-install` picks by layout. CLAUDE.md already
says changing the layout means regenerating `core.img`; this is that,
done deliberately rather than discovered.

### Unlocking

The bootloader passes `novi.luks=UUID=<luks-uuid>` and
`root=/dev/mapper/novi-root`. `/init` resolves the UUID with the same
`resolve_root_device()` the plain-root path uses — a LUKS partition
reports its header UUID to `blkid` with `TYPE="crypto_LUKS"` — prompts
up to three times, and then falls into the ordinary disk-root path
with nothing else changed. Three attempts and then the emergency
shell, rather than an infinite prompt: a person who cannot type the
passphrase needs a shell to look at the disk from, not a loop.

`novi.luks=` rather than dracut's `rd.luks.uuid=` or Arch's
`cryptdevice=`: this initramfs is neither, and a parameter that looks
like somebody else's implies the rest of their semantics.

### The tool

`cryptsetup` 2.7.5, **one static binary**, built by
`build/34-cryptsetup.sh` with `--enable-static-cryptsetup`. Static for
two reasons, and the second is the one that matters:

1. The initramfs is a different root filesystem. A dynamic cryptsetup
   means shipping the loader and four libraries into it and keeping
   that list correct forever; one file cannot rot.
2. The static libraries never reach `${ROOTFS}`, so pkgsplit never
   sees a `.a` or a header it has no `PACKAGE_TABLE` pattern for, and
   the base/desktop split does not have to learn about any of this.

The crypto backend is **`kernel`** — AF_ALG, the kernel's own crypto
through a socket. Every other backend cryptsetup offers is a library
this image has refused to carry (OpenSSL, gcrypt, NSS, nettle), and
the whole argument for `novi-verify` in RFC 0006 was that a base image
with no TLS stack stays that way. Argon2 comes from cryptsetup's own
bundled implementation for the same reason.

Four dependencies, none of them optional in cryptsetup's
`configure.ac`: `popt`, `json-c` (LUKS2 metadata *is* JSON), `libuuid`
and `libdevmapper`. The last two come out of util-linux and LVM2,
which are enormous trees fetched for exactly one library each — both
know how to build just that library, so neither is built in full.

### Kernel

`CONFIG_CRYPTO_XTS=y` is the only addition, and it was the one hole:
`DM_CRYPT`, AES, AES-NI, SHA-256 and the AF_ALG user API were all
already set, but XTS — the mode LUKS2's default `aes-xts-plain64`
needs — was unmentioned, which means `n`. dm-crypt was present and
could not have opened the container cryptsetup creates by default.

## What this is not

- **Not an encrypted `/boot`.** See the table above.
- **Not encrypting an existing installation.** `--encrypt` is an
  install-time choice; converting in place is `cryptsetup reencrypt`,
  which this build deliberately disables.
- **Not a keyfile, a TPM, a recovery key, or a second keyslot.** One
  passphrase. `cryptsetup luksAddKey` works on the installed machine
  for anyone who wants more.
- **Not swap or `/home` on separate encrypted volumes.**
- **Not `--encrypt` in `novi-settings`.** An installer flag is not a
  desktop feature.

## Verification

Live, in QEMU, because an installer that has not installed anything is
an assertion. The whole matrix, on the shipped ISO:

|  | plain | encrypted |
|---|---|---|
| **BIOS** | installs, reboots, `/dev/vda1 on /` | installs, reboots, unlocks |
| **UEFI** | installs, reboots, `/dev/vda2 on /` | installs, reboots, unlocks |

1. **LUKS2 works at all.** On a 64 MB file in a booted VM:
   `luksFormat` → `luksDump` shows `aes-xts-plain64`, 512-bit key →
   `open` → `mke2fs` → mount → write → `close`. The wrong passphrase
   is refused with `No key available with this passphrase.` and exit
   2. `lsmod` afterwards shows `dm_crypt` and `dm_mod`, **neither of
   which anything modprobed** — that is RFC 0016's usermode helper
   paying for itself a second time.
2. **Encrypted UEFI.** `novi-install install --disk /dev/vda --encrypt`
   → GPT with a 512 MiB ESP and an 11.7 GiB LUKS2 partition; the
   kernel and initramfs land on the ESP; reboot with no ISO attached
   and the firmware finds `BOOTX64.EFI`, GRUB loads `/vmlinuz` from
   the ESP, and `/init` prints `Encrypted root: /dev/vda2` and
   prompts. Wrong passphrase → `No key available` → prompted again →
   correct passphrase → `vault login:`. On the running system:
   `/dev/mapper/novi-root on / type ext4`, `blkid /dev/vda2` →
   `TYPE="crypto_LUKS"`, `cryptsetup status` → LUKS2, aes-xts-plain64,
   512 bits, key in the kernel keyring, and `novi-state diff` clean
   with the firewall table loaded.
3. **Encrypted BIOS.** Two partitions, `core-boot.img` (278 sectors)
   in the gap, `/dev/vda1 on /boot type ext4` holding
   `grub/ vmlinuz initramfs.cpio.gz`, `/dev/mapper/novi-root on /`.
4. **Three attempts, then a shell.** Exactly three prompts — counted —
   then `[init] PANIC: Could not unlock /dev/vda2`, an emergency
   shell, and `cryptsetup luksDump /dev/vda2` working inside it.
5. **The plaintext is not on the disk.** `NOVI_SECRET_CANARY_42`
   written to `/root/canary` on the encrypted root, `sync`, then the
   whole 12 GB image read on the *host* with
   `qemu-img convert -O raw … | grep -c` → 0.
6. **No regression.** Plain BIOS and plain UEFI installs still
   partition, install and boot, with `/boot` on the root filesystem
   and `core.img` in the gap, exactly as before.


## Roadmap

- A recovery key, or at least `luksAddKey` from `novi-settings`.
- Encrypted swap.
- `cryptsetup reencrypt`, so a passphrase can be changed and a plain
  install can be converted.
- A TPM keyslot, which is only meaningful once there is a measured
  boot to bind it to — i.e. after a real shim.
- `novi-state health` could notice that the root is encrypted and say
  so; nothing surfaces it today except `cryptsetup status`.
