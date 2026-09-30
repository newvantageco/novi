# What running a glibc binary here actually costs

`PLATFORM-ROADMAP.md` §2 proposes an OCI/Flatpak-compatible bundle tier
*"so upstream glibc-built apps run without every app needing a musl
port"*, §11 calls it **the actual unlock**, and rows 6, 7, 9 and 12 of
the status table all wait on it. Before writing that RFC: the question
RFC 0040 roadmap 3 asked about util-linux, and the one RFC 0031 should
have asked about the browser. **A number, not an opinion.**

`bash probe.sh` — needs root, a glibc build host and a built
`/build/rootfs`. No VM: it chroots into the shipped musl rootfs, which
is RFC 0018's rule about testing the artifact rather than the idea.

## The item states one problem and it is two

An ELF names its own interpreter in `PT_INTERP`, so a glibc binary and
a musl binary **never share a loader — they cannot, by construction**.
That splits §2 into two problems it states as one:

| | |
|---|---|
| **Execution** | can a glibc binary run on this machine at all? |
| **Distribution** | where does the bundle come from, who signed it, how is it updated, what may it touch? |

Only the first is measurable here, and it is the one the item's framing
assumes is hard.

## Measured: 11 checks, 0 failures

| | |
|---|---|
| glibc interpreter | `/lib64/ld-linux-x86-64.so.2` |
| musl interpreter | `/lib/ld-musl-x86_64.so.1` |
| `/lib64` in the shipped rootfs | **does not exist** — the path is free |
| static musl busybox | runs |
| **dynamic musl** binary | runs |
| **dynamic glibc** binary | **runs — no container, no OCI, no shim** |
| glibc `getpwnam` with no `nsswitch.conf`, no `libnss_*.so` | **works** |
| glibc hosts-file resolution | works |
| glibc real DNS (`example.com`) | resolved |
| C++ and threads (`libstdc++`, `libgcc_s`, `libm`) | run |
| the `C` locale | works |
| a real locale (`en_US.UTF-8`) | **`NULL`** — no `locale-archive` |

**Cost: 5.9 MB** — loader 231 KB, `libc.so.6` 2076 KB, `libm` 930 KB,
`libgcc_s` 179 KB, `libstdc++` 2532 KB.

## Why NSS was not the obstacle it is supposed to be

The classic reason this is called hard is that glibc `dlopen`s
`libnss_files.so.2` / `libnss_dns.so.2` at runtime and refuses a
version mismatch. It did not happen here, and the reason is checkable
rather than lucky: **`libc.so.6` exports 83 `_nss_files_*`/`_nss_dns_*`
symbols.** glibc merged those two backends *into* libc, so the
version-matched modules this is supposed to need are not needed. The
separate `libnss_files.so.2` still on a Debian host is a compat stub.

## The control is what makes the rest mean anything

The same binary, in the same chroot, with **no glibc runtime staged**,
is refused. Without that line a pass proves only that something
somewhere could run it. This is the repository's own standing rule and
it is the first thing the probe does.

## What this does NOT say

- **A `printf` is not a desktop app.** A real one needs GTK or Qt,
  dbus, fontconfig, a theme — all glibc-built. That is *bundle
  contents*: the same mechanism, more megabytes. This measures whether
  the mechanism works, not how big a real bundle is.
- **Nothing here is about confinement.** RFC 0039's `novi-sandbox` is
  that, it already exists, and it is *not* §2's tier — see the status
  table's row 2.
- **Nothing here is about distribution**, which is most of what an
  OCI/Flatpak tier is actually for, and which stands untouched.
- **Locale is a real gap**, bounded and known: a program that calls
  `setlocale(LC_ALL, "")` and depends on the result needs
  `locale-archive` shipped with it.
- **Measured in a chroot on the build host**, not on a booted Novi.
  The musl side is this repo's own shipped rootfs and binaries; the
  kernel is the host's, not Novi's. The loader needs only ordinary
  syscalls, and §2's kernel prerequisites are all present in the
  generated config (below), but the end-to-end run on Novi's own
  kernel has not been done.

## The kernel was ready already

From the **generated** `.config`, not the curated file — CLAUDE.md's
rule about answering from a ~280-option subset:

`CGROUPS`, `CGROUP_FREEZER`, `CGROUP_PIDS`, `CGROUP_DEVICE`, `MEMCG`,
`CPUSETS`, `CGROUP_SCHED`, `BLK_CGROUP`, `OVERLAY_FS`, `NAMESPACES`,
`USER_NS`, `PID_NS`, `NET_NS`, `UTS_NS`, `SECCOMP`, `SECCOMP_FILTER`,
`SQUASHFS`, `FUSE_FS` — all `=y`; `VETH`, `BRIDGE`, `NF_NAT` as
modules. Only `IPC_NS` is absent, which RFC 0039 already recorded and
explained (`CONFIG_SYSVIPC` is deliberately off).

So a container runtime's kernel prerequisites have been in this image
since its config was written — the same finding RFC 0039 made about
namespaces and RFC 0031 made about the browser's dependencies. **Third
time a blocking claim in this repository turned out to be a true
statement about something else.**

## Four probe bugs, and they are the usual ones

1. **`cp -a` on the glibc loader copies a dangling symlink.** On Debian
   `/lib64/ld-linux-x86-64.so.2` points into a directory the chroot does
   not have. The symptom is `chroot: failed to run command: No such file
   or directory` about a binary that is plainly there — it is the
   *interpreter* that is missing and nothing says so. `cp -L`.
2. **Direct `NEEDED` is not the closure.** The musl binary died on its
   grandchild library; `libstdc++` then died on `libm`. `ldd` reports
   the resolved set.
3. **`find -printf '%d'` is DEPTH, not size** — the size table printed
   `3 KB` for a 2 MB library, and the total beside it was right, so
   nothing looked wrong.
4. The first `hello.c` referenced a function it had not declared and
   would not have compiled.

Which is the ninth, tenth, eleventh and twelfth time in this repository
that the probe rather than the thing probed was the broken part.
