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

### 12. The supervisor forwards signals, and a second one is SIGKILL.

`novi-sandbox` forks and waits — decision 4 — so there are two
processes where a caller expects one, and a signal aimed at the pid the
caller holds reaches the wrong one. Watched live before this was
fixed: `kill <novi-sandbox>` ended the supervisor and left `sleep 300`
running with nobody waiting on it. One leaked process per invocation,
in a program whose first caller is the thing this corpus exists to run
sixteen times in a row.

Two mechanisms, because they answer different failures. The supervisor
**forwards** SIGTERM, SIGINT, SIGHUP and SIGQUIT; and the child sets
**`PR_SET_PDEATHSIG`**, which is the only thing that can act when the
supervisor is SIGKILLed and has no chance to forward anything.

**Both of them have to be SIGKILL eventually, because of what a PID
namespace does to a signal.** The kernel gives the init of a PID
namespace the protection it gives the machine's own init: a signal
whose disposition is still `SIG_DFL` is *discarded* when it comes from
outside the namespace — and `kill(2)` returns 0 for it. Measured, not
read off a man page:

```
== B. SIGTERM the CHILD directly ==
  kill rc=0
  child after SIGTERM: ALIVE
  child after SIGKILL: gone
```

So a forwarded SIGTERM is a no-op for a program that installed no
handler, and from outside there is no way to tell that apart from a
program shutting down cleanly. The **second** signal is therefore
SIGKILL. Escalation is the sender doing it again, never a timer, which
is the rule RFC 0038 argues for the force-quit key and it is the same
argument. A child that *does* handle the signal gets the real one:
verified with a `trap ... TERM` that printed and exited 7, and the
supervisor returned 7.

`PR_SET_PDEATHSIG` is set to SIGKILL for the same reason — a death
switch the kernel throws away is a death switch that reads as
load-bearing and cannot fire.

### 13. The fork/prctl race cannot be closed with `getppid()`.

`PR_SET_PDEATHSIG` has a window: if the supervisor dies between
`fork()` and the `prctl()`, the signal has already been sent and
nothing will send another. Everywhere else in Unix that is closed by
comparing `getppid()` against the pid captured before the fork.

**In a new PID namespace `getppid()` is 0, always** — the parent is
outside the namespace and has no pid in it to report. So the check
reads as load-bearing, can never pass, and exits the child
immediately. The first build of this did exactly that, and it
presented as a supervisor exiting 125 with nothing on stderr, which is
the failure shape this repository keeps writing down: a guard that
cannot fire, and its cousin, a guard that always fires.

A pipe says the same thing without needing a shared namespace. The
child closes its write end and asks whether the pipe is already at
EOF; it can only be if the supervisor's end is closed too.

### 14. An allowlist, where the program's syscall set is knowable.

Decision 5 chose a denylist and gave the reason: nobody can enumerate
what a layout engine and its libc will ever do. **`novi-recon` is the
other case.** It makes DNS queries and TLS connections, reads no file
it was not given, and runs on an interpreter that ships from this same
build. `novi-sandbox --profile recon` is deny-by-default with 48
syscalls allowed, and `pkg install novi-recon` puts the tool behind it
— the script in `/usr/libexec`, a wrapper on PATH, exactly the shape
RFC 0031 roadmap 5 gave the browser.

**THE LIST IS DERIVED, NOT WRITTEN.** A hand-written allowlist is
somebody's reading of a program, and being wrong means a tool that
worked everywhere it was tried and fails on the path nobody exercised.
So `build/45-novi-sandbox.sh` builds a ptrace tracer —
`/build/sandbox-test/novi-syscalls`, never installed, the hostapd
bargain from RFC 0009 — and the list is the union over every
subcommand plus the host test suite's error branches. Eleven runs, 30
to 44 syscalls each, **48 in the union**, recorded with their
provenance in `novi-sandbox/profile-recon.syscalls`.

