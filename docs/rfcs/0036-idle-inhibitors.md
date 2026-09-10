# RFC 0036 — asking a machine not to sleep

**Status:** Implemented (host checks green; **not yet run on a booted machine** — see "What was verified")
**Depends on:** RFC 0035 (idle blanking and suspend), RFC 0001 (the compositor spawns, it does not hold policy), RFC 0024 (notifications)

> **Summary.** `zwp_idle_inhibit_manager_v1` in novi-shell, so a client
> can ask the machine to stay awake while its window is on screen; and
> **Super+A**, so a person can ask without owning a window. Both feed
> one decision. `novi-power idle` says which of them is happening.

## Motivation & Problem Statement

RFC 0035 gave this desktop an idle clock: the screen blanks after ten
minutes, and the machine suspends after `power.suspend` if you ask for
it. Neither could be interrupted. Watching something to the end meant
declaring `power.blank = off` beforehand and remembering to put it
back, and a long build on a laptop with `power.suspend` set would be
suspended out from under itself.

Every desktop that blanks or suspends on idle also has a way to say
"not now", and there are two different askers:

- **A program that knows what it is doing.** A video player, a
  presentation, a disc burn. Wayland has a protocol for exactly this,
  `zwp_idle_inhibit_manager_v1`, and wlroots already implements the
  server half — the compositor had simply never created the global.
- **A person who knows what they are doing.** "Do not sleep, I am
  building." Said at a terminal by somebody whose actual workload is a
  shell script that has no window and no business speaking a Wayland
  protocol.

Only the first is a protocol question. Shipping only the first would
have been the more standards-shaped thing to do and would have changed
nothing for anybody: **nothing in this image speaks that protocol
today**, so the compositor would have gained a global with no caller —
the "speculative wiring for a hypothetical future client" this
codebase's own comments make a point of avoiding.

## Decisions

### 1. Two askers, one decision function.

`idle_inhibit_active()` counts client inhibitors; the tick tests
`server->stay_awake || inhibiting > 0`. Two sources, one rule — the
same shape RFC 0012 uses for coldplug and hotplug, which are two ways
of discovering a modalias feeding one `modprobe`.

They are **published separately** (`awake 0|1` and `inhibit N` in
`/run/novi/idle`) because they are two different claims with two
different remedies. A machine that will not sleep is a complaint; "one
program asked" and "you pressed a key an hour ago" are different
answers to it, and a single combined count would hide which.

### 2. Visible, not mapped.

The protocol says inhibitors "should only be in effect while this
surface is visible", and on a compositor with workspaces those are not
the same thing. A player left running on workspace 3 while you read on
workspace 1 is mapped, is not on screen, and has no business keeping
the panel lit.

So the test is `workspace == active_workspace && !minimized` — the
same expression `switch_workspace()` drives the scene graph from,
asked of the inhibited surface's **root** surface, since the protocol
takes any `wl_surface` and a client may well name a subsurface of its
toplevel. A layer surface is asked whether it is mapped instead: layer
surfaces are not workspace-scoped, and unlike toplevels they join
their list at creation rather than at map, so membership is not the
mapped test.

The count is recomputed every tick rather than tracked incrementally,
and that is not laziness. A workspace switch or a minimize changes the
answer **with the inhibitor's client sending nothing at all**, so a
cached flag would have to be updated from `switch_workspace()`,
`move_focused_to_workspace()`, minimize, unminimize, map and unmap —
six places, one of which would eventually be missed, and the symptom
would be a machine that never sleeps. Twenty pointer comparisons once
every five seconds is not worth that risk.

### 3. A locked session honours no client inhibitor. Super+A survives.

Behind the lock surface nothing a client owns is on screen, so the
visibility test answers "no" on its own — but it is written as its own
branch because the consequence is a security property rather than an
accident of the arithmetic: otherwise any client still running could
hold a locked machine awake indefinitely, with nobody there to notice.

**The person's toggle deliberately does not follow that rule.** The
difference is who is claiming. Somebody pressed a key on this
keyboard, on purpose; locking the screen to go and get coffee is the
same person's *other* decision, and suspending mid-build because they
stepped away is precisely the wrongness they pressed the key to avoid.
A client's inhibitor is a program's assertion about its own window,
which is worth nothing the moment no window is on screen.

### 4. The clock is held at zero, not merely stepped over.

While anything inhibits, `idle_ms` is reset each tick rather than
allowed to keep climbing past a threshold that is being ignored.

The difference shows up at the end of a film. Letting the clock run
means the screen goes dark the instant the player releases its
inhibitor — at exactly the moment somebody is looking at it, from a
machine that had spent two hours being told nobody was idle. Zeroing
it means the timeout restarts from the release, which is what "not
idle" was claiming all along.

An already-blanked screen is deliberately **not** woken by an
inhibitor arriving. Turning a display on is something a person does; a
background client that could do it would be a worse problem than the
one this solves.

### 5. `/run/novi/idle` became key-value lines.

It was three positional numbers. Inhibitors gave it a variable-length
part — a name per inhibitor, of which there may be none or several —
and positional fields cannot carry that. The file has exactly one
writer and one reader, both in this repository, so the moment to
change its shape was while that was still true.

### 6. `novi-power idle`, because a published file nobody reads is not an answer.

