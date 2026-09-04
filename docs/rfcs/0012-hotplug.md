# RFC 0012 — Hotplug

**Status:** Implemented
**Depends on:** RFC 0004 (syslog), RFC 0011 (hardware enablement)

> **Summary.** `novi-hwdetect` answers "what is in this machine" once and
> is then over. This adds the other half: a supervised listener on the
> kernel's uevent netlink socket, so a device that appears *after* boot
> gets its driver loaded too. Verified in QEMU by hotplugging devices
> whose drivers are modules named in no list anywhere in this system.

## Motivation & Problem Statement

RFC 0011 replaced three hardcoded `modprobe` lists with one rule:
the kernel publishes a `modalias` string for every device it has
enumerated, `depmod` built `modules.alias` from every driver's declared
device table, and handing the first to `modprobe` matches them with no
list to maintain.

That rule was applied by walking `/sys`, which makes `novi-hwdetect` a
*coldplug* tool by construction. It answers a question about the
present tense, once, and by the time it has finished walking it is
over. It can never answer "what did someone just plug in", and on this
system nothing else could either:

- A USB WiFi dongle: no driver, no radio.
- A dock's ethernet: no driver, no link.
- A USB headset: no driver, no sound.
- A memory stick: no driver, no `/dev/sda`.

For three of those four the driver is a module in this kernel that
simply never gets loaded. The device is physically present, correctly
enumerated by the kernel, visible in `/sys` — and dead, because the one
thing that reads `/sys` ran twenty minutes earlier.

## Proposed Design

### The listener is busybox, not ours

`uevent` binds `NETLINK_KOBJECT_UEVENT` and runs a program per
notification with the kernel's own variables (`ACTION`, `SUBSYSTEM`,
`DEVPATH`, `MODALIAS`, `DEVNAME`, …) in its environment. It is already
in this BusyBox and it does the one hard part correctly: it forces a
**128 MB** kernel receive buffer, which is the property that decides
whether a burst of events is queued or dropped. Writing our own
listener would be writing that buffer decision again, less carefully.

It calls the handler with `spawn_and_wait`, so a slow handler stalls
the queue. That is survivable *because* of the receive buffer — events
wait in the kernel rather than being lost. Blocking forever is not
survivable, so nothing in the handler may wait on a device.

### The handler is the RFC 0011 rule, driven by a different source

`packages/novi-hotplug` is ~40 lines and does three things:

1. **`ACTION=add` with a `MODALIAS` → `modprobe -q "$MODALIAS"`.** The
   identical rule to `novi-hwdetect`, from the kernel telling us
   instead of us asking. Two sources, one rule. They are deliberately
   not merged: a sysfs walk and a netlink stream have nothing in common
   but the line that acts on the result.
2. **Notes recognisable devices to syslog** (`block`, `net`, `sound`,
   `input`). Not every uevent — one USB stick emits a dozen, most about
   internal plumbing. RFC 0004 built syslog so that things have
   somewhere to write; a private log file in `/run` would need its own
   rotation and would be one more thing that can quietly stop working.
3. **Runs `alsactl init` on a sound card that appears after boot.**
   See below — this is RFC 0011's trap arriving by a different road.

### What it deliberately does not do

- **It does not create device nodes.** `CONFIG_DEVTMPFS_MOUNT` makes
  them, in the kernel, before any of this runs. `mdev` exists in this
  BusyBox and is not used: it would be a second thing creating nodes
  that already exist, with its own rule file to keep in sync.
- **It does not bring up a network interface that appears after boot.**
  The `network` service picks one interface when it starts and keeps
  it, so a dock's ethernet is detected, gets its driver, appears in
  `ip link` — and gets no lease. Fixing that properly means
  per-interface DHCP, which RFC 0009 already names as its own work.
  Reaching into the network service from a uevent handler would be the
  split-brain this project keeps refusing to build.
- **It is not declared in `system.conf`.** Like `syslog` and `klog` it
  is unconditional infrastructure in the `default` bundle. A key to
  turn off hardware detection is a key whose only use is breaking the
  machine.

### The muted-card trap, again

