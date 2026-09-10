# RFC 0035 — the other half of an idle machine

**Status:** Implemented
**Depends on:** RFC 0013 (power events, `novi-power suspend`), RFC 0002 (declarative state), RFC 0001 (the compositor spawns, it does not hold policy)

> **Summary.** `power.suspend = <seconds> | off`. novi-shell already
> counted idleness to blank the screen; it now suspends the machine
> too, by spawning `novi-power suspend`. Off by default.

## Motivation & Problem Statement

`power.blank` turns the display off after ten minutes. Nothing ever
turned the *machine* off, so a Novi laptop left alone kept the CPU, the
radio and the disk awake until the battery ran out. Blanking saves the
panel; the panel is not where the power goes.

`novi-power suspend` has existed since RFC 0013 and could only be
reached by typing it, closing the lid, or picking it out of the power
menu — three deliberate acts. The one case where a machine should
suspend is the case where nobody is there to perform one.

## Decisions

### 1. The same key shape, on the same tick.

`power.suspend`, seconds or `off`, read at use time from
`/etc/novi/system.conf` by novi-shell — the shape `power.blank`,
`power.lid` and `storage.automount` already have. Nothing holds it, so
it cannot drift and `apply` has nothing to converge, which means
novi-state's **observer** is the only place a typo can surface. It
reports an unusable value as drift, because that is the truth: the
machine is not doing what was declared and no apply can make it.

An **undeclared** value observes as `off`, not as the compositor's
default, because the compositor's default *is* off — otherwise every
machine that has never heard of this key would report drift on it
forever.

Reading the document directly rather than forking `novi-state get`:
that is a shell script, and running one on the compositor's event loop
stalls every window on the screen. The blanking path already made this
call and this rides on it — one extra key parsed from a file that was
already being read, five seconds' granularity, no process created.

### 2. OFF by default, and that is not timidity.

`power.blank` ships at 600 seconds. This ships `off`, and the
difference is what happens when it is wrong.

Turning a display off is undone by moving the mouse. **Suspending is
undone only by a working wake path**, on hardware nobody here has
tested — this project has seen exactly one machine resume, QEMU, and
RFC 0013 records that on that machine the power button stops being
delivered after an S3 resume. Shipping an unattended suspend on by
default would mean shipping a machine that can put itself somewhere it
may not come back from. A person who wants it says so.

### 3. Spawn `novi-power`, never reimplement it.

novi-power already picks the sleep state out of what the kernel offers
(`mem`, then `standby`, then `freeze`), saves the mixer — the one piece
of state that does not come back on its own — and syncs. The
compositor's part is what it is for a theme or a screenshot: notice,
and spawn.

### 4. The idle clock is reset at the TRIGGER, not after the resume.

This is the bug this feature is really about, and it is invisible in a
diff.

The compositor's clock does not advance while the kernel is frozen. So
on resume, `idle_ms` is still whatever it was when the machine went
down — over the threshold — and **the very next tick suspends again**.
A machine that cannot be woken up, from code that reads correctly.

Resetting `idle_ms` before the spawn means the timeout has to elapse
again. It is also what makes an untouched machine re-suspend rather
than staying awake forever after one resume, and it removes the need
for an "already suspending" latch: the threshold itself is the
debounce.

### 5. Blanking is considered first on the same tick.

So a machine whose two timeouts are equal blanks and *then* suspends,
rather than suspending with the panel lit.

Nothing enforces an ordering between the two values, though.
`power.suspend` shorter than `power.blank` is a legitimate thing to
declare — suspend quickly, never mind the panel — and refusing it would
be this program having an opinion about somebody's machine.

### 6. It locks first, and WAITS FOR THE SURFACE TO MAP.

`power.suspend.lock`, **on** when undeclared — the opposite call from
`power.suspend` itself, and for the same reason. An idle suspend is by
definition the one path that fires with nobody standing over the
machine, so coming back to an unlocked session is the wrong default
for it. `power.suspend` shipping `off` makes the key inert until
somebody asks for suspend at all, so defaulting it on costs nobody
anything.

**Spawning novi-lockscreen and suspending in the same breath is a race
the machine loses.** It can freeze before the surface exists, and the
resume then shows the desktop for however long the client takes to
come up — which is the whole thing the lock was for. `server->locked`
already flips when the lock surface *maps*, so there is a real answer
to wait on: the tick spawns the client, and suspends on a later tick
once the flag is set.

