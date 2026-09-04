# RFC 0014 — Service health, separate from drift

**Status:** Implemented
**Depends on:** RFC 0002 (novi-state), RFC 0004 (services and readiness)

> **Summary.** `s6-rc -a list` saying a longrun is "up" means
> *supervised and wanted up*. It has now hidden four separate bugs in
> this project, each of which presented as a fully converged machine.
> `novi-state health` asks the other question. It is deliberately not
> part of `diff`.

## Motivation & Problem Statement

Four times now, in four different subsystems:

| bug | what "up" hid | found in |
|---|---|---|
| `syslog` passed `s6-log -d3` with no `notification-fd` | crash-looped for its entire existence | RFC 0004 |
| `network` started before it was ready | convergence restarted it every boot, burning a generation | RFC 0004 |
| `wpa_supplicant -s` with `CONFIG_DEBUG_SYSLOG` off | printed usage and exited, forever | RFC 0009 |
| `acpid` after an S3 resume | up, holding its fds, delivering nothing | RFC 0013 |

Every one of them showed `novi-state diff` reporting a converged
machine. Three were found by chasing a *different* symptom; the fourth
was found only because a test happened to look at the log.

"Make `diff` notice a crash-looping longrun" has been on the roadmap
since RFC 0004, with a note that the obvious implementation
reintroduces the boot race. That note is correct, and it is not the
whole objection.

## Why this is not part of `diff`

**The race.** A longrun that has just been started is momentarily
indistinguishable from one that keeps dying. If `observe_service`
reported "not really up" for either, boot convergence would call it
drift and restart the service it had just started — the exact loop
RFC 0004's `notification-fd` work was written to end, reintroduced
from a new direction.

**The shape, which matters more.** Drift means *the machine does not
match the document, and `apply` can fix it*. A crash-looping service
matches the document perfectly: it **is** declared on, and the engine
**is** keeping it up. What is broken is the service. No amount of
applying fixes a bug in a `run` script, so folding this into drift
would make `apply` promise something it cannot deliver and leave
`diff` unable to ever reach zero on an affected machine — which would
in turn make the drift signal useless for everything else.

Two different questions deserve two different answers:

- `novi-state diff` — does the machine match the document? (exit 1 on
  drift, unchanged)
- `novi-state health` — are the services actually doing their jobs?
  (exit 1 on failure)

## Proposed Design

`s6-svstat -o up,wantedup,ready,updownfor` gives machine-readable
fields; `s6-svdt` prints one line per recorded death. Neither is new —
they shipped with s6 all along, and nothing had ever called them.

The death tally alone is not the signal: a service that died once last
week and has been up since is not crash-looping. It is the tally
*together with* how long the current run has lasted.

| state | condition | meaning |
|---|---|---|
| `ok` | up, no recent deaths | working |
| `stopped` | not wanted up | declared off; not our business |
| `DOWN` | wanted up, not up | cannot start, or caught mid-loop |
| `CRASHLOOP` | up, deaths > 0, up < 60s | started, died, started again |
| `NOTREADY` | up ≥ 60s, readiness never signalled | the RFC 0004 syslog shape exactly |

s6's own service directories (`s6-svscan-log`, `s6-linux-init-*`,
`s6rc-*`) are skipped — they are not ours to judge.

`diff` prints a clearly-marked note when anything is unhealthy, without
touching its exit status, so a converged-but-broken machine stops
being able to say only the flattering half of the truth. `novi-state
boot` logs the same thing after convergence, so a laptop that comes up
with something broken says so on its own console. That boot check is
deliberately an early and incomplete look: it runs seconds after
`s6-rc change` returned, so a service that is *going* to crash-loop
may not have died yet. It reports what is already true, not what is
about to be.

## Verification

Reproducing the original bug on purpose, in a booted machine: rewrite
a live service's `run` to `exit 1` and restart it.

- **The old signals still say everything is fine.**
  `s6-rc -a list | grep -c klog` → `1`. That is the lie, still being
  told, in the same words as ever.
- **`novi-state health`** → `klog DOWN 13-deaths`, exit **1**.
- **`novi-state diff`** → `system matches declared state`, exit **0**
  — correct, it *is* converged — followed by
  `WARN: converged, but a service is not doing its job: klog DOWN 14-deaths`.
- The tally reading 13 on one call and 14 on the next, seconds apart,
  is the loop itself showing up in the output.
- Healthy baseline first, for contrast: every service `ok up-3s`,
  `health` exit 0, `diff` exit 0, no warning.

The other two classifications, each reproduced as the shape of a bug
this project actually had:

- **`CRASHLOOP`** — a `run` of `sleep 6; exit 1`, the wpa_supplicant
  shape (starts, appears to work, dies) →
  `klog CRASHLOOP 3-deaths-up-5s`. This is the case `s6-svstat` alone
  is least able to help with: caught at the right moment the service
  is genuinely *up*, with a pid, and looks perfect.
- **`NOTREADY`** — a service declaring `notification-fd 3` whose `run`
  never writes to fd 3, which is the RFC 0004 syslog bug exactly →
  `network NOTREADY up-75s` after passing the threshold.

`health` exited 1 with both present.

## Roadmap

- **Nothing consumes this yet.** The panel could show a failing
  service; `novi-install` could check before declaring an install
  finished; a future `novi-state watch` could poll it. The signal
  existing is the prerequisite for all of them.
- **`/run/uncaught-logs/current` is where the *reason* lives**, and
  `health` only points at it. Surfacing the last few lines of a failing
  service's own output would turn "klog is down" into "klog is down
  because …".
- **The thresholds (60s, deaths > 0) are judgement, not measurement.**
  They are right for every failure this project has actually had; a
  service that legitimately restarts every few minutes would be
  reported as unhealthy, and none exists yet.