**`SECCOMP_RET_LOG` was the obvious instrument and it logs nothing
here.** It needs `audit_seccomp()`, which without `CONFIG_AUDIT` is a
no-op stub in `include/linux/audit.h` — checked in the config, not
assumed. A logging mode that silently logs nothing is worse than no
logging mode, and turning audit on to get one is a kernel change for
an instrument. ptrace needs nothing from the config.

**THE TABLE AND THE MEASUREMENT ARE DIFFED AT BUILD TIME.** `main.c`
writes the list as `SYS_recvfrom` and friends because that is what a
reviewer can read; the derivation is numbers because that is what the
tracer produced. Neither is a copy of the other and a transcription
mistake between them is silent in both directions — a missing entry is
a tool that fails on one subcommand, an extra one is a hole. So the
stage extracts the C table, compiles it, and diffs. Provoked both ways:
dropping `SYS_recvmsg` reports `-47`, adding `SYS_ptrace` reports
`+101`.

**WHY A DERIVED LIST IS STABLE HERE and would not be elsewhere:** the
libc, the interpreter and the kernel all come out of this build. musl
reaches for `open` where glibc uses `openat`, and `stat` where glibc
uses `newfstatat`; neither of those numbers is in the list, and on a
glibc system both would have to be. A distribution that mixes versions
cannot make that claim; this one can.

### 15. `clone` only as a thread, and only because one subcommand needs it.

`clone` appears in exactly one of the eleven traces: `ports`, whose
connect scan uses threads. Nothing else in the tool needs it — and
`clone(2)` without `CLONE_THREAD` is `fork`, so a list saying "this
program creates threads" would also be saying "this program starts
processes", which is the distinction an allowlist exists to be able to
draw. seccomp can read the flags, because they are the syscall's first
argument.

Verified on a booted machine by running **the same probe twice, with
the same binds, changing only the filter**:

```
--profile recon           threading.Thread : works
                          os.fork()        : refused -- Operation not permitted

(no profile, the denylist) threading.Thread : works
                           os.fork()        : SUCCEEDED
```

Which is the point of the whole decision: the denylist cannot draw that
line and does not pretend to, and the difference is visible rather than
argued. (The probe has to be a FILE under a bound directory, not
`python3 -c` — see decision 16.)

`clone3` is on no list here, so it is `EPERM`'d — which is what keeps
this from being the usual clone-filter bypass. That is a fact about
**this image**: musl's `pthread_create` uses `clone(2)` where glibc has
moved to `clone3`. Re-check it if the libc ever changes.

### 16. A profile is a program's, not a language's.

`python3 -c 'import threading'` under `--profile recon` fails, and the
one syscall it wants is **`getcwd` (79)** — `-c` puts the working
directory on `sys.path`, and novi-recon, exec'd by absolute path from
`/usr/libexec`, never asks. It is not in the list because it was never
measured, and putting it there "just in case" is how a derived list
stops being derived.

It is worth stating the other way round too: **the profile does not
make Python safe, it makes one program's use of Python bounded.**

### 17. What being wrong costs is `EPERM`, not a dead process.

`SECCOMP_RET_ERRNO`, as in the denylist and for the same reason. A
syscall on an unexercised path becomes an `OSError` with a traceback
naming the line — diagnosable, and recoverable by
`NOVI_RECON_SANDBOX=off`. A `KILL_PROCESS` allowlist would turn the
same mistake into a program that vanishes.

The profile is also checked for `execve` at install time: the sandbox's
own last act is to exec the target, *after* the filter goes on, so a
profile without it fails there and reads exactly like the program not
being installed.

### 18. `--no-net` has a caller: the image viewer.

Decision 6 shipped `--no-net` and roadmap 4 named it honestly as wiring
for a hypothetical. The caller was there all along. **novi-view decodes
a PNG off somebody else's USB stick through libpng and zlib** — the
same class of surface RFC 0031 roadmap 4 pointed a corpus at for the
browser — and unlike the browser it has no business on a socket at all.
`pkg install novi-desktop` now puts it behind `novi-sandbox --no-net`,
script in `/usr/libexec`, wrapper on PATH.

