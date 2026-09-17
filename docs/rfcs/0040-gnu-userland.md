# RFC 0040 — the CLI gap: GNU coreutils and bash as packages

**Status:** Implemented and verified on a booted machine (QEMU/TCG; **no physical hardware**)
**Depends on:** RFC 0007 (base vs package), RFC 0026 (readline is already a package), RFC 0005 (`users.<name>.shell`)

> **Summary.** `pkg install coreutils bash` puts the full GNU tools on a
> Novi machine, under `/usr/gnu/bin`, ahead of the BusyBox applets on a
> **login shell's** PATH and nowhere else. The base image is untouched,
> `/bin/sh` is still BusyBox ash, and removing the packages puts
> everything back.

## Motivation & Problem Statement

`docs/PLATFORM-ROADMAP.md` §5 has said this since it was written:

> **Full GNU coreutils/util-linux/bash become an ordinary `pkg install`**
> for any real interactive system (both stable and advanced tracks) —
> same split already implicit in the track model (§3). This closes the
> capability gap noted in §1 without bloating the base image.

It was never built. BusyBox is the right base userland — one static
binary, 598 applet names, boots and installs — and it is a **subset**.
The difference is not exotic; it is a papercut a developer meets several
times a day, and this session hit three of them while doing unrelated
work:

- `pgrep -c` — not an option BusyBox has, so a probe counting processes
  printed a usage message instead of a number.
- `sed -i` with an address range, `find -printf`, `sort -h`, `du
  --apparent-size`, `stat -c` format letters BusyBox does not know.
- no `bash`: no arrays, no `[[ ]]`, no `${var//a/b}` in a login shell,
  no programmable completion. Every `#!/bin/bash` script written
  anywhere else fails on this machine with "not found".

That last one is the reason this is not purely a convenience. A
distribution that cannot run a script somebody wrote on Debian is a
distribution people bounce off.

## Decisions

### 1. `/usr/gnu/bin`, because `pkg` has no file-conflict handling.

This is the decision everything else follows from, and it is a fact
about the code rather than a preference. `pkg install` extracts an
archive over the root filesystem. There is no owner check, no conflict
refusal, no backup — checked, not assumed.

`/bin/ls` is a symlink to `busybox`. A coreutils package shipping
`/usr/bin/ls` would quietly take the name, and **`pkg remove coreutils`
would then delete it**, leaving a machine with no `ls` at all and no
way for pkg to know it had done that. Every one of the ~100 names is
the same story.

So the packages install into a prefix of their own and PATH decides.
That is additive, reversible, and leaves the base image byte for byte
as it was. Teaching `pkg` about file ownership and conflicts is a real
and good change — and it is a change to the trust-critical program that
installs code as root, which is not something to do as a side effect of
adding a shell.

### 2. A login shell is the right scope, and that is what makes prepending safe.

The `coreutils` package ships `/etc/profile.d/gnu.sh`, which puts
`/usr/gnu/bin` **first** on PATH. On most distributions that would be
alarming: it changes which `ls` every script on the machine gets.

Here it does not, because **`/etc/profile` is not what gives a service
its PATH**. s6-linux-init-maker's `-p` sets the initial PATH for every
s6-rc service (`build/04-s6.sh` documents that), the uevent handler and
the boot scripts inherit it, and `/etc/profile` is read by login shells
only. So the person typing at a prompt gets GNU tools and the system
keeps running the applets it was written and tested against.

The drop-in is a package file rather than base content, so it arrives
and leaves with the tools it points at — a PATH entry for a directory
that does not exist is harmless and is also a line somebody has to
wonder about. It is one line and it says how to turn it off: delete the
file.

### 3. `/bin/sh` is never repointed.

Every `#!/bin/sh` script in this system was written against BusyBox ash
and at least one depends on it: `packages/pkg` uses `set -o pipefail`,
which ash has and dash does not, and CLAUDE.md has a section on that
distinction. Repointing `/bin/sh` at bash on a package install would
change the interpreter for the whole system, including things that run
before anything could complain.

A person who wants bash as their login shell already has a declarative
way to say so: `users.<name>.shell = /usr/gnu/bin/bash` (RFC 0005).
That is the existing path, it is in the document that survives a
reinstall, and it needs nothing new.

### 4. bash links the packaged readline, and that fixes the version.

bash bundles a copy of readline and links it statically by default.
This build passes `--with-installed-readline`, so a machine with both
`python` and `bash` has **one** readline: one library, one CVE to
watch, one GPL-3 `COPYING` already travelling in the `readline`
package. That is the same argument `pkg rdeps` makes about having one
implementation of a question.

