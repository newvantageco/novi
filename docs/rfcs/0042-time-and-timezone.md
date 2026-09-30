# RFC 0042 — the time domain: a zone, a clock, and something that writes it down

**Status:** **Implemented.** Host-tested (`packages/tests/test-state-time.sh`,
53 checks) and built; **not yet verified on a booted machine** — the
booted check is roadmap item 1 and this document does not claim it.
Every number below was measured on this build; every claim about what
already existed was checked in the tree rather than remembered.

**Depends on:** RFC 0002 (the declarative document, and what does and
does not become a key), RFC 0014 (a readiness nothing can signal),
RFC 0029 (`describe`, and the rule against a second write path),
RFC 0040 roadmap 6 (the RTC this kernel gained, and the write-back
nobody was doing)

> **Summary.** This system had **no time zone data at all** — no
> `/usr/share/zoneinfo`, no `/etc/localtime` — so every timestamp on
> every machine was UTC with no way to say otherwise, and the panel
> clock was calling `localtime_r(3)` against nothing. It shipped
> busybox `ntpd` with **no service to run it**. And RFC 0040 roadmap 6
> gave the kernel an RTC and proved by hand that a correction survives
> a reboot, after which **nothing in the system ever wrote one**. Three
> absences, one domain: `time.timezone`, `time.ntp.servers`, a
> `services.ntp` longrun, and a hook that persists the corrected clock.

## Motivation & Problem Statement

Three gaps, each verified before anything was designed.

**1. There is no zone data.** `find /build/rootfs -name zoneinfo` and
`ls -l /build/rootfs/etc/localtime` both come back empty. musl reads
`/etc/localtime` when `TZ` is unset and searches `/usr/share/zoneinfo`
for a named zone; with neither present every conversion falls back to
UTC. So `date`, `ls -l`, every log line, every file listing in
novi-files and the panel clock have shown UTC on every machine this
project has ever booted, and there was no setting that could change
it. The consumer was **already there** — `novi-panel` calls
`localtime_r(3)` — which is the same shape as several findings in this
repository: the code was ready and the data was absent.

**2. `ntpd` ships and nothing runs it.** busybox builds the applet;
there is no `init/services/ntp`. A machine with a network had a
working NTP client on disk and no way to turn it on short of typing
the command.

**3. Nothing writes the clock back.** RFC 0040 roadmap 6 set
`CONFIG_RTC_CLASS`, `RTC_INTF_DEV` and `RTC_DRV_CMOS`, and proved a
correction survives a reboot — by running `hwclock -u -w` at a shell.
No code in this system has ever run it. So a machine that synced by
NTP, ran for a week and rebooted with no network came back to whatever
the hardware clock had drifted to, and the sync was worth nothing past
the next power cycle. **A capability with no caller**, again.

## Decisions

### 1. The zone data is BASE content, and the full set, because it is small

Measured on this build: `zic -b slim` over the ten primary zone files
produces **598 names over 341 inodes, 203,282 bytes** — 79 KB gzipped.
Against a base image the wrong side of 700 MB that is not a number
worth designing around, so there is no `tzdata` package, no curated
subset and no question about whether a console machine has a clock.

`du` says 2.0 MB for that tree and is the wrong instrument: 454 small
files against a 4 KiB block size is almost entirely slack. The apparent
size is what a squashfs carries.

A curated subset was considered and rejected on the same arithmetic.
Every rule for choosing one — "the zones somebody here is likely to
be in" — is a guess about a stranger's machine, and the saving is
under 200 KB.

### 2. `-b slim`, and the two readers agree

`zic` writes either format. **fat** embeds explicit transitions out to
2037; **slim** stops at the last real transition and leaves the future
to the POSIX TZ footer, which every modern reader evaluates. slim is
what every current distribution ships and what upstream defaults to.

The risk is a reader that ignores the footer, and musl is the reader
here, so it was measured rather than assumed — twice, in two
directions:

* musl against **slim** and musl against **fat**: identical on 35
  instants spanning 1970 to 2035.
* musl against **slim** and glibc against **fat**: identical on 56
  instants across 8 zones, DST boundaries included.

A single comparison could not have distinguished "slim is fine" from
"both readers are wrong the same way". Two formats and two
implementations can.

### 3. `time.timezone` is a key; NTP's *servers* are a key and its
*service* is not

`time.timezone = <IANA name>` converges by repointing
`/etc/localtime`. That is exactly what a `system.conf` key is for: a
persistent configuration with an observable live state and an action
that makes them match.

`time.ntp.servers` is a list; **there is no `time.ntp` on/off key**,
because `services.ntp` already is one. A second key meaning "run the
NTP client" would be RFC 0029 decision 10's test failed — a second
path to a decision that has one — and the two would disagree the first
time somebody set only the new one.

**No default pool ships.** A machine that declares nothing asks nobody
for the time. Baking in `pool.ntp.org` would make every Novi machine
contact a third party on first boot because the distribution decided
so, which is the same class of decision as the firewall opening itself
because a daemon started (RFC 0022).

