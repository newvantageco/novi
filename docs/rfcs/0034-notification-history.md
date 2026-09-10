# RFC 0034 — what was said, after the toast has gone

**Status:** Implemented
**Depends on:** RFC 0024 (notifications), RFC 0030 (themes, for the card), RFC 0001 (UI belongs in a client)

> **Summary.** `novi-notifyd` keeps the last fifty notifications and
> republishes them to `/run/novi/notifications`; `novi-launcher
> --notifications` (Super + N, and an entry on the Apps grid) shows
> them. A toast is up for three or five seconds and then it is gone —
> before this, so was the fact of it.

## Motivation & Problem Statement

**A notification you were not looking at was a notification that never
happened.** RFC 0024 built the toast and stopped there, which makes the
whole mechanism unreliable for precisely the thing it exists to do:
tell you something while you are busy with something else. A volume
mounted, a package installed, a service started crash-looping — three
seconds each, and then nothing, anywhere.

Every desktop that ships notifications ships a history for this reason.
It has been on the README's open list since notifications landed.

## Decisions

### 1. A published file, not a second socket.

`/run/novi/notifications`, rewritten entire on every message. Same
argument as `/run/novi/health`, `/run/novi/theme` and
`/run/novi/network.device`: **a reader that starts later has to be able
to find out**, and a file is the whole of that. novi-launcher is
started fresh each time the key is pressed; a socket it would have to
be listening on before the notification arrived is no use to it.

Rewritten rather than appended to, which gets the bound and the
atomicity in one move: fifty short lines is nothing to write, an
appender needs a separate trimmer that can disagree with it, and a
temp-file-and-rename means a reader on its own schedule never sees half
a list.

### 2. Tab separated with NO escaping, and that is safe by construction.

`<epoch>\t<urgency>\t<icon>\t<summary>\t<body>`

