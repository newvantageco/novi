# RFC 0015 — A native toolchain: Novi builds its own software

**Status:** Implemented
**Depends on:** RFC 0006 (package repository), RFC 0007 (base/desktop split)

> **Summary.** Every binary in this distro existed because it had been
> cross-compiled somewhere else. `pkg install novi-devel` now puts gcc,
> binutils, make and the musl headers on the machine, and a booted Novi
> compiles and runs its own C and C++. Verified end to end.

## Motivation & Problem Statement

Fourteen milestones of this project share one unstated property: the
only machine that could add software to Novi was a machine that was not
running Novi. `build/02-toolchain.sh` produces a cross-compiler — it
**runs here** and **produces Novi binaries** — and every package in the
repository came out of it.

That is how a distribution starts. It is not where one can stay, for
two reasons:

- **Nobody can contribute without reproducing this entire build tree.**
  Not "clone and build a package" — clone, build a cross-toolchain,
  build a sysroot, then build a package. That is a wall, and it is the
  reason from-scratch distros tend to have exactly one contributor.
- **Everything downstream is gated on it.** The dev audience needs a
  compiler by definition. The pentest toolkit is mostly Python, Ruby,
  Go and Perl — all of which need to be *built*. A browser needs Rust
  and a large native dependency tree. None of that is reachable while
  the answer to "how do I add software" is "regenerate the world".

## Proposed Design

Four packages plus a meta-package, built by `build/28-native-toolchain.sh`:

| package | size (installed) | what it is |
|---|---|---|
| `musl-dev` | 14 MB | headers, `libc.a`, crt objects |
| `binutils` | 40 MB | `as`, `ld`, `ar` — what gcc shells out to |
| `gcc` | 215 MB | the compiler, C and C++ |
| `make` | 284 KB | BusyBox has no `make` applet |
| `novi-devel` | — | meta-package pulling in all four |

They are packages, never the base image: ~270 MB that a console system
has no use for. Compressed they are 98 MB, which is why the ISO grew
from 329 MB to 423 MB rather than by the full amount — worth carrying,
because until a repository is published (still §2 on the roadmap) the
installation medium is the only mirror that exists.

### Cross-native is a different thing from cross

`02-toolchain.sh` builds `--host=this-machine --target=novi`. This
stage builds `--build=this-machine --host=novi --target=novi`. The
distinction is the entire point and it drives three configure choices:

- **`--with-sysroot=/`** is what gets baked in, because on the machine
  that runs this compiler the root filesystem *is* the sysroot.
  `--with-build-sysroot=${SYSROOT}` points at where those same headers
  live here, so the build can find them without writing this host's
  paths into the shipped compiler.
- **`--disable-bootstrap`.** A bootstrap builds the compiler three
  times to prove it can compile itself, which requires *running* it —
  and these binaries do not run on the build host.
- **`--disable-libsanitizer`**, named rather than quietly dropped: it
  does not build against musl without patches, it is the single largest
  component, and nothing here uses it.

### `musl-dev` is a copy, not a build

Every file in it was produced by `02-toolchain.sh` years of build-steps
ago and simply never copied onto the target, because nothing on the
target could have used them. The *runtime* libc has always been in the
base image; what was missing is everything needed to link something
new — headers, `libc.a`, and `crt1.o`/`crti.o`/`crtn.o`. That last one
is what "compiler cannot create executables" actually means when a
from-scratch toolchain says it.

## Bugs found

- **`gprofng` does not build against musl.** binutils 2.43's profiler
  calls `fopen64`/`fseeko64`/`ftello64`, and musl 1.2.4 removed the
  LFS64 aliases (every `off_t` is already 64-bit there, so the separate
  names had no reason to exist). `--disable-gprofng` rather than a
  patch: this is the same breakage e2fsprogs needed a patch for in
  RFC 0008, and patching a profiler nobody asked for, in order to ship
  it inside a compiler package, is work for its own sake.

- **`depends=` is comma-separated, and `mkpkg`'s own header said it was
  space-separated.** `novi-devel` was written from that comment, built
  without complaint, indexed without complaint, and failed at install
  with `Dependency 'musl-dev binutils gcc make' not found` — naming the
  entire list as one imaginary package. `mkpkg` now rejects a space in
  `depends` (and a comma, pipe or space in `name`) with a clear
  message, on the same argument the index format uses for forbidding
  `|` outright rather than escaping it: make the mistake impossible to
  express instead of merely documenting it.

- **GCC installs its runtime libraries to `/usr/lib64`.** musl's
  dynamic linker searches `/lib:/usr/local/lib:/usr/lib` and nothing
  else, so `libstdc++.so.6` and `libgcc_s.so.1` shipped in a directory
  nothing would ever look in. C compiled and ran perfectly; C++
  compiled, linked, and died at exec with
  `Error loading shared library libstdc++.so.6`. One wrong directory,
  and only the second language noticed.

- **`novi-state health` was crying wolf, and it was mine.** RFC 0014
  shipped a `NOTREADY` rule of "up over 60s and not ready" — but a
  service that does not declare `notification-fd` never reports ready,
  by definition. So every getty, syslog, klog, acpid and hotplug on the
  machine turned `NOTREADY` the moment it had been up for a minute. It
  shipped because RFC 0014's own test read the services at `up-3s` and
  saw them all healthy: **the test was too fast to see the bug.** A
  check written specifically to end warning fatigue would have caused
  it on every machine that stayed switched on. Now gated on the service
  actually declaring readiness.

## Verification

A booted Novi, installing from the signed repository on its own
installation medium, with no network:

```
$ pkg sync
  -> signature on the repository index verified
==> index updated: 30 package(s) available

$ pkg install novi-devel
==> Installing musl-dev (1.2.5) ... binutils (2.43) ... gcc (14.2.0) ... make (4.4.1)

$ gcc --version
gcc (GCC) 14.2.0
$ gcc -dumpmachine
x86_64-linux-musl

$ gcc -O2 -o hello hello.c && ./hello
hello from a novi-built binary

$ g++ -O2 -o hcc h.cc && ./hcc
c++ works

$ make
gcc -O2 -o prog hello.c
hello from a novi-built binary
```

`readelf -d hello` shows a single `NEEDED: libc.so` — a musl binary,
built by Novi, on Novi. `novi-state health` reports every service `ok`
at `up-136s` (past the threshold that produced the false positive) and
`novi-state diff` is clean.

### What this does not yet mean

**Novi cannot yet rebuild itself.** Compiling a C file is not the same
as building this distribution: that still needs a kernel build, and
the autotools stack (`autoconf`, `automake`, `libtool`, `m4`,
`pkg-config`), and `git` to get the source, and Python for
`tools/pkgsplit`. None of those are packaged. The claim here is
narrower and it is the one that matters first: **software can now be
built for Novi on Novi**, which is the prerequisite for all of it.

And, still: none of this has run on physical hardware.

## Roadmap

- **The rest of the build-from-source stack**: autoconf, automake,
  libtool, m4, pkg-config, `git`, and Python. That turns "can compile a
  file" into "can build a package", and it is the shortest path to
  someone other than this project's authors being able to contribute.
- **A `-dev` convention for the existing libraries.** `libinput`,
  `wayland`, `pixman` and the rest ship their runtime `.so` and no
  headers, so nothing can be compiled *against* them yet. That is a
  change to `pkgsplit`, not new builds.
- **`gdb`**, disabled here because it was not needed to prove the
  compiler works.
- **Rebuilding the toolchain with itself**, which is the real
  self-hosting test and needs the point above about a full build stack.
