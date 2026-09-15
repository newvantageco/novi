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
thing `42-novi-recon.sh`'s header explains, so nobody re-derives it.

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
does `42-novi-recon.sh` immediately before packaging — the same reason
`50-repo.sh` runs `check-hardening.sh` there rather than trusting that
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

`42-novi-recon.sh` also **parses the script with the target's exact
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

**`/etc/services`, on a booted machine, in both directions** (roadmap
item 3). `netstat -lt` reports `:::ssh` and `:::kafka` where `-n`
reports 22 and 9092 — and `kafka` is one of the entries the curation
pass added, so the answer is coming from this file rather than from
anything built into musl. Forward: `telnet 127.0.0.1 ssh` connects,
and `telnet 127.0.0.1 nosuchservice` is refused with `bad port` — so
the name lookup is the table too, not a fallback that would have made
the first result meaningless.

**The DNSSEC reporting** (roadmap item 2) was measured against
8.8.8.8: `cloudflare.com` and `internic.net` come back AD set,
`facebook.com` AD clear, and a query built with `RD` alone gets AD
**clear** for a signed name — which is the measurement that made
setting AD in the query the load-bearing half rather than a detail.

## Consequences

- **48 KB**, one file, `depends=python`.
- **The first Python program in this operating system**, which is the
  half of RFC 0026 that was still a claim.
- **`getservbyport` returned nothing on this system** for the life of
  the project, because BusyBox ships no `/etc/services`. `ports`
  printed the number and a dash rather than pretending. This RFC
  called a services file "a package-sized decision that belongs with
  whoever wants named ports", and that was wrong twice over: it is 77
  lines of text, and it is not the recon tool's file — `getservbyname`
  and `getservbyport` are libc, so the answer belongs to the machine.
  Roadmap item 3 below has the shipped version.
- **`--json` on every subcommand**, and it is the same dict the human
  renderer draws from — one place decides the shape. Two independent
  paths is how the JSON ends up missing a field the table shows, which
  is the same argument RFC 0017 makes for `novi-wifi scan --tsv`.
- **This is a tool for authorised use.** `ports` scans and `pwned`
  sends a hash prefix to a third party. Both are ordinary; both are
  said out loud in `--help` rather than left implied.

## Roadmap

1. ~~**A subcommand that reads a target list and writes a report.**~~
   **Done, for one target** — `novi-recon all <domain>` runs `dns`,
   `whois`, `tls`, `headers` and `robots` and prints one report. A
   target *list* is deliberately not part of it: see below.

   **`ports` IS NOT IN THE SWEEP, and that is the decision this
   feature is about.** Every check in it asks a third party about the
   target — a resolver, a WHOIS server, the site's own TLS and HTTP
   endpoints, which is what a browser does on its own. A port scan is
   the one thing this tool does that reaches for a machine's *other*
   services, and this tool's own epilog says to point it only at
   systems you are authorised to test. A subcommand called "all" that
   quietly scanned would move that decision from the person to the
   tool, at exactly the moment they are least likely to be thinking
   about it — so `--ports` opts in, and then it is a scan somebody
   typed. `pwned` is out for a duller reason: it reads a **password**
   from stdin and knows nothing about a domain, so there is nothing
   for a sweep to hand it.

   **One check failing is a FIELD, not the end.** Each runs inside its
   own guard and a failure becomes `ok: false` with the reason,
   because the whole value of a sweep is the parts that answered — a
   WHOIS server being down must not throw away the DNS, TLS, header
   and robots findings gathered around it. Same shape as `novi-state`
   running each converge in a subshell so one impossible key does not
   abandon the rest of the document. Measured on a real run:
   `4 of 5 answered`, with four full reports and one named failure.

   **A partial sweep exits 0; nothing answering exits 1.** A non-zero
   status for "the WHOIS server was down" would make this unusable
   from a script. That second branch is hard to provoke against the
   network — `dns` reports NXDOMAIN as a *finding* and returns
   normally, so a domain that does not exist still answers — which is
   why the exit status is driven through `main()` in the host test
   instead. **A rule nobody can make fire is a rule nobody can rely
   on.**

   **The renderer composes the existing ones.** There is already one
   printer per check; this mode only decides which to call. A second
   formatting of any check would be exactly the drift `novi-agent
   describe --text` avoids by keeping one gatherer and two printers —
   and the host test asserts it by counting calls into a stand-in
   table, because a reimplementation would render the same report with
   none.

   **The host is taken out of whatever was typed, and the derivation
   is reported.** Somebody who has just run
   `headers https://example.com/path` will type the same thing here;
   handing that to the DNS client would look up a name containing a
   slash and report NXDOMAIN about a domain that plainly exists.
   `sweep_host()` also distinguishes `host:port` from a bare IPv6
   address by counting colons — splitting at the first one leaves
   `2606`, which resolves to nothing while still looking like a host.
   `render_all` prints a `from` line whenever the target it used is
   not the one given, so a sweep that rewrote what you typed is a
   sweep you can check.

   **What is still not done is the LIST**, and it needs a decision
   this RFC has not made: a file of targets is a scan campaign, and
   the rate at which it hits third-party WHOIS and DNS servers is a
   policy question rather than a flag. One target per invocation and a
   shell loop is the honest interim.
