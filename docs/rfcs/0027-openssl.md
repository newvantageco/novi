# RFC 0027 — OpenSSL, and the rule it does not break

**Status:** Implemented
**Depends on:** RFC 0006 (package trust root), RFC 0007 (base/desktop split), RFC 0020 (HTTPS), RFC 0026 (Python)
**Amends:** RFC 0026 decision 3

> **Summary.** OpenSSL 3.5.8 LTS as the `openssl` package —
> `libcrypto`, `libssl` and the `openssl(1)` CLI — and CPython rebuilt
> against it, so `import ssl` works. Nothing changes in the base image,
> which still ships no TLS library, and nothing changes on the package
> trust path, where `novi-verify` is still ~10 KB of static TweetNaCl.

## Motivation & Problem Statement

RFC 0026 shipped Python without `ssl` and said so loudly, because
CPython's TLS is written against OpenSSL specifically and this project
had refused OpenSSL since RFC 0006. That was the right thing to ship
and the wrong place to stop: **a Python that cannot fetch an https URL
is a Python most existing programs will not start under.** `import ssl`
is the first line of a large fraction of the networking, automation and
security tooling that is the reason to want Python here at all.

There were three candidate answers and only one of them is ordinary:

1. **Add OpenSSL as a package.** Large, boring, what every
   distribution does.
2. **Write an mbedTLS-backed `_ssl`.** Novel, small-looking, and a
   crypto-correctness undertaking with nobody upstream to catch a
   mistake in it. Not something to do casually on a machine's TLS path.
3. **Leave it, and shell out to `curl`.** Works, and does not help a
   program that imports `ssl` at the top of the file.

This RFC takes (1).

## Decisions

### 1. The rule this appears to break, stated precisely.

"No OpenSSL" has been said in this project since RFC 0006 and it is
worth being exact, because the vague reading of it blocks this forever
and the precise reading does not.

- **RFC 0006's rule is about the TRUST PATH.** Verifying a package
  signature must not require a TLS stack, because a package manager
  that needs libcrypto to check libcrypto's signature is a bootstrap
  with a hole in it. Hence `novi-verify`: static, ~10 KB, TweetNaCl
  hash-pinned in `01-fetch.sh`, the only pinned source in the project.
  **Unchanged and unchangeable.** Verified after this change:
  `readelf -d` on `/usr/bin/novi-verify` still reports *"There is no
  dynamic section in this file."*
- **RFC 0020's rule is about the BASE IMAGE.** No TLS library ships in
  the console base, which is why mbedTLS and curl are packages.
  **Unchanged.** `32-openssl.sh` installs nothing into `${ROOTFS}`;
  verified by `find` finding no `libssl*`, `libcrypto*` or `libmbed*`
  anywhere in the base rootfs after a full build.

Neither rule says a *package* may not contain a TLS library. RFC 0020
already established that when it shipped mbedTLS; RFC 0021 had to make
the identical correction when "no TLS in the base" was invoked against
wolfSSL and turned out to forbid something the base had been doing all
along (`CONFIG_TLS=internal` was ~200 KB of unaudited crypto compiled
into wpa_supplicant). **Getting the rule right is how work stops being
blocked by a slogan** — and it is the third time this project has had
to do it, which is itself the argument for writing the rule down
precisely rather than as a name.

What is genuinely new here is smaller than it looks: a person who runs
`pkg install python` now gets OpenSSL. A person who does not, does not.

### 2. OpenSSL, not LibreSSL, not a new backend.

CPython 3.10 dropped LibreSSL support explicitly, and CPython's `_ssl`
tracks OpenSSL's API version by version. There is no configure switch
here — `--with-openssl` is the only thing CPython offers.

**3.5 because it is an LTS branch.** A distribution wants a
security-fix stream that does not move APIs under the things linking
it; 3.5 is supported through 2030. The alternative (a current 3.6)
buys nothing this system uses and costs a rebuild of every consumer
when it goes end-of-life.

### 3. Two outputs, like mbedTLS: a link prefix and a package.

