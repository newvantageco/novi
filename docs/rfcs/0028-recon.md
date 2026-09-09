# RFC 0028 — novi-recon, and the tool that could not be shipped

**Status:** Implemented
**Depends on:** RFC 0026 (Python), RFC 0027 (OpenSSL)

> **Summary.** `novi-recon` is a network reconnaissance tool — DNS,
> WHOIS, TLS certificates, HTTP security headers, robots.txt, a
> breached-password check and a TCP connect scan — written against the
> Python standard library and nothing else. It exists because the
> obvious thing to port could not be redistributed, and because
> RFC 0026 and RFC 0027 had put a capable interpreter on this machine
> that nothing was using.

## Motivation & Problem Statement

Two things came together.

**Nothing was written in Python.** RFC 0026 shipped the interpreter and
RFC 0027 gave it TLS, and the whole of the evidence that either
mattered was `python3 -VV` printing a version. A language runtime with
nothing written in it is a claim, not a capability.

**And the thing to port could not be ported.** The starting point was
the "God's Eye" information gathering tool on GitHub. Its `LICENCE`
file, in full, is:

```
Copyright 2022 PAVEL DAT. All rights reserved
```

That is not a licence. It grants nothing, and "All rights reserved"
says so explicitly. The other GitHub project of the same name has **no
licence file at all**, which under the Berne Convention means the same
thing, and is in any case 136 lines of skeleton with empty
`adapters/`, `store/` and `orchestrator/` packages. Putting either into
a repository this project *signs* and hands to other people would be
distributing code nobody gave us the right to distribute — and a signed
repository is exactly the artifact where that matters most, because the
signature is a statement that the contents are what this project meant
to ship.

So: the capability was worth having, the code was not ours to give
away, and it is written here instead. The licence check is the first
thing `39-novi-recon.sh`'s header explains, so nobody re-derives it.

## Decisions

### 1. Standard library only. Not a preference — arithmetic.

The tool this replaces needs `requests`, `dnspython`, `python-nmap`,
`folium`, `opencage` and `phonenumbers` — six PyPI packages, two of
which want an API key and one of which pulls a numeric stack in behind
it — plus the `nmap` and `httpie` binaries. This system has no pip
(RFC 0026) and no nmap. Packaging six third-party trees to run one
script is not a trade anybody would make, and each one is a
supply-chain decision of the kind RFC 0006 exists to take seriously.

Everything here is `socket`, `struct`, `ssl`, `urllib`, `hashlib`,
`re` and `concurrent.futures`. The `novi-recon` package's `depends=`
line is one word: `python`.

The visible cost is that the DNS and WHOIS clients are written out
longhand. That turns out to be a feature — see decision 3.

### 2. What it does, and what it deliberately does not.

| | |
|---|---|
| `dns` | A/AAAA/MX/NS/TXT/SOA/CNAME/PTR/SRV/CAA, own resolver client |
| `whois` | TCP port 43, following IANA's referral to the registry |
| `tls` | certificate, SAN list, fingerprint, protocol, cipher, and whether it verified |
| `headers` | HTTP headers with a security summary and a clickjacking verdict |
| `robots` | robots.txt, parsed into groups rather than printed |
| `pwned` | HIBP k-anonymity check; only a 5-character hash prefix leaves the machine |
| `ports` | TCP connect scan |

Dropped from the original's list, on purpose: `ip_info_finder`,
`phone_info` and `one_sec_mail` are thin wrappers around third-party
APIs (one of which is HTTP-only on its free tier, and two of which need
a key). A recon tool whose answers come from somebody else's service,
silently, is a different kind of thing from one that asks the
authoritative source; and hardcoding a vendor into a distribution's
tooling is a decision that deserves its own argument, not a
side effect of a port.

`ports` is a **connect(2) scan and nothing else** — no raw sockets, no
SYN scan, no timing games, no OS fingerprinting, no evasion. It asks
the same question any client asks, which is the only question it needs
to answer and the only one that works without `CAP_NET_RAW`. The
`--help` epilogue says to point it only at systems you are authorised
to test, because leaving that implied in a tool shipped by a
distribution is worse than saying it.

