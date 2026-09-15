# RFC 0037 — the keys are yours

**Status:** Implemented and verified on a booted machine
**Depends on:** RFC 0001 (the compositor, and the promise this keeps),
RFC 0002 (the config-first philosophy), RFC 0030 (the same
load-a-table-at-startup shape)

> **Summary.** `/etc/novi/keys.conf` is `<action> = <binding>`, one
> line per shortcut you want to change. novi-shell dispatches from the
> result and `novi-launcher --keys` displays the result, so the sheet
> and the machine cannot disagree about what a key does.

## Motivation & Problem Statement

RFC 0001 already said this, in its own words:

> All of this is *default configuration*, not hard-coded behavior —
> `novi-shell`'s bindings live in a plaintext config file a user can
> edit directly, the same config-first philosophy as everything else
> in this repo, not a GUI-only settings dialog with nothing backing it
> on disk.

They did not. Every shortcut in this desktop was a compiled-in
constant, so **the one part of a desktop that people reliably want to
change was the one part they could not** — and a distribution whose
stated thread is "user control over their own machine" was telling
anybody who wanted Super+Return somewhere else to fork it and rebuild
a compositor.

RFC 0002's roadmap carried the same gap from the other end, as the
last unimplemented domain on its list: `desktop.*` — "keybindings,
theme — RFC 0001 already calls for keybindings to move to a
user-editable config file; this is that file."

## Decisions

### 1. Its own file, not `system.conf`.

`/etc/novi/system.conf` is the *declared state* of the machine and
`novi-state apply` converges it. **Nothing converges a keyboard
shortcut**: novi-shell reads its bindings when it starts and that is
the whole mechanism. A `desktop.keys.*` key per binding would put
nineteen lines of something that cannot drift into the document whose
entire point is drift, and `apply` would have nothing to do with any
of them.

So it follows `/etc/novi/wifi.conf` and `/etc/novi/firewall.nft`: a
file of its own kind, in the same directory, read by the thing that
needs it. The cost is that `novi-state diff` cannot report a typo in
it — which is why both readers report their own (decision 6).

### 2. Additive. A line per shortcut you want moved.

Anything the file does not mention keeps the compiled default. The
alternative — the file *is* the table, and an absent action is an
unbound one — is how a person ends up with a machine that has lost
Alt+Tab because they wanted Super+T somewhere else. Same rule as
`packages.*` and `users.*`: mentioning a thing is what brings it under
management.

The practical effect is that the shipped file is **entirely comments**.
Every action is listed with its default, commented out, so the file is
also the documentation — and an unedited machine behaves exactly as it
did before the file existed.

### 3. Base content, not part of the `novi-shell` package.

`pkg` overwrites a package's files on upgrade. A config file somebody
has edited must not live inside one, and this is a file whose whole
purpose is to be edited. `system.conf` and `pkg.conf` are base content
for the same reason; this joins them, installed by `07-novi-shell.sh`
into `${ROOTFS}/etc`, where pkgsplit leaves it because no
`PACKAGE_TABLE` pattern claims `/etc/novi`.

### 4. Both binaries load it, and the sheet's text is GENERATED.

`common/keybindings.h` exists because a shortcut sheet maintained
separately from the bindings drifts, and a drifted sheet is worse than
none. An override file is a new way to produce exactly that drift: the
compositor honours Super+Shift+T and the sheet, reading the compiled
table, keeps saying Super+Return.

So the loader is in `common/`, both binaries call the same two
functions over the same path, and **the sheet's text is no longer
stored at all**. Every row is rendered by `novi_keys_format()` from
the binding that will actually fire.

That deletion was only safe because it was checked: the formatter
reproduced all nineteen hand-written strings character for character —
`"Alt + Shift + Tab"` for the `ISO_Left_Tab` row, `"Super + 1…9"` for
the digit ranges, `"Print Screen"` and `"Volume Up"` for the keys whose
xkbcommon names are `Print` and `XF86AudioRaiseVolume`. The host test
asserts no row ever renders as a raw keysym name again.

### 5. What the parser refuses, and why each refusal.

- **An unknown modifier word is a refusal, not a skip.** `Ctrl+Q` is
  the case that matters: this compositor's table has no control
  modifier, so ignoring the word would bind the shortcut to **Q
  alone** — a config that silently does something much worse than what
  it says.
- **A digit-range row can only be moved by its modifiers.** Those two
  rows match nine keys; a line binding one to `Alt+K` would produce a
  row that answers to nine digits while claiming to be K.
- **A line that cannot be parsed leaves its own row alone** and is
  counted. Refusing the whole file over one typo would take nineteen
  working shortcuts away from somebody who is already confused.
- **An action this build has never heard of is counted, not fatal.**
  One file is read by whatever novi-shell is installed, and a line for
  a shortcut that arrives in a later version must not break the rest.
