# RFC 0017 — Joining a WiFi network without a terminal

**Status:** Implemented
**Depends on:** RFC 0002 (novi-state), RFC 0009 (WiFi), RFC 0001 (desktop)

> **Summary.** RFC 0009 gave this system a working WPA2 supplicant and
> `novi-wifi`, a command-line tool. That is the whole interface, which
> means the answer to "how do I get on the wireless network" is still
> "open a terminal and type". This adds a Network panel to
> `novi-settings`: scan, pick, type the passphrase, connected. It also
> gives the GUI clients the thing they had been able to avoid until
> now — a way to run something slow without freezing the window.

## Motivation & Problem Statement

A laptop that cannot join a wireless network from its desktop is not a
desktop anybody uses. RFC 0009's own roadmap named this ("a network
applet in `novi-panel`"), and the desktop's status-bar icons were
generated and left unwired for want of real WiFi data.

There is a second, less obvious problem. Every subprocess
`novi-settings` had ever run — `novi-state get`, `set`, `diff`,
`apply` — takes milliseconds, so it ran them synchronously on the
Wayland event loop, and the file said so with a comment warning that
this stops being acceptable the moment something slow arrives. A WiFi
scan is a radio doing physics for several seconds. It is that moment.

## Proposed Design

### The panel is a front-end, like every other panel

`novi-settings` gains `PANEL_NETWORK`, between Account and System. It
does not open `/etc/novi/wifi.conf`, does not walk `/sys/class/net`,
and does not run `wpa_cli`. Everything is `novi-wifi` and
`novi-state`, for exactly the reason the System panel shells out to
`novi-state set`: the rules about what counts as a wireless device,
where a passphrase may be stored, and how a PSK is derived should
exist in one place.

That required three small additions to `novi-wifi`:

- **`novi-wifi add <ssid> --stdin`** — the passphrase on stdin, no
  prompt, no confirmation, no tty. Stdin and not a third argument
  because `/proc/<pid>/cmdline` is world-readable for as long as the
  process lives, and a WPA passphrase is a secret. No confirmation
  field either: a GUI can ask twice itself, and a second read here
  would be a prompt nobody sees.
- **`novi-wifi scan --tsv`** — `signal<TAB>ssid`, strongest first,
  deduplicated by SSID. Signal *first* because an SSID may contain
  spaces, so a trailing field cannot be found by counting from the
  left; the existing padded human table is unparseable for that
  reason, and a GUI parsing a table meant for people breaks quietly
  the first time somebody names their router with two spaces in it. An
  SSID is attacker-controlled text off the air, so tabs and carriage
  returns are dropped rather than escaped — the same call the package
  index makes about `|`.
- **`novi-wifi iface`** — the wireless interface's name, or exit 1.
  Only so that a caller which needs to *display* it does not grow its
  own idea of what a wireless device is. The rule (RFC 0009) is that
  the kernel says so, through `/sys/class/net/*/phy80211`.

One behaviour changed rather than being added: after writing a new
network, `novi-wifi` now runs `wpa_cli reconfigure` if a supplicant is
up. Before, the honest advice was "run `novi-state apply`" — restart
the service — to pick up a network you had just typed in. That is the
difference between *added* and *connected*.

### One list, not two

Saved networks and scanned networks are merged into a single list. A
person thinks about "networks", not about which of two tables a name
came from, and a saved network that is also in range is one thing, not
two rows that share a name. Each row says what it is: `connected`,
`saved  -45 dBm`, `-71 dBm`, or `saved`.

Rows that are neither saved nor currently on the air are dropped on
every refresh: a network that was in a scan two scans ago and is gone
now is not information, it is a row somebody might try to join.

Keys: `s` scans, `Enter` joins (opening a passphrase prompt for a
network with no credentials), `d` forgets, `w` toggles
`network.wifi`, `r` refreshes. `w` writes through `novi-state set` and
then applies — the same one writer as the System panel, not a second
path into the document.

`Enter` on a network that is already saved deliberately does nothing
but say so. There is no "connect to this one" to issue that would not
be a second opinion about which network the machine should be on; the
supplicant chooses among the networks it knows. Saying that is better
than a button that pretends.

### Not freezing the window