**If the lock screen does not appear, it does not suspend**, and says
so. The declaration was "lock, then suspend"; doing the second half
without the first is not a degraded version of it, it is the one
outcome the key exists to prevent. A machine that stays awake is
recoverable by anyone who walks up to it; a machine that suspended
unlocked is not. The retry is a full timeout away rather than every
tick, so a lock screen that cannot start does not produce a log line
every five seconds forever.

`power.lid = suspend` still does not lock. Somebody closing a lid is
present, and that path belongs to novi-power — a base tool that runs
on machines with no compositor to ask.

## What was verified, and what could not be

On a booted live desktop (QEMU, TCG, **no `/dev/kvm` in this
container**), with `power.suspend = 30`:

| | |
|---|---|
| the trigger | the machine reached QEMU's `suspended` state on its own, with no input, at the declared timeout — observed through QMP `query-status` |
| the default | `power.suspend = off` as shipped reports **zero drift** and never suspends |
| the key's shape | `novi-state` accepts seconds and `off`, and reports anything else as drift, like `power.blank` |

**The lock-then-suspend ordering is verified**, on a second run with
`power.suspend = 30` and the shipped `power.suspend.lock = on`:

| | |
|---|---|
| with **no root password** | novi-lockscreen refuses (*"root has no password set … refusing to lock"*), the compositor waits three ticks, logs *"the lock screen did not appear … NOT suspending"* and **does not suspend** — retried a full timeout later, twice, exactly as designed |
| after `passwd root` | the last frame before the machine went down is the lock screen — **"Locked / Type your password, then press Enter"** — and the next poll found the guest `suspended` |

The first of those is worth stating as a consequence rather than a
quirk: **on the live image, where root has no password, an idle
suspend with the lock on will never happen.** The log says why and
names the escape. That is the design working, not failing — but it is
the sort of thing that reads as a broken feature if nobody wrote it
down.

**The resume could not be verified, and that is a property of this
container rather than of this feature.** The measurement, because "it
did not come back" is worth being precise about:

- `/sys/power/state` offers `freeze mem disk`, and the kernel config
  has `SUSPEND`, `PM_SLEEP`, `PM_SLEEP_SMP`, `HOTPLUG_CPU` and
  `ACPI_SLEEP` all set — so nothing is missing on the Novi side.
- **QEMU's q35 machine types have disabled S3 since 6.1.** Without
  `-global ICH9-LPC.disable_s3=0` the guest's `mem` falls back to
  s2idle: the vCPU halts with no ACPI wake path, so QMP
  `system_wakeup` has nothing to inject. `scripts/mkvm.sh` sets it
  now, and with it `/sys/power/mem_sleep` reads `s2idle [deep]` — real
  S3 — where before it could only have been s2idle.
- With S3 genuinely enabled the guest still does not come back:
  **258 non-black pixels of console before the suspend, 0 after
  `system_wakeup`, and 0 more after typing six characters at the
  emulated keyboard.** QEMU reports the VM "running" while nothing in
  it executes.
- **A plain `novi-power suspend` typed at a console, with no
  compositor running at all, behaves identically.** So this is the
  platform — S3 resume under TCG — and not idle-suspend.

That last check is the one that matters. Without it the honest reading
of the first run would have been "the feature wedges the machine", and
the fix would have been to something that was not broken.

**So decision 4's reset — the thing this feature is really about — is
argued rather than measured.** The 25-second observation that first
looked like proof was taken on a guest that had not resumed, where
nothing happening proves nothing. It is stated here as reasoning from
the mechanism, and it wants a KVM-capable host to become a fact.

## Consequences

- **A Novi laptop left alone now stops burning its battery**, which is
  the thing every other operating system does and this one did not.
- **`power.blank` and `power.suspend` are independent.** Neither
  implies the other and neither constrains the other's value.
- **A resume comes back to the lock screen** unless
  `power.suspend.lock = off`. A lid-close suspend still does not lock.
- **The resume path is unverified**, here and on real hardware. The
  trigger is verified; what happens after is not, which is most of why
  the key ships `off`.
- **A machine with no password never idle-suspends** while
  `power.suspend.lock` is on, because the lock screen correctly
  refuses to run without one. That is the live image, among others.

## Roadmap

1. **Locking a lid-close suspend too**, which needs novi-power to be
   able to ask a compositor that may not exist — the split-brain this
   project avoids, so it wants a design rather than a flag.
2. **Low battery.** The other half of RFC 0013's power story: QEMU
   emulates no battery, so it could be written and not verified.
3. **Inhibitors.** A video player or a long build should be able to say
   "not now", which needs a protocol (`zwp_idle_inhibit_manager_v1`)
   the compositor does not implement yet — and which is the reason
   every desktop that suspends on idle also has one.