**The bind list is built at RUNTIME, which no other wrapper here has
needed.** The one file this program reads is chosen when it starts, so
the list cannot be fixed in the script. Two details in resolving it:
the cwd inside the sandbox is `/`, so a relative path would resolve
against the wrong directory; and a **symlink** would otherwise be bound
at its target and opened at its link name, which does not exist inside.
The resolved path is what novi-view is given.

Verified on a booted machine, from the package: the image renders
(screendumped, with the status bar and both fonts), the root holds
`dev etc lib proc root run tmp usr var`, `/usr/share` holds only the
five directories the wrapper named, **`/root` holds only the image**,
`/etc/shadow` is absent, `Seccomp` is 2, and the process sits in its
own network namespace with only `lo` and `sit0` — `net:[4026532212]`
against init's `net:[4026531840]`. The pair that makes `--no-net` mean
something: `wget` inside reports *Network unreachable*, and the same
`wget` without the flag succeeds.

### 19. A minimal `/dev` needs `/dev/shm`, and a window is how you find out.

musl implements `shm_open(3)` by opening a file under `/dev/shm`, so a
Wayland client asking for a buffer the usual way gets ENOENT from a
directory that is simply not there. It surfaces as `failed to allocate
shm buffer`, three layers from the cause.

The sandbox now mounts **its own tmpfs** there rather than binding the
machine's: shared memory is a channel, and binding the real `/dev/shm`
would hand the sandbox a way to pass bytes to anything else that can
name a segment, which is most of what the mount namespace is for.

The gap survived two sandboxed programs — NetSurf and novi-glinfo —
because their stacks reach for `memfd` instead. **A hole that two
programs walked past is not a hole anybody would have reasoned their
way to.**

### 20. A bind does not follow a symlink out of what it bound.

`/usr/share/X11/xkb` is an **absolute** symlink to
`/usr/share/xkeyboard-config-2`. Binding `/usr/share/X11` therefore
puts a *dangling* link inside, because an absolute link resolves
against the sandbox's root, where the target is not. Bisected rather
than guessed: the wrapper's list segfaulted, `--ro /usr/share/X11`
segfaulted, `--ro /usr/share/xkeyboard-config-2` segfaulted, **both
together survived**, and so did `--ro /usr/share` wholesale.

The wrapper binds both ends and **resolves the target rather than
writing it down** — the `2` in that directory name is a version.

### 21. That crash was novi-view's, and five other clients had it too.

`xkb_context_new()` **returns NULL** when it cannot add a single
default include path, having logged `failed to add default include
path`. Six clients in this desktop called it and used the result
unchecked, so the first keymap the compositor sent went to
`xkb_keymap_new_from_string(NULL, …)` and the process died with
SIGSEGV. **novi-lockscreen is one of the six, where a crash means the
session is not locked.**

This is not a sandbox bug and the fix is not in the sandbox: any
machine without xkeyboard-config had it, and nothing had ever produced
such a machine. All six check and report now, naming the directory —
the provoked run prints *"could not create an xkb context — is
/usr/share/X11/xkb present (xkeyboard-config)?"* and exits 1 where it
used to exit 139.

**A sandbox is a machine with things missing, which is why putting a
program in one finds the places it assumed they were there.** That is
worth more than the confinement on a first pass.

### 22. Where "is this confined?" is answered, and where it is not.

Three wrappers decide whether a program runs confined, so the answer
lived in shell scripts inside packages and nothing on the machine could
be asked. `novi-agent describe` has a `sandbox` section now, in both
the JSON and the table.

**THE ITEM SAID `novi-state` AND THAT IS THE WRONG DOCUMENT.**
novi-state is declared-versus-observed, and *nothing converges a
sandbox*: a wrapper is what a package installed, not a key somebody
set, so `diff` could never report it and `apply` could never fix it.
A row there would be permanently "converged" about something the engine
does not control — the same reason `keys.conf` is not a `system.conf`
key (RFC 0037) and `power.lid` has no converger (RFC 0013). `describe`
is the document that says what this machine *is*, which is the question
being asked. Ninth roadmap item in this repository to be corrected on
contact rather than implemented as written.

