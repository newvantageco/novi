# RFC 0032 — a non-root path, and the socket that becomes the boundary

**Status:** Implemented — not yet exercised on a booted machine
**Depends on:** RFC 0029 (the agent interface), RFC 0022 (a service that opens a way in), RFC 0004 (readiness)

> **Summary.** `novi-agentd` is an s6-rc longrun running `s6-ipcserver`
> on `/run/novi/agent/sock`, so a process that is **not root** can
> drive the declared verb list. The gate is a `0750 root:agent`
> directory — membership of `agent` is the grant. Peer identity comes
> from `SO_PEERCRED`, so the audit log names who asked rather than the
> daemon that acted. Off by default.

## Motivation & Problem Statement

RFC 0029 ended with this and called it "a bigger one than it looks —
that socket becomes the boundary". It is the last item on that
roadmap and the one that changes the shape of the thing.

`novi-agent do` needs root, because `novi-state`, `pkg` and `novi-wifi`
do. So today the program driving a Novi machine runs as root — and
**that program is the largest and least reviewable thing on the
system.** An LLM harness is tens of thousands of lines of somebody
else's Python before it makes a single decision.

The verb list already bounds what may be *asked for*. What it cannot
bound is a bug in the asker: a use-after-free, a deserialisation flaw,
a prompt injection that reaches `os.system` instead of the verb
dispatcher. All of those are root today, and none of them are
questions `agent.allow` gets to answer.

**This does not widen or narrow what an agent may do.** It moves where
the privilege lives: the big untrusted program runs as nobody in
particular, and a small reviewed one holds root.

## Decisions

### 1. `s6-ipcserver`, which was already in the base image.

Three of skarnet's UCSPI tools ship here already — `s6-ipcserver`,
`s6-ipcserver-access`, `s6-ipcclient` — because s6 is this system's
init. So the socket server is not new code, and the code that *is* new
is one 90-line handler.

The alternative was a **setuid helper**. It was rejected for the
reason setuid is usually rejected: the attack surface is the entire
process environment — argv, environ, cwd, fds, resource limits, locale
— and every one of those is chosen by the caller. A socket has one
input, and this project already runs a supervision suite that is good
at sockets.

### 2. The gate is a directory, not a policy key.

`/run/novi/agent` is `0750 root:agent`. A process cannot reach the
socket path unless it is in the `agent` group.

**Membership of that group is the grant**, and that is deliberately
unix's own mechanism rather than a fourth key beside `agent.enabled`,
`agent.allow` and `agent.rate`. A second access-control mechanism is a
second thing that can disagree with the first, and the disagreement is
always discovered by someone who thought they were denied.

The directory rather than the socket's own mode because it is one
thing to read instead of two that must agree, and because a socket
recreated on restart takes its mode from whatever created it.

`agent` is GID **104**, fixed, in `rootfs/etc/group` — a squashed
image's file modes depend on the number being the same everywhere,
which is why every GID here is policy rather than allocation.

### 3. Identity comes from the kernel, not from the request.

`s6-ipcserver -p` fills `IPCREMOTEEUID` and `IPCREMOTEEGID` from
`SO_PEERCRED`. That is what the kernel knows about the process on the
other end — not something the client says about itself.

A protocol where the caller states its own uid would be **a log that
lies on request**, which is worse than no log: it invites belief.

The handler refuses outright if those variables are missing or
non-numeric, rather than falling back to its own uid. A boundary that
cannot name who crossed it is not one.

### 4. The audit log records the peer, and how they arrived.

`audit()` used `id -u`. Through the daemon that is root, so the log
would have recorded root as the actor for every request whoever made
it — **the single question an audit log exists to answer, with one
wrong answer**.

`NOVI_AGENT_PEER_UID` carries the kernel's number through. It is
trusted because of where it comes from: `novi-agent-serve` is the only
thing that sets it, it runs as root as the daemon's per-connection
handler, and anyone who could forge the variable could run the tool
directly anyway.

A `via` field distinguishes `cli` from `socket`, because "root, at a
shell" and "root, through the socket" are different events that a uid
alone cannot tell apart.

### 5. One line in, one JSON line out.

The whole protocol. No framing, no length prefix, no session.

**`set -f` before word splitting is the load-bearing line.**
`set -- $line` is how a request becomes arguments, and unquoted
expansion in a shell expands **globs** as well as splitting words — so
`state.set hostname *` would arrive as the contents of the working
directory. Nothing about that looks wrong in a diff, which is why the
test for it exists and why the test was checked by removing the line
and watching it fail.

Bounds before anything else touches the text: 512 bytes, printable
characters only. This is the first place in the interface where a
possibly-unprivileged stranger's text is read by a root process.

### 6. `wifi.join` is deliberately unreachable over the socket.

Not a policy decision — a protocol one. Its passphrase arrives on
stdin precisely so it is never an argument (RFC 0029 decision 9), and
a one-line request has nowhere to put a secret that is not the
argument line. Inventing a second frame for one verb would make every
other request pay for it.

An agent that must join a network calls `novi-agent` directly as root.
Revisit when a *second* verb needs a secret — then it is a protocol
decision rather than a special case.

### 7. Off by default, and separate from `agent.enabled`.

`services.novi-agentd = off`. Running the agent interface and exposing
it to non-root callers are two decisions, and collapsing them would
mean anyone turning on `agent.enabled` silently opened a socket. That
is RFC 0022's argument about `network.firewall.allow` not being
derived from `services.sshd`, in a third place.

The service definition is base content and inert until declared on —
the seatd/novi-shell arrangement from RFC 0007.

### 8. `notification-fd` is 1 here, not 3.

Every other longrun in this repo declares 3. `s6-ipcserver -1` signals
readiness on **fd 1**; the flag names the descriptor. Declaring 3
would leave s6 watching a descriptor nothing ever writes to, so the
service would never come up ready and `s6-rc -u change` would wait out
`timeout-up` on every start.

That is RFC 0004's `s6-log -d3` bug with the mismatch on the other
side, and it was caught here by reading the flag rather than by
booting.

Readiness means **the socket is bound**, which unlike sshd's "is it
listening?" is genuinely knowable: `s6-ipcserver` binds before it
signals. `timeout-up` is the other half — a longrun that declares
readiness and never signals hangs `s6-rc` forever (RFC 0022).

## What was verified

*Nothing yet. The host test covers the request parser; the socket path
itself has not been run on a booted machine, and this section stays
empty until it has.*

## Consequences

- **Adding somebody to the `agent` group gives them everything
  `agent.allow` permits.** That is the whole point and it is worth
  saying plainly in the place where somebody adds them.
- **The policy has exactly one reader.** `agent.enabled`,
  `agent.allow` and `agent.rate` are still evaluated by `novi-agent`,
  not by the handler. The daemon adds a way in and an identity; it
  does not get an opinion.
- **`novi-agent-serve` is not a command**, and says so if run at a
  shell — without `PROTO=IPC` it would otherwise read a line from the
  terminal and look like a hang.
- **The concurrency ceiling is the server's** (`-c 8`), not a timeout
  in each handler. An agent that opens sockets and never speaks holds
  slots; `s6-ipcserver` already owns that problem, and solving it
  twice is how the two answers disagree.

## Roadmap

1. **`s6-ipcserver-access` rules**, if per-uid policy is ever wanted.
   Today the group is the whole of it, which is coarse and honest;
   per-uid verb lists would mean the policy has two readers again, so
   it needs a design rather than a flag.
2. **A secret-carrying frame**, when a second verb needs one. Then
   `wifi.join` comes back over the socket.
3. **Nothing here has run on physical hardware**, and neither has the
   rest of this system.
