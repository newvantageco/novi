# RFC 0005: Users and Accounts

- **Status:** Draft. Implemented and QEMU-verified end to end; see
  "Verification".
- **Labels:** `rfc`
- **Author:** platform readiness work (`docs/PLATFORM-ROADMAP.md` §15)
- **Requires:** RFC per `CONTRIBUTING.md` — this adds a `novi-state`
  domain, a shipped account database, and an installer flow that
  handles a secret.

---

## Motivation & Problem Statement

Novi had exactly one account: `root`, with an empty password.

That was defensible for a live ISO — an installable image nobody can
log into is useless — and indefensible for an installed machine. After
RFC 0003 there were installed machines, and every one of them shipped
passwordless root and no way to be anything else short of running
`adduser` by hand and remembering to.

Three things were missing, not one:

1. **A group database.** `/etc/group` contained the single line
   `root:x:0:`. No `tty`, so nothing getty/login chowns a terminal to;
   no `video` or `input`, so a desktop session run as anyone but root
   could not open `/dev/dri/*` or `/dev/input/*`; no `wheel`, so no
   admin group to `su` from.
2. **A way to declare an account.** `novi-state` governed the
   hostname, services and the network; users were the conspicuous
   thing you still had to do imperatively and out of band.
3. **`/etc/shadow` in the build at all.** No stage had ever created
   it. The one in `/build/rootfs` was a leftover from a hand-run
   command in some earlier session, so a genuinely clean build produced
   an image with no shadow file — which is not a hypothetical, it is
   what a new contributor would have got.

## Proposed Design

### The account database is repo content

`rootfs/etc/{passwd,group,shadow}` are files in the repository,
installed by `build/03-base.sh`, rather than heredocs inside a build
script. They are policy — fixed GIDs that a squashed image's baked-in
file modes depend on, and a root password field that decides whether
anyone can log into the shipped image — and policy belongs somewhere a
reviewer sees it in a diff.

GIDs are fixed, not dynamically allocated, for the same reason: a Novi
rootfs is built reproducibly and squashed into an image, so a group's
number has to be identical on every machine or the modes baked in at
build time stop meaning what they meant.

All three carry comment headers explaining themselves. That is safe:
musl skips unparseable lines in `/etc/passwd`, `/etc/group` and
`/etc/shadow`, **verified** by running a statically linked musl
`getpwnam()`/`getgrnam()` binary against these exact files in a chroot,
not assumed. BusyBox `adduser` appends and `deluser` removes a line, so
the headers survive account changes too — also verified live.

### The `users.*` domain

```
users.<name>.shell   = /bin/sh | absent
users.<name>.groups  = wheel,video,input | none
```

`shell` is the anchor: declaring one creates the account, `absent`
removes it. Every account has exactly one shell, so there is no
separate "should this user exist" key that can get out of step with the
rest.

Two decisions inside that are load-bearing:

**Removing an account never deletes the home directory.** Removing an
account is a configuration change; deleting someone's files is not. A
declarative engine that quietly does the second while you asked for the
first is one nobody should trust with root.

**Group lists are compared sorted.** Declaring `video,wheel` and
`wheel,video` is the same declaration; an ordering difference is not
drift.

### Passwords are deliberately not in the document

`/etc/novi/system.conf` is world-readable and this project actively
encourages committing it to git. A password hash belongs in neither.
Secrets keep their own 0600 store (`/etc/shadow`) and their own tools:
`passwd`, `novi-settings`' Account panel, and the installer. An account
created by convergence starts **locked** (`!` in the hash field) until
someone with root sets its password.

This is the same exception `novi-settings` already makes for the same
reason, now stated as a general rule: **configuration is declared;
secrets are not.**

### Convergence runs in passes, not one sweep

Adding this domain exposed a real flaw in the apply loop.

Keys are not independent. Some only become *applicable* once another
key has been applied — with no account there is nothing to put in a
group, so `users.alice.groups` reads as converged, and `state_keys` is
sorted, so `.groups` is visited **before** the `.shell` key that
creates the account. One sweep left the account created and its groups
unset, and the very next `diff` reported drift that the `apply` had
just been asked to fix. Confirmed live before it was fixed.