The cost is a version pairing, and the linker is what said so. **bash
5.3 uses `rl_completion_rewrite_hook` and `rl_full_quoting_desired`,
which arrived in readline 8.3**; this system pins readline 8.2 for
CPython. GNU releases bash X.Y alongside readline (X+3).Y, so the
matched pair is bash **5.2.37** with readline 8.2, and that is what
ships. Bumping readline to 8.3 is the other way to close it — and it is
a change to the package CPython depends on, which is a decision for the
day something needs 8.3 rather than a side effect of adding a shell.

### 5. What is in the package is derived; what must be there is a floor.

The first version of the packaging step named all 103 programs by hand,
and the check fired on its second run: `chcon` and `runcon` are SELinux
tools coreutils does not build without libselinux, which this system
does not have — and whose kernel half was never in this kernel either,
despite the config claiming it for the life of the project (RFC 0039
found that).

A hand-written list drifts from what the build produces, which is
pkgsplit's whole argument. So the package takes whatever was built, and
a short **floor** — the programs whose absence would make the package a
lie — is asserted separately. `stdbuf` is on that floor deliberately:
it is the one that needed a build fix, so it is the one most likely to
go missing again.

### 6. Five programs are deliberately not installed.

`kill`, `uptime`, `hostname`, `stty` and `arch`. BusyBox ships all of
them in the **base**, and this package is additive: shadowing a tool
nobody asked to replace changes the answer for scripts and for muscle
memory without being asked. (`arch` is `uname -m` with a longer name.)
`bashbug` goes too — it mails a report through a `sendmail` this system
does not have, and a command that cannot work is worse than one that is
absent, which is RFC 0026's argument for deleting `idle3`.

## What was verified

**`-shared -pie` for the third and fourth time in this repository, and
gcc still does not warn.** RFC 0026 recorded it on CPython's ~40
extension-module links: given both, gcc drops the `-shared`, links an
executable, and dies on `undefined reference to 'main'` from
`Scrt1.o`. It happened twice more here:

- **bash's loadable builtins.** `make install` recurses into
  `examples/loadables`, which links shared objects, and the top-level
  makefile prefixes that recursion with `-` — so the failure is
  **ignored** and `make install` exits 0 having printed fourteen
  undefined references and `Error 2 (ignored)` in the middle of its
  output. A build that reports success while a subdirectory failed is
  exactly the shape this project keeps getting caught by. Nothing here
  packages the loadables, so the recursion is pointed at a directory
  whose Makefile does nothing.
- **coreutils' `src/libstdbuf.so`**, the preload library `stdbuf`
  needs. That one is not ignored, so the build stopped.

And the coreutils fix needed **two** goes, because the second bug was
hidden behind the first:

1. Filtering `-pie` out of the link got past `undefined reference to
   'main'` and into `relocation R_X86_64_PC32 against symbol 'stderr'
   can not be used when making a shared object; recompile with -fPIC` —
   because automake's compile rule is `$(src_libstdbuf_so_CFLAGS)
   $(CFLAGS)`, so upstream's own `-fPIC` comes first and the hardening
   `-fPIE` after it wins.
2. A target-specific variable fixes exactly that one object.

**And the first attempt at the link fix matched nothing.** automake
writes that rule across two lines with a backslash continuation, so
`$(LDFLAGS)` is on the second one and a line-anchored `sed` could not
see it — the substitution "succeeded" and changed nothing. It is an
appended override now, which does not care how upstream lays the rule
out, and the check is on the **artifact**: a `PT_INTERP` in
`libstdbuf.so` would mean gcc had linked an executable again.

**On a booted machine**, from the live image's own repository:

```text
pkg install coreutils bash    coreutils 9.12, bash 5.2.37
                              bash pulls readline and ncurses
