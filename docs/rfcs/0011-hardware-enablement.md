# RFC 0011: Hardware Enablement

- **Status:** Draft. Implemented and QEMU-verified. **The one thing it
  cannot claim is the one that matters most — see "Verification".**
- **Labels:** `rfc`
- **Author:** platform readiness work (`docs/PLATFORM-ROADMAP.md` §21)
- **Requires:** RFC per `CONTRIBUTING.md` — this adds a boot step, a
  new base-image dependency of substantial size, a kernel baseline
  change, and a state domain.

---

## Motivation & Problem Statement

Ten RFCs got Novi to the point where it installs on both firmware
paths, keeps a journalled root, reaches the network, and delivers
signed packages. All of it was verified in QEMU, and QEMU is a machine
where **the hardware is known in advance and never changes**. Almost
everything below is a place where that assumption was quietly load-
bearing.

Four gaps, each of which turns into "it doesn't work and I can't tell
why" on a real machine:

1. **Nothing loaded a driver it hadn't been told about.** Every module
   load was a hardcoded list — `/init` names storage drivers, the
   network service names NICs, the wifi service names radios. There is
   no udev here and no kernel hotplug helper, so an unusual SATA
   controller, a USB-C dock, or a Realtek NIC nobody listed simply had
   no driver.
2. **No firmware at all.** Most WiFi chips and every modern AMD GPU
   need a blob at probe time. RFC 0009 shipped WiFi and had to end with
   "on a large fraction of real laptops the driver loads and the radio
   does not come up".
3. **The kernel had 57 sound options and userspace had none.** A
   machine with working drivers and no way to open, mix or unmute a
   device does not have audio.
4. **Nothing read a battery or wrote a suspend.** `ACPI_BATTERY`,
   `ACPI_AC`, `CPU_FREQ`, `SUSPEND` all compiled in since the
   beginning; nothing had ever opened one of those files.

## Proposed Design

### `novi-hwdetect`: load what is actually here

The kernel publishes a `modalias` file next to every device it has
enumerated — a string describing the device precisely enough for
`modprobe` to match against `modules.alias`, which `depmod` generated
from every driver's declared device table. Walking those and handing
each to modprobe is exactly what udev's builtin does, in about fifteen
lines.

It runs **twice**: in the initramfs before the root device is searched
for (the difference between finding a disk and dropping to an emergency
shell on hardware nobody anticipated), and again from `rc.init` for
everything that was not boot-critical.

Failures are expected and silent. Most aliases have no driver in this
kernel; that is the answer, not an error.

### Firmware, in the base image

**A deliberate exception to RFC 0007's "everything else is a package."**
Firmware is hardware enablement, exactly like the kernel modules
already in the base. Putting the driver blob for your WiFi card in a
package you need working WiFi to fetch is a chicken-and-egg, and
putting your GPU's firmware in a package you need a working display to
install is worse.

A **curated subset**, because linux-firmware is about 4 GB extracted
and most of it is for hardware nobody reading this owns. What is in,
and what is deliberately out:

| In | Why |
|---|---|
| `intel/iwlwifi` (277 MB) | the radio in most laptops |
| `amdgpu` (111 MB) | **amdgpu does not initialise at all without it** — no firmware, no DRM device, no desktop |
| `ath10k/11k/12k`, `mediatek/mt7*`, `rtw88/89`, `brcm`, `qca` | the rest of the WiFi market |
| `i915`, `xe` | Intel display power management and newer GPUs |
| `cirrus`, `intel/sof*` | the audio amplifiers and DSPs in recent laptops |
| `rtl_nic`, `amd-ucode` | Realtek Ethernet; CPU security fixes applied at boot |

| Out | Why |
|---|---|
| `qcom` (502 MB) | Snapdragon SoC firmware for ARM hardware this x86_64 image cannot boot on. Relevant the day there is an aarch64 build, not before. |
| `nvidia` (154 MB) | nouveau is the only driver that could use it, and on a laptop with an NVIDIA chip the display is almost always driven by the integrated GPU anyway. |

Result: **699 MB**, and an ISO that goes from 74 MB to 327 MB.

Two files are **not in linux-firmware** and were missed on the first
pass because of it:

- **`regulatory.db`** is its own project (`wireless-regdb`). This
  kernel has `CONFIG_CFG80211_REQUIRE_SIGNED_REGDB=y`, so without it
  and its detached `.p7s`, the wireless stack falls back to the most
  restrictive world-roaming rules — which presents as bad reception,
  not as a missing file.
