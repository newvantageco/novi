# RFC 0030 — themes, and the light one that found two bugs

**Status:** Implemented
**Depends on:** RFC 0002 (declarative state), RFC 0007 (base/desktop split)

> **Summary.** Every colour in this desktop was a compile-time constant.
> `common/theme.c` makes the palette a runtime table loaded from a
> plain-text theme file; `display.theme = <name>` declares which one,
> `novi-state` publishes the resolved name to `/run/novi/theme`, and
> every client reads it at startup. Four themes ship. Type, spacing and
> radius stay compile-time, deliberately.

## Motivation & Problem Statement

`common/theme.h` was a real achievement — it ended a palette that had
been copied into six clients and drifted in all of them — and it left
the palette **correct and unchangeable**. Altering one hex digit meant
rebuilding ten binaries and reflashing an image.

That is the gap Omarchy makes obvious: a distribution people enjoy
using lets one command change how it looks, everywhere, at once. It is
also the single most visible thing an operating system can do, and this
one could not do it at all.

## Decisions

### 1. Colour is runtime. Type, spacing and radius are not.

The tokens in `theme.h` now read fields of a `struct novi_palette`;
everything in §2 and §3 of the design language stays a macro.

A theme that can move a 12px gap to 11 reintroduces exactly what §3
exists to forbid — ad hoc numbers — one file at a time, in a place no
reviewer looks. A theme that can pick a different font can pick one
with no glyphs. **What a theme may change is what a theme is for.**

### 2. The defaults are compiled in, so there is no state with no colours.

`novi_theme` is statically initialised with the design language's own
palette. A client that never calls `novi_theme_load()`, or one whose
theme file is missing, unreadable, empty or nonsense, draws exactly
what it drew before this RFC.

That matters more than it sounds. The alternative failure — a palette
that failed to load and left the struct zeroed — is a black window with
black text and nothing anywhere saying why.

For the same reason the loader parses into a **copy** and commits only
on success. A half-applied theme (new background, old text colour) is
the one outcome worse than not switching at all, because it can be
unreadable.

### 3. Unknown keys are ignored; a bad value costs one token.

A theme file written against a newer palette must not stop an older
client drawing, and one mistyped colour must not cost you the other
sixteen. `parse_hex` is strict about what it accepts and returns 0 on
anything it does not fully understand — a partial parse is how
`#2dd4b` becomes a colour nobody chose — and a rejected value simply
leaves that field at its default.

Six hex digits get alpha `0xff`. The alternative is a colour that comes
out fully transparent, which is a window that renders as nothing at all
with no error anywhere.

### 4. The active theme is a published file, not an environment variable.

`novi-state`'s converger writes the resolved name to
`/run/novi/theme`, temp-file-and-rename so a reader never sees half a
name. Clients read it at startup.

A file because a client started later — from the launcher, from a
terminal, by novi-shell — has to be able to find out, and an exported
variable only reaches children of whoever had it. That is the same
argument as `/run/novi/network.device` (RFC 0009) and
`/run/novi/health` (RFC 0014).

**The key is observable**, unlike every other `display.*` key: the
published file is what clients actually read, so "what theme is this
machine running" has a real answer to compare the declaration against.
A theme that is declared but not installed reports `missing` rather
than the name — `apply` genuinely cannot fix it, and reporting the name
would call a machine drawing the default palette converged on a theme
it does not have.

### 5. The name is validated once, in the converger.

A theme name becomes a path in every client that reads it. `..`
survives a plain character filter because dots are legal in a name —
the trap RFC 0023 records from the other direction — so the converger
refuses a name that is empty, starts with `.`, contains `/`, or holds
anything outside `[A-Za-z0-9._-]`, and refuses one with no matching
file. The client-side loader repeats the check rather than trusting it,
because the file it reads is in `/run` and the check costs six lines.

### 6. Not declared by default.

The shipped `system.conf` documents `display.theme` and leaves it
commented. `axiom` is compiled in as the fallback, so an undeclared key
and `display.theme = axiom` draw the same desktop — and a console-only
machine, which has no themes installed because they ship with the
desktop, does not report permanent drift against a file it was never
going to have.

### 7. A picker, and the one surface that follows live.