Every field that came from outside has been through the sanitiser,
which **drops** every control character — tabs and newlines included —
rather than escaping them. RFC 0024 made that call for the toast
("there is nothing a control character in a notification summary can
mean except that somebody is trying to draw outside their box"); this
format is a second reason it was the right one. An escaping scheme in a
format parsed by a hand-written splitter is what RFC 0006 refused for
the package index, for the same reason.

So the sanitiser is now **one function in `common/notifications.c`**,
not two copies. Two copies of that rule would be one edit away from a
format where a summary somebody chose shifts every field after it.

### 3. The urgency is a word; the icon is a name.

Both are text in the file, not enum values. A file in `/run` is read by
a *different program*, possibly a different build of it, and a number
that means "critical" only because both sides agree on an enum's order
is a format that breaks silently the day somebody inserts a value.

The icon travels as its name for the same reason, and novi-launcher
resolves it through its own `resolve_icon_name()` — the table it
already uses for `.app` descriptors. The two tables do not fully
overlap, so some icons resolve to nothing, which is RFC 0024's existing
rule: **an unknown icon name is no icon**, not a fallback and not an
error.

### 4. It does not survive a restart, and that is honest.

`/run` is a tmpfs and the history is what *this daemon* has seen. A
daemon that has just started has seen nothing, and saying so beats a
file under `/var` that outlives the session it describes. The empty
state says which of the two situations you are in.

### 5. The reader is novi-launcher, not a new client.

A fourth card mode beside `--symbols`, `--keys` and `--themes`. It
already has the keyboard handling, Esc, the fuzzy filter, the theme,
the fonts, the truncation and the "N more" strip; a new client would be
a second copy of all of it to show a list of strings.

That also means the compositor's part is one more spawn. novi-shell
never reads a notification, exactly as it never reads a theme (RFC
0001).

### 6. Summary and body are separate fields on the row.

Bold summary, muted body, one line — which is how every desktop with
this list draws it, and something `"summary — body"` in one string
cannot express.

It is also what the compiler asked for. Packing them into `primary`
(64 bytes, against a 160-byte body) drew `-Wformat-truncation`, which
was right: most of the body was being thrown away *before layout ever
saw it*. That warning has now caught a real loss in this repository
three times.

The row splits its width: the summary keeps what it needs **up to
half**, the body gets the rest. Half rather than "whatever the summary
wants", so a long summary cannot push the body off the row entirely —
which is exactly the case where this list stops answering the question
it exists for.

### 7. Twelve rows, and it says what it is not showing.

Fifty entries at 32px would be a 1600px card, which fits no laptop
panel. The cap is twelve and the launcher's existing *"N more — keep
typing to narrow"* strip reports the rest, so this is a bounded card
rather than the silent-elision bug class CLAUDE.md keeps recording.

### 8. An empty list says WHY.

A card with a cursor and nothing under it is a puzzle, and here it is a
puzzle with two very different answers: nothing has happened, or the
daemon that would have told you is not running. The empty state
distinguishes them, and `card_h` gets a row's worth of height so the
sentence is inside the card rather than drawn below its bottom edge.

### 9. Enter does nothing, deliberately.

A notification here has already happened, and its sender told us a
summary and a body — not an action. Inventing one (open the volume,
re-run the install) means guessing intent from text: wrong perhaps one
time in ten, and unexplainable every time.

### 10. On the Apps grid as well as Super + N.

`usr/share/novi/apps/notifications.app`. The person most likely to want
*"what did that toast say?"* is the person who did not catch it and has
no idea a key exists — the KDE lesson this repo already applied to the
shortcut sheet: never hide a feature behind only the thing that
documents it.

Because the binding is a row in `common/keybindings.h`, it appears in
`novi-launcher --keys` automatically. A sheet maintained separately
from the bindings drifts; this one cannot.

## What is checked without a desktop

`common/notifications-test.c`, 33 checks, run by `make -C common check`
in the lint pass. It links the real writer and parser rather than
reimplementing them, for the reason `common/theme-test.c` links the
real loader.

The cases are the ones a running desktop cannot produce: a tab inside a
summary (asserted to leave exactly four separators in the record), a
short line, a record with no body field, an unparseable timestamp, an
urgency name this build does not know, the ring dropping the oldest
rather than the newest, a timestamp from the future, and truncation of
an over-long summary still leaving a parseable record. Every
notification a person sends by hand is well formed and in order — so
the interesting half of this format is the half only a test will
exercise.

## What was verified

On a booted live desktop (QEMU, TCG), three notifications sent with
`novi-notify` — one normal with a body, one critical with a body, one
normal with no body:

| | |
|---|---|
| the published file | three records, **newest first**, urgency as a word (`normal`, `critical`), icon as a name (`drive`, `eject`, `package`), body empty on the third |
| before anything was sent | the file did not exist at all, which is the state the empty message describes |
| Super + N | the card opens with the "Search notifications" placeholder and all three rows |
| the row | bold summary, muted body on the same line, age right-aligned in mono — and `critical` beside the age on the one that was |
| the critical toast | still on screen behind the card, because critical never expires (RFC 0024) |

After the icon fix below, on a fully rebuilt image with a fourth
notification added:

| | |
|---|---|
| every row's icon | wifi, package, eject and drive, each the one its sender named |
| the filter | typing `mystick` narrowed four rows to the one whose **body** contains it — the summary does not, so the body is searched too |
| an empty result | *"No notification matches that"*, inside the card |
| the shortcut sheet | `Show recent notifications — Super + N` appears in `--keys` with nothing added to it, because the binding is a row in the shared table |
| the Apps grid | typing `not` in the launcher finds **Notifications**, so the list is reachable with a mouse and no prior knowledge |

**And the screendump found something reading the code did not.** Two
rows out of three had an empty icon column: novi-launcher's
`resolve_icon_name()` is the table for `.app` descriptors and knew
`package` but not `drive` or `eject`. It is not the "unknown icon name
is no icon" rule doing its job — that rule is about names nobody
defined, not about ones this table simply never learned — and an icon
column that is empty twice and full once reads as a rendering bug. The
table now carries every name novi-notifyd accepts.

That is the repo's standing advice about GUI work applied again: the
list was correct, the format was correct, the test passed, and the
thing that was wrong was only visible in a picture.

## Consequences

- **A notification is no longer lost by not being seen.** That is most
  of what makes the mechanism worth having.
- **Two clients now share `common/notifications.c`** — the daemon
  writes, the launcher reads. That is where it belongs: shared code in
  `common/`, tested once, with one sanitiser.
- **The history is per-session.** A reboot, or a restart of
  novi-notifyd, starts it empty.
- **`novi-notify` on a console-only machine still only reaches
  syslog.** The daemon is a desktop package and so is this; nothing
  changed for the base image.

## Roadmap

1. **A panel indicator** — an unread count beside the clock, which is
   the other half of what a history is for. It needs a notion of
   "read", which this deliberately does not have yet.
2. **Dismiss, and clear all.** Both mean writing to the daemon, which
   means the socket gains a direction it does not have.
3. **Persistence across a restart**, if it turns out to be wanted. It
   is a `/var` file and a decision about how long is long enough.