**IT READS; IT DOES NOT RUN.** RFC 0029 decision 1 is that describing
is free because it is a formatted view of files any user can already
read, and executing a program to ask about it would quietly end that.

**NO LIST OF PROGRAMS.** A fourth sandboxed package appears because it
is sandboxed, not because somebody remembered — the drift
`keybindings.h` and pkgsplit's derived `depends=` both exist to
prevent. The test is the wrapper's own text: a `/bin/sh` script on PATH
that invokes `novi-sandbox`. Watched live: a fresh boot listed
`novi-view` alone, and `pkg install novi-recon` made the second row
appear with `recon filter, network on`.

**MATCH THE INVOCATION, NOT THE MENTION.** Every wrapper also carries
`command -v novi-sandbox >/dev/null 2>&1 || run …` — its own check that
the sandbox is installed — and that line comes *first*. Reading it
reported novi-recon as having no profile and novi-view as having the
network: two plausible-looking machines, neither real. The host test
caught it; nobody would have caught it by looking.

### 23. The exact answer belongs to the wrapper, and is one variable away.

`describe` reads, so it sees what a wrapper *says*. What a wrapper
*does* includes runtime branches — novi-view resolves the image path,
the xkb symlink target and two optional theme paths before it execs.
`NOVI_SANDBOX_DESCRIBE=1` makes any wrapper print the argv it would
have run and stop, through the same `run()` every exit path goes
through, so it cannot be a second description that drifts:

```
$ NOVI_SANDBOX_DESCRIBE=1 novi-view /root/test.png
novi-sandbox --no-net --ro /usr/lib --ro /lib --ro /usr/libexec
  --ro /usr/share/fonts … --rw /run/user/0
  --ro /usr/share/xkeyboard-config-2 --ro /usr/share/X11
  --ro /root/test.png -- /usr/libexec/novi-view /root/test.png
```

Two mechanisms for two audiences. `packages/tests/test-agent-sandbox.sh`
is where they are held to agreeing about the three things that matter —
whether there is a sandbox, which filter, and whether the network is
there — and it drives **the wrappers this repository actually ships**,
extracted from the build stages that write them, against the real
reader. A test with its own copy of a wrapper would be testing the
copy, which is precisely the thing a test about two things agreeing
must not do.

**Its own negative check could not fail at first.** `plain-tool`, a
script with no mention of novi-sandbox, is rejected twice over — by the
grep and again by the invocation match — so breaking either left the
answer right. A second fixture that *mentions* the sandbox in a comment
and never invokes it is the layer where a wrong answer is a wrong
answer. Same correction RFC 0028's five malformed-input checks needed.

### 24. Landlock, and the one thing the mounts cannot say.

`CONFIG_SECURITY_LANDLOCK=y` and `landlock_restrict_self` after the
pivot. The mount namespace is still the filesystem boundary; this is a
second one the kernel enforces on the process's own request, and it
holds whatever the mount list turned out to be.

**WHAT IT ADDS IS W^X, and that is a thing a bind mount cannot
express.** A `--rw` path is bound writable, so a program can write a
file there and then run it. Landlock grants `EXECUTE` on the read-only
paths and never on the writable ones. Measured on a booted machine —
the same file, the same sandbox, one flag apart:

| bind | read | write | execute |
|---|---|---|---|
| `--rw` | allowed | allowed | **REFUSED — Permission denied** |
| `--ro` | allowed | **REFUSED — Read-only file system** | allowed |

**Two layers, two errnos.** `EACCES` on the exec is Landlock; `EROFS`
on the write is the mount. Neither can state the other's rule, which
is the whole argument for having both. (`MS_NOEXEC` would give the
mounts a W^X of their own and should follow — doing both in one change
would have left a refusal nobody could attribute to a layer.)

