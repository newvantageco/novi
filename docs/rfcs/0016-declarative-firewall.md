# RFC 0016 — A firewall that lives in the same document as your hostname

**Status:** Implemented
**Depends on:** RFC 0002 (novi-state), RFC 0004 (networking)

> **Summary.** `kernel/config-x86_64` has had `CONFIG_NETFILTER=y` and
> `CONFIG_NF_TABLES=m` for as long as it has existed, and the image has
> never contained a single program that could configure them. Novi has
> shipped a packet filter that cannot be turned on. This adds
> `network.firewall` to `/etc/novi/system.conf` — one key, one policy,
> converged by `novi-state` like everything else.

## Motivation & Problem Statement

The project describes itself as security-minded, and §9 of the platform
roadmap states the security model as "small TCB by construction". That
is an argument about how *many* things can be attacked. It says nothing
about what happens when one of them is listening on a port.

Right now nothing on a Novi machine filters anything. The kernel is
built with netfilter and nf_tables; there is no `nft`, no `iptables`,
no BusyBox applet, nothing. A packet filter that exists in the kernel
and cannot be configured from userspace is worse than not having one,
because reading the kernel config suggests otherwise.

The second problem is where the answer should live. Every other Linux
distribution answers "is the firewall on?" somewhere other than where
it answers "what is this machine called" — a unit file, a service, a
`firewalld` zone, a script in `/etc/network/if-up.d`. This project
already has one document for the whole machine, and a firewall is
exactly the kind of thing a person should be able to see, edit, commit
to git, and diff.

## Proposed Design

### One key

```ini
# /etc/novi/system.conf
network.firewall = on
```

`off` means the kernel filters nothing, which is what happened before
this. `on` means the policy below is loaded, and **`on` is what the
shipped `system.conf` says** — a deliberate departure from this
project's habit of shipping new things off. A firewall that has to be
discovered and enabled is a firewall nobody has, which is the same
criticism this RFC opens with. Nothing in the base image listens on a
port, so it costs nothing here and starts costing something exactly
when you install something that does — which is when you want to have
been asked.

That is the entire interface. There is deliberately no
`network.firewall.rules`, no port list, no zone model in v1 — see
"What this is not" below.

### One policy

`/etc/novi/firewall.nft` is repo content installed by
`33-nftables.sh`, beside the tool that reads it, because it is
*policy* and policy should show up in a diff — the same
argument as `rootfs/etc/{passwd,group,shadow}`:

```nft
table inet novi {
    chain input {
        type filter hook input priority filter; policy drop;
        ct state established,related accept
        ct state invalid drop
        iif lo accept
        ip protocol icmp accept
        ip6 nexthdr ipv6-icmp accept
        udp dport 68 accept
        ip6 nexthdr udp udp dport 546 accept
    }
    chain forward {
        type filter hook forward priority filter; policy drop;
    }
}
```

The two DHCP lines are not decoration. `udhcpc` sends from
`0.0.0.0:68` to `255.255.255.255:67`, and the reply is a broadcast
that conntrack has nothing to relate to — so on the default path, a
machine that gets its address by DHCP would come up filtered and never
renew its lease.

Outbound is unfiltered and there is no `output` chain at all: a
desktop or workstation that cannot make connections is not usable, and
a filter that pretends to constrain a process running as the user who
can also edit the filter is theatre.

ICMP is accepted rather than dropped. A host that black-holes ICMP
breaks path-MTU discovery and is a worse citizen on a network than one
that answers a ping.

The table is named `novi`, and that name is load-bearing: it is how
the observer recognises its own ruleset without claiming anything
somebody else installed (see below).

### Converging it

- **Observer** (`observe_key network.firewall`) runs
  `nft list table inet novi` and reports `on` if it exists, `off` if it
  does not. It reads the kernel's live ruleset, never a marker file —
  the same rule every other observer follows, or `diff` means nothing.