- `Super`, `Win` and `Cmd` all mean the logo key, `Meta` means Alt,
  case does not matter, and punctuation is written as the character
  (`Super+.`) rather than as `period`. Refusing those would be
  pedantry aimed at exactly the person this file is for.

### 6. Two shortcuts cannot share a binding, and the loser says so.

Dispatch stops at its first match, so "the earlier row wins" is what
the loop does whether or not anybody decides it. The decision is what
happens to the *later* row: leaving it listed on a key it can never
win is a sheet that confidently tells you the wrong thing, which is
the defect `keybindings.h` opens by naming. It is **unbound**, counted,
and rendered as `(unbound)`.

Both readers report the counts, in the place their own reader is
looking: novi-shell logs `keys: N rebound, N line(s) not understood, N
disabled for clashing`, and `novi-launcher --keys` puts it in the
search placeholder — the top of the one window a person opens when a
key does nothing. It is in the placeholder rather than as a row of its
own because the sheet has no scroll by design and its card height is
derived from the binding count; a twentieth row would either hide a
real binding or grow the card past the 768px a `_Static_assert`
defends.

### 7. `novi.keys=off`, in the loader and not in the compositor.

A file read at startup can make a machine unusable, and the fix has to
be reachable from the bootloader — which is the argument RFC 0002
already made for `novi.state=off`. `novi.keys=off` on the kernel
command line ignores the file for that boot.

It is honoured **inside the shared loader**, deliberately. Put it in
novi-shell's `main()` and the compositor would ignore the overrides
while `novi-launcher --keys` went on listing them: the escape hatch
would itself produce the wrong-key document the rest of this design
exists to rule out. Matched as a whole word, so a kernel parameter
that merely contains the string does not switch it off.

### 8. `keybindings.h` became self-contained.

It used `xkb_keysym_t` while including only `xkbcommon-keysyms.h`,
which declares the constants and not the type. It compiled because
every consumer happened to include `xkbcommon.h` (or wlroots, which
does) first. A header that only works second breaks the first time
somebody includes it first — which is exactly what `keys.c` did.

## What is checked without a desktop

`common/keys-test.c`, linking the real loader, run by
`make -C common check` from `scripts/lint.sh`. **289 checks** (the
count is pair-wise in places -- every row against every other for the
collision invariant). The
interesting ones are all things a running desktop cannot show you: a
well-formed file exercises one path, and the paths that matter are the
misspelled modifier, the action that does not exist, the line that
lands on another shortcut's key, and the file that is not there — each
of which has a wrong answer that looks exactly like a working desktop
until somebody presses the key.

Every assertion was confirmed by breaking what it covers: not
rewriting the text on an override (the sheet goes stale), accepting an
unknown modifier word (Ctrl+Q becomes Q), and letting collisions fall
through to first-wins (the shadowed row still advertises its key).

**The shipped `keys.conf` is a third list**, and it is checked in both
directions: every action in the table is named in the file, and every
action the file names exists. `novi-agent`'s verbs learned that lesson
the same way — a row added without a line in the file is a shortcut
nobody can discover the name of, and a line naming an action that was
removed is documentation for something that does nothing.

CI installs `libxkbcommon-dev` for this. The test needs a real
`xkb_keysym_from_name()`, the alternative is a hand-copied table of
xkbcommon's own, and a test that skips itself where the header is
missing skips itself exactly where it would have caught something.

## What was verified, and what could not be

**On the build host:** the 111 checks above; both binaries
cross-compiled clean at `-O2` with this project's hardening flags.

**On a booted machine, done.** A live image with these five lines
appended to the shipped `keys.conf`:

```
window.terminal = Super+Shift+T
session.quit = off
session.lock = Super+Q          # window.close already has it
find.themes = Supper+T          # a typo
window.teleport = Super+Z       # no such action
```

