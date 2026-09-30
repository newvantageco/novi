# RFC 0026 — Python, and the https it cannot do

**Status:** Implemented; decision 3 superseded by RFC 0027
**Depends on:** RFC 0006 (package repository), RFC 0007 (base/desktop split), RFC 0015 (native toolchain), RFC 0019 (developer tooling), RFC 0020 (HTTPS)

> **Summary.** CPython 3.11.16, cross-compiled against musl and shipped
> as the `python` package. It is the first scripting language this
> operating system has ever had.
>
> **As first shipped it had no `ssl` module**, and decision 3 below is
> the argument for why. **RFC 0027 answered that question and Python
> has `ssl` now**: OpenSSL is a package, the base image still carries
> no TLS library, and the package trust root is still static
> TweetNaCl. Decision 3 is kept as written because its reasoning about
> what RFC 0006's rule actually forbids is what RFC 0027 had to get
> right, and because the alternative it rejected — a stub `ssl.py`
> raising a friendlier error — is still the wrong answer.

## Motivation & Problem Statement

There was no scripting language on this system. Not an old one, not a
slow one — **none**. No Python, no Perl, no Ruby, no Lua. Every program
in the image was C or a BusyBox `ash` script, and RFC 0015's honest
summary of a Novi developer box ("you can compile what is already on
the disk") had a second half nobody had written down: anything not
written in C could not be brought here at all, in principle.

That is the same shape of gap RFC 0025 found in front of OpenGL, and it
is a wider one. The overwhelming majority of security, networking,
sysadmin and automation tooling that exists is Python. So is most of
what a person writes for themselves on a machine they control, and this
project's stated audience is people who want more control over their
OS. A distribution with a compiler, a package manager, git, ssh and no
interpreter is missing the thing most people would reach for first.

## Decisions

### 1. CPython 3.11, and the version is a property of the BUILD.

Cross-compiling CPython is not like cross-compiling a C program. The
build **runs Python during `make`**: it freezes the `importlib`
bootstrap, generates C source, runs `setup.py` to decide which
extension modules are buildable, and byte-compiles the entire standard
library. None of that can execute on the target, so `configure` takes
`--with-build-python` and requires an interpreter of the same
**major.minor** — the `.pyc` magic number and the marshal format differ
between minors, so a 3.12 host genuinely cannot build a 3.11 target.

3.11 is what this build host has as `python3`, and what the widest
range of hosts this project asks people to build on have as a distro
package. Choosing a newer minor would mean building a native CPython
first: a second multi-minute build, for a language version difference
nobody asked for. `43-python.sh` checks for `python3.11` up front and
says `apt-get install python3.11` if it is absent, for the same reason
`05-kernel.sh` checks for `depmod` and `06-wayland.sh` checks for
`mako` — an unmet build-host dependency should not surface three
minutes in as an autoconf line nobody can interpret.

### 2. A package, never the base image.

~32 MB installed, 11 MB compressed. RFC 0007 keeps the base image
console-only and small, and a language runtime is exactly what
`pkg install` is for. It stages into `${BUILD_DIR}/stage-devtools`
beside git and the ssh client, so `53-devtools-repo.sh` publishes it
with **no change to that stage at all** — its repo phase already globs
every directory there that carries a `MANIFEST`.

The stage number is 38 because 50+ is packaging and `50-repo.sh` must
see a finished tree. This stage puts nothing in `${ROOTFS}`, but it
*reads* from it — zlib, libffi and expat — so it has to run while those
are still there, i.e. before `51-desktop-split.sh` moves them out.

### 3. There is no `ssl` module, and that is a consequence, not an oversight.

> **Superseded by RFC 0027.** What follows was true as shipped and is
> no longer. The `python` package depends on `openssl` now, `import
> ssl` works, and the default trust store loads the same 143
> certificates curl uses. Read on for why it was not simply done in
> the first place — the answer is the distinction RFC 0027 turns on.

CPython's `_ssl` and `_hashlib` are written against OpenSSL
specifically. This project has refused to carry OpenSSL since RFC 0006:
`novi-verify` exists, all ~10 KB of it, so that checking a package
signature does not mean linking libcrypto. RFC 0020 chose **mbedTLS**
for curl; RFC 0021 chose **wolfSSL** for wpa_supplicant. CPython has a
backend for neither, and writing one is not a package build.

So, concretely, on this system:

```
>>> import ssl
ModuleNotFoundError: No module named 'ssl'
>>> urllib.request.urlopen("https://example.com")   # fails
```

Three things soften it, and one does not:

- **`hashlib` works.** md5, sha1, sha2, sha3 and blake2 are ordinary
  built-in C modules in CPython and owe OpenSSL nothing. What is lost
  is the `_hashlib` accelerator and `pbkdf2_hmac`/`scrypt`.
- **`http.client` and plain `socket` work.** Only the TLS layer is
  absent.
- **`curl` is a package, links mbedTLS, and validates against the
  hash-pinned Mozilla bundle** (RFC 0020). Shelling out to it is the
  supported way to fetch an https URL from Python here, and it was
  verified from the interpreter on a booted machine.
- **What is not softened: a Python program that does `import ssl` at
  the top will not start.** Most networked Python does. That is the
  real cost and it is why this is decision 3 rather than a footnote.

Not shipping a stub `ssl.py` that raises a friendlier error was
deliberate. It would read better once and lie permanently:
`importlib.util.find_spec("ssl")` would start returning a spec, so
every piece of feature-detection code that asks properly would get the
wrong answer. A missing module should be missing.

The way to close this is an RFC of its own, and it has two candidate
answers — add OpenSSL as a package (reversing nothing in the base
image, since RFC 0006's rule is about the *trust path*, not about what
a package may contain), or write an mbedTLS-backed `_ssl`. The first is
ordinary and large; the second is novel and small. Neither should be
smuggled in behind a Python package, which is precisely the argument
RFC 0019 made for keeping git's TLS out of the git package until
RFC 0020 decided it on purpose.

### 4. `--enable-shared`, and `-pie` in the one variable that can carry it.

The interpreter is a PIE. Getting there is worth recording, because
every obvious way is wrong.

`harden_flags()` cannot be used: it exports `-fPIE` and `-pie`, and
CPython builds ~40 extension modules as **shared objects** from the
same flags. And there is no LDFLAGS-shaped variable that reaches the
executable link without also reaching the shared ones — read
`Makefile.pre.in`: `LDSHARED` and `BLDSHARED` both append
`$(PY_CORE_LDFLAGS)`, which is `CONFIGURE_LDFLAGS` *plus*
`LDFLAGS_NODIST`. So `-pie` in any of them lands on a `-shared` link,
and **gcc given `-shared -pie` does not warn**: it drops the `-shared`,
tries to link an executable, and fails with `undefined reference to
'main'` out of `Scrt1.o`. Verified with this toolchain rather than
assumed.

`LINKFORSHARED` is the one variable used only on the two executable
links (`python` and `_testembed`), so that is where `-pie` goes — with
its configure-chosen `-Xlinker -export-dynamic` carried through, not
replaced, since dropping that leaves C extensions unable to resolve
symbols back into the interpreter.

`--enable-shared` for the ordinary reason: `libpython3.11.so.1.0` lands
in `/usr/lib`, which musl's loader does search (RFC 0015's `lib64` trap
does not apply), and the interpreter becomes a 16 KB PIE in front of
it.

