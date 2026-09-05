# RFC 0006: A Package Repository, and Signing It

- **Status:** Draft. Implemented and QEMU-verified end to end, including
  the tamper cases; see "Verification".
- **Labels:** `rfc`
- **Author:** platform readiness work (`docs/PLATFORM-ROADMAP.md` §16)
- **Requires:** RFC per `CONTRIBUTING.md` — this adds a repository
  format, network fetch to the package manager, a cryptographic trust
  root, and a `novi-state` domain.

---

## Motivation & Problem Statement

`pkg` and `mkpkg` have worked for a while. `pkg`'s "repository" was a
directory of `.pkg.tar.gz` files at `/var/cache/pkg/repo` that nothing
ever put anything into. There was no index, no way to fetch, and no
repository anywhere to fetch from — so the entire package model in §2
of the platform roadmap, and the update model in §3, sat behind a gap
nobody had closed.

The second problem is the one that decides the design. A package
manager downloads code and runs it as root. If the trust root is "the
transport handed it to me", then whoever controls the network controls
the machine. Novi's base image deliberately has no OpenSSL, no GnuPG
and no libsodium, and BusyBox's built-in TLS does not validate
certificates — so "just use HTTPS" was not available even as a weak
answer.

## Proposed Design

### One signature over an index, not one per package

```
<repo>/
  index                                the package list
  index.sig                            detached Ed25519 signature over it
  index.pub                            the public half, for convenience only
  <name>-<version>-<arch>.pkg.tar.gz   the packages
```

`index` carries every package's SHA-256. So signing the index
authenticates the entire repository with one signature, and
`pkg install` extends that signature to each archive by re-checking its
hash before unpacking it — cached archives included, because "we
downloaded this once" is not a statement about what is in the file now.

The index format is one line per package, pipe-separated:

```
name|version|arch|size|sha256|file|depends|description
```

Line-based rather than stanza-based on purpose: `pkg` is BusyBox ash,
so finding a package is `grep "^name|"` and parsing it is one
`IFS=| read`, with no state machine and no awk program to get subtly
wrong. It stays greppable and diffable, which is the property this
project cares about everywhere else too. `|` is *forbidden* in every
field rather than escaped — an escaping scheme in a format parsed by
`read` is a bug waiting to happen — and `mkrepo` refuses to index a
package whose metadata contains one.

The index is sorted, so the same pool produces byte-identical bytes.
An index that churned would be a new signature and a pointless download
for every machine on every rebuild.

### `novi-verify`: a ~60 KB verifier instead of a TLS stack

`novi-verify <public-key> <signature> <file>` exits 0 or 1. It is built
on **TweetNaCl** (Bernstein, Janssen, Lange, Schwabe, Van Assche;
public domain; `tweetnacl.cr.yp.to`), vendored unmodified and
**hash-pinned** in `build/01-fetch.sh` — the one source in this project
that is, because everything else is trusted for where it comes from and
this one becomes the trust root of package verification. If TweetNaCl
arrives modified, `pkg` verifies signatures with an implementation an
attacker chose.

Writing an Ed25519 implementation by hand would be indefensible.
Picking the smallest audited one — one C file, no build system, no
configuration, no assembly — is not.

It is **statically linked**, deliberately: this binary is the trust
root for every package the system installs, and it should not resolve
through a shared library that a package could later replace.

Everything it touches is raw bytes — a 32-byte key, a 64-byte
signature — rather than PEM or base64. Parsing is attack surface, and
this is the one program that should have none. `mkrepo` produces both
formats from an OpenSSL key on the build host, and interoperability
with OpenSSL's Ed25519 was verified rather than assumed.

TweetNaCl's API verifies a *combined* signed message (signature
followed by message) and returns the message; detached signatures are
what every tool and every repository layout actually uses, so
`novi-verify` joins them itself. It also implements `randombytes()`
properly rather than stubbing it, even though verification never
generates randomness: a stub returning zeroes would be a catastrophic
key-generation bug the moment anyone linked that file into something
that signs.

### `pkg sync` and `pkg update` are different operations

`sync` refreshes the index; `update` upgrades installed packages. apt
calls these `update` and `upgrade`, which is a naming accident people
have simply memorised. `pkg update` already meant "upgrade" here, so
the new verb got the unambiguous name.