2. ~~**DNSSEC validation**, or an explicit statement that there is
   none.~~ **Done — the second one, plus one real fact.**

   There is no validation here and there is not going to be: it needs
   a trust anchor, a clock you believe and a chain walk, none of which
   belong in a recon tool's DNS client. So `dns` says so **in its own
   output, on every run** rather than in a README somebody read once:

   ```
   dnssec   AD set -- the resolver says it validated; this tool did not
   ```

   What it can honestly report is the resolver's own claim, and that
   is one bit in each direction. **The bit in the QUERY is the
   load-bearing half**, and this was measured against 8.8.8.8 rather
   than assumed: with `RD` alone, the response for a signed name comes
   back with **AD clear** — so without setting AD in the query (RFC
   6840 §5.7: a client sets it to say it understands the bit) the tool
   would have reported "not validated" about every domain on earth.
   `CD` is deliberately never set: it tells the resolver to skip
   validation, which is the opposite of the question.

   The verdict is **three-valued** for the same reason the
   clickjacking verdict is: "nothing came back, so nobody said
   anything about it" is a real answer a boolean cannot carry, and
   reporting `false` for it would be the tool saying something untrue
   about a domain. A mixture (some types AD, some not — a signed zone
   with an unsigned delegation under it) gets its own wording rather
   than being folded into "unsigned zone". Only a response that
   actually **carried an answer** votes: a NODATA reply for AAAA has
   nothing to validate, and counting its clear AD bit would turn one
   absent record type into "not validated" for a domain that is signed.

   Discriminates in practice: `cloudflare.com` and `internic.net`
   report AD set, `facebook.com` AD clear.

   **AD is only worth the path to the resolver** — it is a claim made
   by a machine over an unauthenticated UDP hop, and anyone who can
   spoof the answer can spoof the bit. Every verdict says who made the
   claim, and a host check asserts that it does: a reader who takes
   "validated" for "validated by novi-recon" has been told something
   false by a tool whose job is not lying to them.
3. ~~**`/etc/services`**, so `ports` can name what it finds.~~
   **Done.** `rootfs/etc/services` is base content, installed by
   `03-base.sh`, 77 entries. Curated rather than IANA's ~14,000-line
   registry, on the same argument `kernel/config-x86_64` makes about
   Kconfig: a list somebody chose beats a list nobody has read.
   Three things it turned out to be about, none of which are the
   naming:

   - **A PORT NAME IS NOT A POLICY.** Shipping the table is the moment
     `tcp dport ssh` starts working in `nft`, and RFC 0022's rule is
     that `/etc/novi/firewall.nft` names ports as NUMBERS — a rule
     that resolves through a name table means something different on
     a machine whose table differs. The rule could not be written
     wrong before because there was no table;
     `packages/tests/test-services.sh` enforces it now.
   - **musl's parser has two silent limits**, read out of
     `src/network/lookup_serv.c` and `src/network/getnameinfo.c`
     rather than assumed. Both readers use `fgets(line, 128, f)`, so a
     line of 128 bytes or more is split and its tail parsed as a
     record of its own; and `reverse_services()` skips any entry whose
     name is 32 bytes or longer, so an over-long name resolves by NAME
     and stops resolving by PORT — half-working, in the direction
     nobody would test. The host test asserts both against the shipped
     file.
   - **Every failure here looks like the feature working.** musl does
     not report a malformed line, a duplicate or an over-long name; it
     skips and hands back a number, which is exactly what `ports`
     prints for the hundreds of ports that genuinely have no name.
     That is why a data file with no code in it got a test with 823
     checks, and why each of them was provoked by breaking the file on
     purpose and watching it fire.

   **Aliases resolve one way**, which is worth knowing before adding
   an entry: the forward lookup searches the whole line, so
   `getservbyname("www")` finds `http`; the reverse copies the first
   field only, so `getservbyport(80)` is always `http`. Put the name
   you want printed first.

   A port that is not in the table still prints as a number, and that
   is the right answer rather than a gap — inventing a name for a port
   nobody registered would be the tool guessing.
