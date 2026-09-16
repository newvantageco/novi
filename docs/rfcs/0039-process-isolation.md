# RFC 0039 — a process that cannot reach the machine

**Status:** Implemented and verified on a booted machine (QEMU/TCG; **no physical hardware**)
**Depends on:** RFC 0031 (the browser this was written for), RFC 0007 (base vs package), RFC 0016 (the kernel config is a thing to check)

> **Summary.** `novi-sandbox` runs a program with a root filesystem
> containing only the paths named on its command line, its own process
> table, and a seccomp filter. `pkg install netsurf` puts the browser
> behind it. Namespaces and seccomp, no new dependency — the kernel has
> had every primitive since its config was written.

## Motivation & Problem Statement

RFC 0031 said this three times and never scheduled it. Its roadmap item
7, in full:

> **Process isolation, which none of the above is.** Said in item 4 and
> repeated here because it is the item that never gets written: a bound
> and a priority change what a hostile page can do to the machine, and
> nothing at all about what it can do inside the process that parsed
> it.

Item 4 said the same thing at more length — *"a layout engine parsing
arbitrary HTML off the network is among the larger attack surfaces this
project has ever shipped, and it still ships with none of the
sandboxing a mainstream browser would put around it"* — and item 5's
bound and item 6's watchdog both close with a sentence disclaiming it.
Three items pointing at one gap is a gap somebody should close.

### What it was waiting for, and the answer is nothing

The reason it kept being deferred is the reason RFC 0031's browser was
deferred: an unchecked assumption that it needed something this system
does not have. Checked:

| | |
|---|---|
| `CONFIG_USER_NS`, `CONFIG_PID_NS`, `CONFIG_IPC_NS`, `CONFIG_UTS_NS`, `CONFIG_NET_NS` | all `=y` in `kernel/config-x86_64` |
| `CONFIG_SECCOMP`, `CONFIG_SECCOMP_FILTER` | both `=y` |
| `linux/seccomp.h`, `linux/filter.h`, `linux/audit.h` | in the sysroot |
| `unshare`, `nsenter`, `setpriv`, `chroot` | already busybox applets |

**No new dependency at all**, and 439 lines of C. That is the third
time in this repository a blocking claim turned out to be a true
statement about something else (a Chromium-class browser; NetSurf's
lack of a progress signal; here, a sandbox needing bubblewrap).

## Decisions

### 1. Default deny, named on the command line.

`novi-sandbox --ro /usr/lib --rw "$XDG_RUNTIME_DIR" -- /usr/libexec/netsurf-fb`

The new root is an empty tmpfs; a path nobody named is **not there**.
The alternative — mount the real root and over-mount the sensitive
parts — is shorter and is a denylist of directories, which means every
future package that puts something private somewhere new is a hole
nobody opens a file to notice.

The cost is that the list has to be right, and a missing bind is a
program that fails to start. That is a loud failure on the first run
rather than a quiet one forever, which is the trade this repository
makes everywhere else.

### 2. A user namespace, so nothing here needs privilege.

`unshare(CLONE_NEWUSER|CLONE_NEWNS|CLONE_NEWPID|CLONE_NEWIPC|CLONE_NEWUTS)`
in one call, `CLONE_NEWUSER` included, because an unprivileged process
may create the others **only** as a side effect of creating a user
namespace it owns. Two separate `unshare()` calls fail with `EPERM` on
the second.

This is what keeps the sandbox out of the setuid business. There is no
setuid helper, no capability on the binary, nothing to audit for
privilege escalation — the program has exactly the authority of whoever
ran it, and inside its own namespace that is enough to build a root.

### 3. `pivot_root`, not `chroot`.

`chroot` leaves the old root reachable through any directory descriptor
that survives it, and through `..` from a directory outside the new
tree. `pivot_root` replaces the process's idea of the filesystem, and
then the old root is unmounted out from under it.

### 4. The PID namespace is why the mounts happen after a fork.

`CLONE_NEWPID` takes effect for *children*, not for the process that
asked. So the setup runs in a forked child that is PID 1 of the new
namespace — which is also what makes the freshly mounted `/proc` show
only the sandbox. The parent does nothing but wait and forward the exit
status.

### 5. A denylist filter, and saying so is the point.

The seccomp program refuses 36 syscalls: `ptrace` and the
`process_vm_*` pair, the module and `kexec` calls, `mount`/`umount2`/
`pivot_root`/`setns`/`unshare`/`chroot`, `bpf`, `perf_event_open`,
`userfaultfd`, the keyring, `name_to_handle_at`/`open_by_handle_at`
(which address a file without a path and so reach outside a mount
namespace by design), the machine-wide settings, and `io_uring`.

