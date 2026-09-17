# RFC 0038 — a window that stopped answering

**Status:** Implemented and verified on a booted machine (QEMU/TCG; **no physical hardware**)
**Depends on:** RFC 0001 (the compositor), RFC 0024 (notifications), RFC 0031 (the browser this was written for), RFC 0037 (the bindings are a file)

> **Summary.** novi-shell samples two things about every mapped window
> every two seconds: whether its client committed a surface, and how
> much CPU that client's process burned. A window whose client has
> burned half a processor for ten seconds without committing anything
> is judged **not responding** — one notification, a line in
> `/run/novi/windows`, an hourglass — in the notification and in the
> status bar — and a row in novi-settings' Session panel. **Super+Shift+Q** is what ends it.
> Nothing here kills anything on its own.

## Motivation & Problem Statement

RFC 0031 roadmap item 5 put a **memory** bound on the browser — 1 GiB
of address space through `s6-softlimit -a` — after a corpus of
deliberately awkward pages took a 4 GB guest down twice. Item 6 is what
that bound cannot reach, and the corpus says so exactly:

> Three of the five runaways in the corpus peg a core on 29–44 MB, so
> no memory ceiling will ever reach them, and the honest version of
> item 5 says a cumulative CPU limit cannot either.

`RLIMIT_CPU` was examined there and rejected: it is cumulative over a
process's whole life, so the only bound it can express is "this program
has existed for too long", which kills a browsing session that has done
nothing wrong. `nice` ships, and a priority is not a bound — it keeps
the rest of the machine usable and stops nothing.

So the thing left is not a limit at all. It is **noticing**. A person
sitting in front of a window that has stopped drawing has no way to
find out whether it is thinking or dead, and this desktop gave them
nothing: no spinner, no dialogue, no line in a log, and a close button
that sends a request into a socket the program is not reading. GNOME,
KDE and Windows have all shipped a version of this for twenty years,
and it is the most conspicuous thing missing from a desktop that now
ships a browser.

### The claim that item 6 got wrong

Item 6 filed this as needing "a notion of progress NetSurf does not
currently export", and that framing is what made it look expensive —
it reads as a patch to an upstream, or the process-per-tab rewrite the
sentence after it contemplates.