| | |
|---|---|
| the counts | `keys: 3 rebound, 2 line(s) not understood, 1 disabled for clashing (/etc/novi/keys.conf)` in the compositor's log — three because `off` is an override too |
| the new key | **Super + Shift + T opened a terminal** (`foot`, pid 7554) |
| the old key | **Super + Return did nothing** — no window, no process |
| the sheet | Super+/ renders "Open a terminal — Super + Shift + T", "Lock the screen — (unbound)", "Quit the desktop — (unbound)", and "Change the colour theme — Super + T" (the typo'd line was refused, so its default stands) |
| the warning | the search placeholder reads `keys.conf: 2 line(s) not understood, 1 binding(s) taken twice` |
| **the escape hatch** | `novi.keys=off` bind-mounted over `/proc/cmdline` and novi-shell restarted: **no `keys:` line at all**, Super+Shift+T does nothing, and Super+Return opens a terminal again (a new pid — the old one went with the compositor) |

The hatch was tested by bind-mounting a file over `/proc/cmdline`
rather than by rebooting with an edited GRUB entry. That exercises
every line of the reader and not the bootloader; the bootloader's half
is the same `linux ...` line a person edits for `novi.state=off`.

## Consequences

- **The keys are configurable, as RFC 0001 said they were.**
- **`novi-launcher --keys` is still the truth**, by construction
  rather than by discipline.
- **`/etc/novi/keys.conf` is a fourth thing in `/etc/novi`** that is
  not `system.conf`, after `pkg.conf`, `wifi.conf` and `firewall.nft`.
  That is a pattern now and worth naming: the declared document holds
  configuration that converges; a file of its own holds configuration
  that is read at use time by exactly one program.
- **A change takes effect at the compositor's next start**, like the
  theme's does for open windows. The file says so.

## Roadmap

1. ~~**A GUI for it.**~~ **Done** — a fourth panel in `novi-settings`,
   beside Account, Network and System.

   **This is the one configuration file the System panel cannot
   reach**, and deliberately so: `keys.conf` is not a `system.conf`
   key, because nothing converges a keyboard shortcut (decision 3). So
   unlike RFC 0033's wired-network item — which turned out to be a
   second path to keys the GUI already had — this was a real gap, and
   a text editor was the only way to change a shortcut.

   **The write path was the open question and the answer is
   `novi_keys_write()` in `common/keys.c`**, beside the loader,
   because a writer that does not agree with the reader about what a
   line means is exactly the drift that file exists to end. It is
   `state_set`'s surgical edit rather than a rewrite: a settings panel
   that rewrites this file turns it into a machine-owned blob the
   first time somebody uses the panel, and this RFC's whole claim is
   that the GUI and a text editor write the same document.

   **A COMMENTED LINE IS NOT A MATCH**, and that is the load-bearing
   rule rather than a nicety. The shipped `keys.conf` is 87 lines and
   *every one of them is a comment* — it is the documentation as well
   as the file — so a matcher that skipped the `#` would find
   `# session.lock = Super+L` in the middle of a prose block and
   rewrite it in place, uncommenting a line of documentation into a
   setting without being asked. Same trap CLAUDE.md records about
   editing `system.conf` by hand, from the writing side. An action
   with no live line is appended.

   Four more decisions in the writer: leading whitespace is preserved
   (a file somebody formatted stays formatted); removing is a **delete
   and not a comment-out**, because a commented line is documentation
   and inventing documentation on somebody's behalf is not its job; a
   **duplicate live line is dropped** rather than left, since the
   loader resolves duplicates last-wins and writing above a stale line
   that still overrides would leave the file saying one thing and the
   desktop doing another; and an unknown action or unparseable spec is
   **refused**, leaving the file byte for byte as it was.

   **The binding is TYPED, not captured**, and that is forced rather
   than chosen: novi-shell grabs Super+&lt;anything&gt; before a client
   sees it, so a "press the shortcut you want" prompt would have the
   compositor close the Settings window when somebody pressed Super+Q
   at it. The box is pre-filled with the row's current text, so the
   common edit is adding Shift to something rather than retyping it,
   and the accepted spelling is visible rather than guessed at.

   The panel shows the **description**, not the action name —
   "Close the focused window" is what you are looking for and
   `window.close` is what you write in the file, so the action name is
   in the footer for the row you are on, which is where somebody about
   to edit the file by hand needs it. A row you changed is drawn in
   the accent with a `*`, the way the System panel marks drift, and
   that comes from `novi_keys_is_set()` reading the **file** rather
   than from comparing against the compiled table: setting a shortcut
   to what it already was is a real thing somebody does, and only the
   file can say so.

   **The footer is two lines, and that is a bug fix rather than a
   layout.** The first draft had one, chosen by a chain that reached
   "something was saved this session" before anything else — so after
   one successful save every later answer was shadowed by a standing
   *"Saved"*, and a **refused** write reported nothing at all. Typing
   `Ctrl+Q` at a booted machine produced exactly the worst reading:
   the file correctly untouched, the panel saying "Saved". A standing
   fact about the file (a line the loader threw away, a shortcut
   shadowed by an earlier one, the restart reminder) and an answer to
   the keystroke you just pressed are different things and cannot
   share a line. Found by screenshotting it, which is this
   repository's standing advice about GUI changes that read correctly
   in the diff.

   It says what it cannot do. novi-shell reads `keys.conf` once when
   it starts (decision 3 again), so the footer after a save reads
   *"restart the desktop"*. Making the compositor watch the file was
   considered and rejected here: rebinding live could hand somebody a
   conflicting table with no restart left to recover through, which is
   the failure `novi.keys=off` exists for.
2. **More actions than the compositor has.** A binding that runs an
   arbitrary command is the obvious next request and is deliberately
   not here: it is RFC 0029's `exec` verb in a different costume, and
   the same argument applies — a shortcut file that can run anything
   is a shell with a config file attached. If it happens, it should
   name things the desktop already knows how to do.
3. **Per-user bindings.** This is a machine-wide file. A `~/.config`
   layer over it is a small change to the loader and a real question
   about which of them wins.
