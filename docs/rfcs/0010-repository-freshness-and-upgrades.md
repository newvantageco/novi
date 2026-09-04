# RFC 0010: Repository Freshness and Real Upgrades

- **Status:** Draft. Implemented and QEMU-verified against a live
  mirror, including the replay case; see "Verification".
- **Labels:** `rfc`
- **Author:** platform readiness work (`docs/PLATFORM-ROADMAP.md` §20)
- **Requires:** RFC per `CONTRIBUTING.md` — this changes the package
  index format and the update model.

---

## Motivation & Problem Statement

Two holes were left open by RFC 0006, and both had been listed on its
roadmap since. They are worth taking together because they are the same
sentence from two directions: **the repository could not tell you what
was current.**

### A signature says "genuine", not "current"

`pkg sync` verified an Ed25519 signature over the index and refused
anything that failed. What it could not detect was an index that was
*perfectly genuine and months old*. Someone able to serve one — a
hostile mirror, a captive network, a stale caching proxy — could hold a
machine at a version with a known hole indefinitely, and every
signature and every SHA-256 would still check out.

This is the classic metadata replay attack, and every serious package
manager closes it the same way: the metadata says when it expires, and
the client refuses it after that.

### `pkg update` did not update

It compared the installed version against whatever archive was lying
around locally, using string inequality. Two consequences:

- **It could not see the repository.** A machine with a synced index
  and a newer version available would report nothing to do.
- **It could silently downgrade.** `!=` is not "newer", so an old
  archive in the cache was a perfectly good reason to install it.

Since §3's whole update model rests on this command, that made the
update story a description rather than a mechanism.

## Proposed Design

### `valid-until`, inside the signature

`mkrepo` stamps two comment lines at the top of the index:

```
# generated:   1788531116 (2026-09-04T14:11:56Z)
# valid-until: 1791123116 (2026-10-04T14:11:56Z)
```

Epoch seconds, with a human-readable form beside them. Epoch because
`pkg` compares it against `date -u +%s` and there is then no date
parsing to get wrong, in either direction, on any locale.

They are **comment lines**, which means two things at once: the row
parser never sees them, and they are inside the signed blob, so they
cannot be edited off without breaking the signature.

`--valid-days` defaults to 30.

Three decisions about how it is enforced:

- **Checked after the signature, never before.** An unverified header
  is a string an attacker chose; refusing on it would hand them a
  denial of service that costs them nothing.
- **`pkg sync` refuses; `pkg update` only warns.** Sync is where a
  replayed index would arrive, so that is where staleness is fatal. A
  machine that has been offline for a month should explain why it has
  nothing to offer, not stop working.
- **A broken clock is not treated as 1970.** If `date` fails, the check
  declines to judge rather than judging wrongly. `allow_stale = yes` in
  `pkg.conf` is the documented override, and the file says that a
  machine without a battery-backed clock should have its clock fixed
  instead.

### The index is the authority on what version exists

`locate_pkg` now asks the index for the version it should be looking
for, and only matches local files at *that* version.

This is the fix for a bug worth stating plainly, because the symptom
was a lie: `pkg update` printed

```
==> Upgrading novi-screenshot: 0.1.0 -> 0.2.0
==> Installing novi-screenshot (0.1.0)
```

It had decided correctly, then matched `novi-screenshot-*.pkg.tar.gz`
against the cache, found the 0.1.0 archive the previous install had
left there, and installed that. The decision and the action disagreed,
and only the decision was printed.

Fixing it in `locate_pkg` rather than in `cmd_update` means
`pkg install` after a `pkg sync` also stops handing back a stale cached
archive — the same bug, reached by a different path.

`fetch_from_mirror` takes the wanted version too and fails rather than
substituting a different one.

### `pkg update` consults the index and refuses to go backwards

- The index decides what is available; the cache is only a place a file
  might already be.
- Version comparison is `sort -V`, the only comparison available here
  that knows 1.10.0 is newer than 1.9.2 — which a string comparison
  gets backwards, and which is exactly the kind of wrong that ships a
  downgrade.
- An older version in the index is **not an error**: a repository
  legitimately rolls back a bad release. It is refused, loudly, with
  `pkg install <name>` named as the way to do it deliberately.
- Nothing is downloaded until the decision to upgrade is made. The old
  code fetched the archive before it knew whether it wanted it.

`pkg info` now prints an `Available` line when the index offers a
different version, because printing only the installed version after a
sync reads as "you are up to date" when you are not.

## Alternatives Considered

**Sign each package as well as the index.** More keys to manage and no
more security: the index already carries every hash, and a fresh signed
index is what tells you which hashes are current. It would not have
closed the replay hole either.

**A monotonically increasing index serial instead of an expiry.**
Detects rollback but not freeze: an attacker who serves you serial 47
forever passes every check. Debian uses both; an expiry is the half
that stops the attack this project can actually be subjected to today.

**Trust the transport for freshness.** BusyBox's TLS does not validate
certificates (RFC 0006), so there is no transport to trust.

## Implementation status

- `packages/mkrepo` — `generated`/`valid-until` headers, `--valid-days`
- `packages/pkg` — freshness check, `allow_stale`, version-aware
  `locate_pkg`/`fetch_from_mirror`, rewritten `cmd_update`,
  `version_gt`, `Available` in `pkg info`
- `rootfs/etc/novi/pkg.conf` — `allow_stale`, documented

### What this deliberately does not do

**Two ISOs.** It was the next item on RFC 0007's roadmap and it is not
worth doing yet: the desktop is 2.8 MB of a 72 MB image. Separate
console and desktop images are a habit from distributions where the
desktop is hundreds of megabytes, and building one here would be
motion, not progress. When the package set grows enough for the split
to save something real, it is half an hour's work in `mkiso.sh`.

## Verification

QEMU, against a live HTTP mirror on the build host that was **mutated
between guest commands** — publishing new versions and a replayed index
while the machine was running.

- `pkg install novi-screenshot` → 0.1.0, resolving and fetching its
  dependencies.
- Host publishes **0.2.0** → `pkg sync` → `pkg update novi-screenshot`
  upgrades to 0.2.0, and `pkg list` confirms 0.2.0 (this is the check
  that failed the first time, installing 0.1.0 again).
- Host publishes **0.0.9**, older → `pkg update` refuses: *"the index
  offers 0.0.9, older than the installed 0.1.0 — not downgrading"*,
  naming `pkg install` as the deliberate route.
- Host rewinds `valid-until` by 40 days **and re-signs**, so the
  signature is genuinely valid → `pkg sync` verifies the signature,
  then refuses: *"the repository index is not current: it expired 39
  day(s) ago"*. The previously synced index is left in place;
  `grep -c` for the injected marker in `/var/lib/pkg/index` returns 0.
- `allow_stale = yes` → the same sync succeeds with a warning naming
  the file that permitted it.

## Roadmap

- **A published repository and an offline release key.** The build
  still generates a development key and trusts it — correct when you
  built both halves, and not how a release works.
- **An index serial**, alongside the expiry, for rollback detection.
- **`pkg update all` across a version-constrained dependency graph.**
  `depends=libfoo>=2.0` parses and the constraint is still discarded.
- **Cache pruning.** Superseded archives stay in `/var/cache/pkg`
  forever.
