# RFC 0013 — Power events, and a shutdown that finishes

**Status:** Implemented
**Depends on:** RFC 0004 (syslog), RFC 0011 (novi-power)

> **Summary.** `novi-power suspend` had existed since RFC 0011 and
> nothing had ever called it: closing a lid did nothing, pressing the
> power button did nothing. Wiring those up found something worse
> underneath — **this system could not shut down at all while anybody
> was logged in**, and no test had ever noticed because every test
> killed the VM ten seconds after typing `poweroff`.

## Motivation & Problem Statement

RFC 0011 gave the machine a way to suspend and a way to read its
battery. It did not give anything a way to *decide* to suspend. On a
laptop that is most of the feature:

- **Close the lid and nothing happens.** The machine goes into a bag at
  80%, runs at full tilt in an enclosed space, and comes out flat and
  hot.
- **Press the power button and nothing happens.** So people hold it for
  four seconds, which is a hard power cut with filesystems mounted —
  the exact outcome handling the button is supposed to avoid.

## Proposed Design

### acpid, and two paths we do not get to choose

BusyBox `acpid` reads every `/dev/input/event*` when given no `-e`,
matches events against a table **compiled into the binary**, and runs
`$confdir/<action>`. The table is three entries; two matter:

| event | action path |
|---|---|
| `EV_KEY` / `KEY_POWER` / value 1 | `/etc/acpi/PWRF/00000080` |
| `EV_SW` / `SW_LID` / value 1 | `/etc/acpi/LID/00000080` |

Those two path names are dictated by that table, not chosen here.
Renaming either file means acpid runs nothing and the button silently
goes back to doing nothing at all — so both carry a comment saying so.
There is no lid-*open* entry, which needs no handler anyway: the kernel
resumes on its own.

Each handler is three lines and execs `novi-power event lid|button`.
Policy lives in `novi-power`, which already owns suspend; `/etc/acpi/`
stays pure wiring.

### `power.lid` and `power.button` are declared, and read at event time

```
power.lid    = suspend     # suspend | poweroff | ignore
power.button = poweroff    # poweroff | suspend | ignore
```

`ignore` exists for the laptop being used as a small server: close the
lid, keep serving.

These are the first keys with **no converger and no observer**, and
that is deliberate. `novi-power` reads the declared value at the moment
the event arrives, so the machine's behaviour and the document can
never disagree — there is no window for drift, and nothing for `apply`
to do. Writing the value to `/run` during an apply purely so `diff` had
something to look at would be the project's own "observers read real
live state, never a cache" rule turned inside out. `state.*` already
established the shape.

**But a key that cannot drift is a key whose value is never checked.**
`converge_key` is where every other domain rejects a bad value, and it
never runs for these. `power.lid = suspned` would have sat in the
document reading as converged while the lid did nothing. So the
observer reports an unusable value as `unsupported`, which shows up as
drift the machine cannot fix — which is the truth — and `apply` then
rejects it with the same wording every other domain uses.

## The bug underneath: shutdown never finished

Wiring the power button to `poweroff` produced a machine that logged
`novi-power: button: poweroff`, stopped most of its services, and then
**stayed up, at a prompt, forever**. Removing acpid from the picture
reproduced it exactly: `poweroff` typed at a shell had never worked.

The chain, in order:

1. `getty` execs `login`, which execs the shell — so the process s6
   supervises **is the interactive shell**.
2. Bringing a service down sends it SIGTERM, and an interactive shell
   ignores SIGTERM by definition.
3. `timeout-down` was unset, which in s6-rc means *wait forever*. So
   `s6-rc -bDa change` printed `service getty-ttyS0: stopping` and
   never returned. Every other service stopped cleanly, including
   `getty-tty1` — the one with nobody logged into it.
4. `s6-linux-init-shutdownd` runs that script with a plain `wait_pid()`
   and **no timeout of its own** (`run_stage3`, verified in the
   source), so it never reached the stage that SIGTERMs everything,
   SIGKILLs the remainder, and calls `reboot(2)`.