### 5. The build says which modules it could not build — and which of those were expected.

CPython does not fail a build over a module it could not build. It
prints a paragraph and carries on, which is correct for a language that
runs on everything and is **exactly the failure shape this repository
keeps getting caught by**: the build succeeds, the artifact is missing
something, and nothing says so at a moment anyone is reading. `import
ssl` failing is a five-line fix at build time and an afternoon at use
time.

So `43-python.sh` parses that paragraph and compares it against the set
this build *expects* to be missing, printing anything else loudly. Not
a hard failure — CPython's module list shifts between point releases,
and a build that stops because `_dbm` moved would be worse than one
that says so.

Its first version reported twelve words of English as missing modules:
the block ends with the sentence *"To find the necessary bits, look in
setup.py…"*, not with a blank line, so a `sed` range to `/^$/` swallowed
it. The range ends on the sentence now. A checker that cries wolf is a
checker people stop reading, which is the same argument as `/init`'s
twenty-two meaningless `Could not load module` warnings.

## What was verified

On a booted image, from the live medium's own signed repository, not
compiled and assumed:

- `pkg install python` resolves and installs `zlib`, `libffi`, `expat`
  and then `python`, each with its sha256 checked against the signed
  index.
- `python3 -VV` → `Python 3.11.16 (main, …) [GCC 14.2.0]`,
  `sys.prefix == '/usr'`.