`job_start` / `job_pump` in `novi-settings`: fork, hand the child's
stdout and stderr to one pipe, and let the main loop poll that pipe
alongside the Wayland fd. On EOF, `waitpid` and dispatch on the job
kind. One job at a time — two concurrent scans have no meaning, and a
second `add` in flight would race on `wifi.conf`; a queue would be
machinery for a situation a person cannot create by pressing keys.

Three details that are load-bearing:

- **The read end is `O_NONBLOCK`.** `job_pump` drains in a loop until
  it sees EOF; on a blocking fd the second read sleeps until the child
  produces more, freezing the window for exactly as long as the scan
  it was supposed to be running alongside.
- **`POLLHUP`, not just `POLLIN`.** A child that prints nothing and
  exits produces only a hangup. Waiting for `POLLIN` alone would leave
  the job hanging and the window saying "Scanning..." forever.
- **`wl_display_prepare_read` / `read_events` / `cancel_read`.** This
  is libwayland's protocol for waiting on the display fd yourself, and
  getting it wrong is a hang: `cancel_read` on *every* path that does
  not read, a poll error included, or the next `prepare_read` blocks
  forever.

The passphrase goes to the child down a pipe before its output is
read. That ordering is only safe because the payload is 63 bytes at
most — far inside a pipe buffer — and would deadlock on anything that
could fill one.

`set_status` now copies its message instead of storing the pointer.
Every existing caller passed a string literal; this panel reports what
a child process just said, which lives in a buffer the next job
overwrites.

## What this is not

- **Not WPA3.** RFC 0009's limit stands: internal TLS has no EC
  crypto. A WPA3-only network cannot be joined from here either.
- **Not a panel applet.** The status bar still has no WiFi indicator.
- **Not enterprise WiFi**, not hidden SSIDs, not manual BSSID
  selection, not a static-IP form.
- **Not mouse-driven.** Keyboard only, like every other client here.

## Verification

Live, on the shipped ISO booted to the Live Desktop entry, against two
`mac80211_hwsim` radios — `wlan1` running hostapd as a WPA2 access
point, `wlan0` left for Novi — which is RFC 0009's own harness. The
handshake is real.

Console first, because the new `novi-wifi` verbs have to be right
before a GUI depends on them:

- `novi-wifi iface` → `wlan0`.
- `novi-wifi scan --tsv` → `-30.00	NOVI_TESTNET`.
- `printf 'novitest12345\n' | novi-wifi add NOVI_TESTNET --stdin` →
  written, `/etc/novi/wifi.conf` mode `0600`, and
  `grep -c novitest12345` on it returns **0** — the passphrase is not
  stored, only the derived PSK.
- `novi-state set network.wifi on && novi-state apply` →
  `wpa_state=COMPLETED`, `iw dev wlan0 link` → connected, bytes both
  ways.

Then the whole flow through the GUI, driven by QMP `send-key` and
recorded with `screendump`:

1. Network panel: `wlan0  supplicant not running`, `network.wifi off`,
   an empty list saying to press `s`.
2. `s` → the footer says `Scanning...`.
3. **While the scan is still running, `Left` switches to the Account
   panel and it draws.** That is the proof the event loop is alive —
   a blocked loop would have kept the old frame.
4. Back on Network: `NOVI_TESTNET   -30 dBm`, footer
   `1 network(s) in range`.
5. `Enter` → `Passphrase for "NOVI_TESTNET"`; thirteen keystrokes
   render as thirteen dots.
6. `Enter` → `Saved "NOVI_TESTNET" -- turn WiFi on with w`, and the
   row now reads `saved  -30 dBm`.
7. `w` → `network.wifi` flips to `on`, and mid-association the
   subtitle shows the supplicant's own live state, `wlan0  SCANNING`.
8. Settled: `wlan0  connected to "NOVI_TESTNET"`, the row reads
   `connected`, and on the console `novi-state diff` says the machine
   matches its document.

## Roadmap

- A WiFi indicator in `novi-panel`, which now has something real to
  read.
- Forget-with-confirmation. `d` is immediate, which is defensible for
  a credential you can retype and would not be for anything else.
- A visible-passphrase toggle.
- Hidden SSIDs and enterprise (802.1X) networks.