`novi-launcher --themes` (Super+T, and a `Theme` row in the Apps list
for people who do not know Super+T yet — the KDE lesson this repo
already records: never hide a feature behind only the thing that
documents it). It **scans** `/usr/share/novi/themes` rather than
naming the four, because a hardcoded menu beside a directory of files
is the drift this project keeps writing tests to prevent, and it marks
the one that is live.

Marking it correctly on a stock machine took a little care.
`display.theme` is undeclared by default (decision 6), so nothing is
published and the desktop is drawing the palette compiled into
`theme.c`. Reporting "no active theme" there would leave the picker
showing four rows and no answer to "which of these am I looking at",
on the exact machine most people open it on. `NOVI_THEME_DEFAULT`
names the compiled-in palette in the header, so exactly one place
knows that the built-in colours are axiom's.

Enter runs `novi-state set display.theme X && novi-state apply` as
**one** `/bin/sh` child. Two spawns would race — `apply` against a
document `set` had not finished writing — and the launcher's own
`spawn_command()` splits on spaces and cannot express a sequence.

Each row draws a **swatch** rather than a glyph: that theme's own card
colour with its own accent inside it, read from the file by
`novi_theme_read()` so it shows what the theme looks like whichever one
is currently running. Two squares and not an icon because
`draw_icon()` blends a monochrome glyph in ONE colour and has no way to
express two, which is the whole information here. On the shipped set
you can see at a glance that `paper` is light.

**The panel and the background both follow a switch live**, by
different mechanisms, and the difference is the interesting part.

novi-panel already redraws once a second, so `novi_theme_reload()` is
one `stat(2)` on a tick it already had. novi-bg had *nothing* to poll —
its own comment said so, and that was a property worth keeping: a timer
would wake an idle wallpaper tens of thousands of times a day to learn
nothing. It gets an **inotify** fd instead: one descriptor, zero
wakeups.

The watch is on the DIRECTORY, not the file. `novi-state` publishes by
writing `theme.new` and renaming it over `theme`, so a watch on the
file follows the old inode into oblivion — it would fire once, for the
deletion, and never again. `IN_MOVED_TO` on `/run/novi` is the event a
rename actually produces. And the fd is **drained** on every wake
whatever it says, because the watch covers a whole directory and an
unread inotify fd stays readable — which would spin the loop at 100%
CPU, silent, visible only as a hot laptop. That is the same shape as
the `POLLPRI` trap novi-files hit on `/proc/mounts`.

Measured on a booted machine, one Enter, nothing restarted: the panel
went `#15161d` → `#0f1018` and the background `#121a1f` → `#11121c`
(teal-tinted to indigo-tinted) within ten seconds. Everything else
still picks the palette up when it next starts — a window that repaints
only on input has nowhere to hang either mechanism.

The reload records the file's mtime and size **before** attempting the
load, not after. A theme file that fails to parse would otherwise be
retried on every tick, which turns a typo into a busy loop opening a
file 86,400 times a day.

### 8. Four themes, and one of them is light on purpose.

