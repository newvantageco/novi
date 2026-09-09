# RFC 0026 — Python, and the https it cannot do

**Status:** Implemented
**Depends on:** RFC 0006 (package repository), RFC 0007 (base/desktop split), RFC 0015 (native toolchain), RFC 0019 (developer tooling), RFC 0020 (HTTPS)

> **Summary.** CPython 3.11.16, cross-compiled against musl and shipped
> as the `python` package. It is the first scripting language this
> operating system has ever had. It has **no `ssl` module**, because
> this project carries no OpenSSL and CPython's TLS is written against
> OpenSSL specifically; https from Python means `curl`, which is
> already a package and already verifies certificates. That gap is the
> most important thing in this document and is stated everywhere a
> person might meet it.

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
nobody asked for. `38-python.sh` checks for `python3.11` up front and
says `apt-get install python3.11` if it is absent, for the same reason
`05-kernel.sh` checks for `depmod` and `06-wayland.sh` checks for
`mako` — an unmet build-host dependency should not surface three
minutes in as an autoconf line nobody can interpret.

### 2. A package, never the base image.

~32 MB installed, 11 MB compressed. RFC 0007 keeps the base image
console-only and small, and a language runtime is exactly what
`pkg install` is for. It stages into `${BUILD_DIR}/stage-devtools`
beside git and the ssh client, so `43-devtools-repo.sh` publishes it
with **no change to that stage at all** — its repo phase already globs
every directory there that carries a `MANIFEST`.

The stage number is 38 because 40+ is packaging and `40-repo.sh` must
see a finished tree. This stage puts nothing in `${ROOTFS}`, but it
*reads* from it — zlib, libffi and expat — so it has to run while those
are still there, i.e. before `41-desktop-split.sh` moves them out.

### 3. There is no `ssl` module, and that is a consequence, not an oversight.

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

So `38-python.sh` parses that paragraph and compares it against the set
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

1. **The `ssl` question**, on its own terms and in its own RFC. Until
   it is answered, "Novi has Python" needs the qualifier attached
   wherever it is said.
2. **ncurses and readline.** A REPL where the up-arrow prints `^[[A` is
   a visibly unfinished interpreter, and `curses` is how a large class
   of terminal tooling draws. Two small autotools builds; the only
   design question is how much of ncurses' 7 MB terminfo database to
   ship (`--with-fallbacks` for `linux`, `xterm-256color` and `foot` is
   probably the whole answer).
3. **sqlite3**, which is what most local-state Python assumes exists.
4. **A way to install Python code.** `pkg` handles Novi's own packages;
   there is no story at all for third-party Python, and pip cannot be
   the answer until item 1 is. Vendoring a program's dependencies into
   a Novi package is the option that needs no https.
