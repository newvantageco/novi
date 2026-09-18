# Package Format Specification

## File Extension

```
<name>-<version>-<arch>.pkg.tar.gz
```

Examples:
```
curl-8.9.1-x86_64.pkg.tar.gz
musl-1.2.5-x86_64.pkg.tar.gz
mesa-24.2.0-x86_64.pkg.tar.gz
```

---

## Package Structure (inside the tarball)

```
MANIFEST               ← metadata (required)
files/                 ← package contents (required)
  usr/
    bin/curl
    lib/libcurl.so.4
    share/man/man1/curl.1
scripts/               ← lifecycle hooks (optional)
  pre-install
  post-install
  pre-remove
  post-remove
```

---

## MANIFEST Format

Plain `key=value`, one per line. Blank lines and `#` comments allowed.

### Required Fields

| Field | Description | Example |
|---|---|---|
| `name` | Package name, lowercase, no spaces | `curl` |
| `version` | Package version | `8.9.1` |
| `arch` | Target architecture | `x86_64` |
| `description` | One-line description | `Command-line HTTP client` |

### Optional Fields

| Field | Description | Example |
|---|---|---|
| `depends` | **Comma**-separated list of package names | `musl,zlib,openssl` |
| `replaces-files` | Space-separated root-relative paths this package knowingly takes over from no other package | `usr/bin/strings` |
| `provides` | Virtual packages this satisfies — **not implemented** | `libcurl` |
| `conflicts` | Packages that must not be installed — **not implemented** | `curl-legacy` |
| `replaces` | Packages this supersedes on upgrade — **not implemented** | `curl-old` |
| `size` | Installed size in KB (auto-set by mkpkg) | `1024` |
| `url` | Upstream homepage | `https://curl.se` |
| `license` | SPDX license identifier | `MIT` |
| `maintainer` | Package maintainer | `Your Name` |

**`depends` is COMMA-separated, and this table said "space" for a long
time.** `pkg` splits it with `tr ',' '\n'` and `mkpkg` now refuses a
space outright. A package written from the old row built fine, indexed
fine, and failed at install naming the whole list as one imaginary
package — so the row is corrected here rather than left as the second
place somebody could read it wrong.

**Three of these fields are documented and not implemented**, and the
table says so now. That matters for more than tidiness: `replaces` is
the conventional dpkg name for *superseding a package*, and the field
RFC 0040 roadmap 1 needed is about *paths*. Rather than take a
well-known name for a different idea, the new one says what it is
about — `replaces-files`.

**What `replaces-files` means.** `pkg install` refuses to write a path
that another package owns, and refuses a path that no package owns
(base content, or a file a person made). A package that must take over
an unowned path names it here; pkg then **saves what was there** and
`pkg remove` puts it back. Exactly one package in this repository
needs it: `binutils` ships `usr/bin/strings` where the base image has
a symlink to busybox. Paths are root-relative with no leading `/` or
`./` — `mkpkg` refuses the other spellings, because a declaration that
matches nothing reads correct and permits nothing.

### Example MANIFEST

```
name=curl
version=8.9.1
arch=x86_64
description=Command-line HTTP client and library
depends=musl zlib openssl ca-certificates
provides=libcurl
url=https://curl.se
license=MIT curl
maintainer=build@platform
size=1842
```

---

## Lifecycle Scripts

Scripts in `scripts/` are plain POSIX shell, run **as root**, and receive
two arguments: **`$1` the package name and `$2` its version.**

> This table said "one argument: the package version" for the life of the
> file, and was wrong about all four scripts — in the worst direction, since
> a script written from it treats `$1` as a version and is handed a name.
> The install pair had always been passed both; the remove pair had been
> passed only the name. They agree now. Nothing shipped a script yet, which
> is why the interface could still be corrected rather than documented.

| Script | When it runs | A failure | Common uses |
|---|---|---|---|
| `pre-install` | Before any file is extracted | **Aborts the install** | Refuse an unsupported machine |
| `post-install` | After files are extracted | Warns, install stands | Build an index from what was installed |
| `pre-remove` | Before files are deleted | Warns, removal proceeds | Stop something still using them |
| `post-remove` | After files are deleted | Warns, removal stands | Discard a cache the files fed |

**Only `pre-install` is fatal, and that asymmetry is deliberate.** It runs
before anything has moved, so refusing leaves the machine exactly as it was.
The other three run once files are already on or off the disk, where aborting
would leave a half-installed package — worse than either outcome it is
choosing between.