So: a Novi machine could not shut down while anyone was logged in —
which is always, because somebody has to type `poweroff`. Every
release, every install, every power-down was a hard cut, and on an
installed ext4 root that is a journal replay every single boot.

**Nothing caught it because nothing looked.** Every QEMU test in this
repo ended `vm.line("poweroff"); time.sleep(10); vm.kill()` — issuing
the command and killing the machine before observing whether it
worked. The command's *effect* was never once checked, across every
milestone that ran one.

### The fix

`down-signal = SIGHUP` and `timeout-down = 4000` on both gettys.

SIGHUP rather than a bigger hammer, because it is *correct*: a getty
going away is a hangup, and hangup is the signal a shell is specified
to die on. `timeout-down` is the backstop for anything that ignores
even that — after 4 seconds s6-rc gives up, `rc.shutdown` exits
non-zero, shutdownd warns and carries on to the sweep that ends the
machine. Losing a shell rudely at that point is fine; hanging forever
was not.

Both are copied through by `s6-rc-compile` (`down-signal` into the
servicedir, `timeout-down` into the compiled database).

## Verification

- **Shutdown finishes.** `poweroff` from an interactive shell now
  reaches `sending all processes the TERM signal` →
  `sending all processes the KILL signal` → `reboot: Power down`, in
  under a second — it does not even reach the 4-second backstop.
- **A real ACPI power-button event runs the handler.** QMP
  `system_powerdown` (a genuine runtime ACPI event, not a simulated
  one) with `power.button = ignore` leaves the machine up and logs
  `novi-power: button: ignore`; pressed three times in a row it fires
  three times. With `power.button = poweroff` the machine shuts down
  cleanly.
- **The lid handler works** when invoked directly. acpid's mapping from
  `SW_LID` to that path is a compiled-in table that has been read, but
  QEMU cannot emulate a lid switch, so that one link in the chain is
  reasoned about rather than tested.
- **Suspend to RAM genuinely works.** RFC 0011 had to say "suspend was
  never actually entered"; it has been now — `PM: suspend entry (deep)`
  and `PM: suspend exit` in the kernel log, resumed via QMP
  `system_wakeup`, with the shell alive on the other side.
- **A typo is caught.** `novi-state set power.lid suspned` →
  `diff` reports `- power.lid = unsupported (actual)`, and `apply`
  refuses with `power.lid: must be 'suspend', 'poweroff' or 'ignore'`.

### One thing that does not work, and it is not ours

**After an S3 resume, the power button stops being delivered — in
QEMU.** Chased to the bottom rather than papered over, because the
obvious "fix" would have been wrong:

- acpid is still up, same PID, holding the same three
  `/dev/input/event*` fds. The device nodes did not change.
- Reading the evdev node directly during a press returns **24 bytes
  before the suspend and 0 bytes after** — so nothing above the kernel
  could have seen it. acpid was never the problem, and restarting it
  (the tempting one-line fix) would have fixed nothing.
- `/sys/firmware/acpi/interrupts/ff_pwr_btn` shows the counter **not
  incrementing** and the status bit latched: `EN` before the suspend,
  `EN STS` after. The ACPI fixed event fires and is never cleared, so
  the kernel never dispatches it to the input layer.

That is below every line of code in this repository. Whether it is
QEMU's S3 emulation or this kernel's ACPI resume path is not something
this test rig can settle, and no userspace change fixes either. Real
firmware re-arms the fixed event on resume, so a physical laptop very
likely does not have this — *likely*, which is the honest word, and one
more thing for the first real-hardware boot to check.

## Roadmap

- **A lid switch on real hardware**, which is the only place the
  `SW_LID` half of this can actually be tested.
- **Suspend-on-idle and low-battery actions.** `novi-power status` can
  read the battery and nothing acts on it; a machine that runs itself
  flat while idle is the same class of problem as the lid.
- **The desktop should ask first.** A lid close that suspends while an
  unsaved document is open is correct behaviour with no confirmation
  path; that belongs with the compositor, not here.
- **`novi-state diff` should notice a crash-looping longrun.** Standing
  since RFC 0004 and re-earned here: `s6-svstat` reported acpid `up`
  throughout the window in which it was delivering nothing.
