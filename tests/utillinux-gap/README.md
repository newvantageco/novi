# What would a util-linux package buy?

RFC 0040 roadmap 3. The roadmap names util-linux beside coreutils and
bash; RFC 0040 scoped it out as *"its own RFC"*. Before writing that
RFC, the same question roadmap 4 asked about sed/grep/awk/tar: **a
number, not an opinion.**

    bash probe.sh                 measure busybox against util-linux
    bash probe.sh --self-check    point BOTH sides at util-linux; must return 31/31
    bash inventory.sh             classify the programs busybox does not provide

Both run on the BUILD HOST against `/build/rootfs/bin/busybox` -- the
static binary this repo ships -- and against Debian's util-linux.
Nothing here needs a VM.

## Two populations, and only one can be compared

util-linux installs **91 programs**. busybox provides **48 of those
names** and lacks **43**. Those are different questions and they get
different instruments.

- `probe.sh` measures the **48 overlapping names**. Where busybox
  answers differently is where somebody gets bitten, and it is the
  only part a package would fix silently.
- `inventory.sh` classifies the **43 missing names**. There is nothing
  to compare against, so the test is REACHABILITY: could this program
  do anything on this machine at all?

## The 48 that overlap: 31 comparable cases, 25 agree, 6 differ

Cases needing root, a block device or a real console are OUT: a probe
that cannot run is not evidence, and guessing at those would be the
feature-list reading this exists to replace.

| tool | agree | differ |
|---|---|---|
| getopt | 5 | 1 |
| flock | 5 | 1 |
| rev | 2 | 0 |
| mountpoint | 0 | 2 |
| setsid | 1 | 0 |
| taskset | 2 | 0 |
| chrt | 1 | 0 |
| ionice | 1 | 0 |
| fallocate | 1 | 1 |
| script | 1 | 0 |
| setpriv | 2 | 0 |
| unshare | 3 | 0 |
| blkid | 0 | 1 |
| mkfs.minix | 1 | 0 |