### 3. The DNS client is written out, and the three things that are easy to get wrong are done explicitly.

`dnspython` is 25,000 lines to ask one question. This is about 120, and
writing it meant confronting the parts a library hides:

- **Name compression.** A name in an answer usually ends in a two-byte
  pointer to an earlier offset in the same message, and pointers may
  chain. A parser that does not follow them reads garbage on almost
  every real response, because servers compress the question name into
  every answer. The chain is **bounded**: a two-byte packet can point a
  name at itself, and an unbounded follower hangs forever on data
  somebody else chose.
- **Truncation.** `TC` set means the answer did not fit in 512 bytes
  and the query must be repeated over TCP, where the message carries a
  two-byte length prefix. Reporting the truncated half is worse than
  asking again; the client asks again.
- **The transaction ID.** Random, from `SystemRandom`, and checked on
  the way back. Any host on the path can otherwise answer first. This
  is not a secure resolver — there is no DNSSEC here — but an unchecked
  ID is free to exploit and free to prevent.

A fourth, found by running it: **a long TXT record is always split into
255-byte chunks on the wire**, and reading only the first chunk
silently truncates exactly the records people look at (SPF, DKIM). The
chunks are concatenated with nothing between them.

A fifth, found by looking at real output: **the root name is `.`, not
the empty string.** A null MX (RFC 7505) is literally `0 .`, and
rendering it as `0 ` reads as a parse failure. That one is in the tests
now with the reason attached.

### 4. Clickjacking is a header question, so it is part of the header report.

The original has a `ClickJacking` checker and an `HttpHeadersGrabber`
as separate tools, and the first is a subset of the second: whether a
page can be framed is decided by `X-Frame-Options` and CSP
`frame-ancestors`, both of which are headers. One request, one report.

**CSP `frame-ancestors` overrides `X-Frame-Options` wherever both
appear.** That is the spec, and a checker reading only XFO calls a
`frame-ancestors 'none'` site unprotected and an
`XFO: DENY; frame-ancestors https://elsewhere` site protected — both
backwards. The verdict is three-valued (`protected` / `FRAMABLE` /
`partial`) because "framable by these specific origins" is a real
answer that a boolean cannot carry, and every branch is a row in the
test's truth table.

### 5. Redirects are followed by hand.

`urllib` follows them silently, and *which hop set the header* is most
of what the `headers` command is for. The chain is reported.

### 6. The tests run on the build host, and that is where the interesting cases are.

Same argument as `novi-panel/icons-test.c`. Most of what can be wrong
here cannot be shown by running the tool:

- A real resolver never sends a compression pointer loop, a mismatched
  transaction ID, or a `TC` flag on a small answer — and those are
  exactly the three cases worth getting right.
- A live site exercises one row of the clickjacking truth table.
- `robots.txt`'s one subtle rule (consecutive `User-agent` lines share
  a group) does not appear in most real files.

So DNS messages are **built here and parsed back**, and every verdict is
tested as a table. No network, no downloaded fixtures, nothing that can
go red because a third party changed. `scripts/lint.sh` runs it, and so
does `39-novi-recon.sh` immediately before packaging — the same reason
`40-repo.sh` runs `check-hardening.sh` there rather than trusting that
lint was run on the tree that produced the artifact.

The WHOIS referral chase is a separate function from the socket
(`whois_chain` takes an `ask` callable) precisely so it can be tested
with a fake. Without that split, the only way to exercise "IANA refers
you to the registry, which refers you to the registrar" is to have the
internet, and the VM this is verified in does not.

### 7. The shebang changes at packaging time.

`#!/usr/bin/env python3` in the repository, so it runs out of a
checkout anywhere; `#!/usr/bin/python3` in the installed copy. On the
target there is exactly one interpreter at a known path, and `env`
costs a PATH search and an exec on every invocation — worse, a `$PATH`
that finds a different `python3` first is a way for a system tool to
behave differently for different users.