**An allowlist is stronger and this is not one.** An allowlist has to
know every syscall the program and its libc will ever make, and being
wrong turns a working browser into a crash on a page nobody tested. A
denylist closes the doors known to lead somewhere and leaves the rest
open. Calling this "seccomp" and letting a reader supply the stronger
meaning would be exactly the overclaim RFC 0025 warns about with the
word "Mesa".

`SECCOMP_RET_ERRNO(EPERM)`, not `KILL_PROCESS`: a killed process tells
the person nothing except that their browser vanished, where a refused
syscall usually surfaces as the program's own error message. A filter
meant to catch an exploit in the act would choose differently; this one
is meant to remove the tools an exploit reaches for.

The architecture check in front of the syscall numbers is not
decoration. A syscall *number* is meaningless without knowing whose
table it indexes, and a process entering through the 32-bit compat
layer would otherwise be filtered against a table that is not its own.
That one is `KILL_PROCESS`, because there is no sensible way to continue.

### 6. Not a network namespace, by default, and it says which you got.

A browser's whole job is the network. `--no-net` exists for programs
with no such excuse. What this sandbox gives the browser is filesystem
and process-table isolation and a reduced syscall surface; it is not a
network boundary, and a reader who is told "sandboxed" and assumes
otherwise has been misled by the word rather than by the code.

### 7. Base content, not part of the browser package.

The same argument RFC 0031 roadmap 5 made for `s6-softlimit`: the bound
costs no new dependency because s6 is how this system boots. This costs
none either, and a confinement tool that arrives only with the browser
is one that nothing else can be put behind. `novi-recon`, a future mail
client, anything that reads somebody else's file — all of them want
this and none of them should have to install a browser to get it.

### 8. The staging directory is `mkdtemp`'d.

A fixed name under `/tmp` is a name somebody else can create first, as
a symlink, and this program then builds a root filesystem inside
whatever it points at. The mount namespace makes the result invisible
to them, which is not the same as making it harmless.

### 9. A bind mount is two operations.

`MS_BIND|MS_RDONLY` in one call does **not** produce a read-only mount:
the kernel takes the flags from the source mount and ignores the rest,
so what you get is a bind that reads as confined in the source and is
writable in fact. The remount is what makes it true, and it has to
repeat `MS_BIND` or it applies to the wrong thing. This is the classic
mistake in every hand-written container and it is silent.

### 10. A minimal `/dev` always, rather than six binds every caller repeats.

Nothing runs without `/dev/null`, and a program denied `/dev/urandom`
fails somewhere far from the cause. Bind-mounted rather than `mknod`'d:
creating a device node needs a capability the user namespace does not
grant over the real filesystem, and binding a node that already exists
needs none.

### 11. A missing path is a warning, not a failure.

The caller names what a program *might* need. A desktop without a font
directory should still get a browser that starts and complains about
fonts itself, rather than a sandbox that refuses to run and reports a
path.

## What was verified

**On the build host, which is where the interesting cases are** — the
same argument `novi-panel/icons-test.c` makes. Running the real binary
under the real kernel:

- **The root contains what was named and nothing else.** `ls /` inside
  a sandbox given one bind returns exactly that bind plus `dev`, `proc`
  and `tmp`. **`/root` does not exist**, and neither does `/home`,
  `/etc` or `/usr`.
- **`ps` shows PID 1 as the sandboxed program** and only its own
  children. The machine's process table is not there to be read or
  signalled.
- **The filter denies, and the denial is the filter.** `mount` returns
  `permission denied` and `unshare` returns `EPERM` inside — while
  `/proc/self/status` reports **`CapEff: 000001ffffffffff`**, every
  capability, and **`Seccomp: 2`**. That pairing is the whole proof: a
  process holding `CAP_SYS_ADMIN` in its namespace is refused `mount(2)`
  by the filter and by nothing else. `mkdir` in the same shell succeeds,
  so it is not a blanket privilege drop either.
- **The stage refuses to build against a kernel that cannot run it.**
  `45-novi-sandbox.sh` checks the six required symbols in
  `kernel/config-x86_64` up front, because a binary that builds
  perfectly and fails at every run is the failure shape this repository
  keeps getting caught by.
- **`-Wformat-truncation` was right for the sixth time here**: a
  `PATH_MAX` source appended to inside a `PATH_MAX` destination can
  truncate, and the fix it points at is the clamp — the staging path is
  a 64-byte buffer, not a wider one.

**And then the booted machine found two bugs that the build host could
not**, which is the whole reason this project boots things.