- **61 of 67** standard-library modules import. The six that do not are
  exactly the six this build expects: `ssl`, `sqlite3`, `bz2`, `lzma`,
  `readline`, `curses`.
- Functionally, not just importably: `hashlib.sha256` and
  `hashlib.blake2b` produce digests; `ctypes.CDLL('libc.so').getpid()`
  agrees with `os.getpid()`; a zlib round-trip of 1000 bytes; `pty.fork()`
  + `execv` returns `pty-works` (so `/dev/ptmx` and `/dev/pts` are
  really there — `ac_cv_file__dev_ptmx=yes` was an assertion until this);
  `subprocess` runs a child.
- The documented https path, from the interpreter:
  `subprocess.run(['curl','--version'])` →
  `curl 8.11.1 (x86_64-pc-linux-musl) libcurl/8.11.1 mbedTLS/3.6.2 zlib/1.3.1`.
- `readelf -h` on the installed interpreter: `DYN (Position-Independent
  Executable file)`, `NEEDED libpython3.11.so.1.0`, `libc.so`.
- Extension modules name the right sonames: `zlib` → `libz.so.1`,
  `_ctypes` → `libffi.so.8`, `pyexpat` → `libexpat.so.1`. `pkgsplit`
  is not involved (this never enters the rootfs), so the `depends=`
  line is hand-written and was checked against these.

**A test-harness bug, recorded because it cost the most time here.**
`pkg sync` failed on the first boot with `could not fetch the index
from /run/live/novi-repo`, and `/run/live` did not exist while
`/proc/mounts` said `/dev/vda` was mounted there — which is precisely
the buried-mount signature RFC 0003 documents and fixes. Half an hour
went into reasoning about mount IDs and `s6-linux-init`'s `-N` flag
before the actual cause: the QEMU launcher pointed at a **five-day-old
`/build/initramfs.cpio.gz`**, not the one just built into the repo's
`build/`. The old image really did have the bug; the shipped one does
not. `/run/live` and `pkg sync` work on the current initramfs. The
lesson is the one CLAUDE.md already carries in another accent — when a
test reports a bug the code says was fixed, check that the test is
running the artifact you think it is.

## Consequences

- **~32 MB installed**, 11 MB compressed, one package, `depends=zlib,libffi,expat`.
- **`sys.implementation._multiarch` says `x86_64-linux-gnu`** on a musl
  system, so extension modules are named
  `*.cpython-311-x86_64-linux-gnu.so`. Cosmetically wrong and
  functionally harmless: the interpreter computes the same suffix it
  built with, so imports agree. It would matter for a wheel built
  elsewhere, and there is no pip, so nothing is built elsewhere. Alpine
  gets `x86_64-linux-musl` here; matching that is a one-line
  `config.site` change worth making the day binary wheels become
  possible, and a gratuitous package rename before then.
- **No pip, deliberately**, and not only because `--without-ensurepip`
  is easier: pip fetches over https, which this Python does not have.
  Shipping it would ship a tool that cannot do its one job.
- **`sqlite3`, `bz2`, `lzma`, `curses` and `readline` are absent
  because their libraries are absent**, not by decision. Each is a
  small autotools build away; see the roadmap.
- **`_uuid` is absent and `uuid` works** — the module falls back to its
  pure-Python implementation. Worth knowing before someone "fixes" it.
