# RFC 0004: Networking and System Logging

- **Status:** Draft. Implemented and QEMU-verified end to end, on both
  a live boot and an installed disk; see "Verification".
- **Labels:** `rfc`
- **Author:** platform readiness work (`docs/PLATFORM-ROADMAP.md` §13)
- **Requires:** RFC per `CONTRIBUTING.md` — this adds two init
  subsystems and a new `novi-state` domain.

---

## Motivation & Problem Statement

After RFC 0003, Novi could be installed and would remember what you did
to it. It still could not reach a network, and it could not tell you
what had happened to it.

**Networking did not exist at all.** No DHCP client service, no
resolver, no `/etc/hosts`, no `network.*` anything. The kernel had
`CONFIG_PACKET=y` and NIC drivers; nothing used them. That blocks
essentially everything downstream: a package repository has no
transport, updates have no transport, and `pkg` has nothing to install
from no matter how good it is.

**Logging existed on paper and not in fact.** The `syslog` service ran
`s6-log -d3 … /var/log/syslog`, and two independent things were wrong
with it:

- `-d3` means "notify readiness on file descriptor 3", and the service
  declared no `notification-fd`. s6-supervise therefore never opened
  that descriptor, s6-log could not notify, and the service
  crash-looped. Invisibly — s6-rc's "up" for a longrun means
  "supervised and wanted up", not "running", so `s6-rc -a list`
  cheerfully reported `syslog` for a service that had never once
  started successfully. `/var/log/syslog` did not exist.
- Even with that fixed, s6-log reads its **stdin**. As a standalone
  service with no producer piped into it, it was a log file with no
  writers: a directory containing a zero-byte `current`, forever.

s6-log is the right tool for a per-service logger in a supervised
producer/consumer pipeline. It is not a system log daemon, and this
service wanted the latter. That distinction cost real time during this
very work: diagnosing a boot-time race (below) was impossible because
there was no log to read.

## Proposed Design

### Networking: one supervised DHCP client, declared like everything else

A single `network` longrun under s6-rc:

1. Record the declared interface and DNS spec into `/run/novi`.
2. Notify readiness (see below).
3. `modprobe` the NIC drivers this kernel builds as modules.
4. Bring up `lo`.
5. Wait for the interface to appear.
6. `exec udhcpc -f -R -i "$IFACE" -s /usr/share/udhcpc/default.script`.

`-f` keeps udhcpc in the foreground so s6 supervises the real process
rather than a daemonized orphan; `-b` (background on lease failure) is
exactly wrong under a supervisor. `-R` releases the lease when the
service is brought down.

The lease is applied by `/usr/share/udhcpc/default.script`, which
BusyBox does not ship — udhcpc negotiates a perfectly good lease and
applies none of it without one, which is a failure that looks like a
network problem for an hour.

### The `network.*` state domain

```
network.dhcp      = on | off
network.interface = auto | <name>
network.dns       = auto | 1.1.1.1,9.9.9.9
```

`network.dhcp` maps to the `network` service and is deliberately **not
also exposed as `services.network`**. Two keys governing one service is
precisely the split-brain this project exists to prevent; the network
domain owns it and the services domain never mentions it.

`network.interface` and `network.dns` are read by the service when it
starts, and it records what it was started with under `/run/novi`.
**The recorded spec is what `diff` observes, not the declared value.**
That is what makes changing either show up as real drift — and gives
`apply` something to do about it (restart the service) — instead of the
change silently having no effect until the next reboot. With the
service down there is nothing running to be out of step with, so the
declared value is the honest observation; anything else would report
permanent, unfixable drift on a machine that simply has DHCP off.

Convergence here is **eventually consistent by nature**: `apply`
returns once the restarted service is ready, and the new resolver lands
a second or two later when the lease binds. Measured, not assumed.

### Two deliberate departures from what a stock distro's udhcpc hook does

- **It never sets the hostname from DHCP.** The hostname is declared in
  `/etc/novi/system.conf` and converged by `novi-state`. Letting a DHCP
  server overwrite it would put a second, invisible writer on a value
  the whole project promises has exactly one.
- **It writes the resolver to `/run`, not `/etc`.** A DHCP lease is
  runtime state; `/etc/novi/system.conf` is where configuration lives,
  and rewriting a file under `/etc` on every lease renewal blurs a line
  this project draws deliberately. `/etc/resolv.conf` is a symlink to
  `/run/novi/resolv.conf`. It also keeps a live boot honest — `/etc`
  there is a read-only squashfs layer under a tmpfs overlay, and
  pointing at `/run` means the resolver lands in the same place either
  way.

A declared `network.dns` wins over whatever the lease offered. `auto`
is how you say you want the lease's answer.

### Logging: syslogd owns /dev/log, klogd feeds it the kernel

- `syslog`: `syslogd -n -O /var/log/messages -s 1024 -b 4`. Creates
  `/dev/log` (the AF_UNIX socket every `syslog(3)` caller writes to),
  appends to `/var/log/messages`, rotates at 1 MB keeping 4 backups.
- `klog`: `klogd -n`, depending on `syslog`. Without it, everything the
  kernel says after boot — a disk error, a link change, an OOM kill —
  exists only in `dmesg` and is lost at the next reboot.

Deliberately no `-C` (shared-memory ring, read with `logread`): with
`-C`, BusyBox syslogd logs to the ring **instead of** the file, and
this kernel has no `CONFIG_SYSVIPC`, so the ring cannot be created at
all. Confirmed live — `logread` returned "can't find syslogd buffer:
Function not implemented" and `/var/log/messages` did not exist. A flag
that quietly redirects all logging into a facility the kernel does not
have is worse than no flag.