- **Converger** runs `nft -f /etc/novi/firewall.nft` for `on`, and
  `nft delete table inet novi` for `off`.

The kernel holds the ruleset, so there is no daemon and no service:
nothing needs supervising, and `novi-state boot` reapplies it on every
boot as part of ordinary convergence. That is the same reasoning as
`power.lid` having no converger — the difference is that this one *can*
drift (somebody with root can flush the table), and when it does,
`diff` says so and `apply` fixes it. That is the whole point of the
engine.

### The tool

`nftables`, with `libmnl` and `libnftnl` — three small upstream
packages built by `build/33-nftables.sh`, configured
`--with-mini-gmp --without-cli --disable-man-doc` so it pulls in no
gmp, no readline and no jansson. (JSON and the Python bindings are off
by default in 1.0.9 and have no `--disable-` switch; passing one only
produces a warning.) Base image, not a package: a console server wants
a firewall at least as much as a desktop does, and the whole set is
1.1 MB stripped next to the 699 MB of firmware already here.

Writing the netlink messages by hand was considered, in the spirit of
`novi-gpt` — which exists precisely because BusyBox `fdisk` could not
write a GPT and a purpose-built writer that emits exactly one layout
was better than a general tool. The difference is the cost of being
subtly wrong. A GPT that is wrong fails loudly at boot; a firewall rule
that is wrong fails silently and permits traffic you believe is
blocked, and nf_tables' expression encoding is far more intricate than
a partition table. Use the tested implementation, and apply the
"exactly one layout" discipline to the *policy* instead: one file, one
table, in the repo, where it can be reviewed.

### Kernel

`CONFIG_NF_TABLES_INET=y` is the only addition — the `inet` family, so
one table covers IPv4 and IPv6 rather than needing two that can drift
apart. It is a `bool` that `depends on IPV6` and `select`s
`NF_TABLES_IPV4`/`NF_TABLES_IPV6`, and it was simply unmentioned in
the curated config, which means `n`: `table inet novi` could not have
loaded. `NF_TABLES`, `NF_CONNTRACK`, `NFT_CT` and `NFT_LOG` are
already set (`NFT_PAYLOAD` and `NFT_COUNTER` are not separate symbols
any more — they are compiled into `nf_tables`).

### The thing this turned up: nothing could autoload a module

`nft -f` on the ruleset above failed with

```
/etc/novi/firewall.nft:27:3-10: Error: Could not process rule: No such file or directory
                ct state established,related accept
```

which reads like a missing file and is a missing *exec*. `ct` needs
the `nft_ct` module; the kernel asks for it with
`request_module("nft-expr-ct")`; that is a usermode-helper call; and
`kernel/config-x86_64` has set **`CONFIG_STATIC_USERMODEHELPER=y`**,
in its hardening block, since that block existed. That option routes
every usermode-helper call through one compiled-in path —
`/sbin/usermode-helper` — and this image has never contained that
file.

So no kernel-initiated module autoload has ever worked on this system,
for the whole life of the project. Nothing noticed, because every
module this image loads is loaded by something in userspace naming it:
`/init`'s list, `novi-hwdetect`'s modalias walk, `novi-hotplug`'s
uevents. The hardening was real, its cost was total, and the only
symptom was an error message about a file.

The option is worth keeping — `modprobe_path` and `core_pattern` are
root-writable, and pinning what the kernel may exec to one compiled-in
path is a genuine constraint on an attacker who reaches them. What was
missing is the other half: `novi-umh/main.c`, built by
`build/30-novi-umh.sh` into `/sbin/usermode-helper` and copied into
the initramfs. The kernel leaves the helper it *meant* to run in
`argv[0]`, so it is a filter, not a dispatcher: check `argv[0]`
against a list compiled into the binary and `execv` it unchanged.

The list has one entry, `/sbin/modprobe`, because `request_module()`
is the only usermode helper this configuration reaches. Refusals go to
`/dev/kmsg`, loudly, and a path that is allowed but fails to exec says
so separately — the bug being fixed here was a silent exec failure,
and a silent refusal would be the same bug in a different hat.