`pkg sync` downloads `index` and `index.sig`, verifies, and only then
installs the index — a machine that already had a good index must not
be left with a worse one because a sync failed halfway.

**A missing signature is not weaker than a wrong one.** Both fail. A
machine can opt out with `allow_unsigned = yes` in
`/etc/novi/pkg.conf`, which is what bootstrapping a repository you are
in the middle of creating needs, and which the file describes as "run
whatever the network hands me, as root". The decision lives in exactly
one function, because two places that decide it is how one of them ends
up more permissive than the other.

### Where the fetch hooks in

`locate_pkg()` — not `cmd_install` — falls through to the mirror when
nothing local matches. Dependency resolution and `pkg update` reach the
network through the same path, without either growing its own copy of
the fetch-and-verify logic.

### `/etc/novi/pkg.conf` is not `system.conf`

Same `key = value` shape, deliberately separate file. `system.conf` is
the declared state of the machine; a mirror is a *bootstrap parameter*.
`novi-state` cannot install a package from a mirror it would have to
read out of the file it is in the middle of applying.

There is no default mirror. There is no public Novi repository yet, and
pointing a package manager at a host that does not exist is worse than
pointing it at nothing.

### The `packages.*` state domain

```
packages.<name> = present | absent
```

This is the piece that makes the README's claim true of the whole
machine rather than only of its configuration: what software is
installed joins the same document, with the same `diff`, the same
generations and the same `rollback`.

The observer reads `pkg`'s install database directly
(`/var/lib/pkg/installed/<name>/MANIFEST`) — one `stat()` per key
instead of a fork, and `diff` runs it over every declared key on every
refresh of the Settings app's System panel. The converger shells out to
`pkg`, because reimplementing any of fetch/verify/unpack here would
give the system two package managers that disagree.

**Worth knowing before adding more domains like this:** converging a
package means a download and an unpack, which is the first converger
slow enough for the GUI's blocking `novi-state` calls to actually
matter (see CLAUDE.md). A `set` is still one awk pass; an `apply` that
installs something is not.

### What is in the repository

The desktop: `foot` and `fcft`, and Novi's own `novi-shell`,
`novi-panel`, `novi-launcher`, `novi-settings`, `novi-lockscreen`,
`novi-screenshot`. §2 wants a small native base with everything else
delivered as packages, and the desktop is the largest thing currently
baked into the base image that a console-only machine has no use for.
`build/30-repo.sh` builds these from exactly the binaries the earlier
stages produced, so the repository's contents and the image's contents
cannot drift.

They are still in the base image as well. Splitting them out is the
next step and a separate change; this one is about there being a
repository at all.

### The signing key

`build/30-repo.sh` generates a development key under `${BUILD_DIR}/keys`
on first run and installs its public half into the image at
`/etc/novi/keys/novi-repo.pub`. That is correct for a build you run
yourself — you are the publisher, and trusting your own repository is
the point.

It is **not** how a release should work: a real release key lives
offline, only its public half is ever in a tree like this one, and
signing happens somewhere that is not the build host. The private key
is deliberately left in `${BUILD_DIR}` — never squashed into the image,
never under the repo checkout — so it cannot be committed by accident.

The public key has to reach a machine by some path other than the
mirror it is used to check. `mkrepo` publishes `index.pub` next to the
index as a convenience for setup and says in as many words that it is
not a trust root when fetched from there.

## Alternatives Considered

**HTTPS instead of signatures.** BusyBox's TLS does not validate
certificates, so this would be encryption without authentication —
strictly worse than a signature because it *looks* like security. And
signatures survive mirroring, caching and offline media; TLS does not.

**GnuPG, like Debian.** A large C codebase, a keyring format, a trust
model, and a dependency the base image exists to avoid. The property
actually needed is "verify one Ed25519 signature".

**Per-package signatures.** More signatures to manage and no more
security than a signed index that carries every hash — and it would
make `pkg` parse a signature file per package instead of once per sync.

**A binary index format.** Faster to parse and unreadable, ungreppable
and undiffable, which are the three properties this project keeps
choosing on purpose.

## Implementation status

Implemented:

- `novi-verify/main.c`, `build/19-novi-verify.sh`, hash-pinned
  TweetNaCl in `build/01-fetch.sh`
