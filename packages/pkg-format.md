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
| `depends` | Space-separated list of package names | `musl zlib openssl` |
| `provides` | Virtual packages this satisfies | `libcurl` |
| `conflicts` | Packages that must not be installed | `curl-legacy` |
| `replaces` | Packages this supersedes on upgrade | `curl-old` |
| `size` | Installed size in KB (auto-set by mkpkg) | `1024` |
| `url` | Upstream homepage | `https://curl.se` |
| `license` | SPDX license identifier | `MIT` |
| `maintainer` | Package maintainer | `Your Name` |

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

Scripts in `scripts/` are plain POSIX shell. They receive one argument: the package version.

| Script | When it runs | Common uses |
|---|---|---|
| `pre-install` | Before files are extracted | Check conflicts, create users/groups |
| `post-install` | After files are extracted | Run ldconfig, update icon cache |
| `pre-remove` | Before files are deleted | Stop services, warn user |
| `post-remove` | After files are deleted | Clean up config, remove users |

### Example post-install

```sh
#!/bin/sh
# Rebuild shared library cache after install
ldconfig
# Update desktop icon cache if present
[ -d /usr/share/icons ] && gtk-update-icon-cache -f /usr/share/icons/hicolor 2>/dev/null || true
```

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
| `description` | no | Not yet shown anywhere; reserved for a future results view | `foot terminal emulator` |

### Example: `usr/share/novi/apps/foot.app`

```
name=Terminal
exec=/usr/bin/foot
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