**A script runs as root, unattended, and `packages.<name>` means that can
happen at BOOT**, with nobody there to read what it printed. Prefer shipping
a file to running code: reach for a script only when the thing needed cannot
be expressed as a file, and keep it idempotent, because an upgrade runs it
again.

### Example post-install

```sh
#!/bin/sh
# $1 = package name, $2 = version
# Index the manual pages this package just installed, but only if a
# formatter is actually on the machine -- `man` is its own package here.
command -v makewhatis >/dev/null || exit 0
makewhatis /usr/gnu/share/man 2>/dev/null || true
```

The example this file carried before called `ldconfig` and
`gtk-update-icon-cache`. **Neither exists on Novi** — musl's dynamic linker
has no cache and so musl ships no `ldconfig` at all, and there is no GTK — so
the one worked example in the format specification told a package author to
run two commands that do nothing here.

---

## GUI Application Registration

`novi-launcher` (RFC 0001 decision 7's Alt+Space overlay) needs a way to
discover launchable GUI apps by name. There's no special `pkg`/`mkpkg`
mechanism for this — a package that provides a launchable app just
installs one more file under `files/`, the same way it installs anything
else. `pkg install`/`pkg remove` need no changes: the descriptor is
extracted and removed automatically along with the rest of the package's
`files/` tree.

A launchable app registers itself by shipping a file at
`usr/share/novi/apps/<name>.app` (packages contribute here the same way
they'd contribute `usr/bin/<name>`). Format is plain `key=value`, one per
line, same style as `MANIFEST`:

| Field | Required | Description | Example |
|---|---|---|---|
| `name` | yes | Display name shown in launcher results | `Terminal` |
| `exec` | yes | Command to run, whitespace-split argv (no shell — no quoting, globbing, or `$VAR` expansion; a path with spaces isn't representable in v1) | `/usr/bin/foot` |
| `icon` | no | One of `shared/icons/icons.h`'s app-grid icon names (`terminal`, `folder`, `globe`, `pencil`, `package`, `settings`, `shield`, `keyboard`, `image`) — a closed, fixed set, not an arbitrary path, matching `docs/design/ICON-PIPELINE.md`'s "the icon set is small, fixed, and known entirely at build time" reasoning. Unrecognized or absent means no icon is shown next to this result, not a broken/missing-icon placeholder. | `terminal` |
| `description` | no | Not yet shown anywhere; reserved for a future results view | `foot terminal emulator` |

### Example: `usr/share/novi/apps/foot.app`

```
name=Terminal
exec=/usr/bin/foot
icon=terminal
description=foot terminal emulator
```

`novi-launcher` scans `/usr/share/novi/apps/*.app` at startup, matches
typed input against each entry's `name` (case-insensitive substring), and
`execvp()`s the first match's `exec=` command on Enter. `foot` itself is
the first entry — it isn't `pkg`-installed (it's baked into the base
rootfs by `build/09-foot.sh`), so its `.app` file is written directly by
that build script rather than shipped in a `.pkg.tar.gz`, but the file
format and the directory `novi-launcher` scans are exactly what a real
package would use, so packaged apps need no special-casing once `pkg`
starts installing GUI apps for real.

---

## Package Database

Installed packages are recorded in `/var/lib/pkg/installed/`.  
One file per package, named `<name>`, containing the MANIFEST.

```
/var/lib/pkg/
  installed/
    curl          ← MANIFEST of installed curl
    musl          ← MANIFEST of installed musl
    mesa          ← ...
  cache/          ← downloaded .pkg.tar.gz files
  lock            ← lockfile (prevents concurrent pkg runs)
```

---

## Naming Rules

- Package names: lowercase letters, digits, `-` and `_` only. No dots, no uppercase.
- Version: follows upstream version. `~` prefix = pre-release (sorts before).
- Arch values: `x86_64`, `aarch64`, `any` (architecture-independent packages)

---

## Dependency Resolution

The `pkg` tool performs a topological sort of dependencies before install.  
Circular dependencies are rejected with an error.  
Virtual packages (`provides=`) are resolved before searching by name.

---

## Building Packages (workflow)

```
mypackage/
  MANIFEST
  files/
    usr/bin/myprogram
    usr/share/man/man1/myprogram.1
  scripts/
    post-install     ← optional
```

```bash
# Build the package
mkpkg ./mypackage ./out/

# Install it
pkg install ./out/mypackage-1.0.0-x86_64.pkg.tar.gz

# Or from a repository
pkg install mypackage
```