**It is true of NetSurf and false of the problem.** The compositor
already has a notion of progress for every client on the machine,
because a Wayland client that is answering **commits surfaces** and a
client stuck inside its own layout loop commits nothing. Nothing had to
be exported. It had to be looked at. This is the fourth roadmap item in
this repository found to be wrong about what is already available,
after RFC 0002's `packages.*`, RFC 0030's "a re-render there is not one
function call", and RFC 0033's wired-network GUI — and it is the second
time the blocking claim in RFC 0031 in particular (the first being "a
browser needs Rust and a large native dependency tree") turned out to
be a true statement about something else.

## Decisions

### 1. Two facts, and neither is sufficient.

A window is judged unresponsive when **both** hold for five
consecutive two-second samples:

- its client committed no surface in the sample, and
- its client's process used **≥ 50%** of a processor over it.

Each alone is nothing. A window that commits nothing is, nine times in
ten, a window nobody is using — every idle editor on the machine looks
exactly like a wedged one on that test alone. A client burning CPU
while it draws is a client doing its job.

The CPU half is what makes "not drawing" mean something, and it also
makes the whole thing **cheap**: the commit flag is one store on a path
that already runs per frame, and the measurement happens five times a
minute in a timer.

**50% rather than 90%**, because the case this exists for is a layout
loop on a machine with other work on it — and `nice 5` on the browser
(RFC 0031 roadmap 5) makes a wedged browser *less* likely to have a
whole core, not more. A threshold that only fires on an idle machine
would miss the case the person is most annoyed by.

### 2. It cannot tell slow from stuck, and that is why it kills nothing.

This is the honest limit and it decides everything else. A client
laying out a genuinely enormous document looks — from outside the
process, which is the only vantage point available — exactly like one
that will never finish. No amount of sampling closes that gap; only
the client saying "I am at step 3 of 9" would, and that is the export
item 6 asked for and nobody has.

So the watchdog **reports** and a person acts. The cost of a false
positive is one sentence on a screen. The cost of the same false
positive in a design that killed the window automatically is somebody's
unsaved work, thrown away by a heuristic that was doing its best.

That is also why the thresholds are generous rather than quick. Ten
seconds at half a processor is set where a long computation inside a
client's own process is rare, not where a hang is caught soonest.

### 3. The measurement is per-PROCESS; the verdict is per-window.

`/proc/<pid>/stat` knows nothing about windows, so a program with two
windows has one CPU figure. The composition follows from that: a client
counts as making progress if **any** of its mapped windows committed.
A program animating one window and blocked on another is busy and is
working, and judging its second window wedged would be this code
disagreeing with itself about one process.

Recomputed every tick rather than cached, for the reason RFC 0036's
inhibitor count is: twenty pointer comparisons every two seconds
against a cached flag that map, unmap, minimize, unminimize and two
workspace operations would each have to remember to update.

### 4. A window this compositor cannot measure is never accused.

No pid from `wl_client_get_credentials`, or no `/proc` entry for it,
and the window is left permanently "making progress". That is the same
call the theme loader makes about a file it cannot parse and
`novi-state` makes about a key it does not recognise: the failure of
the instrument must not read as a finding about the thing measured.

### 5. `Super+Shift+Q` has one rule, and that is what makes it safe
one shift from `Super+Q`.

**Ask the program to close; signal it instead when the watchdog has
already established that it cannot hear the request.**

Pressed by accident on a healthy window it *is* `window.close` —
unsaved-changes prompt and all — which is the whole reason it can live
next to it on the keyboard. A key that always killed would be a
fat-finger away from losing an editor buffer, and a key bound somewhere
lonely would be a key nobody finds.

Escalation is **the person pressing it again**, not a timer: SIGTERM
first, SIGKILL if the key comes again while the window is still there
and still judged wedged. A state machine that decides how long a dying
program deserves would be guessing; a second keypress is a decision
somebody made. A recovery resets it, so a SIGTERM from a previous
episode cannot make the next press a SIGKILL.

The asymmetry is worth naming because it is unavoidable: a close
request is per-window and a signal is per-process, so force-quitting
one wedged window of a program with several takes them all. There is no
third option — **a client that cannot read its socket cannot act on a
per-window request at all**, and the process is the only lever left.

**A SANDBOXED WINDOW HAS NO SIGTERM STAGE, and the kernel is what
removed it.** A client under `novi-sandbox` (RFC 0039 — the browser, on
this machine) is pid 1 of its own PID namespace, and the kernel gives
such a process the protection it gives the machine's own init: a signal
whose disposition is still `SIG_DFL` is *discarded* when it is sent
from outside the namespace, and `kill(2)` returns 0 for it. Measured on
a booted machine, against a process under the sandbox: `kill` reported
success, the process was still there two seconds later, `kill -9` ended
it.

So on those windows the polite stage was not merely unlikely to work —
it could not work, it cost a keypress, and this compositor logged that
it had signalled the window. `novi_procstat_is_ns_init()` reads
`NSpid:` out of `/proc/<pid>/status` and the stage is skipped, with the
log saying why. It answers *false* when it cannot tell, so a failed
read leaves the ordinary two-stage path rather than escalating: an
instrument failing must not be what turns a SIGTERM into a SIGKILL.

That decision is narrower than it looks. It applies only where the
watchdog has *already* established the window cannot hear a request —
everything above about a healthy window still holds, and there `Super+
Shift+Q` is still `window.close`, sandbox or no sandbox.

### 6. The pid is checked before it is signalled.

A pid is a number the kernel reuses, and this is the only place in this
compositor that acts on one — as root. The process's **start time**
(field 22 of `/proc/<pid>/stat`) is recorded when the window maps and
compared before the signal goes out; a change means a different process
is wearing the number, and nothing is sent.

The race is narrow — the client's socket closing destroys the window,
so a dead client's window is not focusable for long — but the cost of
losing it is signalling a stranger from a root process, which is worth
four lines to remove rather than to reason about.

### 7. Nothing in this reaches a shell.

The notification's summary contains a **window title**: text the client
chose, from a program whose entire job is rendering somebody else's
document. `spawn()` in novi-shell hands a string to `/bin/sh -c`, so a
page titled `'; reboot #` would have been a remote command injection
into the compositor, as root, **delivered by the code that noticed the
page was hostile**. `notify_unresponsive()` forks and `execlp`s
`novi-notify` with an argv. There is no quoting scheme worth getting
right when not having a shell is free.

The same title reaches `/run/novi/windows`, and goes through
`novi_hist_sanitise()` — this repository's one sanitiser (RFC 0034),
which **drops** control characters rather than escaping them. That is
what makes a line-oriented file safe by construction: a newline cannot
arrive to forge a second record.

### 8. Its own timer, not the idle tick.

novi-shell already has a five-second timer. Hanging this on it was
tempting and wrong twice over: that tick **counts idleness**, and it
**returns early** from several branches — inhibited, waiting for a lock
surface to map, having just suspended. A watchdog on it would stop
watching in exactly the situations where nobody is looking at the
machine. RFC 0030's theme watch made the same call for the same reason.

### 9. A toast on the transition, a file while it is true.

RFC 0014's rule. One notification when a window is first judged wedged
— re-announcing an unchanged problem every two seconds is how a
notification stops being read — and `/run/novi/windows` republished on
every tick that has something in it, which is where novi-settings'
Session panel reads from.

The file is written **once at startup with a count of zero**, so that
an absent file means *no compositor* and a present one with `0` means
*nothing is wrong*. Those are different answers and a reader cannot
otherwise tell them apart. A machine with nothing wedged does no
further I/O here at all.

### 10. There is no icon.

RFC 0024's rule is that an unknown icon name is *no icon*, never a
fallback. This icon set has no glyph that means "wedged", and borrowing
`shield` or `power` would say something else confidently. The empty
column is the honest column until somebody draws the right glyph.

### 11. The notification names the live binding, not `Super+Shift+Q`.

`/etc/novi/keys.conf` can move it (RFC 0037), so the message looks the
row up in the table novi-shell actually loaded and says "no key is
bound to end it" when somebody has unbound it. A message naming a key
that does nothing is precisely the drift `common/keybindings.h` opens
by saying is worse than having no sheet at all.

### 12. Not a `system.conf` key.

Nothing converges a watchdog threshold, the same way nothing converges
a keyboard shortcut (RFC 0037) — novi-shell reads the numbers when it
starts and that is the mechanism. They are compiled in rather than
configurable at all, which is a smaller promise than an environment
variable and can grow into one if anybody's machine disagrees with
them.

### 13. An hourglass in the status bar, and not a warning sign.

Roadmap item 3, and the argument for it is the one that put the bell
there (RFC 0034 roadmap 1): the toast is gone in five seconds and the
condition is not. Five seconds after a window wedges, a machine with a
wedged window on it looked exactly like a machine with nothing wrong
with it — the fact was in `/run/novi/windows` and in the Session
panel, and nothing on screen said to go and look.

**An hourglass, in text-secondary, not a triangle in the warning
colour** — and that is decision 2 above rather than a matter of taste.
The watchdog cannot tell slow from stuck; the strongest claim it can
support is *this is taking a long time*. `long-line.html` was judged
and then recovered four seconds later, having merely been slow, and a
glyph that had shouted about it would have been wrong in a way the
code that raised it is careful not to be. The health glyph is the
warning colour because a service that has died is a fact.

**One glyph, no number**, which is a departure from the bell rather
than an oversight. A number beside an hourglass reads as a *duration*
— the exact quantity this glyph is about — while what the compositor
counts is windows. The Session panel names each window with its stall
time and its CPU, which is where a count can be read without being
mistaken for something else.

It goes **between the health glyph and the coffee cup**, so that the
three glyphs which open the Session panel are contiguous: a click that
lands between two of them still opens the window that explains
whichever was aimed at. `status_layout()` computes the march once and
the drawing, the taskbar's right-hand limit and the hit-test all read
it — RFC 0036 decision 11's rule, now about four glyphs instead of
three.

**An absent `/run/novi/windows` and one saying `unresponsive 0` draw
the same nothing**, and they are different answers. There is no glyph
for "asked, and everything is fine" — the same reason the health glyph
is absent on a healthy machine rather than greyed out.

### 14. And the notification has an icon now — decision 10, closed.

Decision 10 said the empty icon column was "the honest column until
somebody draws the right glyph", because the rasterised set had no
glyph meaning *wedged* and borrowing `shield` or `power` would have
said something else confidently. Drawing the panel's hourglass is what
made it obvious that Lucide already has one — `hourglass`, vendored at
the same pinned commit as every other icon here, and **the same two
bars and two diagonals meeting at a waist** that
`novi_wedge_coverage()` draws procedurally. Two pipelines agreeing, as
`wifi` and `power` already do; neither is derived from the other.

The rule did not bend for it. An unknown name is still no icon, the
name is still matched against a fixed list in `novi-notifyd`, and the
new entry says the thing decision 2 permits — *taking a long time* —
rather than the thing a warning triangle would have claimed.

## What was verified

**The parse has a host test** (`common/procstat-test.c`, run by
`scripts/lint.sh` via `make -C common check`), and it is not
decoration. Field 2 of `/proc/<pid>/stat` is the executable name in
parentheses, and the kernel neither escapes nor rejects what is in it:
a process can call `prctl(PR_SET_NAME)` with a space, a `)`, or the
text `R 1 1 1 1 1 1 1 1 1 1 999 888`. A parser counting whitespace
tokens from the left reads the wrong field and reports a plausible
number. The parse starts from the **last** `)`.

Both bugs were provoked rather than reasoned about:

- Replacing the parse with one that counts from the left fails four
  checks.
- Replacing `strrchr` with `strchr` fails one — and **the first
  version of that check could not fail**, because with `utime 700,
  stime 7` the misparse also lands on 707: the field it mistakes for
  utime happens to hold a 7. The test now uses a stime that makes the
  two answers differ. A probe that cannot fail on the bug it names is
  worse than no probe, which is the sixth time this repository has
  found that in a test rather than in the code.

**The `_Static_assert` in novi-launcher fired, on the first row added
since it was written.** `window.force-quit` makes twenty bindings; at
the sheet's 32px rows that is a 769px buffer against a 768px limit —
over by one pixel, on a 1366×768 panel nobody here has. CLAUDE.md had
recorded that the sheet was "one row from outgrowing" it, and that was
exact. Rows are 30px now (729px, one more row of headroom and no
more). Confirmed by putting 32 back and watching the build stop.

**The shipped `keys.conf` check fired too**, before the binding was
written into it: `test-keys` asserts that every action in the table is
named in the file, and it named the missing one. The third list
working as designed.

**And it was verified on a booted machine**, against the corpus RFC
0031 roadmap 4 built for exactly this.

- **The control never fires.** A benign page renders in 0.1s with its
  links laid out and `/run/novi/windows` stays at `unresponsive 0` —
  including six minutes later, with the file's mtime unchanged, which
  is the "a healthy machine does no I/O here" claim as an observable.
- **`unclosed-tags.html` fires and stays fired.** `unresponsive 1`,
  `window 11534 100 42 NetSurf`, climbing to 202 seconds; the log line
  `watchdog: "NetSurf" (pid 11534) has used 100% of a processor for
  10s without committing a frame`; and a notification reading *"It has
  used 100% of a processor for 10 seconds without drawing. Press Super
  + Shift + Q to end it."* — with the key name looked up rather than
  written down, which is decision 11 in the text of the thing itself.
- **A second browser on the same machine was NOT accused**, which is
  what makes the first result mean anything.
- **The slow/stuck limit was watched rather than argued.**
  `long-line.html` — 4 MB with nothing to break a line on — was judged
  unresponsive at 99%, and logged **`is drawing again` four seconds
  later**. It was slow, not stuck, and this said the wrong thing about
  it for four seconds. That is decision 2 happening, and it is the
  reason decision 2 exists: the cost was one notification.
- **Both halves of Super+Shift+Q.** On the healthy browser it closed
  the window the ordinary way (the shell reported `Done`, not
  `Terminated`). On the wedged one it logged `force-quit: sent SIGTERM
  to "NetSurf" (pid 11534) -- press the key again if it is still
  there`, the shell reported `Terminated`, and the file went back to
  `unresponsive 0`.
- **The Session panel** drew `1 not responding  (Super + Shift + Q
  ends one)` in the error colour with `NetSurf  --  pid 11534, 100% of
  a processor, 152s` under it. Screendumped.

**One bug came out of the booted machine and nothing else would have
found it.** The idle timeout blanked the screen in the middle of a run,
and with the outputs off wlroots stops sending frame callbacks — so
every well-behaved client stops committing, and the one window still
burning CPU would be a client legitimately computing in the background.
Exactly the shape this looks for, inverted. The verdict is **frozen**
while blanked rather than cleared: a window already judged wedged still
is, and clearing it would log that it had started drawing again about a
dark screen.

The fix was then watched on the same machine, which is the only way to
know a freeze is a freeze: with a wedged window at 74 seconds,
`power.blank = 60` blanked the screen, and 25 seconds later the file
still read `unresponsive 1 / window 11944 100 74 NetSurf` — the same
74. A keypress later it read 78, then 102. **The CPU percentage kept
moving while the counter did not**, which is the other half of the
rule: sampling continues so that the first tick after the screen comes
back has a real delta rather than one spanning the whole dark period.

**One thing this feature did not cause and ran into anyway:** closing
the focused window left nothing focused, so the very next
`Super+Shift+Q` did nothing at all — which presented as the new key
being broken, and was novi-shell's unmap path never handing focus on.
It predates all of this by the life of the compositor;
`minimize_toplevel()` and `switch_workspace()` have both always done
it, which is what made the omission look deliberate. Fixed separately
with the same MRU-first pick, restricted to the active workspace.

## What this is not

**It is not a sandbox, and it is not process isolation.** RFC 0031
item 7 stands entirely untouched: a bound, a priority and now a
watchdog change what a hostile page can do to the *machine*, and
nothing whatever about what it can do inside the process that parsed
it.

**It is not a promise that a wedged window can always be recovered
from.** SIGKILL ends a process; it does not end a kernel that is
thrashing, and RFC 0031 item 4's finding was that the takedown was
memory rather than CPU. This is the other half of that pair, not a
replacement for the bound.

**And it is not a liveness protocol.** A client that keeps committing
frames while doing nothing useful is, to every part of this, working
perfectly.

## Roadmap

1. **A verdict that survives a workspace switch being wrong.** A
   window on an inactive workspace gets no frame callbacks, so a
   well-behaved client stops drawing there — and stops burning CPU with
   it, which is why this does not misfire today. A client that
   legitimately computes in the background while hidden would be
   judged wedged, and the fix is to know whether the client has *asked*
   to draw (a pending frame callback) rather than only whether it did.
2. **Something that can say "it is thinking".** Everything above is
   the outside view. The inside view is one line of client cooperation
   — a frame committed per layout pass, or a protocol that says so —
   and the moment any client here offers it, the slow/stuck
   distinction stops being unavailable. Not worth a protocol before
   there is a caller (RFC 0036 decision 0's argument).
3. ~~**The panel says nothing.**~~ **Done** — decision 13. An
   hourglass between the health glyph and the coffee cup, in
   text-secondary rather than the warning colour because the watchdog
   cannot tell slow from stuck, with no number beside it because a
   number next to an hourglass reads as a duration. Clicking it opens
   the Session panel, which is where the windows are named.
4. ~~**The notification still has no icon.**~~ **Done** — decision 14,
   which closes decision 10. Lucide's `hourglass` at the pinned
   commit, and it is the same shape the panel draws procedurally.