**THE ABI IS ASKED FOR, NOT ASSUMED.**
`landlock_create_ruleset(NULL, 0, LANDLOCK_CREATE_RULESET_VERSION)`
answers with the version this kernel speaks, and the handled set is
built up from that number — `REFER` at 2, `TRUNCATE` at 3, `IOCTL_DEV`
at 5. A ruleset naming a right the kernel does not know is EINVAL, so
a hardcoded set would turn one kernel bump into a sandbox that refuses
to start. Same rule as reading `/proc/self/ns`, which is the mistake
this program's first booted run made.

**Absent is not fatal, and never silent.** A kernel without it still
gets the mount namespace, the PID namespace and the filter; one line
on stderr says what is missing.

**Order is forced in both directions.** `PR_SET_NO_NEW_PRIVS` comes
out of `install_filter()` and runs first, because `restrict_self`
requires it for the same reason seccomp does. And **Landlock goes
before seccomp**: after the filter, the landlock syscalls are subject
to it, and an allowlist profile derived from a program that never
calls them — which is every profile here — would answer EPERM to the
sandbox's own last step.

### 25. A directory-only right on a file is EINVAL, not ignored.

`LANDLOCK_ACCESS_FS_READ_DIR`, the `MAKE_*` set, `REMOVE_*` and `REFER`
mean nothing about a regular file, and `landlock_add_rule` **refuses**
rather than dropping them. This sandbox binds plenty of single files —
`/usr/bin/python3`, `/etc/resolv.conf`, the image a viewer was given —
so the first build granted its read-only set uniformly and every
sandboxed program died with `novi-sandbox: landlock_add_rule: Invalid
argument`, which names the call and not the reason. The rights are
masked by `S_ISDIR` now.

### 26. The caller's binds go on last, because they were being buried.

They used to be applied *before* the private `/tmp`, the minimal `/dev`
and `/proc` — so `--rw /tmp/work` was bound and then covered by the
tmpfs mounted on top of it. The mount existed, nothing could reach it,
and the program reported `nonexistent directory` about a path the
caller had named on the command line.

**Third time this repository has buried a mount by ordering** — RFC
0003's `/run/live`, RFC 0018's ESP under `/boot` — and the first where
the thing buried was something somebody asked for. What this program
supplies by default goes down first; what the caller named goes on top.

### 27. A `CONFIG_X=y` line is a claim, and thirty-two of them were false.