RFC 0011 established that ALSA's default state on a fresh card is
*muted*, and `rc.init` runs `alsactl init` at boot because of it. A
card that arrives afterwards has never been through that — so the
built-in speakers work and the USB headset someone plugs in is silent,
which reads as "unsupported device" rather than "nobody moved the
slider". The handler calls `alsactl init <card>` for a new `cardN`,
backgrounded because it is the one thing here that could take real
time and nothing depends on its result.

Two things learned by actually running it, both of which will mislead
the next person:

- **`alsactl init` exits 99 on success.** "Hardware is initialized
  using a generic method" with exit 99 is the documented path for a
  card no ruleset matches, and the initialisation still happened. It is
  not a failure and must not be "fixed" into one.
- **`alsactl init` only knows standard control names.** Its `default`
  ruleset is a fixed list — `Master Playback Volume`, `PCM …`,
  `Headphone …`, `Speaker …`, `Front …`. A card that invents its own
  name gets the generic method, which does nothing.

## Verification

QEMU, driving the plug events over QMP so they are genuinely runtime
events and not boot-time configuration.

- **A driver in no list, loaded on plug.** `snd_usb_audio` appears in
  no `modprobe` list anywhere in this system (checked by grepping every
  one of them). Baseline `lsmod | grep -c snd_usb_audio` → `0`. QMP
  `device_add usb-audio` → the module is live, `aplay -l` shows
  `card 1: Audio [QEMU USB Audio]`, and its dependencies
  (`snd_hwdep`, `snd_usbmidi_lib`) came with it.
- **A USB stick, end to end.** QMP `device_add usb-storage` with a
  32 MB FAT image → `/dev/sda` and `/dev/sda1` appear, `blkid` reports
  `LABEL="NOVISTICK" TYPE="vfat"`, and the file on it reads back
  correctly through a real `mount`.
- **Removal.** `device_del` on both → `/dev/sd*` gone, the card count
  back to 1, five `removed` lines in the log.
- **The handler's own account**, from `/var/log/messages`:
  ```
  hotplug: added sound/card1
  hotplug: unmuting sound card 1 (alsactl init)
  hotplug: added sound/pcmC1D0p (snd/pcmC1D0p)
  hotplug: added block/sda (sda)
  hotplug: added block/sda1 (sda1)
  ```
- `novi-state diff` clean, the boot-time HDA card still at 73% `[on]`,
  DHCP unregressed.

### RFC 0011's unmute claim, now actually proven

RFC 0011 said the HDA card reading 73% `[on]` after boot "only happens
because `alsactl init` ran". That was an inference, and a weak one: 73%
could have been the driver's own default. It is now a demonstration —
mute `Master` to 0% `[off]`, run `alsactl init 0`, and it returns to
**73% / -20.00dB / [on]**, where `-20dB` is literally the value in
`/usr/share/alsa/init/default`. The claim was right; the evidence for
it was not, until now.

### What this does NOT verify

**Still no physical hardware.** And one specific gap this test cannot
close: the only USB audio device QEMU emulates names its mixer control
`Audio Output Volume Control`, which is in none of ALSA's lists, so
`alsactl init` guesses and a manually-muted control on that card stays
muted — reproduced twice. Real USB headsets present standard names
(`PCM Playback Volume`, `Speaker Playback Volume`) and should be
unmuted correctly, but *should* is the operative word: the one device
available to test with is the one device whose naming defeats the
mechanism. The handler's call is logged for exactly this reason —
so the next person can see whether it ran, separately from whether it
worked.

Deliberately not chased: making the handler unmute by pattern when
alsactl declines. That is second-guessing ALSA's own database, and the
first thing it would get wrong is a control that is muted on purpose.

## Roadmap

- **Automount for removable media.** The mechanism now exists — a stick
  appears, is logged, and mounts by hand. What is missing is policy,
  and it is real policy: mounting read-write invites data loss on an
  unclean pull, mounting read-only makes a USB stick useless for the
  thing people use USB sticks for. Wants a `hotplug.automount` key, a
  `novi-eject`, and a decision — not a quick `mount` in this handler.
- **Per-interface DHCP**, which would let a dock's ethernet work.
  RFC 0009's roadmap already.
- **A desktop that notices.** The panel could show a plugged stick or a
  connected headset; today nothing in the GUI reads any of this.