- **`idle` and `tkinter` are removed from the staged tree, not merely
  unbuilt.** `make install` writes an `idle3` launcher whether or not
  tkinter exists. A command that cannot start is worse than a command
  that is not there.
- **`python`, unversioned, is not shipped** — only `python3` and
  `python3.11`. `python` meaning python3 is a convention some
  distributions adopted and others refused; a script whose shebang says
  `python` should say what it means.

## Roadmap

1. ~~**The `ssl` question**, on its own terms and in its own RFC.~~
   **Done: RFC 0027.** OpenSSL as a package, CPython rebuilt against
   it, and the verification triple run from the interpreter against a
   local TLS server.
2. ~~**ncurses and readline.**~~ **Done** — `build/40-ncurses.sh`, and
   `pkg install python` brings both.

   **It was three problems, and the third was invisible.** The item
   above names two of them and guessed right about the design
   question; what it missed is that **nothing set `TERM`**. Measured
   on a booted machine before any of this was built: `echo $TERM` on
   the console printed nothing at all, and had for the life of the
   project. The gettys pass a TERMTYPE argument now
   (`getty 38400 tty1 linux`, `getty 115200 ttyS0 vt100`), which is
   base content and nothing to do with the package.

   **What an empty TERM costs was written into four documents before
   it was measured, and it was wrong.** The claim was that the REPL
   would still print `^[[A`. It does not — readline's arrow keys are
   *compiled-in* bindings rather than terminfo-derived, so history
   recall survives an empty TERM. Checked both ways on a booted
   machine, which is the only reason it was caught. What does not
   survive is `curses`: `setupterm()` fails outright with *"could not
   find terminfo database"*, so half of what this item is for cannot
   work at all, and readline gets no cursor capabilities either
   (`tigetstr("cuu1")` returns nothing) — which costs redisplay on a
   resize and multi-line editing, not basic recall. Right in
   direction, wrong in mechanism; and a mechanism stated confidently
   is what somebody later reasons from.

   **The database is not shipped, and what that costs is exact.**
   `--with-fallbacks` compiles a named set into the library and
   `--disable-db-install` keeps the other ~7 MB out. A TERM with no
   fallback then gets **nothing** — ncurses fails to initialise rather
   than degrading — so the list is the terminals this system produces
   plus the ones a person arriving over ssh announces: `linux`,
   `foot`, `xterm-256color`, `screen-256color`, `tmux-256color`,
   `vt100`, `dumb`. The two halves are coupled: changing a getty's
   TERMTYPE without changing that list gives a terminal description
   that cannot be found.

   **foot's entry is derived, not copied.** This build host has no
   `foot` terminfo (`infocmp foot` fails), so the fallback generator
   would have produced nothing for the one terminal this desktop
   ships. foot's own source carries `foot.info` as a meson template;
   the stage substitutes it, compiles it into a private database and
   points the generator at that.

   **readline is GPL-3.0-or-later where CPython's licence is
   permissive.** It ships as its own shared library, unmodified from
   the pinned tarball, with its `COPYING` in the package, and
   CPython's `readline` module links it dynamically — what every
   distribution does. The obligation is the one RFC 0031 learned about
   the OFL fonts: the licence travels with the thing. libedit (BSD)
   was the alternative and was rejected: its readline emulation is
   incomplete in ways that produce a REPL which *almost* works, which
   is the failure this item exists to end.

   **A new stage had to precede an existing one, and the free range is
   at the end.** CPython detects both at configure time, so this had
   to run before the Python stage; 01–39 were taken and 40–49 sits
   after it. That is a gap in the numbering rule rather than a
   violation of it — the rule protects the 49/50 boundary between
   content and packaging and says nothing about ordering *within*
   content. python moved 38 → 41, novi-recon 39 → 42, ncurses took 40.
   (Both moved again for sqlite — 41 → 43 and 42 → 44 — and the
   vacated 38 and 39 are free, which is the thing to check before
   assuming the free range is still only at the end.)

   **Four things in the first draft were assumed rather than read, and
   each built cleanly.** `libtinfow.so*`, a `libform w.so*` with a
   space in it, `ncursesw/curses.h` (this build puts `curses.h` at the
   top of the include directory), and two `ln -sf` lines "fixing up"
   unsuffixed names — one of which replaced a correct `libtinfo.so`
   with a dangling link, so readline failed on `cannot find -ltinfow`,
   a library the stage had invented. Names are read out of ncurses'
   own `tinfo.pc` now and headers are found rather than named. Two
   checks were wrong in the same way: the package step counted files
   and passed with **three of five patterns matching nothing** (so
   `ncurses` shipped without the terminal library `libreadline.so`
   NEEDs), and the fallback check read the generator's *intent* — the
   `fallback entries for:` comment, written straight from its argument
   list — rather than the `<name>_alias_data[]` lines only a real
   entry produces.