- **Intel SOF audio firmware** moved out to its own project too. Intel
  laptops from roughly 2019 on drive audio through SOF rather than
  legacy HDA; without it they have no sound while an older machine on
  `snd_hda_intel` is unaffected.

### ALSA, not a sound server

alsa-lib plus `amixer`, `alsactl`, `aplay` and `speaker-test`. Not
PipeWire or PulseAudio: those are session-level sound servers, and they
matter when several applications want the card at once — which needs
applications first. ALSA is the layer that decides whether the hardware
works at all, and that is the question a hardware test is asking.

`rc.init` runs `alsactl init` then `alsactl restore` after hwdetect. A
sound card comes up with everything muted and every level at zero;
that is the kernel being conservative, and it is why "the drivers
loaded and there is still no sound" is the usual first experience of
audio on a from-scratch system.

### `novi-power`, and `power.governor` as declared state

Everything is sysfs — no daemon, nothing running, no new dependency.
The only reason it did not exist is that nobody had opened those files.

The CPU frequency governor is a real, persistent policy decision — how
this machine trades battery life against speed — and exactly the sort
of thing that otherwise lives in someone's half-remembered shell
history. Declared, it survives a reboot and shows up in a diff. It is
set on **every** CPU, not just cpu0: they are set independently, and
half a machine on `powersave` is a performance bug nobody would find.

### The kernel config asked a plain question

"What is in the machine someone would test this on?" None of the
answers show up in QEMU, which is exactly why none of them were there:

- **`CONFIG_I2C_HID_ACPI`.** `I2C_HID` was already set and is useless
  alone — modern laptop touchpads are enumerated through ACPI, and
  without the glue layer the driver never binds. A laptop with no
  working trackpad is the first thing anyone notices.
- **`CONFIG_E1000`.** `E1000E` was set, which is the PCIe driver and a
  *different one*. VMware, VirtualBox and QEMU's classic emulated NIC
  had no driver at all — confirmed live, a guest given `-device e1000`
  came up with loopback only.
- USB Ethernet (`CDCETHER`, `AX88179`, `RTL8152`): a modern laptop's
  only wired port is often on a dock.
- `HID_MULTITOUCH` and the common HID quirk drivers; the laptop
  platform drivers (ThinkPad/Dell/HP/Asus/Lenovo/Acer) that make
  brightness and rfkill keys work; SD card readers.

### Secure Boot: signed, and honest about it

`bootx64.efi` is signed with a locally generated key, and the
certificate ships beside it as `novi-secureboot.der`.

**This does not make Novi boot on a stock Secure Boot machine.**
Firmware trusts Microsoft's keys; getting into that chain needs a
signed shim, which needs an organisation to go through Microsoft's
signing process. What this gives is the *option*: enrol the certificate
in your firmware's db and Secure Boot can stay on. Without enrolling
it, Secure Boot still has to be turned off — exactly as before.

Shipping an unsigned image would have been easier and would have left
"turn off Secure Boot" as the only answer forever.

## Implementation status

- `packages/novi-hwdetect`, run from `/init` and `rc.init`
- `build/26-firmware.sh` — curated linux-firmware, wireless-regdb, SOF
- `build/27-audio.sh` — alsa-lib and alsa-utils
- `packages/novi-power`, `power.governor` in `novi-state`
- `kernel/config-x86_64` — the laptop hardware above
- `scripts/mkiso.sh` — Secure Boot signing and certificate

Slack removed while here: four libnl libraries (3 MB) nothing links
against. `System.map` stays deliberately — it is exactly what decodes
an oops on unfamiliar hardware.

### Bugs found on the way

- **`grep -c . || printf 0`** appends a second zero when grep counts
  nothing, because grep exits non-zero then and the fallback fires
  too. The count became `"0\n0"` and the arithmetic rejected it as
  "bad number". `wc -l` always succeeds.
- **A tar wildcard that matches nothing is not an error worth
  noticing** among two hundred others. The first firmware extraction
  produced 393 MB with **zero iwlwifi files** and looked like a
  success, because linux-firmware had reorganised into per-vendor
  directories and the top-level `iwlwifi-*.ucode` pattern silently
  matched nothing. The stage now distinguishes "pattern matched
  nothing" (expected) from a real tar failure, instead of discarding
  stderr and trusting an exit code that was wrong in both directions.
- **libtool `.la` files reference each other.** Removing
  `libasound.la` but leaving `libatopology.la` made alsa-utils stop
  with "cannot find the library '/usr/lib/libasound.la'" — a path
  correct on the target and meaningless on the build host.