```
${BUILD_DIR}/openssl-target      headers + libraries, for LINKING
${BUILD_DIR}/stage-devtools/openssl   the package
```

Never `${ROOTFS}`, per decision 1. `43-python.sh` points
`--with-openssl` at the first, and the second is published by
`53-devtools-repo.sh` with no change to that stage — it already globs
every staged directory carrying a `MANIFEST`.

The stage number is **32**, beside `31-mbedtls.sh`: two TLS
implementations, both packages, neither in the base, each the only one
its consumer accepts. Python (38) links it, and stages run in numeric
order.

`--prefix=/usr` is the **target's** path even though the files are
staged elsewhere, because OpenSSL compiles it in — `OPENSSLDIR`, the
providers directory and the engines path all derive from it. Staging
under `DESTDIR` and keeping the prefix honest is the same discipline
RFC 0015 records for pkgconf's `--with-system-libdir`, which bakes in
the build host's prefix if you let it.

The package ships **runtime only**: libraries, the CLI, `openssl.cnf`
and the loadable providers. Headers, `.pc` files and `libcrypto.a` stay
in the link prefix — they are build inputs, and there is no compiler in
this package (that is `novi-devel`, RFC 0015).

### 4. `/etc/ssl/cert.pem` is a symlink, and without it verification silently trusts nothing.

OpenSSL is configured `--openssldir=/etc/ssl`, so its default verify
paths are `/etc/ssl/cert.pem` and the directory `/etc/ssl/certs`. The
`ca-certificates` package (RFC 0020) ships exactly one file,
`/etc/ssl/certs/ca-certificates.crt` — and **the directory lookup is by
subject hash**, so a directory holding one bundle satisfies it not at
all.

Caught by the test rather than by reading: with the bundle sitting
right there, `ssl.create_default_context().cert_store_stats()` returned
`{'x509': 0, 'crl': 0, 'x509_ca': 0}` and
`ssl.get_default_verify_paths().cafile` was `None`. Every https
connection from Python would have failed to verify, on a machine that
has the CA store installed. **curl is unaffected** — it is built with
the bundle path compiled in — which is precisely the asymmetry that
would make this read as a Python bug rather than a layout bug.

`ca-certificates` now also ships `/etc/ssl/cert.pem ->
certs/ca-certificates.crt`. It belongs to that package rather than to
`openssl` because it is a statement about where the certificate store
is, and that package *is* the store. Alpine ships the same link for the
same reason. After the fix: `{'x509': 143, 'crl': 0, 'x509_ca': 143}`.

### 5. A missing `_ssl` is a hard build failure now.

RFC 0026 built `43-python.sh`'s missing-module check as a *warning*,
because CPython's optional-module list shifts between point releases
and a build that stops over `_dbm` would be worse than one that says
so. `_ssl` and `_hashlib` are the exception: they are the entire reason
this RFC exists, and their absence is discovered at the top of somebody
else's program rather than in a build log. The stage exits non-zero if
either is missing despite `--with-openssl`.

## What was verified

On a booted image, installing from the live medium's own signed
repository:

- `pkg install python` resolves `openssl` and, through it,
  `ca-certificates` — a two-level dependency chain the packager derived
  from hand-written `depends=` lines and `pkg` walked correctly.
- `ssl.OPENSSL_VERSION` → `OpenSSL 3.5.8 25 Aug 2026`.
- `hashlib.pbkdf2_hmac('sha256', ...)` works, so `_hashlib` is really
  linked and not merely present.
- The default trust store loads **143 CA certificates**, from
  `/etc/ssl/cert.pem`, with no environment variable set.
