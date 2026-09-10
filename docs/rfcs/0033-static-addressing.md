# RFC 0033 — a static address, and the resolver that had two writers

**Status:** Implemented and verified on a booted machine
**Depends on:** RFC 0002 (declarative state), RFC 0004 (the network service and readiness), RFC 0009 (which interface)

> **Summary.** `network.address = 192.168.1.50/24` and
> `network.gateway = 192.168.1.1`. The network service configures the
> interface itself instead of running a DHCP client; `novi-state`
> observes, converges and validates the two keys like every other part
> of the document. `/run/novi/resolv.conf` gains a single writer,
> `/usr/lib/novi/resolv.sh`, shared by the lease script and the static
> path.

## Motivation & Problem Statement

**This system could not be given a fixed address at all.** The network
service ran `udhcpc` unconditionally, so a machine on a segment with no
DHCP server had no way to get on the network short of typing `ip addr
add` at a console after every boot — which is not configuration, does
not survive a reboot, and does not appear in a diff. That is precisely
the state of affairs RFC 0002 exists to abolish, sitting in the middle
of the network domain.

It is also the ordinary case for most of the machines this project
says it is for. A server has a fixed address. A lab or pentest segment
frequently has no DHCP at all. `docs/PLATFORM-ROADMAP.md` and the
README have both listed "static IP" as an open state domain since the
domains were written.

## Decisions

### 1. `network.address` is a MODE, not a second service.

`dhcp` (the default, and what an absent key means) or a CIDR. The
network service reads it at start and either execs `udhcpc` or
configures the interface itself.

One service, because "which interface" is already answered here and a
static machine needs the *same* answer. RFC 0009's `pick_interface()`
has real rules — wired before wireless, a radio is a `phy80211` link
rather than a name, `sit0` is not an Ethernet device — and a second
implementation of them for the static path would drift, which is the
exact mistake the panel's network indicator was written to avoid.

**What this costs is a name.** `network.dhcp` is now the switch that
turns the *network service* on, and `network.address` decides whether a
DHCP client is any part of it — so a machine can have `network.dhcp =
on` and run no DHCP. The key is older than static addressing and says
what the service does in its default configuration. Renaming it would
silently ignore the key in every `system.conf` already committed to a
repository, which is worse than a name that needs a sentence of
explanation; both `system.conf` and `novi-state`'s own key list carry
that sentence.

### 2. A bare address is refused, not assumed to be /24.

The prefix length decides which hosts this machine believes are local.
Guessing it is guessing at the shape of somebody's network, and the
failure is not an error — it is a machine that works for some
destinations and not others.

### 3. The validator is pedantic on purpose.

`network.address` is the first value in `system.conf` that becomes an
argument to `ip addr add`. A value that gets past `novi-state` costs
the machine its network and reports it in `ip`'s words, naming neither
the key nor the file. So:

- **exactly four octets** — `1.2.3` and `1.2.3.4.5` are both rejected
  here rather than downstream;
- **a leading dot, trailing dot or `..` is rejected explicitly**,
  because field splitting DROPS the empty field they produce and a
  naive four-octet count passes `.1.2.3`;
- **no leading zero on an octet** — `010` is eight to anything that
  reads it as octal and ten to anything that does not, and an address
  whose value depends on the reader is not an address.

All of that is textual, none of it needs a machine, and no running
machine would ever produce it — so it is a host test
(`packages/tests/test-network-static.sh`, 40 checks, in the lint run),
the same argument `novi-panel/icons-test.c` and `novi-recon`'s wire
tests already make.

### 4. A refused value must not take the rest of the document with it.

`converge_key` runs each key in a subshell (the `power.governor`
lesson), so a malformed address is one `ERROR` line, one skipped key,
and a non-zero exit from `apply` — while every other key still
converges and **the machine keeps the working configuration it had**.
Verified live: a bad address alongside a hostname change applied the
hostname, refused the address by name, and left the existing lease
untouched.

### 5. The resolver has ONE writer now.

`/usr/lib/novi/resolv.sh`, sourced by the udhcpc lease script and by
the static path. The rule it holds — a declared `network.dns` beats
whatever the lease offered, `auto` is how you ask for the lease's
answer — is a policy, and a policy implemented twice is a policy that
disagrees with itself. The static path's first draft had its own copy
and had already dropped the `search` line.

Same argument as `/usr/lib/novi/json.sh` being the one escaper (RFC
0029), and the same guard: `.` is a special builtin, so sourcing a
file that is not there ends the calling script immediately with status
2 and nothing on stderr anyone would connect to a missing library.
Both callers check `[ -f ... ]` first.

**It returns non-zero when the result would name no server, and writes
the file anyway.** That combination is the point. With a static
address there is no lease to learn from, so `network.dns = auto` — the
shipped default — means no resolver at all; the service says so on
startup rather than leaving it to be discovered by a name that will
not resolve. And the file is still rewritten, or a stale resolver from
the previous configuration would sit there looking current.

