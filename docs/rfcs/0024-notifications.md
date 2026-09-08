# RFC 0024 — Notifications, without a message bus

**Status:** Implemented
**Depends on:** RFC 0001 (desktop), RFC 0023 (removable media)

> **Summary.** `novi-notify "Something happened"` shows a toast if
> there is a desktop and writes to syslog either way. The transport is
> a UNIX datagram socket, not D-Bus. `novi-mount` and `novi-eject` use
> it, so plugging a stick in now says so.

## Motivation & Problem Statement

Things happen on this system and nothing tells anyone. A stick mounts,
a package installs, a service crashes, a volume is safe to unplug — all
of it goes to `/var/log/messages`, which is the right place for a
record and the wrong place for a person. RFC 0023 ends with the user
plugging in a USB stick and having to look at a file manager sidebar to
find out whether anything happened.

It is also the last missing desktop primitive. The panel, the launcher,
the settings app, the file manager and the lock screen are all here.
There is no way for the system to say one sentence.

## Proposed Design

### Not D-Bus, for the third time

`org.freedesktop.Notifications` is the standard interface, and it is a
D-Bus interface. RFC 0009 rejected iwd and RFC 0023 rejected udisks2 on
the same grounds: a message bus daemon in a base image whose entire
point is not having one.

What is actually needed is "hand a short string to a program that may
not be running". That is a datagram socket, and it is about eighty
lines.

The cost is real and worth stating: nothing written for a normal Linux
desktop will notify on Novi without being taught this interface. That
is the same cost this project has already accepted twice, and the same
answer — a first-party tool that does the job — applies.

### Two programs, in two halves of the system

**`novi-notify`** is the sender, and it is in the **base image**. The
things with something to say are base tools: `novi-mount` when a stick
arrives, `novi-eject` when one is safe to pull. A notifier that only
existed when the desktop did would have to be conditionally called by
every one of them.

It **always writes to syslog**, delivered or not. A notification worth
showing is worth recording, and on a console-only machine that line is
the whole of the feature.

**`novi-notifyd`** is the daemon that draws them: a layer-shell client
in the **desktop package**, spawned by `novi-shell` beside `novi-panel`
— the arrangement novi-shell already documents for "its own UI pieces",
and the right one here because a notification daemon with no compositor
to draw on has nothing to do.

**A separate client, not a second surface inside `novi-panel`**, and
that is a failure-domain decision. The panel is the always-visible
chrome: clock, taskbar, network indicator. A bug in socket handling
that takes down this process costs a toast; the same bug inside
novi-panel costs the user their taskbar and their clock.

### A datagram socket, and specifically not a FIFO

`/run/novi/notify.sock`, `SOCK_DGRAM`, mode 0666.

- **Datagram**, so one message is one message: no framing to get wrong,
  no partial reads, no connection state, no ordering between senders.
- **Not a stream**, because a stream needs `connect()` to succeed, and
  a daemon that is starting up would make senders block or fail
  depending on timing.
- **Not a FIFO** — the option a shell script could have used with no C
  at all. `open(O_WRONLY)` on a FIFO with no reader **blocks forever**.
  The largest caller is a uevent handler, where blocking forever stops
  the kernel's hotplug queue (RFC 0012). The one transport a shell
  could reach is the one transport this must not use, which is why
  `novi-notify` is a C program.

With no daemon listening, `sendto` fails immediately with `ENOENT` or
`ECONNREFUSED` and the sender exits 0. Having no desktop is not an
error.

### Everything on that socket is untrusted text

The largest single source of notifications is `novi-mount` announcing a
volume **by its filesystem label** — a string off a stranger's USB
stick. RFC 0023 filters that label for use as a directory name; here it
is being rendered. The socket is world-writable, so any process on the
machine can send one too.