3. ~~**sqlite3**, which is what most local-state Python assumes
   exists.~~ **Done** — `build/41-sqlite.sh`, and `pkg install python`
   brings it. SQLite 3.53.4 from the amalgamation: the whole library
   as one translation unit, wrapped by upstream's "autoconf" bundle
   (autosetup, not GNU autoconf despite the name), which is why a
   database engine costs one stage and 1.4 MB installed.

   **The stage is bracketed from both sides, and that is why it is
   41.** CPython probes for `sqlite3.h` at configure time and builds
   `_sqlite3` or does not, so it must precede the Python stage — the
   readline trap from item 2, wearing the same clothes. And the CLI
   links the readline built at 40, so it cannot precede that. python
   moved 41 → 43 and novi-recon 42 → 44, the second time those two
   have shifted for a build input of Python's. **38 and 39 are free**
   — vacated by item 2's renumber, which nobody noticed, because a
   vacated number does not announce itself. They are no use here.

   **SQLite'S SHARED LIBRARY HAS NO SONAME BY DEFAULT.** Upstream's
   autosetup says so in as many words: "this project has no direct use
   for soname, so default to none". What that costs a distribution is
   that every consumer records the FILENAME it linked against — here
   `libsqlite3.so`, the development symlink — so the runtime package
   would have had to ship a dev symlink for anything to start, and an
   ABI bump would be invisible to the loader. `--soname=legacy` gives
   `libsqlite3.so.0`, which is what `_sqlite3.so` now records.
   Verified on the artifact and confirmed by deleting the flag and
   watching the check fire.

   **The CLI's readline can silently not happen**, which is item 2's
   whole argument arriving through a different door: configure reports
   what it found and carries on, so the shell builds and installs with
   no line editing. The stage asks the binary rather than the log. And
   the flags name the CROSS-BUILT readline explicitly, because
   autosetup's probe searches the build host's paths and a cross build
   that finds them links a library that cannot load on the target.

   **Public domain, and the binary is not.** SQLite has no licence
   text to travel with it; the CLI links GPL-3 readline, so `sqlite3`
   as a binary is a combined work under those terms. `depends=readline`
   puts readline's `COPYING` on the machine, so RFC 0031's rule is
   satisfied through the dependency rather than by a second copy.

   **FTS5, JSON, R*Tree and math functions are on; ICU is not.** The
   first four are what a Python program written elsewhere expects to
   find, and discovering `json_extract` is missing happens at runtime,
   in a query, on somebody else's machine. ICU is ~30 MB this system
   does not have, for collations most programs never ask for.

   Verified on a booted machine: the CLI creating a table, an FTS5
   match, `json_extract`, an R*Tree query and `sqrt`; `sqlite3` module
   2.6.0 against library 3.53.4 from Python doing the same; and **the
   up-arrow recalling the previous statement** in the interactive
   shell over a vt100 serial console.
