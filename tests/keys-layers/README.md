# The per-user keys layer, on a booted machine

RFC 0037 roadmap 3. `common/keys-test.c` covers the loader and the
writer over real files; what it cannot reach is the **session** — the
environment novi-shell runs in, the bindings that actually fire, and
which file the Keys panel writes. This drives those three on a booted
guest.

    bash tests/keys-layers/check.sh [path/to/novi.iso]

It boots the ISO headless, brings the desktop up with
`novi-live-desktop` (the script the Live Desktop menu entry runs —
never a hand-rolled sequence), and reports pass/fail per check.

## What it found, on the image built 2026-09-29

**10 checks, 10 passed.**

| | |
|---|---|
| the session | `HOME=/root` in `/proc/<novi-shell>/environ`, beside `XDG_RUNTIME_DIR=/run/user/0` |
| both files | the compositor logs `(/etc/novi/keys.conf then /root/.config/novi/keys.conf)` |
| yours wins | with `window.terminal = Super+Shift+Y` in `/etc` and `= Super+Shift+T` in `~/.config`, **Super+Shift+T opens a terminal** |
| and the default it replaced | **Super+Return opens nothing** |
| per action | `find.themes = Super+Y`, set only in `/etc`, is still in force — the user file replaced one action, not the document |
| the panel writes yours | after an edit, `/root/.config/novi/keys.conf` gained `window.cycle-next = off` and **`/etc/novi/keys.conf` is byte-identical** |

The Keys panel's header reads `/etc/novi/keys.conf, then
/root/.config/novi/keys.conf`, and both overridden rows carry the `*`.

## SIX HARNESS BUGS, ZERO PRODUCT BUGS

Worth more than the table. Every one of them presented as the product
failing, and this repository has recorded the same family before.

1. **No keyboard.** `-nodefaults` means no input device, and QMP
   `send-key` then returns `{"return": {}}` — success — having
   delivered the keystroke to nothing. Two bindings read as broken.
   `mkvm.sh` attaches `qemu-xhci` + `usb-kbd`; this did not.
2. **A bring-up invented instead of the one the image ships.** Setting
   `services.novi-shell on` and running `apply` made the machine
   oscillate — novi-shell off→on, seatd on→off, three passes, never
   settling — because `novi-live-desktop` declares `services.seatd on`
   as well. A harness that invents its own version of a sequence the
   image ships is measuring the invention.
3. **`pgrep -c` does not exist in busybox** (`[-flanovx]`). It printed
   its usage, exited non-zero, and `|| printf 0` reported zero
   terminals on a machine whose compositor log showed foot mapping a
   window two lines earlier.
4. **The console speaks CRLF.** `pgrep -x foot | wc -l` returning `1`
   arrives as `1\r`, and `^[0-9]+$` never matches it. The substring
   greps that passed hid this; `run()` strips `\r` now.
5. **A GUI launched from the serial shell has no `WAYLAND_DISPLAY`.**
   novi-settings exited instantly and `[1]+ Done` was the only trace.
   novi-shell publishes `/run/novi/display` for exactly this and
   `novi-power` already reads it; assuming `wayland-0` is the
   split-brain that file exists to prevent.
6. **A regex with no hyphen in it.** The action is
   `window.cycle-next`; `^[a-z.]+ = off` cannot match it, so a save
   that had worked — the screendump showed `(unbound)` and "Saved" —
   was reported as a failure.

**A control is what made the difference.** Checks 2b are "the user's
binding fires" and "the default it replaced does not" — and a guest
where no key arrives at all fails the first and PASSES the second.
Check 2a presses Super+Return with the shipped bindings BEFORE
anything is planted, and aborts the run if no terminal opens, so the
two below it cannot pass by accident. It is also what turned bug 1
from a false finding into a loud stop.

**And the screendump settled three of them.** Reading the code and
re-reading the harness did not; a 1280x800 PPM showed the refusal
message, then the `(unbound)` row and "Saved", each time naming the
real cause. CLAUDE.md's standing advice, earning its keep again.