So `sanitise()` is the contract, not garnish: control characters are
**dropped** (not escaped — there is nothing a control character in a
notification summary can mean except drawing outside the box), lengths
are capped, and `urgency` and `icon` are matched against fixed lists
rather than believed. An unknown icon name is no icon, not a fallback
glyph and not an error: a notification whose sender asked for something
this build lacks should still be readable.

World-writable is deliberate. An unprivileged program has as much
business saying "your download finished" as root has saying "a disk is
full", and this system has no session bus to arbitrate. The security
position is not access control on the socket; it is that every message
is treated as hostile.

### Urgency decides how long, not how loud

| | stripe | expires |
|---|---|---|
| low | grey | 3 s |
| normal | teal | 5 s |
| critical | red | **never** |

Critical does not expire because something that matters enough to be
called critical should not vanish while the person is looking away. It
goes when clicked.

`novi-mount` uses critical for exactly one thing: a volume that
disappeared while still mounted — somebody pulled it without ejecting.
That is not melodrama; the whole point of saying it is that they should
see it after they have already looked away.

## Alternatives Considered

- **D-Bus + a real `org.freedesktop.Notifications` implementation.**
  Interoperability with everything, at the cost of the thing this base
  image is defined by not having. Rejected, consistently with RFC 0009
  and RFC 0023.
- **A second surface inside `novi-panel`.** One less process, one
  shared failure domain. Discussed above.
- **A FIFO**, so the sender could be a shell script. Blocks forever
  with no reader. Discussed above.
- **Unmapping the surface when the stack empties.** Tried, and it is
  the bug below.

## Verification

On a booted desktop:

- One notification appears; three at once stack in arrival order with
  the right accent per urgency.
- After seven seconds the low and normal ones are gone and the critical
  one is still there.
- Plugging a USB stick in produces *"NOVI_FAT is ready —
  /run/media/NOVI_FAT"*; `novi-eject` produces *"NOVI_FAT is safe to
  unplug"*. Both are `novi-mount` and `novi-eject` calling
  `novi-notify`, not the test.
- A summary containing a tab, a newline and a carriage return renders
  as `A B`, and a 300-character body is truncated with an ellipsis. The
  daemon is still running afterwards.
- Every one of them is in `/var/log/messages`, including the ones that
  were shown on screen, and the critical one at `daemon.warn`.

### The bug: a surface that unmapped and never came back

The first version attached a NULL buffer when the stack emptied — the
documented way to stop occupying a rectangle. It does not come back. A
layer surface that has been unmapped needs another configure round
before the compositor will accept a buffer, so the next toast attached
one to a surface that was not ready and wlroots dropped it.

**Nothing drew, ever, and nothing said so.** The daemon was running,
the socket was bound, `novi-mount` was firing notifications, and syslog
had every one of them. Only a screenshot showed the empty corner —
which is this repo's standing advice about GUI bugs, earning itself
again.

The fix is better than what it replaced: the surface stays mapped for
its whole life, and click-through is done the way Wayland actually
provides for it — `wl_surface_set_input_region()` covering exactly the
cards. That also makes the **gaps between cards** transparent to the
pointer, which unmapping could never have done.

## Impact

- **Base image:** `novi-notify`, 14 KB, links libc.
- **Packages:** `novi-notifyd`, 50 KB, in `novi-desktop`.
- **`novi-mount` / `novi-eject`** gained a `tell()` helper. It is
  separate from their existing `note()` on purpose: `note` is a
  diagnostic for whoever reads the log afterwards, `tell` is a sentence
  for the person who just pushed a stick into a slot.

## Still not done

- **No history.** A toast that expires is gone; there is no panel
  applet listing what was missed.
- **No actions.** A notification is text, not a button.
- **No per-application muting**, no do-not-disturb, and no
  `novi-state` key — all of which want a notion of "which application"
  that a datagram from an anonymous socket does not carry.
- **One output.** A multi-monitor machine gets toasts on whichever
  output the compositor puts the layer surface on.
