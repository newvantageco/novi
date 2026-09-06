# RFC 0020 — HTTPS, and who gets to say who a server is

**Status:** Implemented
**Depends on:** RFC 0006 (packages), RFC 0019 (git and ssh)

> **Summary.** Three RFCs in a row have stopped at the same wall.
> RFC 0009 could not do WPA3, RFC 0019 could not do `git clone
> https://`, and RFC 0006 fetches packages over plain HTTP. Each named
> the same missing piece and each declined to add it as a side effect
> of something else. This is that decision, made on its own: **mbedTLS
> and curl, as packages**, and a hash-pinned Mozilla CA bundle.

## Motivation & Problem Statement

`pkg install git` gives you a git that cannot clone the URL every forge
puts in the copy box. That is the immediate cost. The underlying one is
that this system has no way to establish that it is talking to the
server it meant to talk to, for any purpose at all.

The reason it has been avoided is good and still holds: RFC 0006 built
`novi-verify`, a 10 KB static Ed25519 verifier, specifically so that
*verifying a package* would not mean linking OpenSSL, and RFC 0009
built wpa_supplicant with internal TLS for the same reason. A TLS stack
in the **base image** is a large permanent attack surface for a
console-only system that has no use for it.

The resolution is that this does not have to be in the base image.

## Proposed Design

### Packages, and the base image does not change

```
pkg install git          # now pulls curl, mbedtls and ca-certificates
```

`mbedtls`, `curl` and `ca-certificates` are three new packages.
Nothing is added to the console base: a machine that never installs
them has exactly the attack surface it had yesterday, and `pkg`'s own
trust chain still rests on an Ed25519 signature over the index rather
than on transport security (RFC 0006), which is why it needs none of
this.

### mbedTLS, and a correction to RFC 0009

mbedTLS 3.6.2 (LTS), dual Apache-2.0 / GPL-2.0-or-later, so it is
clean under this project's own GPLv2.

**RFC 0009 said mbedTLS was "the named way in" to WPA3. That is wrong
for the wpa_supplicant this project ships**, and the correction
belongs here because this is the RFC that went looking.
wpa_supplicant 2.11's `Makefile` offers `CONFIG_TLS` values of
`openssl`, `gnutls`, `wolfssl`, `internal`, `linux` and `none`. There
is no mbedTLS backend anywhere in the tree — `grep -rli mbedtls` over
the whole tarball returns nothing.

So WPA3 needs one of: **wolfSSL** (which does have a backend, and is
GPL-2.0, hence compatible), a newer hostap than 2.11, or a backport of
the out-of-tree `crypto_mbedtls.c`. That is a separate decision with a
separate library and it stays out of this RFC — but it is no longer
blocked on "we have no TLS library", it is blocked on picking the
right one for that job.

### curl, and what is switched off

curl 8.11.1 with `--with-mbedtls` and everything else this image has no
use for disabled: no libssh2, no libidn2, no zstd, no brotli, no
libpsl, no LDAP, and only the protocols git actually asks for. A
smaller curl is a smaller thing to be wrong.

### The certificate authorities

This is the part worth arguing about, because it is the only new
*trust* decision here.

`ca-certificates` ships Mozilla's root store, as curl.se publishes it —
143 certificates, 223 KB, at `/etc/ssl/certs/ca-certificates.crt`.

It is **hash-pinned in `01-fetch.sh`**, and it is only the second thing
in this project that is. The first is TweetNaCl, because it verifies
package signatures. The argument is identical: a CA bundle is a list of
parties whose word is accepted about who a server is, so if it arrives
modified, every HTTPS connection this system makes is validated
against a set somebody else chose. Pinning requires fetching a *dated*
file rather than the rolling `cacert.pem`, which is also what makes the
build reproducible.

Trusting 143 organisations is the deal the web makes, and it is worth
saying plainly rather than shipping silently: any one of them can
issue a certificate for any name. Novi does not improve on that and
does not pretend to. What it does is make the set explicit, versioned,
and a package you can decline to install.

### git, again

`35-devtools.sh` drops `NO_CURL=1` and git gains `git-remote-https`.
`git` now depends on `curl`, which depends on `mbedtls` and
`ca-certificates`. RFC 0019's package README stops being true and is
rewritten.

## What this is not

- **Not TLS in the base image.** `pkg` still fetches over whatever the
  mirror speaks and still trusts only the signature. Making `pkg` use
  HTTPS would put curl in the base to gain confidentiality about which
  packages you install — a real but secondary property, and its own
  decision.
- **Not WPA3.** See the correction above.
- **Not a system-wide TLS policy**, certificate pinning, OCSP, or CT.
- **Not `update-ca-certificates`.** The bundle is a file in a package;
  replacing it is `pkg update`. A local-additions directory is
  roadmap.

## Verification

Live, in a booted VM, against two HTTPS servers on the host: one with a
certificate signed by a test CA, one self-signed for the same name.
**The test that matters is not that HTTPS works — it is that HTTPS
fails when it should, and that the failure is verification rather than
anything else.** A single "it worked" cannot tell those apart, so it is
a triple:

1. **The chain installs.** `pkg install git` resolves and installs
   `zlib`, `openssh`, `mbedtls`, `ca-certificates`, `curl`, `git`.
   `curl --version` →
   `curl 8.11.1 (x86_64-pc-linux-musl) libcurl/8.11.1 mbedTLS/3.6.2 zlib/1.3.1`,
   and the bundle has 143 certificates in it.
2. **A certificate that chains to nothing in the bundle is refused:**
   `fatal: unable to access 'https://10.0.2.2:8443/repo.git/':
   mbedTLS: The certificate is not correctly signed by the trusted CA`.
3. **Append that CA to the bundle and the same clone succeeds** —
   `c88c3da (HEAD -> main, origin/main) hello from https`, a real
   commit fetched over TLS. This is what proves step 2 was
   verification doing its job rather than the server being
   unreachable.
4. **A self-signed certificate for the same name is still refused**,
   with the CA from step 3 trusted — so it is chain validation, not
   "any certificate presenting the right name".
5. `curl` on its own: `http=200`, and `info/refs` comes back with the
   ref — a failure can be attributed to curl or to git rather than to
   "the network".

Not verified: a **public** HTTPS host against the real Mozilla bundle.
This container has no outbound egress from the guest (`http=000` to
curl.se), so the 143 shipped roots are exercised only by the code path,
not by a certificate any of them signed. Everything above uses a CA
appended at runtime.