`axiom` (the design language's own), `nocturne` (near-black, indigo),
`ember` (warm, amber), `paper` (light).

Shipping more than one proves the mechanism changes what you see.
Shipping only four is because a palette is a design decision and a list
of forty is a shrug. Each keeps the design language's **structure** —
four background layers a fixed step apart, one accent used as a signal,
three text weights — and changes only the hues.

`paper` is there for a reason beyond preference, and it earned its keep
immediately. **Every dark palette can get the elevation order backwards
and still look plausible.** On a light ground the background layers get
*darker* as they rise and `text.on-accent` is light rather than dark, so
anything that assumed "the background is nearly black" shows up at
once. It found both bugs below.

## What was verified

On a booted machine, screendumped and pixel-sampled rather than
eyeballed:

| theme | panel pixel at (600, 8) | expected `bg.panel` |
|---|---|---|
| axiom | `#15161d` | `#15161d` |
| nocturne | `#0f1018` | `#0f1018` |
| paper | `#f6f7f9` | `#f6f7f9` |

`novi-state set display.theme nocturne && novi-state apply` publishes
`nocturne` to `/run/novi/theme` and `novi-state diff` exits 0. The
whole desktop follows: panel, launcher, file manager, window chrome,
background. A full light desktop was screendumped with a client window
open — dark text on light chrome throughout, the accent still reading
as a signal.

### Two bugs, both found by the light theme

**novi-bg had the accent hardcoded, under a comment naming the token.**

```c
const double gcol[3] = { 0x2d, 0xd4, 0xbf };  /* NOVI_ACCENT */
```

The desktop background — the most visible surface there is — kept its
teal glow on every palette while the panel above it switched correctly.
This is the palette-drift bug class CLAUDE.md already documents twice,
**wearing a disguise its two greps cannot see**: a colour written as
three separate two-digit bytes looks nothing like a colour to a grep
for eight-hex constants or for `.red =`. There is a third grep now.

**novi-shell's title bar wrapped an unsigned subtraction.**

```c
NOVI_R(top_rgb) - (int)NOVI_R(NOVI_BG_CARD)
```

`NOVI_R()` yields an *unsigned* int, so the `(int)` is promoted back to
unsigned. When the raised layer is darker than the card, `231u - 255u`
is about 4.29e9, the float multiply carries it, and the cast back to
`uint32_t` writes garbage. **Every title bar came out in horizontal
bands of orange and red.**

On a dark palette the raised layer is always *lighter*, so the
difference was always positive and this was invisible for the entire
life of the file. It is a latent bug that predates this RFC by months
and that no dark theme could ever have surfaced. That is the whole
argument for shipping `paper`, made concrete on the first run.

## Consequences

- **Every client links `common/theme.c`** and calls `novi_theme_load()`
  as the first statement of `main()`. Eleven binaries; the call is
  four lines of comment and one line of code in each.
- **A token is no longer a constant expression**, so 31 file-scope
  `static const pixman_color_t X = NOVI_PIX(TOKEN);` became
  `#define X NOVI_PIX(TOKEN)` — a compound literal evaluated at each
  use, which is what they always morally were. None was used by
  address, which is what made the transform mechanical. Do not
  reintroduce one: the compiler says "initializer element is not
  constant", which does not explain itself.
- **A change reaches windows that are already open only when they
  reopen.** Clients read the published name at startup. `apply` says so
  in a note rather than leaving it to be discovered. Live reload is on
  the roadmap and is a bigger change than it looks — every client would
  need a watch on `/run/novi/theme` and a full re-render on wake.
- **`novi-themes` is its own package**, in `novi-desktop`. `usr/share/novi`
  was claimed wholesale by `novi-launcher` in pkgsplit's `DATA_FILES`;
  that is now `usr/share/novi/apps`, because DATA_FILES is walked in
  full for every entry rather than first-match, so a parent and a child
  both listed would put the same file in two packages — and the parent
  was the wrong owner anyway. The `.app` descriptors are the launcher's;
  the palettes are not.
- **Three greps now, not two.** The palette audit in CLAUDE.md gains
  the byte-triple form.
- **A sixteenth keybinding**, `Super + T`, in the shared table — so it
  is in the shortcut sheet by construction rather than by somebody
  remembering to add it (RFC's own rule: there is no display-only row).
- **`THEME_NAME_MAX` is 31, not 32**, and that is `copy`'s size minus
  its NUL. `-Wformat-truncation` caught it on the first build: a
  32-character name would have been truncated in the field
  `apply_theme()` acts on and would have applied **a different theme
  than the row the person selected**. `scan_themes()` skips a longer
  name rather than truncating it, so one that cannot be applied
  correctly is never offered.

## Roadmap

1. **Live reload in the clients that have an event loop.** novi-files,
   novi-edit and novi-settings all poll already; the same inotify fd
   would work in each. They were left out because a re-render there is
   not one function call, and the panel plus the background is what a
   person watches while switching.
2. **Light-mode auditing that is not a screenshot.** Both bugs here
   were found by looking. A host test that renders each theme through
   the same geometry the icon test uses would find the next one
   without booting anything.
4. **A theme in `/etc`**, so somebody can write their own without
   putting it in `/usr/share`. The loader would take the first hit of
   `/etc/novi/themes` then `/usr/share/novi/themes`.