### 6. `sleep infinity`, because there is nothing to supervise.

A static address is held by the kernel. There is no client to keep
alive and no lease to renew — but s6 supervises a *process*, and a
longrun whose run script returns is a longrun s6 restarts forever.

`sleep infinity` is one `nanosleep` and zero wakeups. Deliberately not
`tail -f /dev/null`, which BusyBox implements by polling once a second,
forever, for a file that will never change — the same objection this
project raised to a panel that forks `amixer` on every repaint.

The process existing is what keeps `s6-rc`'s answer and `ip addr`'s
answer about this configuration in step, and stopping the service is
what runs `./finish`.

### 7. A `finish` script, and it is not optional.

`udhcpc -R` releases its lease and the hook deconfigures the
interface, so the DHCP path has always cleaned up after itself. **A
static address is held by the kernel and nothing removes it.** Without
this, `network.dhcp = off` left the machine still answering on its
declared address, and switching from static back to `dhcp` left the
old address sitting beside the new lease — `novi-state diff` reporting
converged while `ip addr` showed two addresses. That is the shape this
project keeps recording: a report that is right about the document and
wrong about the machine.

It reads the spec the service **published**, not the declared value:
by the time a stop happens the document may already say something
else, and what has to come off is what actually went on. Same reason
generations snapshot observed state rather than the state file.

This is the second `finish` script in the repo; RFC 0032's was the
first.

### 8. `/run/novi/network.ip` finally has a reader.

The lease script had always written the held address there — under the
name `network.address`, which this RFC needed for the declared spec —
and **nothing had ever read it**. A file written and never read is
dead weight, and in a base/desktop split computed from what the base
needs, dead weight is not inert.

It is `network.ip` now (the address actually held), it is written by
both paths, and `novi-agent describe` reports it. "What did you
declare" and "what is on the wire" are different questions, and an
agent asking a machine what it is wants the second.

## What was verified

On a booted Novi (QEMU user-mode networking, TCG), in one session:

| | |
|---|---|
| **the DHCP path still works** after the resolver refactor | lease `10.0.2.15/24`, `resolv.conf` written by the shared writer with the lease's `10.0.2.3`, `novi-agent describe` → `"address": "10.0.2.15"`, zero drift |
| a static address | `network.address = 10.0.2.50/24` + `gateway 10.0.2.2` + `dns 10.0.2.3` → **exactly one** address on the interface, `default via 10.0.2.2` |
| the resolver came from the other writer | the file's own header reads `Generated by the network service for eth0`, not `by udhcpc` |
| it actually routes | `wget http://10.0.2.2:8099/probe.txt` from the guest returned the host's file, and `nslookup example.com 10.0.2.3` resolved |
| readiness and drift | `s6-svstat` → `up true ready true`; `novi-state diff` → matches declared state |
| the `finish` script | `network.dhcp = off` → **no address at all** on the interface and `/run/novi/network.ip` gone |
| the round trip | back to `dhcp` → the lease returns as `10.0.2.15/24` with **no leftover** `10.0.2.50` and the resolver back to the lease's answer |
| a refused value | `network.address = 192.168.010.5` → one `ERROR` naming the key and the expected form, the hostname change in the same apply still applied, the working lease untouched, `apply` exit status **1** |
| the honest partial | static with `gateway = auto` and `dns = auto` → address held, two warnings in the log naming both gaps, and a resolver file with no `nameserver` line rather than a stale one |

Two things worth recording from the run:

- **`novi-state apply | tail -5` reports `tail`'s exit status.** The
  refusal test read `exit=0` from a pipeline and would have concluded
  `apply` swallowed the failure. It exits 1; CLAUDE.md already records
  this trap from a build stage, and it caught the same reader twice.
- **The test's own grep could not fail.** "the lease's server must not
  survive a declared `network.dns`" grepped for `1.1.1.1` unanchored —
  and the resolver file's header prints `1.1.1.1` in the example
  command it suggests. Anchored to `^nameserver`, it passes for the
  right reason.

## Consequences

- **A machine can now be given a fixed address declaratively**, which
  it could not be before, and the declaration is in the same document,
  the same diff and the same generations as everything else.
- **`network.dhcp` names the service, not the protocol.** Stated in
  two places rather than left to be inferred.
- **IPv4 only.** IPv6 is not addressed here at all — no `ip -6`, no
  SLAAC opinion, nothing. Saying so is better than a key that half
  works.
- **One address per interface, one interface.** Per-interface
  configuration is still RFC 0009's open item and this does not
  advance it.
- **Nothing here has run on physical hardware**, and neither has the
  rest of this system.

## Roadmap

1. **IPv6.** `network.address6` / `network.gateway6`, or a single key
   that takes both families. The validator is the interesting half.
2. **More than one address**, and more than one interface. Both wait
   on RFC 0009's per-interface work rather than growing a second
   answer beside it.
3. **A GUI for it.** `novi-settings`' Network panel does WiFi; the
   wired half is a text file today.