- `packages/mkrepo` — index builder and signer
- `packages/pkg` — `pkg sync`, mirror fetch, SHA-256 verification,
  index-aware `search`/`info`
- `rootfs/etc/novi/pkg.conf`, installed by `build/11-pkg.sh`
- `build/30-repo.sh` — builds and signs the first-party repository
- `packages/novi-state` — the `packages.*` domain

### Three bugs this work surfaced

- **`/dev/fd` did not exist on the shipped image.** devtmpfs does not
  create it and nothing else did. BusyBox ash implements
  `< <(process substitution)` through `/dev/fd/N`, so every one of them
  in `packages/pkg` failed with `can't open /dev/fd/64: no such file` —
  and **not fatally**, which is worse: dependency resolution printed
  the error and carried on having resolved nothing, so
  `pkg install foot` fetched foot and silently skipped `fcft`. The
  original comment in `pkg` said process substitution was "verified
  working against the real busybox binary this repo builds" — and it
  was, on a *host* with a `/dev/fd`. Testing the shell answered a
  different question than testing the image.

  Fixed twice over: `rc.init` creates `/dev/fd`, `/dev/stdin`,
  `/dev/stdout` and `/dev/stderr` (as does the initramfs, so an
  emergency shell behaves like the real system), *and* `pkg` no longer
  uses process substitution at all. The trust-critical path should not
  depend on a shell extension, and a temp file is plain POSIX.

- **`mkpkg` exited 141 after succeeding.** Its final `tar -tzf … |
  head -5` gives `tar` a SIGPIPE once the archive has more than five
  entries, and with `set -o pipefail` that became the script's exit
  status — after the package had been written perfectly. Invisible
  while `mkpkg` was only ever run by hand; the first script to call it
  in a loop under `set -e` died on the first package.

- **`mkrepo`'s own newline check matched everything.**
  `case "$v" in *"$(printf '\n')"*)` — command substitution strips
  trailing newlines, so the pattern was `*""*`, and it rejected the
  first package it ever saw. Counting newlines works.

## Verification

QEMU, `-machine pc`, `-nic user`, with the repository served over HTTP
from the build host (reachable from the guest at `10.0.2.2` through
slirp). Every claim below is from that live run.

- `/dev/fd -> /proc/self/fd` and `/dev/stdin` present.
- `pkg sync` → "signature on the repository index verified",
  8 packages available.
- `pkg search screenshot` and `pkg info foot` answer from the index for
  packages that are not installed — `foot` correctly reporting
  `Depends: fcft`, `Status: available (not installed)`.
- **Dependency chain over the network:** with `foot`, `footclient` and
  `libfcft.so*` deleted and the cache emptied, `pkg install foot`
  fetched and verified both `fcft` and `foot` and restored the binary
  and the library.
- **A tampered package is refused.** Flipping one byte inside
  `novi-screenshot`'s archive *in the pool on the server* made
  `pkg install` fail its SHA-256 check, discard the download, and
  install nothing. Restoring the archive made the same command succeed.
- **A tampered index is refused.** Appending a package line to the
  signed index on the server made `pkg sync` fail signature
  verification and leave the previous index in place — the injected
  package never appeared in `/var/lib/pkg/index`. Restoring the index
  made `pkg sync` succeed again.
- **`packages.*` round-trip:** `novi-state set packages.novi-screenshot
  absent` → `diff` showed the drift → `apply` removed it and wrote a
  generation → `rollback` reinstalled it *from the mirror* and `diff`
  came back clean.

## Roadmap

- **Split the desktop out of the base image.** The packages exist; the
  base still contains them too. Doing the split is what makes §2's
  "small native base" real rather than described.
- **A real release key and a published repository.** Offline key,
  signing off the build host, and something at a stable URL.
- **`pkg update` against the index.** It compares against local
  archives today; it should compare installed versions against the
  index and upgrade from the mirror.
- **Version constraints.** `depends=libfoo>=2.0` parses today and the
  constraint is discarded.
- **Repository metadata expiry.** A signed index with no timestamp can
  be replayed: an attacker who can serve stale-but-validly-signed
  metadata can hold a machine at a version with a known hole. A signed
  `valid-until` is the standard answer.
- **`packages.*` and the event loop.** Moving `novi-state` subprocess
  calls off the Wayland thread was already on RFC 0002's roadmap; a
  package install is the first converger that makes it visible.