4. ~~**A way to install Python code.**~~ **pip works, and it already
   shipped.** This item said "pip cannot be the answer until item 1
   is", and item 1 — `ssl`, via RFC 0027 — was done four items ago.
   Nobody went back and re-read this one. **Sixth roadmap item in this
   repository found to be wrong about what is already available**, and
   the second whose stated blocker had been removed by a later item in
   the same RFC.

   **The wheels were on the machine the whole time.** `--with-ensurepip
   =no` decides whether pip is *installed*, not whether it is
   *present*: `ensurepip` is part of the standard library and its
   bundled wheels ship with it — pip 24.0 and setuptools 79.0.1, 3.3 MB
   of the package. `python3 -m ensurepip --default-pip` installs pip on
   the target, offline, in one command, and did.

   **Then it fetched from PyPI and installed `six` 1.17.0.** Over
   HTTPS, verified, from the shipped image.

   **`--with-ensurepip=no` STAYS, with a different reason.** The old
   comment ("pip fetches over https, which this build has none of") is
   dead and has been corrected in place. The reason to keep the flag is
   that pip writes into `/usr/lib/python3.11/site-packages`, a
   directory the `python` package owns — so installing it by default
   puts a second package manager into `pkg`'s territory on every
   machine that installs an interpreter. One command is the right
   amount of friction for that decision.

   **pip does not use the system trust store, and that is a real
   defect on a distribution.** It verifies against a vendored copy of
   certifi's bundle, so on a machine whose operator has added a CA,
   `pip install` fails with a certificate error while
   `urllib.request.urlopen()` succeeds against the same host — measured
   here, on a machine where Python's own `ssl` was perfectly happy, and
   the same two-stores-disagreeing shape RFC 0027 found in reverse.
   `/etc/pip.conf` now points it at `/etc/ssl/certs/ca-certificates.crt`.
   pip reads `~/.config/pip/pip.conf` after it, so a person can still
   override it without editing a file a package upgrade replaces.

   **AND A CROSS-COMPILED CPython GETS ITS OWN PLATFORM TRIPLET
   WRONG.** This is the finding, and nothing short of installing a
   binary wheel would have surfaced it. CPython computes
   `PLATFORM_TRIPLET` by preprocessing `#if defined(__GLIBC__)` tests
   — which say `x86_64-linux-gnu` on any Linux — and then corrects it
   for musl with `case "$build_os" in linux-musl*)`. **`build_os` is
   the build machine.** A native musl build is corrected; a cross build
   to musl is not, so the triplet stays `x86_64-linux-gnu` on a libc
   that is nothing of the kind. It should read `host_os`.

   That is not cosmetic, and **this RFC previously recorded that it
   was** — "functionally harmless... it matters only when binary wheels
   become possible, and there is no pip". Binary wheels became
   possible. `PLATFORM_TRIPLET` becomes `SOABI` becomes `EXT_SUFFIX`,
   which is the only extension-module filename the import system will
   look for. Watched live before the fix: `pip install MarkupSafe`
   selected the correct wheel
   (`markupsafe-3.0.3-cp311-cp311-musllinux_1_2_x86_64.whl`),
   installed the correct `_speedups.cpython-311-x86_64-linux-musl.so`,
   and **`import markupsafe._speedups` then failed** — an interpreter
   whose `EXT_SUFFIX` says `-linux-gnu.so` cannot see that file — so
   the package fell back to its pure-Python path with nothing said. A
   package with no fallback fails with `ImportError` instead, having
   installed successfully.

   After the fix, on a rebuilt image: `EXT_SUFFIX` is
   `.cpython-311-x86_64-linux-musl.so`, the same wheel's module
   imports, and `markupsafe._escape_inner` is a
   `builtin_function_or_method` from `markupsafe._speedups` — the C
   implementation, in use. **The first probe for that was the broken
   thing, for the umpteenth time here**: `type(escape).__name__`
   reports `function` on a correct installation too, because
   MarkupSafe 3.x's `escape` is a Python wrapper around the C
   `_escape_inner`. Ask the layer where a wrong answer is a wrong
   answer.

   `pip`'s own tag detection was right all along and is worth saying so
   plainly: it reports `cp311-cp311-musllinux_1_2_x86_64` and never a
   manylinux tag, so it will not select a glibc wheel. The fix is one
   word in `configure` and `configure.ac`, with the stage asserting the
   RESULT — configure's own printed triplet — rather than the sed's
   exit status.

   **`python3 -m venv` works, and it is the answer to the
   site-packages question.** Measured rather than assumed, which is the
   lesson of this whole item: `python3 -m venv /tmp/v` builds an
   environment with pip 24.0 inside it, `pip install six` lands in the
   venv, and the venv's interpreter imports it. The global
   `/etc/pip.conf` applies there too — the install succeeded against
   this machine's own trust store with no `--cert`. So the answer to
   "pip writes into a directory `pkg` owns" is the ordinary one, and it
   is available out of the box.

   **What still needs a compiler** is any package with no musllinux
   wheel: pip falls back to the sdist, which needs `novi-devel` (RFC
   0015) and the Python headers, both of which exist. Untested, and
   said so.