### Where it converges, and why twice

Boot convergence runs after `s6-rc change` returns (RFC 0002; the
comment in `init/skel/rc.init` explains why an s6-rc oneshot cannot do
it). That is right for everything whose convergence *is* a service
transition, and wrong for this: measured on a live boot, the ruleset
landed a second or two **after** the login prompt, by which point
`network` had a DHCP lease. Harmless on a base image where nothing
listens; exactly backwards the moment somebody installs something that
does, since that service starts in the same transition.

So `rc.init` calls `novi-state boot --early` before starting services
and plain `novi-state boot` after. `--early` converges `EARLY_KEYS`,
which is `network.firewall` and nothing else; the rule for membership
is that converging the key must need nothing from s6-rc. It is
deliberately not a general "apply this one key" flag — partial
convergence on demand is how a client ends up owning half the
document. The later full convergence finds the firewall already
correct, reports no drift, and burns no generation.

## What this is not

- **Not a rule language in `system.conf`.** Expressing arbitrary
  firewall rules in a flat `key = value` document would either be a
  worse nftables or an inexpressive one. The escape hatch is editing
  `/etc/novi/firewall.nft`, which is a real file in a real format.
- **Not per-service port opening.** `network.firewall.ssh = on` is
  obvious and tempting and belongs in a later revision with the port
  list derived from something real, not hand-maintained beside a
  service list that will drift from it.
- **Not outbound filtering, not NAT, not zones.**

## Verification

Live, in a booted VM, because a firewall that has not been shot at is
an assertion. All five done on the shipped ISO:

1. **The ruleset is there at the login prompt**, with no manual apply:
   `nft list table inet novi` prints it at 18 s uptime, `novi-state
   diff` says converged, and the generations directory is empty —
   early convergence had nothing to undo and the full pass had nothing
   to do. `lsmod` shows `nft_ct`, `nf_conntrack`, `nf_defrag_ipv4` and
   `nf_defrag_ipv6` loaded, none of which anything in userspace named:
   that is `novi-umh` working.
2. **A listening port on the guest, shot at from the host.** QEMU
   forwards `localhost:18080` to the guest's `:8080`, where a
   `nc -l -e /bin/echo BANNER` is waiting. Firewall on: the host TCP
   connection reaches QEMU and then nothing — the guest never sees a
   completed handshake, no banner. Firewall off: `BANNER`. Same
   listener, same probe, one key changed. **This is the test that
   matters**: the rules being present is not the same as the rules
   working.
3. **Outbound and loopback with the filter on.** `ping 10.0.2.2`, two
   of two replies. A DNS query to 10.0.2.3 goes out and its answer
   comes back (NXDOMAIN — the answer is the point, not the verdict),
   which is conntrack accepting an inbound UDP reply to an outbound
   query. `nc 127.0.0.1 9099` gets its banner.
4. **Flushed behind novi-state's back.** `nft flush ruleset` →
   `novi-state diff` reports `network.firewall = off (actual)` /
   `on (declared)` and exits 1 → `apply` snapshots generation 0001 and
   puts the table back. The snapshot records `network.firewall=off`,
   the state that was *observed*, not the file it was applying —
   RFC 0002's generations invariant holding on a new domain.
5. Covered by 1: the ruleset is loaded by ordinary boot convergence,
   before login and before any service starts.

## Roadmap

- Per-service openings once there is a real source for "what is
  listening" to derive them from.
- The allowlist in `novi-umh` is one entry because one entry is all
  this kernel calls. Anything that adds a usermode helper — a
  `core_pattern` pipe, `request-key` — has to add itself there, and
  will find out that it must from `dmesg`, which is the point.
- `novi-state health` could notice a table that exists but is empty.
- Logging dropped packets is one `log` statement away and deliberately
  absent: it needs a rate limit and somewhere for the output to go that
  is not the console.