`39-novi-recon.sh` also **parses the script with the target's exact
major.minor** before packaging. A syntax error in Python is a runtime
error: without that check the package builds, installs, signs and
verifies perfectly, and fails at the first invocation.

## What was verified

**On the build host, against the real internet** (the code that runs is
byte-identical to the packaged copy):

- `dns example.com` against a public resolver returns A, AAAA, MX, NS,
  TXT and SOA correctly — compression pointers followed, a multi-record
  TXT set intact, the SOA's two names and five timers parsed.
- `tls example.com` verifies a real certificate chain and prints
  subject, issuer, validity, serial, SAN list and SHA-256 fingerprint.
- `headers https://example.com` reports `FRAMABLE` with the reason, and
  lists which of the six security headers are absent.
- `robots https://www.google.com` parses — and its first group really
  is `User-agent: *` and `User-agent: Yandex` together, which is what
  sent me back to check that the grouping rule was right rather than
  lucky.
- `pwned` with `password` on stdin: **BREACHED, 52,372,427 times**,
  from a 5-character prefix and 2,164 returned suffixes. With a random
  passphrase: not found, 2,101 suffixes — the near-equal counts are the
  `Add-Padding` header doing its job.
- `ports` finds a listener started for the purpose and reports nothing
  on a range with nothing on it.

**On a booted Novi**, installed from the live medium's signed
repository. The VM has no network, so each subcommand was pointed at a
local peer:

- `pkg install novi-recon` pulls `python` (and through it `openssl` and
  `ca-certificates`).
- `dns ... -s 127.0.0.1:5353` against a replay server serving **real
  wire bytes captured from a public resolver**, with only the
  transaction ID patched — so the parser is tested against a real
  server's output, not against this project's own encoder. MX (`0 .`)
  and a two-record TXT set both correct, in both table and `--json`
  form.
- `headers` against a local server: `protected -- CSP frame-ancestors
  'none'` on a page that sets both headers, `FRAMABLE` on one that sets
  neither.
- `robots` parses two groups and a sitemap, with the shared-agent rule
  exercised.
- `whois -s 127.0.0.1` against a local port-43 responder.
- `tls localhost:4443` against `openssl s_server`, all three ways:
  **verification refused** (self-signed), `-k` showing the certificate
  *and still reporting the failure*, and `SSL_CERT_FILE=` making it
  verify — with the same SHA-256 fingerprint in the `-k` and verified
  runs, which is what proves the insecure path really talked to the
  same server.
- `ports 127.0.0.1` finds exactly the three ports those servers opened.

`pwned` is the one subcommand not exercised on the target, because it
needs `api.pwnedpasswords.com` and that VM has no route anywhere. Its
hashing and range parsing are unit-tested (including `sha1('password')`
pinned to a value anyone can check by hand) and the whole command was
run live on the build host.

## Consequences

- **48 KB**, one file, `depends=python`.
- **The first Python program in this operating system**, which is the
  half of RFC 0026 that was still a claim.
- **`getservbyport` returns nothing on this system**, because BusyBox
  ships no `/etc/services`. `ports` prints the number and a dash rather
  than pretending; a services file is a package-sized decision that
  belongs with whoever wants named ports.
- **`--json` on every subcommand**, and it is the same dict the human
  renderer draws from — one place decides the shape. Two independent
  paths is how the JSON ends up missing a field the table shows, which
  is the same argument RFC 0017 makes for `novi-wifi scan --tsv`.
- **This is a tool for authorised use.** `ports` scans and `pwned`
  sends a hash prefix to a third party. Both are ordinary; both are
  said out loud in `--help` rather than left implied.

## Roadmap

1. **A subcommand that reads a target list and writes a report.** Right
   now each command answers one question about one target; the original
   tool's actual shape is "run everything against this domain".
2. **DNSSEC validation**, or an explicit statement that there is none.
   At the moment there is none and the README should say so before
   somebody assumes otherwise.
3. **`/etc/services`**, so `ports` can name what it finds.
4. **Certificate transparency and chain listing** in `tls` — the leaf is
   there, the intermediates are not.