5. ~~**A package with no musllinux wheel, built from its sdist.**~~
   **Done — and it could not have worked, for a reason that was
   sitting in the shipped package the whole time.**

   `_sysconfigdata_*.py` is how an interpreter remembers how it was
   built, and `setuptools` reads it to decide how to compile a C
   extension. A CROSS build remembers the CROSS toolchain. The shipped
   `python` package recorded **`CC = 'x86_64-linux-musl-gcc'`** — a
   program that exists on no Novi machine — and
   **`LDSHARED = '... -L/build/rootfs/usr/lib'`**, a directory on the
   machine that built it. **207 lines of that file, and the whole of
   `config-3.11-*/Makefile` beside it, named this build host.**

   So every `pip install` of anything without a musllinux wheel would
   have died on `x86_64-linux-musl-gcc: not found`. And the mode where
   it did *not* die is the worse one: a machine that happened to have
   a `/build/rootfs` would have been handed that tree to link against.

   **Found by reading the artifact, not by running it** — which is the
   only reason it was fixed before anyone met it, and the same move
   that found RFC 0027's missing `/etc/ssl/cert.pem`. `43-python.sh`
   rewrites both files: the tools to their native names, every private
   build prefix onto the target's own `/usr`, and the CPython source
   directory onto the config directory the package actually installs.
   The stale `__pycache__` copy is regenerated, because a cached copy
   of the file just edited is the original bug wearing a different
   name.

   **The first version of that rewrite could not fire on `c++`.** `\b`
   is a word boundary and `+` is not a word character, so
   `c++\b` requires a word character after the second plus and never
   matches at the end of `x86_64-linux-musl-c++`. `CXX` went on naming
   the cross compiler, silently, past a check that asked only about
   `gcc`. Two lists now, and the assertion names every tool — provoked
   by putting the cross name back and watching it fire.

   **Verified on a booted machine.** `sysconfig.get_config_var('CC')`
   is `gcc`, `CXX` is `c++`, `LDSHARED` points only at `/usr/lib`; and
   then the whole path end to end: `pip install --no-binary :all:
   MarkupSafe` downloaded `markupsafe-3.0.3.tar.gz`, built a wheel
   through `pyproject.toml`, installed
   `_speedups.cpython-311-x86_64-linux-musl.so` **compiled by the
   machine's own gcc**, and `markupsafe._escape_inner` is a
   `builtin_function_or_method` from `markupsafe._speedups`. Novi
   compiles C extensions for its own interpreter.

   Two things deliberately not done. A locally built wheel is tagged
   `linux_x86_64` rather than `musllinux`, which is what every
   distribution's local build produces and is only interesting if
   somebody starts sharing them. And the five extension modules that
   carry `/build/python-build/...` inside them do so as `__FILE__`
   strings in assertions — cosmetic, a reproducible-builds concern
   rather than a functional one, and `-ffile-prefix-map` on every
   object is a bigger change than the finding deserves.
6. **A build backend that wants the network, and one that wants
   Rust.** `MarkupSafe` is setuptools and C. The packages people
   actually hit are `cryptography` (Rust, no toolchain here),
   `numpy` (meson-python and a BLAS hunt) and `lxml` (libxml2 and
   libxslt, neither packaged). Each is a different wall and none of
   them is this interpreter's fault; what is worth knowing is which
   wall comes first.