- **The proof that verification works is a triple, not a success**
  (RFC 0020's standard, with one case added). Against a local
  `openssl s_server` on a self-signed P-256 certificate for
  `CN=localhost`, all from the Python interpreter:

  | case | result |
  |---|---|
  | default context, self-signed server | **REFUSED** — `CERTIFICATE_VERIFY_FAILED: self-signed certificate` |
  | that certificate trusted (`cafile=`) | **ACCEPTED**, `TLSv1.3` |
  | trusted, but connecting as a different hostname | **REFUSED** — `Hostname mismatch` |

  Any one of those alone cannot distinguish "verification works" from
  "nothing works" or from "everything is accepted".
- The `openssl(1)` CLI runs on the target and generated that key and
  certificate itself.
- The base image still contains no `libssl`, `libcrypto` or `libmbedtls`,
  and `novi-verify` is still statically linked.

## Consequences

- **8 MB staged**, one package, `depends=ca-certificates`.
- **`python` now depends on `openssl`.** Installing Python installs a
  TLS stack. That is the trade this RFC makes explicit; it is what
  every distribution does and it is now written down rather than
  implied.
- **This system now carries three TLS implementations** — mbedTLS for
  curl and git, wolfSSL for wpa_supplicant, OpenSSL for Python — and
  that is worth stating plainly rather than discovering. Each exists
  because its consumer accepts only it: curl was chosen small
  (RFC 0020), wpa_supplicant 2.11 has no mbedTLS backend at all
  (RFC 0021), CPython has no backend but OpenSSL. Consolidating means
  changing a consumer, not changing a preference. All three are
  packages; the base image has none of them.
- **RFC 0026's decision 3 is superseded.** Its argument against a stub
  `ssl.py` still stands and is now moot. Its roadmap item 1 is done.
- **The `openssl` CLI is a real tool on this machine**, not just a
  side effect: generating keys, inspecting certificates and running
  `s_client`/`s_server` are things the stated audience for this
  distribution does, and until now there was no way to do any of them.

## Roadmap

1. **A `python-tls` verification that reaches the outside world.**
   Everything above is a loopback handshake against a certificate this
   machine made, which proves the code path and not the CA set. The
   first boot on a network should fetch a real https URL and check that
   the 143-certificate store is the reason it succeeded.
2. ~~**Rebuild curl against OpenSSL, or not.**~~ **Answered on
   purpose: NOT.** The item asked for a decision rather than a build,
   and guessed the ratio almost right — it said 10x; measured, it is
   **8.2x**.

   **Installed on the target: mbedTLS 972 KB** (libmbedcrypto 597 KB,
   libmbedtls 295 KB, libmbedx509 85 KB) **against OpenSSL 8.0 MB**
   (libcrypto 6.1 MB, libssl 1.0 MB, the legacy provider 142 KB).

   Who pays is settled by the dependency graph, not by taste. `git`
   depends on `curl` depends on `mbedtls`, and on nothing else that
   carries TLS — so **a machine with git and no Python would go from
   972 KB of TLS to 8.0 MB, +7 MB, for no capability it did not
   already have.** The saving is under 1 MB and lands only where
   OpenSSL is already present for another reason: `netsurf` (which
   depends on both) and `python`.

   | machine | today | curl on OpenSSL | delta |
   |---|---|---|---|
   | `git` | 972 KB | 8.0 MB | **+7.0 MB** |
   | `netsurf` | 8.97 MB | 8.0 MB | −972 KB |
   | `python` | 8.0 MB | 8.0 MB | 0 |

   The maintenance argument — one upstream to bump, one CVE watch-list
   — is real and small, and its second half cuts the other way: **the
   smaller stack is the one on the HTTPS fetch path.** 972 KB parsing
   certificates off the internet is a better place to be than 8 MB of
   it, which is RFC 0020's original reasoning intact.

   And the choice was always one-sided: **OpenSSL can never leave**,
   because CPython's `ssl` accepts nothing else. The only question
   available was whether mbedTLS goes, and at 972 KB on the path that
   matters most it earns its place. This is sediment no longer; it is
   a decision, and re-opening it needs a new number rather than a new
   opinion.
3. ~~**`pip`.**~~ **Done — RFC 0026 roadmap 4 and 5, and BOTH of the
   objections listed here were already answerable when this item was
   written.** It named three: https (gone, this RFC), no compiler in
   the `python` package (true, and irrelevant — the compiler is a
   PACKAGE, `novi-devel`, and `pip install --no-binary :all:
   MarkupSafe` now builds a wheel with the machine's own gcc), and the
   `x86_64-linux-gnu` SOABI mislabel (a real bug, and a **one-word**
   one: CPython's configure corrects the triplet for musl by testing
   `build_os` where it should test `host_os`, so a native musl build
   is corrected and a cross build is not).

   pip also **shipped in the package the whole time**:
   `--with-ensurepip=no` decides whether pip is INSTALLED, not whether
   it is present, and `ensurepip`'s bundled wheels are part of the
   standard library. What the work actually needed was that one word,
   `/etc/pip.conf` (pip verifies against a vendored certifi bundle, so
   on a machine whose operator added a CA `pip install` fails while
   `urllib` succeeds against the same host — measured), and nothing
   else. **Tenth roadmap item in this repository found to be wrong
   about what is already built or already possible.**
4. ~~**Trim the OpenSSL build.**~~ **Done, and the number is smaller
   than the item implied.** Measured, stripped, like for like:

   | | before | after |
   |---|---|---|
   | `libcrypto.so.3` | 6,137,328 | 5,915,568 |
   | `libssl.so.3` | 1,061,376 | 728,960 |
   | `openssl` | 957,192 | 913,704 |
   | `ossl-modules/legacy.so` | 142,120 | — |
   | **total** | **8,298,016** | **7,558,232** |

   **739 KB, 8.9%** — and the package on disk goes 8.0M → 7.3M. The
   item said this "helps every machine that has OpenSSL", which is
   true and is nine percent. **libcrypto barely moves (3.6%)**: its
   weight is bignum, elliptic curve and provider machinery, not the
   algorithm tables, so removing ciphers takes hundreds of kilobytes
   off the thing that was already small. A third of `libssl` goes,
   which is DTLS, QUIC and the PSK/SRP suites.

   **WHAT IT COSTS IS EXACTLY THE PSK AND SRP SUITES, and that was
   enumerated rather than reasoned about.** `openssl ciphers -v` goes
   from **60 suites to 30** on a booted machine, which sounds alarming
   until the two lists are diffed: all thirty removed are `*-PSK-*` or
   `SRP-*`, which need an out-of-band shared secret and appear nowhere
   on the public web. The thirty that remain are the ECDHE/DHE/RSA set
   with AES-GCM, AES-CBC and ChaCha20, including all three TLS 1.3
   suites.

   **`hashlib` is unchanged at 19 algorithms**, `ripemd160` included —
   it moved back into the default provider in 3.0.7, so `no-legacy`
   does not cost it. And the legacy provider was **unreachable
   anyway**: the shipped `openssl.cnf` activates `default` and nothing
   else, so 142 KB shipped that could not be used without editing a
   config file nobody edits. RFC 0007's rule about dead weight, in the
   TLS stack.

   **`no-deprecated` was NOT taken.** It is the one entry that could
   break CPython's `_ssl` and `_hashlib`, and folding it into a size
   trim would make a build failure look like a packaging change. It is
   its own question.

   **The first probe could not tell the two builds apart.** `openssl
   s_client -ssl3` answers "Unknown option" in BOTH, because upstream
   already builds without the SSLv3 method — so the check that looked
   like it proved `no-ssl3` proved nothing. The cipher-list diff is
   what distinguishes them. Same shape as every other unfalsifiable
   probe this project has caught itself writing.

   **NetSurf needed no rebuild**, established by comparing its 57
   undefined OpenSSL symbols against what the trimmed libraries still
   export — all present. That comparison was itself wrong twice
   before it was right: `nm -D` prints `SYMBOL@VERSION` on the
   undefined side and `SYMBOL@@VERSION` on the defined side, so the
   first two runs reported every symbol missing.

   Verified on a booted machine: `openssl version`, the 143-certificate
   store intact, and **RFC 0020's verification triple from Python** —
   an untrusted self-signed certificate refused, the same certificate
   accepted once its CA is trusted (TLSv1.3, `TLS_AES_256_GCM_SHA384`),
   and the right CA with the wrong hostname refused again.