### 4. A name with no file is REFUSED, not applied

`converge_timezone` will not create a link to a zone that does not
exist. The failure from allowing it is not an error anybody sees: musl
falls back to UTC, the link says `Europe/London`, every timestamp says
otherwise, and nothing reports a problem. The validator additionally
refuses an absolute path, a `..` anywhere, an empty name, a space, and
anything outside `[A-Za-z0-9/_+-]` — because the value is concatenated
onto a directory and becomes a symlink target.

Those guards **overlap on purpose and each is individually provable**.
A clean measurement found that no single clause fails alone: dropping
`*..*` still refuses `../../../etc/shadow` via the character class,
and dropping both accepts it. `/*` is load-bearing only for a name
like `/UTC`, which the first version of the test had no case for and
which now has one.

### 5. The hardware clock is UTC, and the hook says so in one flag

`/usr/lib/novi/ntp-hook` runs `hwclock -u -w`. Without `-u` hwclock
writes **local** time to the RTC, and on a machine with a declared
zone that shifts the hardware clock by the offset — so the next boot
is wrong by exactly that much with nothing anywhere to say why. The
kernel reads the RTC as UTC at boot and `time.timezone` is applied on
top; one convention, stated in the shipped `system.conf`, in the man
page and in the hook itself.

It acts on `step` and `periodic` only. **`unsync` deliberately writes
nothing**: it means ntpd has lost its peers and no longer trusts its
own clock, so persisting that reading is the one thing that should not
outlive the boot. `stratum` is a change of source rather than of time,
and the next `periodic` covers it within 11 minutes.

No RTC is not an error, and neither is a read-only one. A machine
without a persistent clock is a machine whose clock does not persist —
a fact about it, not a failure of this hook, and ntpd must not be made
to look broken by it.

### 6. The service declares no readiness, and refuses rather than inventing a server

`init/services/ntp` has **no `notification-fd`**. ntpd says nothing
when it has a usable peer, and declaring a readiness it can never
signal is RFC 0014's `syslog` bug — a service that reads NOTREADY to
its own health check after sixty seconds, for ever.

With no servers declared it **exits with a message** rather than
starting. An NTP client with no peers is a process that will never do
its job, and the alternative — silently substituting a default — is
decision 3 from the other side.

### 7. `describe` reports the zone, the offset and whether the clock persists — and no timestamp

`novi-agent describe` gains a `time` section: `zone`, `utc_offset`,
`rtc`, `ntp_sync`. There is deliberately **no wall-clock reading** in
it. `describe` says what a machine *is*, and `date` already answers
what the clock reads; a timestamp would also be the one field in the
document that differs between two runs a second apart, which is a
property `test-agent-text.sh` compares the two output forms on.

**The offset is where a broken zone shows up**, which is why it earns
its fork: a zone whose data is missing leaves the link saying one
thing and every timestamp on the machine saying another, and the
offset is the only field that can tell them apart.

The zone is read from the symlink, **not resolved** — `readlink -f`
collapses "set to UTC" and "set to a zone that is not installed" into
one answer, and the second is the one worth seeing.

## What this is not

* **Not verified on a booted machine.** The state engine, the
  validator, the observer, the service's refusal and the hook's
  branches are host-tested; that `date` and the panel clock show local
  time after `novi-state set time.timezone`, and that the RTC stays
  UTC across a reboot, is roadmap item 1 and has not been run.
* **Not a leap-second policy.** busybox ntpd steps or slews as it
  sees fit and this adds nothing to that.
* **No `right/` zones.** The TAI-based tree is not built; every
  timestamp here is POSIX time.
* **Not a clock for a machine with no network and no RTC.** Such a
  machine starts at whatever the kernel decides, as it always has.
* **Not a settings panel.** `time.timezone` is a `system.conf` key, so
  the System panel's inline editor already reaches it — a Time panel
  would be a second write path to a key the GUI has (RFC 0033
  roadmap 3's correction, and RFC 0029 decision 10's test).

## Roadmap

1. **Boot it.** `novi-state set time.timezone Europe/London`, then
   `date`, `ls -l` and the panel clock; then `hwclock -u -r` against
   `date -u` to show the RTC is still UTC; then a reboot with no
   network to show the corrected time survives.
2. **Whether `novi-state health` should notice a clock nobody has
   set.** A machine whose time is years wrong breaks TLS verification
   and package `valid-until` checks before it breaks anything a person
   would notice. Not obviously a health verdict — RFC 0041's trial-boot
   rule already records what happens when an unrelated signal is
   allowed to fire — so this needs the argument made before the code.
3. **`zdump`-style verification in the build stage.** The stage asserts
   one zone reads correctly under the shipped musl; a handful of
   boundary instants across several zones would cost nothing and catch
   a bad `zic` invocation rather than a bad tarball.