### Readiness notification, and the race it fixes

The `network` service declares `notification-fd = 3` and writes to fd 3
immediately after recording its spec, before anything slow.

This is not a nicety. `s6-rc change` returns as soon as a longrun is
*started* unless the service declares readiness, and `rc.init` runs
boot convergence the moment it returns. Without the notification, boot
convergence raced the service's own startup, observed
`network.interface` as `unknown`, called it drift, and **restarted the
very service it had just started — burning a generation on every single
boot**. Confirmed live: a fresh boot with nothing touched came up at
generation 0001.

Two lessons worth keeping, both of which generalize past this service:

- A longrun that anything else observes needs a readiness
  notification. "Started" is not "usable".
- Generations must mean "the system actually changed here". A
  convergence engine that manufactures a generation per boot teaches
  people to ignore its history, which is the whole value of having one.

## Alternatives Considered

**A `dhcpcd`/`NetworkManager`-class daemon.** Both are large, dynamic,
and bring a configuration model of their own — a second place network
configuration lives, which is the exact thing `novi-state` exists to
prevent. BusyBox's udhcpc is already in the base image and the lease
hook is 90 lines of shell anyone can read.

**Static IP support in v1.** Deliberately out. Observing a static
configuration correctly (comparing declared address/route against
`ip addr` output) is real work, and a half-observed key that reports
false drift is worse than an absent one. `network.address` /
`network.gateway` are roadmap items with a design, not a stub.

**Keep s6-log and pipe things into it.** The s6-native answer is a
producer/consumer pair per service, which is a good architecture and a
much larger change than "the system should have a log". `syslogd`
serves `syslog(3)`, which is what the software Novi will run actually
calls.

## Implementation status

Implemented:

- `init/services/network/{run,type,notification-fd,timeout-up}`
- `rootfs/usr/share/udhcpc/default.script`
- `init/services/syslog/run` — rewritten to `syslogd`
- `init/services/klog/{run,type,dependencies}`
- `init/services/default/contents` — `syslog`, `klog`, both gettys,
  `network`
- `packages/novi-state` — `observe_network()` / `converge_network()`
- `rootfs/etc/novi/system.conf` — the `network.*` block, `services.klog`
- `build/18-network.sh` — the udhcpc hook, `/etc/hosts`, and the
  `/etc/resolv.conf → /run/novi/resolv.conf` symlink

### A second bug this work surfaced

The new log immediately showed eight `virtio_net: Unknown symbol
net_dim / net_failover_create (err -2)` lines on every boot — two
racing load attempts failing before a third succeeded. `modules.dep`
was correct and the driver did end up loaded and working, so nothing
downstream ever noticed; it was pure noise in a log nobody could read
until now. Loading the dependency modules (`dimlib`, `failover`,
`net_failover`, `mdio`) by name before the drivers that need them
removes the race outright and costs nothing when they are already in.
Verified: `dmesg | grep -c 'Unknown symbol'` → 0.

That is the argument for having a log, made by the log on its first
day.

## Verification

QEMU, `-machine pc`, `-nic user,model=virtio-net-pci`, serial console.

**Live boot:**
- `eth0` at `10.0.2.15/24`, default route via `10.0.2.2`,
  `/etc/resolv.conf` (through the symlink) carrying `nameserver
  10.0.2.3`.
- `ping` to the gateway: 2/2. `nslookup example.com`: resolved to a
  real address — the resolver path works end to end, not just the
  address assignment.
- `novi-state diff` clean and `novi-state history` **empty** on a
  fresh boot: no spurious generation.
- `/dev/log` present; `logger -t novi-test 'hello from logger'`
  appeared in `/var/log/messages`; kernel lines present via klogd.
- `dmesg | grep -c 'Unknown symbol'` → 0.

**Drift round-trip on `network.interface`:** `set` → `diff` reported
`- network.interface = auto (actual) / + network.interface = eth0
(declared)` and exited 1 → `apply` restarted the service and wrote a
generation → `diff` clean, address intact.

**Drift round-trip on `network.dns`:** `set network.dns
1.1.1.1,9.9.9.9` → `apply` → after the new lease bound,
`/etc/resolv.conf` carried both servers → `rollback` restored `auto`
and the lease's own resolver came back.

**Installed system (the real test):** installed from a live boot onto a
blank disk, then cold-booted from that disk with the ISO detached.
`novi-box` came up with `/dev/vda1` mounted rw as `/`, `eth0` at
`10.0.2.15`, DNS resolving, `s6-rc -a list` showing
`getty-tty1 getty-ttyS0 klog network syslog`, `novi-state diff` clean,
`novi-state history` empty, `dmesg | grep -c 'Unknown symbol'` → 0, and
739 lines in `/var/log/messages`. After a second cold boot the marker
file was still there and `/var/log/messages` had grown to 1106 lines —
**logs that survive a reboot**, which is the difference between a log
and a scrollback buffer.

## Roadmap

- **Static IPv4**: `network.address`, `network.gateway`, with real
  observers.
- **WiFi**: needs a supplicant (`wpa_supplicant` or `iwd`) in the base
  image — a genuine dependency addition, and the first one where the
  `desktop.*` story (a network applet in `novi-panel`) meets this
  domain.
- **IPv6**: SLAAC works passively today; DHCPv6 (`udhcpc6`) is not
  wired up and `network.*` has no v6 keys.
- **Per-service logging**: the s6-native producer/consumer pipeline,
  alongside syslogd rather than instead of it.
- **`log.*` state domain**: retention and rotation are hardcoded in the
  run script and should be declared like everything else.
