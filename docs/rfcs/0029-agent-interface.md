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

So the verb list is six: `state.set`, `state.apply`, `state.rollback`,
`pkg.sync`, `pkg.install`, `wifi.join`. Each maps to exactly one
existing tool. The interface adds no capability the machine did not
have — it adds a boundary and a record around capabilities it already
had.

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

### 9. `wifi.join`, and where a secret is allowed to exist.

The first verb that handles one, and the reason it was worth adding
ahead of easier candidates: **an automated actor is exactly the caller
most likely to put a secret somewhere it will be read back later.**

`novi-wifi add <ssid> --stdin` already existed — RFC 0017 built it so
`novi-settings` could join a network without the passphrase appearing
in `/proc/<pid>/cmdline`, which is world-readable for the life of the
process. The agent verb uses the same door. The passphrase arrives on
stdin, goes straight down the pipe, and is never held in a shell
variable this script could print.

**And it is never audited — including on the refusal path, which is
the half that is easy to get wrong.** `cmd_do` captures `args="$*"`
before it dispatches, so a caller making the obvious mistake —
`wifi.join <ssid> <passphrase>`, putting the secret in argv where
every other verb puts its arguments — would have it written into
`/var/log/novi-agent.jsonl` permanently, **by the refusal that was
supposed to protect them**. A boundary that leaks the thing it guards
while reporting that it refused is worse than no boundary. Every
refusal in this branch therefore audits a fixed string.

The SSID *is* audited, because the SSID is configuration. That split
is RFC 0005's rule reaching the agent interface intact.

Two smaller decisions:

- **The SSID is rejected by class, not by allowlist.** Every other
  argument here is checked against `[A-Za-z0-9._-]`-ish sets. An SSID
  is arbitrary text a stranger chose and broadcast over the air, and
  real ones contain spaces and apostrophes — so that rule would refuse
  a large share of actual networks. Instead: no leading `-`, nothing
  empty, no control characters, and 32 bytes, which is what 802.11
  allows. A longer one is not a network anybody can join.
- **A terminal on stdin is refused.** `novi-wifi` would *prompt*, so an
  agent that reached this verb by accident would hang forever rather
  than fail. This verb exists to be driven by a pipe and says so.

### 10. `firewall.allow` was considered and deliberately not added.

It is the other verb this RFC's roadmap named, and on inspection it
should not exist.

`network.firewall.allow` is a `novi-state` key, so an agent permitted
`state.set` can already set it. A dedicated verb would add no
capability — it would add a **second path to one key**, and the two
could disagree about what the document says. RFC 0022's whole argument
is that the set of things reachable from the network has to be one
list a person chose; giving it a second writer with its own semantics
(append, presumably, since that is the only thing a verb would add
over `state.set`) is how that list stops being one list.

If appending without a read-modify-write race is the real need, that
belongs in `novi-state` as a general facility for list-valued keys,
where the System panel and a person at a shell would get it too — not
in the agent as a special case.
### 11. `agent.rate` bounds an accident, and is not a security control.

The roadmap asked for "rate limiting, or a reason not to", and the
reason not to is real enough to state before the feature: **anything
that can run `novi-agent do` can run `pkg` or `novi-state` directly.**
A limit here does not stand between a hostile caller and the machine,
and presenting it as though it did would be worse than not having it —
a boundary people believe in is more dangerous than one they don't.

What it does bound is the failure this interface actually invites: a
**buggy** actor looping. Reinstalling one package a thousand times,
applying the same document until the disk fills. And the value is less
that the loop stops than that it becomes **visible** — a run of `rate
limit` refusals in the audit log says what happened, where a thousand
successful installs say nothing at all. That is RFC 0016's argument
about silent refusals, from the other end.

**Only allowed calls count**, and that is the one subtle decision.
Counting refusals too would make the limit self-sustaining: each
refusal is itself a log line, so once tripped it would stay tripped
for a full minute even if the caller stopped entirely. That is a
lockout wearing a rate limit's clothes, and it reads fine in a diff.