**THE FIRST RUN ON NOVI'S OWN KERNEL FAILED, AND THE CONFIG SAID IT
SHOULD NOT.** `unshare()` answered `EINVAL` — not `EPERM`, which is
the interesting part, because `EINVAL` means a flag the kernel does
not know. `/proc/self/ns/` listed `cgroup mnt net pid user uts` and
**no `ipc`**: `CONFIG_IPC_NS` depends on `CONFIG_SYSVIPC`, which this
kernel deliberately does not set (RFC 0004 found the same absence from
the other end — busybox syslogd's `-C` logs to a SysV shm ring and
therefore logs nowhere here). `olddefconfig` had silently dropped the
symbol, and `kernel/config-x86_64` went on **stating `CONFIG_IPC_NS=y`**
for a kernel that never had it.

Two fixes, and both are about not asking for what is not there. The
sandbox reads `/proc/self/ns` and asks for the namespaces this kernel
supports — a machine with no System V IPC has nothing for an IPC
namespace to isolate, so requesting one is not a stricter sandbox, it
is no sandbox at all. And the kernel config now says in a comment that
the symbol is unsettable rather than claiming it: **a symbol the
config states and the build discards is the same defect as one the
build has to repair.**

**THE SECOND WAS `MS_NODEV`, AND THE EVIDENCE WAS THREE LAYERS AWAY.**
With the namespaces fixed, the browser started and printed
`NetSurf failed to initialise`. Verbose logging put the failure at
`curl_global_init failed` — so mbedTLS could not seed its DRBG — and
the cause was that **every bind got `MS_NOSUID|MS_NODEV`, including
the six device nodes this program mounts itself**. `MS_NODEV` means a
device node on that mount cannot be *opened*: `/dev/urandom` was
present, correct, and unreadable. A hardening flag applied uniformly,
silently disabling the one case that needed the exception, surfacing
as a TLS library failing in a browser.

The flag is per-bind now. A path the caller named still gets
`MS_NODEV`; only the six nodes this file creates do not.

**With both fixed, on a booted machine:**

- **The browser renders inside the sandbox.** `http://127.0.0.1:8089/ok.html`
  lays out in **0.1s** with its heading, its paragraph and its
  window chrome — screendumped, and indistinguishable from the same
  page with `NOVI_BROWSER_SANDBOX=off`.
- **And it is genuinely confined while it does.** From outside, on the
  running process: `NoNewPrivs: 1`, `Seccomp: 2`, and
  `/proc/<pid>/root` containing exactly `dev etc lib proc root run tmp
  usr` — no `/bin`, no `/sbin`, no `/var`. Its `/root` holds the two
  directories the wrapper bound and nothing else of the real one.
- **`novi-glinfo` runs inside it too**, which is what proved the
  Wayland socket and the filter were not the browser's problem while
  the browser still was.

The corpus at `tests/hostile-pages/` under the sandbox is the obvious
next measurement and has not been taken.

## What this is not

**It is not a security boundary against a kernel bug.** Every mechanism
here is the kernel enforcing something on itself. A user namespace in
particular has been the starting point of real privilege escalations;
what it buys is that the browser's own bugs stop at the namespace, not
that the kernel's do.

**It is not an allowlist**, said again because the difference is the
difference between this and a browser sandbox anybody would call
finished.

**There is no Landlock.** `CONFIG_SECURITY_LANDLOCK` is not in this
kernel's config — checked, not assumed — so filesystem confinement here
is entirely the mount namespace, and a program that can open a path it
was given can do anything with it. Landlock would let the sandbox say
"read-only, and only these directories" to the kernel directly, which
is a second lock on the same door and does not depend on getting the
mount list exactly right.

**It does not isolate the browser from itself.** One process still
parses every page; a page that corrupts the layout engine owns the
whole browser, including its other tabs. Per-tab processes are a
different and much larger change.

## Roadmap

1. **The hostile corpus under the sandbox.** RFC 0031 roadmap 4's
   sixteen pages, measured inside this, against the numbers taken
   outside it. The interesting question is not whether they still
   fail — they will — but whether the private `/tmp` and the smaller
   filesystem change what failing costs.
2. **Landlock**, which is one kernel symbol and a second policy layer
   that does not depend on the mount list being complete.
3. **An allowlist filter for programs whose syscall set is knowable.**
   `novi-recon` makes DNS queries and TLS connections and reads no
   files it was not given; that is a short list, and a short list can be
   an allowlist. The browser is the hard case and can keep the denylist.
4. **A `--no-net` caller.** Nothing uses it yet, which by RFC 0036's
   own rule means it is wiring for a hypothetical — it ships because it
   is four lines and the alternative is a flag added under pressure
   later, but a feature with no caller should be named as one.
5. **`novi-state` should be able to say a package runs sandboxed.**
   Today the wrapper decides, which means the answer lives in a shell
   script inside a package rather than in the document that describes
   the machine.