`cmd_apply` now re-runs until nothing changes, bounded to three passes.
That is the honest answer, and it generalizes to every future domain
instead of encoding one special case in the sort order. It is bounded
because a converger that never satisfies its own observer would
otherwise spin forever, and saying so is more useful than hanging.

### The installer creates the account, rather than declaring it for later

`novi-install --user NAME`:

- creates the account **inside the target** (`chroot … adduser -D`), so
  the machine is usable the moment it boots rather than after someone
  logs in as root to finish the job;
- adds it to `wheel,users,video,input,audio,seat` by default — enough
  for a desktop session and an admin;
- prompts for its password (twice, echo off) and sets it with
  `chpasswd -c sha512 -R "$MNT"`. `-R` chroots for us, so this needs no
  working `/proc` or `/dev` inside the target. **sha512, not BusyBox's
  DES default**, which truncates at 8 characters and would silently
  make a long password weak;
- and *then* declares the same two keys in the target's
  `system.conf`, via `novi-state set`, so the account is part of the
  document that governs the machine rather than a fact about it nobody
  wrote down — and so `novi-state diff` on the installed system is
  clean rather than showing a user it is about to create.

`--set-root-password` does the same for root. If root is still
passwordless when the install finishes, the installer says so loudly
and tells you how to fix it, rather than shipping a machine anyone at
the console owns and not mentioning it.

The password prompt uses `stty -echo` rather than `read -s`. Both work
under BusyBox ash, but a Ctrl-C mid-prompt with `read -s` leaves the
console with echo permanently off and no obvious way back.

## Alternatives Considered

**Put the password hash in `system.conf`.** NixOS allows
`hashedPassword` in configuration.nix and warns about exactly this.
Novi's pitch is "commit your machine's configuration to git", which
makes the warning insufficient — the design has to not offer the foot-
gun.

**Let the installer only declare the user and leave creation to first
boot's convergence.** Simpler code, worse machine: the first boot would
come up with the account existing but locked and no way to set its
password except logging in as root, which is the problem `--user` was
meant to remove.

**Encode the shell-before-groups ordering in the sort.** Fixes one
case, hides the general problem, and the next domain with an internal
dependency rediscovers it. Passes cost one extra sweep on an apply that
changed nothing.

## Implementation status

Implemented:

- `rootfs/etc/passwd`, `rootfs/etc/group`, `rootfs/etc/shadow`;
  `build/03-base.sh` installs them (shadow at 0600)
- `packages/novi-state` — `observe_user()` / `converge_user()`,
  multi-pass `cmd_apply`
- `packages/novi-install` — `--user`, `--user-groups`, `--user-shell`,
  `--no-password`, `--set-root-password`, and the passwordless-root
  warning
- `rootfs/etc/novi/system.conf` — a worked, commented `users.*` example
- `rootfs/etc/profile` — the login environment, which did not exist

### /sbin on everyone's PATH

There was no `/etc/profile` at all, so a login shell inherited whatever
`login(1)` handed it — which does not include `/sbin`. Confirmed live:
a normal user on a freshly installed machine typing `ip addr` to see
their own address got `ip: not found`.

The historical `bin`/`sbin` split exists because sbin held statically
linked rescue binaries and, later, "administrator" tools. Neither
applies here: the whole userland is one static BusyBox, so `/sbin/ip`
and `/bin/ls` are literally the same file, and the commands that need
privilege are stopped by the kernel, not by being hard to spell.
Leaving them off was a papercut, not a boundary. Debian and Arch have
both since merged sbin into the default PATH for the same reason.

### Two build bugs this work surfaced

Both were latent re-run hazards: harmless on a clean `01..05` because
of stage order, destructive the moment anyone re-ran an early stage.
Both produced images that **failed at boot** with no build-time signal.

