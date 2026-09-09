# RFC 0029 — the interface an automated actor uses to this machine

**Status:** Implemented
**Depends on:** RFC 0002 (declarative state), RFC 0006 (package repository), RFC 0022 (the firewall's separate allow key)

> **Summary.** `novi-agent describe` answers "what is this machine" as
> one JSON document, composed from the observers that already exist.
> `novi-agent do <verb>` changes it, but only when `agent.enabled = on`
> **and** the verb appears in `agent.allow` — two keys in
> `/etc/novi/system.conf`, beside everything else this system declares.
> Every attempt is recorded, refusals included. `novi-state show`,
> `diff` and `health` gained `--json` to make it possible without a
> second source of truth.

## Motivation & Problem Statement

Every operating system can be driven by a program. You shell out to
twenty tools, parse twenty human-shaped outputs, run as root with no
boundary and no record, and it works. That is not a design; it is the
absence of one, and everybody has it.

Three things are actually missing, and Novi was one small file away
from all three:

1. **One call that answers "what is this machine."** An automated actor
   has to know which twenty tools to run before it can orient at all.
2. **A declared boundary on what may be changed.** "The agent runs as
   root" is the entire security model in general use.
3. **A record of what was attempted**, including what was refused.

Novi already had the ingredients, which is why this is a small change
rather than a subsystem. `novi-state` is a single declared truth with
real observers reading live state (RFC 0002). The network interface,
the health verdict and the volume are already *published* to `/run` by
the services that own them. `pkg` already knows what is installed. What
was missing was a machine-readable rendering of all of it and a gate in
front of the writes.

## Decisions

### 1. Reading is free. Writing is declared.

`describe`, `capabilities` and `audit` change nothing and are always
available. They are a formatted view of files any user on this machine
can already read; gating them would buy no security and would make the
interface useless for the thing it is best at.

`do <verb>` runs only when **both** `agent.enabled = on` and the verb
is named in `agent.allow`.

**Two keys, not one, and that is the design.** Deriving the permissions
from "an agent is installed" would be one key instead of two and it is
what people expect — and it is a machine that grants powers because a
program exists on it. That is the identical argument RFC 0022 makes for
`network.firewall.allow` being separate from `services.sshd`: a
firewall that opens itself because a daemon started is a service
registry with a policy file attached. **The set of things an automated
actor may do has to be one list a person chose.**

Off by default, and that is not a hedge. An interface that can install
packages and converge system state should be switched on by somebody
who meant to.

### 2. There is no `exec` verb, and there will not be one.

An interface that runs an arbitrary command is not a boundary with a
hole in it — it is the absence of a boundary wearing a policy file.
Anyone who wants that has a shell; the point of this is to be the thing
you can hand out when you do not.

`packages/tests/test-agent-verbs.sh` fails the lint run if an `exec)`,
`shell)` or `run)` branch ever appears, because "we agreed not to" is
not a mechanism.

### 3. There is no `service.start` either, and the reason is architectural.

Starting a service without declaring it is **drift by construction**,
and an agent that produces drift on purpose defeats the engine it is
talking to. Services are reached the way everything else is:
`state.set services.X on` then `state.apply`.

So the verb list is five: `state.set`, `state.apply`, `state.rollback`,
`pkg.sync`, `pkg.install`. Each maps to exactly one existing tool. The
interface adds no capability the machine did not have — it adds a
boundary and a record around capabilities it already had.

### 4. `describe` composes; it computes nothing of its own.

The declared state and the drift come from `novi-state --json`. The
service verdicts come from `novi-state health --json`. The network
interface comes from `/run/novi/network.device`, the file RFC 0009's
service *published*, never a second walk of `/sys/class/net` — that
function has real rules (wired first; a radio is a `phy80211` link, not
a name) and a reimplementation would drift from them, which is exactly
why novi-panel reads the file too. Packages come from `pkg list`.

That is the whole discipline of the file. **An agent-facing summary
that computed its own answers would be a second source of truth about a
machine whose entire architecture exists to have one.**

Hence the other half of this RFC: `novi-state show`, `diff` and
`health` gained `--json`. Each is the *same* loop over `state_keys` and
`observe_key` as its text form, not a parallel implementation.

### 5. JSON from a shell script needs one escaper, and it is a file.

`/usr/lib/novi/json.sh`, sourced by both `novi-state` and `novi-agent`.
A function copied into both is a second thing to get wrong, and the
copy that is wrong is the one nobody is looking at — this repository
has learned that about C libraries three times (novi-launcher/fcft,
novi-panel/libnl, Mesa/zlib).

**The escaping is the whole point.** Every JSON document this system
emits is assembled by a shell script out of strings the shell did not
choose: a hostname, a filesystem label off a stranger's USB stick, an
SSID off the air, a package description. One unescaped quote and the
document an agent is parsing is not a document.

The policy is the one RFC 0024 already argued for the notification
socket: control characters **dropped**, tab and newline to a space, `"`
and `\` escaped, length capped. A JSON string may legally carry a
`\u0001` and no consumer of this wants one, so the smaller,
always-valid answer is the right one.

Two details that are load-bearing and were both caught by the test
rather than by reading:

- **Backslash is escaped before quote.** The other order turns `"` into
  `\"` and then that backslash into `\\`, so the quote ends the string
  — which is the injection this exists to stop.
- **Tab and newline become a space BEFORE the length cap, not after.**
  `cut` is line-oriented and appends a newline to input that had none,
  so converting newlines afterwards put a trailing space on **every
  string this system emits**. Valid JSON, silently wrong, and only a
  round-trip through a real parser finds it.

### 6. The audit log is JSON lines, and refusals are in it.

One object per line at `/var/log/novi-agent.jsonl`, mode 0600. `audit`
is therefore a `tail` and not a formatter — the thing that reads the
record needs no parser this project would have to keep in step with the
writer.

**Refusals are logged.** A boundary that records only what it let
through tells you nothing about what was tried. This project learned
that in RFC 0016, where a silent exec refusal would have been the same
bug as the silent exec failure it replaced.

Truncation is by line count, on write. A log that grows forever on a
machine with a small writable layer is a way to fill a disk, and a cron
job nothing runs is not a plan.

### 7. Arguments are refused, not sanitised.

Every argument reaching this tool came from something automated and is
about to become part of a command line.

- **Nothing may start with `-`.** `pkg.install --root=/` is a different
  program than `pkg install <name>`, and an argument that turns into an
  option is the oldest injection there is.
- **A restricted character set per argument kind**, and a value
  containing `#` is refused because it would start a comment when
  `system.conf` is read back — the same rule novi-settings' System
  panel already applies to the same document.

Reject rather than sanitise, per RFC 0023: a cleaned-up name that no
longer refers to the thing asked for is a worse answer than a refusal.

### 8. `agent.enabled` and `agent.allow` are read-at-use-time keys.

`novi-agent` reads them on every `do`, so nothing holds them, they
cannot drift, and `apply` has nothing to converge — which also means
`converge_key` never runs to reject a typo. So the **observer**
validates them, exactly as `power.lid` and `storage.automount` do.

It matters more here than for a lid switch. `agent.allow = pkg.instal`
is a policy file that looks like it permits something and permits
nothing, and the failure otherwise surfaces as a refusal three layers
away from the typo. **One** unknown verb makes the whole line report as
`unsupported`: reporting the other four as converged would hide the
problem from precisely the diff a person would look at.

## What was verified

On a booted machine, in order:

| | result |
|---|---|
| `describe` with the agent off | 2,603 bytes, **valid JSON**, 9 top-level keys — identity, hardware (CPU, memory, block devices, BIOS/UEFI), network, declared state, drift, health, packages, agent |
| `do state.set` with `agent.enabled = off` | refused — `"agent.enabled is not on"` |
| `do exec /bin/sh` | refused — `"no such verb"` |
| enabled, verb not in `agent.allow` | refused — `"not in agent.allow"` |
| enabled, verb allowed (`pkg.sync`) | **ran**, `"ok"`, status 0 |
| `do pkg.install --root=/tmp evil` | refused — `"invalid package name"` |
| `do pkg.install "foo;rm -rf /"` | refused — `"invalid package name"` |
| `agent.allow = pkg.instal` | reports as **drift**: `unsupported (actual)` against `pkg.instal (declared)` |
| `do state.set hostname agentbox` then `do state.apply` | **the machine converged** — `hostname` returns `agentbox`, the shell prompt becomes `root@agentbox`, and `novi-state diff` exits 0 |

The audit log after that sequence held **six lines, five of them
refusals**, each with its reason, at mode `0600` — and every line
parsed as JSON, including the one whose `args` field is
`"foo;rm -rf /"`, which is the escaper doing its job on real hostile
input rather than a contrived test string.

The escaper additionally has a host test
(`packages/tests/test-lib-json.sh`) that runs it **under the shipped
BusyBox ash, not the host's bash**, and validates the result with
Python's `json` module rather than a string comparison. That shell
choice is CLAUDE.md's own lesson, applied: `packages/pkg`'s process
substitution was "verified working against the real busybox binary" on
a host that has `/dev/fd`, and failed on the image that does not. 23
checks, including a deliberate `", "evil": "yes` injection attempt.

## Consequences

- **Base image, not a package.** ~21 KB of shell. "What is this
  machine" and "change it within a declared list" are how you talk to a
  Novi box, and a console-only install is exactly the machine somebody
  drives from a program rather than a desktop.
- **`novi-state` now has `--json` on its three read commands**, which
  is useful well beyond this RFC — it is what any script or CI job
  wanted and had to `grep` for before.
- **The verb list exists in two files**, because `novi-agent`
  dispatches on it and `novi-state` needs it to validate `agent.allow`.
  This repository's usual answer is one shared table
  (`common/keybindings.h`), and that is not available across two
  standalone shell scripts installed at different paths. So the other
  answer: `packages/tests/test-agent-verbs.sh` checks the two against
  each other on every lint run, and checks that every listed verb is
  actually dispatched. Verified by breaking it on purpose and watching
  it fail.
- **`describe` runs `pkg list` and three `novi-state` subprocesses**,
  so it costs perhaps a second on a slow machine. That is fine for a
  command and would not be fine on an event loop; nothing should poll
  it in a tight loop.
- **`agent.enabled = off` is declared in the shipped `system.conf`**,
  rather than left absent. An absent key is invisible, and the point of
  this document is that the boundary is something you can read.

## Roadmap

1. **A non-root path.** Everything here runs as whatever invoked it;
   `describe` works fine unprivileged, and every `do` verb needs root
   because the tools underneath do. A setuid helper or an s6 service
   taking requests on a socket is the obvious next question, and it is
   a bigger one than it looks — that socket becomes the boundary.
2. **More verbs, one at a time, each with an argument to make.**
   `wifi.join` and `firewall.allow` are the obvious candidates.
3. **A `describe --text` for humans.** JSON is the default here on
   purpose, and a person reading it in a terminal deserves better.
4. **Rate limiting, or a reason not to.** Nothing stops an automated
   actor calling `pkg.install` in a loop.