**One LOUD difference, and it is the only real gap in this column:
`flock -w <timeout>` does not exist in busybox.** busybox flock has
`-s`, `-x`, `-n` and `-u`, and no way to say *"wait at most N seconds
for this lock"*. There is no workaround either -- `timeout N flock
...` releases the lock when it kills flock. A script written elsewhere
that uses `flock -w` fails here with `unrecognized option: w`, which
is at least a bug report the person gets for free.

**Five differences are classed SILENT by the harness and only two of
them are a wrong ANSWER.** Read them, do not count them:

- `blkid` omits `BLOCK_SIZE=` from its output. A script parsing that
  field gets nothing. Real.
- `mountpoint` exits **32** where busybox exits **1**, on the same
  verdict (`d is not a mountpoint`). Every `if mountpoint -q d` works
  either way; only `[ $? -eq 32 ]` breaks.
- `getopt` on an unknown option and `fallocate -l 0` differ **only in
  the wording of the error**. Both refuse, both non-zero. Not a gap.

So the harness's own classifier is cruder than the finding: LOUD
versus SILENT is the right axis (RFC 0040 roadmap 4) and it cannot
tell a different *message* from a different *answer*. The table above
is the measurement; this paragraph is the reading.

`--self-check` points both sides at util-linux and must return
**31/31**. A harness that found a difference in every case would
produce an alarming table with nothing in the output to say so.

## The 43 that are missing: GAP 26, COVERED 12, CANNOT 5

**CANNOT (5)** -- the kernel has no such thing, so the program could
not work if it were here. `ipcmk` and `lsipc` need `CONFIG_SYSVIPC`
(n); `mkfs.cramfs`/`fsck.cramfs` need `CONFIG_CRAMFS` (n);
`mkfs.bfs` needs `CONFIG_BFS_FS` (n).

**COVERED (12)** -- something already answers. `agetty` (busybox
getty, which this init runs), `i386`/`x86_64` (busybox setarch),
`runuser` (busybox su), `ctrlaltdel` (s6-linux-init owns the reboot
path), `mkfs` (a dispatcher over `mkfs.*` busybox provides directly),
`scriptlive` (busybox has script and scriptreplay), `lastb`,
`utmpdump` and `lslogins` (all read utmp/wtmp/btmp, which nothing in
this image writes), `mcookie` (X authority cookies, and there is no
X), `rename.ul` (a Debian rename, not util-linux core).

**GAP (26)** -- nothing stands in for them: `addpart`, `blkzone`,
`chcpu`, `chmem`, `choom`, `delpart`, `findmnt`, `hardlink`,
`isosize`, `ldattach`, `lsblk`, `lscpu`, `lslocks`, `lsmem`, `lsns`,
`namei`, `partx`, `prlimit`, `resizepart`, `setterm`, `swaplabel`,
`uclampset`, `wdctl`, `whereis`, `wipefs`, `zramctl`.

**A GAP is not automatically a reason to port anything.** Read the
list and ask which ones somebody on this machine would reach for. Two
stand out -- `lsblk` and `lscpu`, both "what is this machine?"
questions -- **and `novi-agent describe` already answers both**: CPU
model and count, memory, firmware, and every block device with its
size and removable flag, in JSON and as a table, from `/proc` and
`/sys` with nothing forked. What `lsblk` adds over that is the
PARTITION TREE with mountpoints and filesystem types, which is
"extend `describe_hardware()`" rather than "port 91 programs".
`partx`/`addpart`/`delpart`/`resizepart` look like an installer gap
and are not one: busybox ships `partprobe` and `novi-install` already
calls it.

## Recommendation: no util-linux package

Four named deficits, each cheaper to fix where it is than by porting
91 programs and a `libmount`/`libblkid`/`libsmartcols` stack:

1. `flock -w` -- the one loud gap, and nothing in Novi's own code
   uses flock at all (novi-state and novi-mount both use an `mkdir`
   lock, precisely because busybox has none).
2. `blkid`'s missing `BLOCK_SIZE` -- nothing here parses it, and
   `mkinitramfs.sh` deliberately parses busybox blkid's exact output
   (RFC 0008).
3. `mountpoint`'s exit 32 -- a number, on an agreed verdict.
4. `lsblk`/`lscpu` -- already answered by `novi-agent describe`,
   except for the partition tree.

And the cost side is not only size. util-linux would put a SECOND
implementation of "what is mounted" and "what is on this block
device" beside busybox's and beside `novi-mount`'s -- the parallel
truth this project writes tests to prevent (RFC 0007's derived
split, RFC 0009's `pick_interface()`, the panel-indicator mistake).

**What would change this answer is a new NUMBER, not a new opinion**
(RFC 0027's rule for the mbedTLS collapse): somebody hitting
`flock -w` in a real script, or a partition tree something on this
machine actually needs.

## What the measurement found that was not about util-linux

**Sixteen busybox applets on this image name kernel features this
kernel does not have.** Ten were installed as commands that could
never work -- `hwclock`, `rtcwake`, `nbd-client`, five `ubi*` and
`vconfig` -- beside `ipcs` and `ipcrm`, which answered *"kernel not
configured for message queues"* and *"unknown errror in id (1)"* for
the life of the project. A command that cannot work is worse than one
that is absent (RFC 0026's `idle3`, RFC 0040's `bashbug`, RFC 0040
roadmap 2's busybox `man`). `kernel/dead-applets` and
`scripts/prune-dead-applets.sh` are the fix, and the removal is
DERIVED from the generated kernel config so turning a symbol on
restores the command.

**`CONFIG_RTC_CLASS` was not set**, which is why `hwclock` was on that
list: the kernel read the CMOS clock at boot through
`CONFIG_RTC_MC146818_LIB` and had no `/dev/rtc0`, so nothing could
write the system time back to hardware and there was no RTC alarm to
wake a suspended machine (RFC 0035). It is set now — RFC 0040 roadmap
6, verified by a correction that survives a reboot.

**And that closed a hole in THIS measurement.** `rtcwake` is one of
the 48 overlapping names and `probe.sh` has no case for it, which the
harness's stated exclusions do not cover: it needs an RTC, and at the
time neither the guest nor this build host had one (`/dev/rtc*` is
still absent here). With the guest's RTC enabled the answer arrived
from a booted machine instead: **busybox's `rtcwake` has no `-m no`**
— it arms the alarm and then writes the mode to `/sys/power/state`
unconditionally, so the alarm IS set and the command exits 1 with
`write error: Invalid argument` — **and no `-m disable` at all**,
where it prints its usage. Both are real util-linux deltas, and both
are worked around from sysfs (`echo 0 >
/sys/class/rtc/rtc0/wakealarm` disarms; writing an epoch second arms).

So the 31 comparable cases are a floor, not a ceiling: a case this
harness cannot run is a case it says nothing about, and "nothing to
compare" is not the same answer as "they agree". Neither finding
changes the recommendation — both are loud, and `rtcwake -m no` still
arms the alarm.

## Two probe bugs worth not repeating

**THE CURATED KERNEL CONFIG IS A SUBSET, AND ANSWERING FROM IT GAVE
THREE WRONG LABELS.** `kernel/config-x86_64` is ~280 options; a symbol
it does not mention is NOT thereby off. `CONFIG_SWAP` and
`CONFIG_HOTPLUG_CPU` are both unmentioned there and both `y` in the
generated config -- and swap really works on a booted machine. Read
`/build/sources/linux-*/.config`, or ask the running kernel.

**THE FIRST pid NORMALISER ATE AN EXIT STATUS.** `chrt -p $$` prints
`pid 2179's ...`, which differs between the two runs for a reason that
has nothing to do with the tools -- so the harness normalises it. The
first version was `s/\b[0-9]{2,7}'?s?\b/<pid>/g`, any two-to-seven
digit number, and it turned `mountpoint`'s `rc=32` into `rc=<pid>`:
the one field the comparison turns on. It happened to still report a
difference because busybox's `rc=1` is one digit and survived; a
busybox exiting 33 would have compared EQUAL. It also blanked blkid's
`BLOCK_SIZE` value. **A normaliser wide enough to hide the noise is
wide enough to hide the finding** -- match the SHAPE the noise comes
in, not "a number". Sixth time in this project that the instrument,
rather than the thing measured, was the broken part.