There is no key to switch inhibitors off, and that is deliberate. The
failure worth guarding against is a client that inhibits and should
not, and the remedy for that is knowing **which** client — not a flag
nobody would find, set on a machine whose owner does not yet know
there is anything to set.

So the inhibitors and their `app_id`s are published, and `novi-power
idle` prints them. A machine that will not sleep and cannot say why is
the actual complaint people have about this protocol on other
desktops.

An `app_id` is a string a stranger's client chose and it is about to
be written into a file a shell script reads, so it is capped and
filtered on the way out — the same treatment novi-notifyd gives a
summary and novi-mount gives a filesystem label. Characters that would
end the line or split the field become underscores rather than being
dropped: a name that silently loses characters is a name that stops
matching the window it came from, which is its only job.

### 7. Super+A is a toggle, and it is in the table.

One row in `common/keybindings.h`, so the shortcut sheet
(`novi-launcher --keys`, Super+/) documents it without anybody writing
it down twice — the property that whole table exists for. A toggle
rather than a held key: an hour-long build is not a thing to keep a
finger on.

It spawns a low-urgency notification on each flip, because a toggle
whose state you cannot see is a toggle nobody will trust, and it
publishes immediately rather than at the next tick — `novi-power idle`
run straight after the keypress must not still say `no`, or the one
tool that can report this state looks broken for five seconds.

## What was verified, and what could not be

**On the build host, done:**

| | |
|---|---|
| the reader | 16 host checks on `novi-power idle` under the shipped busybox ash, each confirmed by reintroducing the bug it covers |
| the sheet's height | a `_Static_assert` on `BUFFER_HEIGHT`, confirmed by putting `ROW_H_KEYS` back to 40 and watching the build stop |
| both binaries | cross-compiled clean at `-O2` with this project's hardening flags, so `-Wformat-truncation` had a chance to speak |

**On a booted machine, done:**

| | |
|---|---|
| the global | novi-shell logs no "could not create the idle-inhibit manager", so `wlr_idle_inhibit_v1_create()` returned an object — the absence of that line is the only evidence available, since wlroots does not announce a global |
| the format | `/run/novi/idle` reads the new key-value lines, `awake` and `inhibit` separate |
| Super+A on | `idle: stay-awake ON (Super+A)` from the keypress, then `idle: inhibited (Super+A and 0 client surface(s)), first is "Super+A"` from the next tick — the transition line, once, not once per tick |
| the toasts | both drew, with the power glyph, in the order they were pressed |
| **the clock is HELD** | `power.blank = 10`, then **thirty seconds** untouched with the toggle on: `blanked 0` and `idle 0`. Three timeouts' worth of not blanking |
| **and released** | Super+A off → `idle: no longer inhibited -- the clock restarts`, and twenty seconds later `blanked 1` with `idle: output Virtual-1 off committed`. The commit result, not the intent — RFC 0035's rule |
| `novi-power idle` | on the target: `awake yes -- somebody pressed Super+A`, with `inhibit no` beside it, the two claims apart |
| the sheet | Super+/ renders all nineteen rows, "Keep this machine awake (on/off) — Super + A" among them in the Session group, with no edit to novi-launcher |

The console is on ttyS0 and is not a libinput device, so typing these
commands does not reset the compositor's idle clock — which is what
makes the thirty-second measurement mean anything.

**One thing that had to be rebuilt twice, and it is a trap worth
naming.** `novi-power idle` printed the command's *usage* on the first
booted image: `packages/novi-power` is base content installed by
`03-base.sh`, and the documented desktop recovery range is
`--from 06 --to 39`, which does not reach it. The compositor half of
this same change was live in that image, so one half of the feature
had updated and the other silently had not. CLAUDE.md records it.

And separately from all of the above: **the client half of the
protocol has not been exercised by a client,
because there is not one in this image.** foot, NetSurf, novi-view and
the rest speak no idle-inhibit. The code path a client would take —
`new_inhibitor`, the visibility test, the destroy hook — is reasoned
from wlroots' own header and this compositor's own workspace model,
and is the same arithmetic Super+A exercises from the point where the
two meet. Say that plainly wherever this is described, the way RFC
0025 says virgl ships unverified: an implemented protocol and a tested
protocol are different claims.

## Consequences

- **A film can be watched to the end**, if the player asks. None here
  does yet.
- **A long build can be protected by a person**, with Super+A, which
  needs no protocol and no window.
- **`/run/novi/idle` is a different format.** One writer, one reader,
  both updated in the same commit.
- **A locked machine sleeps despite any client**, and does not sleep if
  the person said not to.
- **The shortcut sheet is one row from outgrowing a 1366×768 panel**,
  and now says so at compile time rather than shipping a card taller
  than the screen.

## Roadmap

1. **A panel indicator.** `/run/novi/idle` already carries everything
   needed and novi-panel already reads `/run/novi` files once a second
   for the network, the volume and the health verdict. Display-only,
   like the health glyph: there is nowhere for a click to lead.
2. **A client that actually inhibits.** NetSurf has no video and no
   JavaScript (RFC 0031), so the first honest caller here is probably
   a media player, which this system does not have.
3. **`novi-state` reporting it.** `novi-agent describe` composes a
   picture of the machine out of published files; whether something is
   holding it awake belongs in that picture.
