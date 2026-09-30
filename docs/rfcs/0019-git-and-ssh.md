# RFC 0019 — A compiler with nothing to compile

**Status:** Implemented
**Depends on:** RFC 0006 (packages), RFC 0015 (native toolchain)

> **Summary.** RFC 0015 put gcc, binutils, make and the musl headers on
> a running Novi. It stopped one step short of usefulness: there is no
> way to *get* source onto the machine. This adds `git` and an ssh
> client, as packages, and OpenSSH is built **without OpenSSL** —
> which is the only reason it is allowed in this image at all.

## Motivation & Problem Statement

`pkg install novi-devel` gives you a compiler and an editor and no way
to fetch anything to point them at. The honest description of a Novi
developer machine today is "you can compile what is already on the
disk", and the only thing on the disk is Novi.

That is the gap. It is also the last one that can be closed without
arguing about a TLS stack — see "What this is not".

## Proposed Design

### Two packages, never base

```
pkg install git         # git, and openssh as a dependency
pkg install openssh     # the client on its own
```

Neither goes in the base image. The base is console-only and stays
that way (RFC 0007); these follow the same rule the toolchain does
(RFC 0015) — built once by a cross stage, staged, and published into
the signed repository by a 50+ stage, because `50-repo.sh` wipes and
recreates the repository and anything adding to it has to run after.

`git` depends on `openssh` and `zlib`. That dependency is real rather
than tidy: without an ssh client, `git clone` can reach nothing.

### OpenSSH without OpenSSL

`--without-openssl`. This project has refused to carry a TLS stack
since RFC 0006 — `novi-verify` exists, all ~10 KB of it, precisely so
that verifying a signature does not mean linking OpenSSL — and RFC
0009 built wpa_supplicant with `CONFIG_TLS=internal` for the same
reason. An ssh client that dragged in libcrypto would undo both.

What that costs is real and worth stating: **ed25519 keys only.** No
RSA, no ECDSA, no DSA, no certificates, no FIDO tokens, no PKCS#11.
The ciphers are chacha20-poly1305 and the internal AES-CTR set; key
exchange is curve25519-sha256.

For a machine created in 2026 that is not a hardship — ed25519 is what
anyone setting up a new key should be generating anyway, and every
forge accepts it. For a machine that has to reach an old server with
an RSA-only host key, it is a wall. Say so rather than discovering it.

**Client only.** `ssh`, `scp`, `sftp`, `ssh-keygen`, `ssh-add`,
`ssh-agent`, `ssh-keyscan`. No `sshd`: a listening service needs host
key generation, a privilege-separation user, an s6 service, a
`services.sshd` key, and a hole in the firewall RFC 0016 just closed —
five decisions, each of which deserves to be made deliberately rather
than as a side effect of wanting `git clone` to work. That is its own
RFC.

`sshd` *is* built, into `/build/ssh-test/`, and never installed. It is
the test peer: a client that has not talked to a server is an
assertion, and `git clone ssh://` cannot be verified without something
listening. Same bargain `25-wifi.sh` makes with hostapd (RFC 0009) —
a test dependency in the shipped image is a worse trade than an
untested feature — and it is delivered to the VM on a separate disk.

Building it turned up something worth knowing: **OpenSSH 9.8 split the
daemon.** `sshd` is now only the listener and execs `sshd-session` for
each connection, from a compiled-in `/usr/libexec` path. `make sshd`
alone produces a daemon that starts, binds, accepts a connection and
dies with "sshd-session does not exist or is not executable".

### Git without curl

> **Superseded by RFC 0020.** git now has curl, mbedTLS and a CA
> bundle, all as packages, and `https://` remotes work. The reasoning
> below is why it was left out here rather than done badly as a side
> effect — the decision it defers is the one RFC 0020 makes.

`NO_CURL=1 NO_OPENSSL=1 NO_EXPAT=1`, plus `NO_PERL`, `NO_PYTHON`,
`NO_TCLTK` and `NO_GETTEXT` for things that would need interpreters
this image does not have.

So: `git clone git@host:repo`, `ssh://`, and every local operation.
**Not `https://`** — that needs curl, which needs a TLS stack, which
is the argument above. `git` prints a clear "Unable to find remote
helper for 'https'" rather than failing obscurely, and the package's
README says which URL form to use.

Git's own SHA-1 comes from its bundled `block-sha1` and its
collision-detecting variant, which is what upstream uses when built
without OpenSSL — not a downgrade.

## What this is not

- **Not HTTPS.** Both gaps above are the same gap. Closing it means a
  TLS library, and the honest candidate is **mbedTLS**, which RFC 0009
  already named as the way to WPA3. One library would then serve
  three things: WPA3, `git clone https://`, and `pkg` over TLS. That
  is a decision worth making once, on its own, with its own RFC —
  not smuggled in behind a git package.
- **Not sshd.** See above.
- **Not `git send-email`, `git gui`, `gitk`, or the interactive add**
  — all need perl or tcl/tk.
- **Not a `packages.git = present` convergence key.** `packages.*`
  already exists (RFC 0006); nothing new is needed to declare these.

## Verification

Live, in a booted VM, because a git that has not cloned anything is an
assertion. Against a real sshd delivered on a second disk, built by the same
stage and never installed:

1. **The package chain.** `pkg sync` against the ISO's repository —
   "signature on the repository index verified", 39 packages — then
   `pkg install git` resolves and installs `zlib`, `openssh` and
   `git`, in that order, each with "sha256 verified".
2. **No OpenSSL, and it says so.** `ssh -V` →
   `OpenSSH_9.9p2, without OpenSSL`. `ssh -Q cipher` →
   `aes128-ctr aes192-ctr aes256-ctr chacha20-poly1305@openssh.com`.
   `ssh -Q key` → the four ed25519 forms and nothing else.
   `ssh-keygen -t ed25519` makes a key; `ssh-keygen -t rsa` →
   `unknown key type rsa`, which is the honest answer.
3. **A local repository, including a real merge.** init, add, commit,
   branch, a divergent commit on each side, `merge --no-ff` →
   "Merge made by the 'ort' strategy" and a `--graph` log with the
   fork and the join in it.
4. **Clone and push over `ssh://`.** `ssh -p 2222 root@127.0.0.1`
   authenticates with the ed25519 key and runs a command;
   `git clone ssh://root@127.0.0.1:2222/tmp/r` brings across the whole
   history, merge commit included; a commit made in the clone and
   `git push`ed lands in the origin repository, confirmed by
   `git log` there.
5. **HTTPS fails legibly.** `git clone https://…` →
   `git: 'remote-https' is not a git command` and
   `fatal: remote helper 'https' aborted session`. Not a crash, and
   the package README says why.