4. ~~**Certificate transparency and chain listing** in `tls` — the leaf
   is there, the intermediates are not.~~ **Done, and the two halves
   turned out to be different problems.**

   **The chain was never a gap in this tool** — `getpeercert()` decodes
   the leaf and nothing else, so "the intermediates are not there" is
   all the public `ssl` API offers. They are reachable, on
   `_ssl._SSLSocket.get_verified_chain()`, which was undocumented until
   CPython 3.13. `tls` now lists every certificate the server sent,
   leaf first, with subject, issuer, validity, serial and SHA-256, and
   marks a self-signed one.

   **Reaching through `_sslobj` is the risk, so it degrades rather than
   crashes.** Every step is behind a `getattr`: a Python without the
   getter, or a getter that raises, produces `chain: null` and a line
   saying why. A recon tool that died three checks into a sweep because
   a private attribute moved would be worse than one that never listed
   the chain.

   **A FAILED VERIFICATION IS WHERE A READER MOST WANTS THE CHAIN, AND
   IT IS THE ONE PLACE THIS CANNOT PRODUCE IT.** The handshake that
   failed left no connection to ask, so reading it means connecting
   again — which is what `-k` does, and the `-k` path does list it,
   from `get_unverified_chain()`. Found on a booted machine, where the
   guest does not trust this network's CA: the chain section was simply
   absent and `ct` printed the bare word *"unknown"*. Both say why now,
   and name the flag that would get an answer. A report that silently
   omits the interesting half reads as a tool that found nothing.

   **That same test found a crash.** `cmd_tls` read `e.verify_message`
   unguarded, and OpenSSL's own raise is the only thing that sets it —
   so an `SSLCertVerificationError` reaching there re-raised or wrapped
   would turn a *reported* verification failure into an AttributeError
   traceback, inside a sweep. It is a `getattr` now. The bug was
   invisible until a host test raised the exception directly, because
   every live failure came from OpenSSL and carried the attribute.

   **CT could not be done the same way, because `get_info()` returns no
   extensions.** Checked rather than assumed: `ssl` exposes no CT
   option and `_ssl` no SCT attribute of any kind. Embedded SCTs live
   in extension OID `1.3.6.1.4.1.11129.2.4.2`, so reporting them at all
   means walking the certificate's DER — which this tool now does, and
   three things about that are load-bearing:

   - **IT IS A PARSE, NOT A SEARCH.** Finding the OID's bytes somewhere
     inside a certificate would be a heuristic wearing a fact's
     clothes: the sequence can occur inside a key or a serial, and a
     tool whose value is not lying to you does not get to answer
     "unlikely". The walk goes Certificate → TBSCertificate → `[3]`
     extensions → the matching Extension, and finds nothing anywhere
     else. The host test drives exactly that: a certificate whose
     **serial number contains the OID bytes** must report no SCTs, and
     the same bytes as a real extension must still count.
   - **IT IS FOR DISPLAY, NEVER FOR TRUST.** OpenSSL decided whether
     the chain verifies before any of this runs, and nothing here votes
     on that. A hand-written parser in the trust path is the thing
     `novi-verify` being static TweetNaCl exists to avoid.
   - **PRESENCE IS NOT VALIDITY, and the line says so every run.** An
     SCT is a log's signed promise; checking one needs that log's
     public key and an inclusion proof, and this tool holds none. Same
     rule as the DNSSEC verdict, for the same reason — and `None` is
     deliberately not `0`, because "no CT extension" and "a CT
     extension holding an empty list" are different things a CA did.

   **Five of the first draft's malformed-input checks could not fail.**
   They asserted `count_scts(junk) is None` — which is also what a
   parser with its bounds checks deleted returns, because the damage
   surfaces as a `DERError` that `count_scts` swallows. Found by
   deleting each guard in turn and watching the suite stay green. They
   test `der_tlv` directly now, and assert the **wording**: a truncated
   length and an indefinite one are both caught further down by
   "length runs past the end", so a type-only check stays green when
   the specific guard goes. Two more were the same shape — the
   not-a-SEQUENCE payload died one step later on a truncated tag
   whether or not the tag check existed, and the bad-total SCT list
   needed **well-formed** trailing bytes before removing the
   total-length check changed the answer.

   Verified two ways. The synthetic certificates are built and parsed
   back, like the DNS messages. And the extension walk was cross-checked
   against **OpenSSL's own parser** on three real certificates: same
   OIDs, every time. (The first version of that comparison reported a
   mismatch on all three — its regex for reading OpenSSL's output
   dropped every `: critical` header. The probe was broken, not the
   code, for the second time in this feature.)

   **What is NOT verified is the SCT list framing against a real
   CT-logged certificate.** Every TLS endpoint reachable from this
   build environment is re-issued by an egress proxy that strips SCTs,
   so the count has only ever been exercised against lists this
   repository built. The extension-finding half is cross-checked
   against OpenSSL; the list-walking half is not.