```

- `/usr/gnu/bin/ls --version` says `ls (GNU coreutils) 9.12`, while
  `busybox ls --version` answers `ls: unrecognized option: version` —
  BusyBox has no `--version` on an applet, and its refusal is itself
  the evidence that the two are different programs. `/bin/ls` still
  points at `busybox`. **Both are on the machine and neither has
  replaced the other.**
- A login shell resolves `ls` to `/usr/gnu/bin/ls`; `env -i /bin/sh -c
  'command -v ls'` — a non-login shell with an empty environment, the
  service case — still resolves it to `/bin/ls`. That pair is decision
  2 as an observable.
- `bash --version` reports `5.2.37(1)-release (x86_64-pc-linux-musl)`,
  and an array plus a `[[ ]]` test both work. Its `DT_NEEDED` —
  `libreadline.so.8`, `libhistory.so.8`, `libtinfo.so.6`, `libc.so`
  and nothing else — was read on the build host, because `readelf` is
  in `novi-devel` and a machine that has just installed a shell need
  not have a toolchain.
- `sort -h` orders `2K 1M 3G` and `numfmt --to=iec 1536000` says
  `1.5M`: two things BusyBox cannot do, which is the whole point.
- `pkg remove coreutils` leaves `/bin/ls` pointing at busybox and
  working, and `/usr/gnu/bin/ls` gone. That is decision 1's claim
  tested rather than argued.

**`stdbuf` SHIPPED BROKEN ON THE FIRST BOOT, and the floor that was
meant to catch it checked the wrong half.** `stdbuf` is a launcher: it
sets `LD_PRELOAD` to
`/usr/gnu/libexec/coreutils/libstdbuf.so`. The packaging step swept
`${GNU_PREFIX}/bin` only, so the binary installed, ran, and answered
`stdbuf: failed to find 'libstdbuf.so'`. The floor named `stdbuf`
*precisely because* it was the program most likely to go missing — and
then asserted the presence of the part that was there. **A program is
not always one file.** The package carries `libexec/` now and the
check is on the staged package rather than on the build tree, because
the question is what a machine installing this will have.

## What this is not

**It is not util-linux**, which the roadmap names in the same sentence.
`mount`, `lsblk`, `fdisk` and the rest are a larger port with real musl
friction, and several of them are things this system deliberately does
its own way (`novi-mount`, `novi-gpt`). That is its own RFC.

**It is not `sed`, `grep`, `awk`, `tar` or `gzip`.** Those are separate
GNU packages and separate decisions; BusyBox's versions of all five are
much closer to complete than its coreutils are.

**It does not make Novi a GNU system.** The base is BusyBox and stays
BusyBox: that is what boots, what installs, and what every service
runs. This is a package a person installs when they want the full
tools, which is exactly what §5 asked for.

~~**No documentation is shipped.**~~ **The man pages ship now** (see
roadmap 2): they were built all along, 102 of them and 916 KB, and
thrown away because the only `man` on the machine was busybox's
applet. `--disable-nls` stands — there are no translations.

## Roadmap

1. ~~**`pkg` should know about file conflicts.**~~ **Done**, and it
   found a live case one package deep. `pkg install` now refuses a
   path another package owns, refuses a path nothing owns, and takes
   over an unowned path only when the MANIFEST says `replaces-files=` — in
   which case it **saves the original and `pkg remove` puts it back**.
   `--overwrite` is the operator's escape hatch and is deliberately
   not something a MANIFEST can ask for.

   Measured against this repository before writing a line: **zero
   paths are shared between the 60 packages** (pkgsplit derives them,
   so it could not be otherwise) and **exactly one package overlays
   base content** — `binutils` ships `usr/bin/strings` where the base
   has a symlink to busybox. So `pkg install novi-devel` silently took
   that name and `pkg remove binutils` deleted it outright. binutils
   declares it now, and on a booted machine the record reads `link
   usr/bin/strings ../../bin/busybox`, removal logs `restored
   usr/bin/strings -> ../../bin/busybox`, and `strings` runs again.

   `/usr/gnu` stays a choice rather than a requirement now — but it
   stays, because ~100 declared takeovers with ~100 saved originals is
   a worse answer than a prefix and a PATH entry.

   **The regression check that mattered was the whole repository, not
   the unit tests.** `pkg install novi-devel python netsurf novi-recon
   sqlite openssh coreutils bash` on a booted machine — eight packages
   and everything they depend on — installs with **zero** refusals and
   one line reading `binutils: taking over 1 declared path(s);
   originals saved`. The first attempt at that run did NOT pass, and
   what it found was a pre-existing bug rather than a false positive:
   see RFC 0006's roadmap.
2. ~~**`man`, and the pages these packages already build.**~~ **Done**,
   and the item understated it: the base image has shipped a `man`
   **that could never display a page** for the life of the project.
   busybox's applet shells out to `tbl`, `nroff` and `col`, none of
   which exist here, so `man ls` printed two "not found" lines and
   nothing else — measured with the shipped busybox binary, not
   assumed. A command that cannot work is worse than one that is
   absent, which is RFC 0026's argument for deleting `idle3`.

   `pkg install man` brings **mandoc** (ISC, one self-contained C
   program, ~584 KB, what Alpine and OpenBSD ship) and the coreutils
   and bash packages carry their pages. It is also **the first real
   user of roadmap 1's `replaces-files=`**: mandoc installs
   `/usr/bin/man`, which is busybox's, so it declares the takeover and
   `pkg remove man` puts the applet back. A mechanism built for
   binutils' `strings` that the very next package needed is a
   reasonable sign it was the right shape.

   Cross-compiling it needed every `configure` answer supplied by hand
   — `runtest` compiles a probe and then **executes** it, which a cross
   build cannot, so each answer would have come back "no" and mandoc
   would have built against a libc it invented. `configure.local` is
   upstream's documented override, and every value in it was read out
   of this musl with `nm` and `ls` rather than guessed.
3. **util-linux**, the third name in §5's sentence.
4. **`sed`, `grep`, `awk` and `tar`**, if the difference turns out to
   matter as often as coreutils' did. It should be measured the way
   RFC 0027's collapse was: a number, not an opinion.