Two smaller things:

- **ISO-8601 UTC sorts lexically**, so "is this line inside the last
  minute" is a string comparison and there is no date parsing in a
  shell script. That property is most of what the audit format is
  worth.
- **Off by default.** A limit that fires on somebody's first
  legitimate batch is a limit they turn off and never reconsider.

`agent.rate` is read at use time like `agent.enabled` and
`agent.allow`, so nothing holds it, it cannot drift, and
`converge_key` never runs to reject a typo — the observer is the only
place `agent.rate = twenty` can surface, and it surfaces as drift.

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

**`wifi.join`'s secret handling has its own host test**
(`packages/tests/test-agent-secrets.sh`, 9 checks, run by
`scripts/lint.sh` under the shipped BusyBox ash). It drives the real
script with every path redirected — audit log, state file, JSON
escaper, and a `novi-wifi` stand-in that records what it was handed —
and asserts that the passphrase reaches the pipe and **not** argv, not
the audit log on success, and not the audit log on the refusal path.
Confirmed by reintroducing the leak (`refuse … "$args"`) and watching
it fail with *"THE PASSPHRASE REACHED THE AUDIT LOG on the refusal
path"*.

And confirmed again on a booted machine, which is a different question
— the host test proves the logic, a live run proves `novi-agent`,
`novi-state` and `novi-wifi` are the versions actually on the image and
find each other:

| | result |
|---|---|
| `novi-agent capabilities` | offers `wifi.join` |
| `agent.allow = pkg.sync, wifi.join` | **0 drift lines** — `novi-state`'s `AGENT_VERBS` accepts the new verb |
| `do wifi.join <ssid> <passphrase>` | refused; the log line reads `withheld`, not the passphrase |
| `printf '…' \| do wifi.join MyNet` | log line reads `"args": "MyNet"` — the SSID, and only the SSID |
| `grep -c <passphrase> /var/log/novi-agent.jsonl` | **0** |
| the log itself | `-rw-------` |

**The rate limit has a host test too**
(`packages/tests/test-agent-rate.sh`, 12 checks). The check that
matters is the self-sustaining one, and **its first version could not
fail** — it raised the limit and expected one more call through, which
passes whether or not refusals count. Introducing the bug on purpose
left the suite green, which is the only reason it was caught. The
check now builds a window where *allowed* is under the limit while
allowed-plus-refused is over it (three successes, four non-rate
refusals, limit five), so the two behaviours give different answers;
with refusals counting it fails on *"that is a lockout, not a rate
limit"*.

A smaller trap the same file hit twice: **`grep -c` prints the count
AND exits 1 when the count is zero**, so `grep -c … || echo 0` emits
`0\n0` and every arithmetic test on it dies with "integer expression
expected". `|| true`.

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

1. ~~**A non-root path.**~~ Done — **RFC 0032**. `novi-agentd` is the
   s6 service taking requests on a socket, and the socket did become
   the boundary: the gate is membership of the `agent` group, the
   caller's uid comes from `SO_PEERCRED` and lands in this log's
   `uid` field, and a new `via` field says which way the request
   arrived. The policy stays here — `novi-agent` remains the only
   reader of `agent.enabled`, `agent.allow` and `agent.rate`.
2. ~~More verbs, one at a time, each with an argument to make~~ —
   `wifi.join` is in (decision 9) and `firewall.allow` is
   **deliberately out** (decision 10): it would be a second writer for
   a key `state.set` already reaches. The next candidates should be
   held to the same test — does this verb add a capability, or only a
   second path to one that exists?
3. **A `describe --text` for humans.** JSON is the default here on
   purpose, and a person reading it in a terminal deserves better.
4. ~~Rate limiting, or a reason not to~~ — **done, and the framing
   was the important half.** `agent.rate` caps how many verbs may
   **succeed** in a rolling minute; unset, `0`, `off` and `none` all
   mean no limit, which is the default. See decision 11 — including
   why it is not a security control.