- **`03-base.sh` stripped kernel modules.** Its "strip everything" pass
  ran `--strip-all` over every ELF file in the rootfs, which on a `.ko`
  removes `.symtab` and leaves the module permanently unloadable. On a
  clean build there are no modules yet. On a re-run after
  `05-kernel.sh`, every module in the image dies. Confirmed live: all
  22 of `/init`'s `modprobe` calls failed, including `virtio_blk`, so
  there was no `/dev/vda`, no live medium, and a PANIC into the
  emergency shell; `readelf -S` on `virtio_blk.ko` showed the symbol
  table gone. `/lib/modules` is now excluded — the kernel's own
  `INSTALL_MOD_STRIP` uses `--strip-debug` for exactly this reason.
- **`03-base.sh` handed PID 1 back to BusyBox.** BusyBox's `make
  install` creates `/sbin/init` and `/linuxrc` symlinks to itself.
  `04-s6.sh` deletes `/sbin/init` before installing the real one, so
  ordering saved a clean build; a re-run of stage 03 put BusyBox init
  back, and the next boot died right after `switch_root` with "can't
  run '/etc/init.d/rcS': No such file or directory" — the exact failure
  `04-s6.sh`'s own comments already documented from the first time it
  happened. Stage 03 now removes those symlinks at the source, so no
  stage ordering can reintroduce it, and `16-s6-rc-db.sh` checks
  `/sbin/init` and repairs it from the tree it just generated.

## Verification

QEMU, `-machine pc`, serial console.

**Declared account round-trip, live:**
- `novi-state set users.alice.shell /bin/sh` +
  `users.alice.groups audio,input,seat,users,video,wheel` → `diff`
  reported the drift and exited 1.
- One `apply` created the account **and** set every group (2 changes,
  across passes): `id alice` →
  `uid=1000(alice) gid=1000(alice) groups=1000(alice),10(wheel),29(audio),44(video),100(users),101(input),103(seat)`.
  `diff` clean afterwards.
- The account was created locked (`alice:!:…` in `/etc/shadow`) and
  `/home/alice` existed.
- `/etc/passwd`'s comment header survived intact.
- `chpasswd -c sha512` then `su - alice -c 'id -un; pwd'` → `alice`,
  `/home/alice`. A real login shell, not just a passwd entry.
- `set users.alice.shell absent` + `apply` → account gone, home
  directory left in place with its numeric uid.
- `rollback` → account back, groups back, `diff` clean.

**Installer, `--user` and `--set-root-password`, live:**
- Installed onto a blank disk with both flags, including a deliberately
  mismatched root password confirmation to exercise the retry — it was
  rejected and re-prompted, and the install continued.
- Cold-booted from the installed disk with the ISO detached and logged
  in **as alice** with the password the installer set. `id` →
  `uid=1000(alice) … groups=10(wheel),29(audio),44(video),100(users),101(input),103(seat),1000(alice)`,
  `pwd` → `/home/alice`, prompt `alice@novi-box:~$`.
- `grep alice /etc/novi/system.conf` on the installed machine showed
  both declared keys, and `novi-state diff` was clean — the account is
  declared *and* real, not one or the other.
- As that unprivileged user: `PATH` carried `/sbin`, `ip -4 addr show
  eth0` printed the address, and `nslookup` resolved.
- Logged out and logged back in **as root** with the password the
  installer set; `/etc/shadow` showed a `$6$` (sha512) hash.

## Roadmap

- **`novi-settings` Account panel for non-root users.** It writes
  `/etc/shadow` for root today; the same code generalizes.
- **`users.<name>.home` and `.uid`.** Both are useful and both need
  real observers before they are worth declaring.
- **Removing an undeclared user.** `novi-state` only iterates keys the
  document declares, so deleting a key does not delete the account —
  you have to declare `absent`. That is a genuine limit of the model,
  and closing it means the document knowing the full set of accounts it
  owns.
- **`su` vs `doas`/`sudo`.** `wheel` exists and BusyBox `su` honours
  root's password; there is no privilege-escalation policy beyond that.