Adding one kernel symbol meant checking it survived, and that check
found the rest. `olddefconfig` drops a symbol whose dependencies are
unmet, or that upstream renamed or removed, **silently** — the line
stays in the curated config reading as policy and the kernel is built
without it. `CONFIG_IPC_NS` did exactly that and cost this program its
first booted run (decision 3's note). A sweep for the same shape found
**thirty-two more**:

- **Sixteen upstream has renamed or removed**: `SLAB`, `X86_SMAP`,
  `X86_SMEP`, `PAGE_TABLE_ISOLATION`, `RETPOLINE`, `MNT_NS`,
  `MEMCG_SWAP`, `BPFILTER`, `INTEL_PSTATE`, `EFI_VARS` and six more.
- **Sixteen that exist and cannot be reached from here.** Four of those
  are *select-only* — `PARAVIRT`, `LOCKUP_DETECTOR`, `SND_HWDEP`,
  `SND_RAWMIDI` — which a config file can never set, so stating them
  was meaningless by construction.
- **`CONFIG_SECURITY_SELINUX` is in that second group.** It needs
  `CONFIG_AUDIT`, which this config does not set, so **SELinux has
  never been in this kernel** while the config claimed it for the life
  of the project. There is no SELinux policy on this system either, so
  it could not have done anything — but a security claim that was
  never true is worth naming as one.

`05-kernel.sh` now diffs the curated file against the generated
`.config` and **fails the build** on any `=y` that did not survive.
Derived, with no list to maintain: a hand-written set of symbols to
watch would not have contained `IPC_NS` either.

**The sweep changed nothing about the kernel**, which is the property
that made it safe to do in the same pass: every line removed was one
the build was already ignoring, and the generated `.config` after the
cleanup is byte-identical to the one before it apart from Landlock.
Making a dependency reachable — `AUDIT` for SELinux, `DEBUG_KERNEL`
for the lockup detectors, `HYPERVISOR_GUEST` for paravirt — is a
decision about what this kernel should be, not a typo fix.

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

**The corpus at `tests/hostile-pages/` has now been run under it**, in
both modes on one booted machine — roadmap 1, and the tables are in
that directory's README. The short version is that **the sandbox
changes nothing about the corpus at all**: same eleven survived, same
five spinning, same pages, CPU within a few points, and peak memory
identical to the byte on every page that had stopped growing by the
time it was sampled. That is the honest answer to the question the
item asked, and it is a negative result worth having — the item
guessed that a private `/tmp` and a smaller filesystem might change
what failing costs, and they do not, because what a layout engine
allocates is its own heap and no mount list touches it.

What the attempt did find were three defects, none of them in the
corpus:

- **The harness was measuring the supervisor.** The wrapper's job pid
  is `novi-sandbox`, which forks and waits: 0% CPU and 848 kB of
  address space, on a page burning 98% of a core. Unchanged, `run.sh`
  would have reported the entire corpus as harmless the day the
  sandbox shipped — the strongest possible result, and false. An
  instrument that answers about the wrong process is worse than one
  that refuses to answer, so it resolves the browser now and prints
  `UNMEASURED` when it cannot find it.
- **The signal handling above**, which was found by the harness's own
  `kill` leaving a runaway behind.
- **RFC 0038's force-quit had lost its first stage** for a sandboxed
  window, silently, for the same namespace-init reason. novi-shell
  reads `NSpid:` and skips the stage rather than spending a keypress
  on a signal the kernel will discard.

**RFC 0031 roadmap 5's address-space bound still reaches the browser
through this**, which was checked rather than assumed: the wrapper now
puts a process between `s6-softlimit` and the program, and `RLIMIT_AS`
is inherited across the fork and the exec into the namespace.
`unclosed-tags.html` sandboxed reads 1,048,576 kB at 700 seconds and
holds — the same ceiling, the same plateau.

**THE ALLOWLIST WAS CHECKED FROM THE PACKAGE, not from a hand-copied
binary** — `pkg install novi-recon` on a freshly built image, which is
what puts the wrapper on PATH and the script in `/usr/libexec`. On a
booted machine: inside `--profile recon` the root holds `dev etc lib
proc tmp usr` and nothing else, `/root` and `/etc/shadow` are not
there, `Seccomp: 2` and `NoNewPrivs: 1` sit beside
`CapEff: 000001ffffffffff` — so the refusals are the filter and not a
privilege drop — `threading.Thread` works, and `os.fork()` is refused.
Every subcommand behaves the same as with `NOVI_RECON_SANDBOX=off`:
`dns`, `tls`, `ports` and `all` succeed with the same output, and
`whois`, `headers`, `robots` and `pwned` fail **byte for byte
identically in both modes** — this network blocks port 43 and
intercepts TLS with a CA the guest does not trust. Running both modes
is the only reason that could be told apart from a sandbox that had
broken four subcommands.

One measurement corrected another, too. A single sample taken 13
seconds in showed `many-siblings.html` at 312,948 kB unsandboxed
against 273,928 kB sandboxed, which reads as a 39 MB saving; at 40
seconds both are 516,384 kB. **A sample taken while the number is
still moving is not a comparison.**

**MS_NOEXEC CLOSED THE MOUNT HALF OF W^X**, the follow-up the Landlock
decision named and deliberately did not do in the same change. Every
mount this program makes itself — the root tmpfs, `/tmp`, `/dev`, the
six device binds and `/dev/shm` — carries it now, and so does every
`--rw` bind the caller names. The `--ro` binds do not, which is the
whole point: that is where the program being sandboxed lives.

The evidence is the sandbox's **own `/proc/self/mountinfo`**, not an
errno, and that is forced: with both layers on, a refused exec on a
`--rw` path is EACCES from either of them, so the errno can no longer
say which one answered. Inside, on a booted machine:

```text
/          rw,nosuid,nodev,noexec      /root/wx  (--rw)  rw,nosuid,nodev,noexec
/tmp       rw,nosuid,nodev,noexec      /root/ro  (--ro)  ro,nosuid,nodev
/dev       rw,nosuid,noexec            /bin      (--ro)  ro,nosuid,nodev
/dev/shm   rw,nosuid,nodev,noexec      /usr      (--ro)  ro,nosuid,nodev
```

`/dev` is the one without `nodev`, which is the exception the bind
helper already documents. And the behaviour matches the flags: on the
`--rw` path a write succeeds and the same script is `Permission
denied` (126); on the `--ro` path the script runs and a write is
`Read-only file system`; `/tmp` and `/dev/shm` each take a copy of
busybox and refuse to run it.

**All three real callers still work**, which is the check that matters
because `/dev/shm` is now noexec and both GUI clients allocate buffers
through it: `novi-recon` prints its usage under `--profile recon` and
`NOVI_SANDBOX_DESCRIBE=1` still reports the exact argv; NetSurf renders
the control page in 0.1 s with its link laid out; and `novi-view`
decodes and draws a PNG, window and title bar and all.

## What this is not

**It is not a security boundary against a kernel bug.** Every mechanism
here is the kernel enforcing something on itself. A user namespace in
particular has been the starting point of real privilege escalations;
what it buys is that the browser's own bugs stop at the namespace, not
that the kernel's do.

**It is not an allowlist**, said again because the difference is the
difference between this and a browser sandbox anybody would call
finished.

~~**There is no Landlock.**~~ **This paragraph was true when it was
written and is not now** — roadmap 2 added
`CONFIG_SECURITY_LANDLOCK=y` and `landlock_restrict_self` after the
pivot, so filesystem confinement is the mount namespace *and* a policy
this process asks the kernel to hold over itself. It is left here
struck through rather than deleted because "checked, not assumed" was
the right habit and the answer simply changed; what would be wrong is
a reader finding the old sentence and believing it.

**It does not isolate the browser from itself.** One process still
parses every page; a page that corrupts the layout engine owns the
whole browser, including its other tabs. Per-tab processes are a
different and much larger change.

## Roadmap

1. ~~**The hostile corpus under the sandbox.**~~ **Done** — see *What
   was verified*. Both tables are in `tests/hostile-pages/README.md`.
   They are the same table: the sandbox does not change whether a page
   fails, what it costs in CPU, or what it costs in memory. It changes
   what a page that fails can reach, which this corpus does not
   measure and never could.
2. ~~**Landlock**~~ **Done** — decisions 24 to 27. One kernel symbol,
   as the item said; the W^X it buys is measured, and getting there
   found a directory-only right that is EINVAL on a file, a bind list
   the sandbox was burying under its own defaults, and thirty-two
   kernel symbols this config claimed and never had.

**Every item in this roadmap is now closed.** What is left is named
under *What this is not*, and the largest of it — an allowlist for the
browser, per-tab processes, a boundary against a kernel bug — is not
this RFC's.
3. ~~**An allowlist filter for programs whose syscall set is
   knowable.**~~ **Done** — decisions 14 to 17. 48 syscalls, derived by
   tracing rather than written, diffed against the measurement at build
   time, with `clone` accepted only as a thread. The browser keeps the
   denylist, as the item said it should.
4. ~~**A `--no-net` caller.**~~ **Done** — decisions 18 to 21.
   `novi-view`, which decodes a stranger's PNG through libpng and has
   no business on a socket. Putting it in the sandbox found three
   things the confinement itself was not looking for: a missing
   `/dev/shm`, a symlink a bind does not follow, and an unchecked
   `xkb_context_new()` in six clients.
5. ~~**`novi-state` should be able to say a package runs
   sandboxed.**~~ **Done** — decisions 22 and 23, though not in
   novi-state: nothing converges a sandbox, so the answer belongs in
   `novi-agent describe`, which is the document that says what this
   machine is. Derived from the wrappers, with no list to maintain.

**Only item 2 is left**, and it is a kernel change rather than a
userland one.