- **`AM_PATH_ALSA` is a link test, not pkg-config**, so `PKG_CONFIG`
  alone was not enough and alsa-utils compiled against the build
  host's headers, found none, and stopped while the cross-compiled
  library sat in the rootfs.
- **`novi-hwdetect` ran in the initramfs before the initramfs had
  `tr`.** It loaded every driver correctly and then died on the last
  line, counting what it had loaded: `tr: not found`. The applet list
  in `mkinitramfs.sh` is hand-written and `tr` was not on it. Two
  fixes, because either alone leaves the trap set: the applet list
  gained `tr`, `comm`, `mktemp`, `basename`, `dirname`, `readlink` and
  `mdev`, and the script no longer needs any of them — `comm` falls
  back to `grep -Fxv -f`, and arithmetic replaces `tr -d ' '`. A
  script whose whole job is early boot must not fail on its own
  reporting.
- **`echo x > /proc/... 2>/dev/null` does not suppress anything.**
  Redirections are applied left to right, so the failing `>` is
  reported while stderr is still the console. The mdev hotplug-helper
  write now tests `[ -w ... ]` instead.
- **A builtin and a missing module look identical to modprobe**, so
  `/init`'s hardcoded list printed a `WARNING: Could not load module`
  line for each of ten filesystems and controllers that were compiled
  in and working, on every boot. Twenty-two lines of warning that
  meant nothing is how people learn to ignore warnings. `/sys/module`
  distinguishes the two; the genuinely-absent ones are now one line.

## Verification

QEMU, with hardware QEMU can actually emulate.

- **`novi-hwdetect` loads drivers nothing names by hand.** Booted
  under UEFI with `virtio-balloon-pci`, `virtio-rng-pci` and
  `virtio-keyboard-pci` — three devices whose drivers are modules and
  which appear in no `modprobe` list anywhere in this system — and
  `lsmod` on the running system shows `virtio_balloon`, `virtio_rng`
  and `virtio_input` live. Nothing else could have loaded them. A
  second `novi-hwdetect --report` from the shell then correctly
  reports nothing new, having found all 70 aliases already handled.
- **An e1000 NIC, also in no list, gets a lease.** `eth0` at
  `10.0.2.15/24` with a default route, and `/run/novi/network.device`
  naming it, on a driver the network service never mentions.
- **Audio, end to end.** With `-device intel-hda -device hda-duplex`:
  `/dev/snd/` populated, `aplay -l` listing the card, and
  `amixer sget Master` reporting **73% and `[on]`** — unmuted, which
  only happens because `alsactl init` ran at boot.
- Firmware present and correct on the booted image: 693 MB,
  `regulatory.db` and its signature, 194 iwlwifi files, all four SOF
  directories.
- `novi-power status` correctly reports no battery and no cpufreq
  driver on a VM, and lists the suspend states the firmware offers
  (`freeze mem disk`).
- `novi-state diff` clean; services, networking, packages and the
  desktop split all unregressed.

### What this does NOT verify, and it is the important part

**None of this has run on physical hardware. Not once.** Every claim
above is QEMU, and the entire subject of this RFC is the things QEMU
does not have.

`novi-hwdetect` is proven to work — but on three virtio devices, which
is the easiest possible case: their aliases are simple, their drivers
are in this kernel, and they need no firmware. The hard case is an
unknown SATA controller, an NVMe behind a bridge, a Realtek NIC nobody
listed. The mechanism is the same one udev uses and there is no reason
it should behave differently, but "no reason it should" is not a test.

The firmware is present but no device has ever requested a byte of it.
The I2C-HID and platform drivers cannot be tested here at all. Suspend
was never actually entered, and `bootx64.efi` has never been presented
to a firmware that enforces Secure Boot.

This RFC makes a real machine much more likely to work. It does not
demonstrate that one does, and no amount of further QEMU work would.

## Roadmap

- **Boot it on physical hardware.** Everything else here is a
  prediction.
- **Firmware as packages, selected by hardware.** The right long-term
  shape: `novi-install` walks the target's modalias list and installs
  only the firmware that machine needs, instead of every image
  carrying 699 MB. It needs the live medium to still carry all of it,
  so it is a saving on installed systems, not on the ISO.
- **A shim for real Secure Boot**, which is an organisational step
  before it is a technical one.
- **Hotplug.** `novi-hwdetect` runs at boot; a device plugged in
  afterwards is still not noticed. That wants a real uevent listener.
- **Lid, power button and hotkeys.** `novi-power suspend` works; what
  is missing is anything that *calls* it when you close the lid.
- **Mesa**, for GPU acceleration. The compositor renders in software
  today, which will be visible on a high-resolution screen.
