# RFC 0007: Splitting the Desktop Out of the Base Image

- **Status:** Draft. Implemented and QEMU-verified; see "Verification".
- **Labels:** `rfc`
- **Author:** platform readiness work (`docs/PLATFORM-ROADMAP.md` §17)
- **Requires:** RFC per `CONTRIBUTING.md` — this changes what the base
  image contains, adds an install profile, and adds a boot path.

---

## Motivation & Problem Statement

§2 of the platform roadmap describes a small native base with everything
else delivered as packages. RFC 0006 built the repository. What it did
not do was take anything *out* of the base: the desktop was in the image
**and** in the repository, which is the architecture described rather
than the one shipped.

That is not a cosmetic gap. A console-only machine — a server, a build
host, a router, the thing a "small native base" is for — was carrying a
Wayland compositor, wlroots, libdrm, pixman, fontconfig, freetype, a
font family and a terminal emulator it would never run. And the package
system, having nothing load-bearing to carry, was decoration.

## Proposed Design

### The file set is computed, not listed

`tools/pkgsplit/pkgsplit.py` works out what leaves from the only thing
that cannot lie about it — the ELF dependency graph:

```
desktop = closure(NEEDED) from the desktop binaries
keep    = closure(NEEDED) from everything else that ships
move    = desktop - keep
```

then **fails the build** if anything left in `keep` links against
anything in `move`. That turns "I think this is safe" into "the build
stops if it isn't".

A hand-written list is how a split rots: someone adds a library in
`build/06-wayland.sh`, nobody updates the list, and the "console-only"
image quietly grows a Wayland stack again.

Inter-package dependencies are computed the same way — every `NEEDED`
soname mapped back to its owning package. `wlroots depends on
libdisplay-info, libdrm, libinput, libudev, libxkbcommon, pixman, seatd,
wayland` is read out of the binaries, not typed in and not maintained.

### …but the graph is not the only input

The closure cannot see `dlopen`. libdrm loads `libdrm_amdgpu`,
`libdrm_nouveau` and `libdrm_radeon` by name at runtime, and
`libwayland-egl` is linked by GL clients that do not exist yet — so
nothing `NEEDED` any of the four, and the first split left all of them
sitting in a "console-only" base. Found by looking at what was actually
left behind, not by reasoning about it.

So there are two inputs, with different jobs: **the graph finds what is
reachable; `PACKAGE_TABLE` claims what is ours.** Anything the table
claims, that lives in a library directory, and that nothing staying
behind needs, moves too. A library the base genuinely uses is still
protected — it is in `keep`, and the safety check fails the build.

A file that matches no pattern is a hard error rather than a guess.
Silently dropping a library into the wrong package produces an image
that installs cleanly and fails at runtime, which is the worst of both.

### What that turned up

The base image was carrying **build-time tooling** that `make install`
had dropped into it: `fc-cache`, `fc-list`, `fc-match` and the rest of
fontconfig's utilities, `libinput`, `mtdev-test`, `di-edid-decode`,
`xmlwf`, `wayland-scanner`. While those sat in `/usr/bin` they counted
as part of the base, so every library they needed — fontconfig,
freetype, libinput, libudev, libevdev, libmtdev, expat,
libdisplay-info — counted as "needed by the base" and could never move.

**Eight libraries were being held in a console image by eight programs
nobody would ever run on one.** The split only became possible once
those were named as desktop-side too.

After the split, `/usr/lib` in the base image contains exactly one
library: `libskarnet`, which the s6 stack needs. Everything else is a
package.

### The medium carries the repository

`scripts/mkiso.sh` copies the whole signed repository onto the ISO at
`/novi-repo`, and the shipped `pkg.conf` points at
`/run/live/novi-repo`. `pkg` treats a mirror that starts with `/` (or
`file://`) as a local directory and copies instead of fetching.

That is what makes "console-only base" not mean "desktop requires a
network". The same index signature and the same per-package SHA-256 are
checked either way; only the transport differs.

`mkiso.sh` also refuses to build if it finds a `.key` or `.pem` inside
the repository directory. The private signing key lives in
`${BUILD_DIR}/keys` and never there — but shipping one on an ISO is the
kind of mistake that cannot be taken back once published, so it is
checked rather than trusted.

### `novi-install --profile desktop|console`

Default is **desktop**. The medium has the packages, and an installer
that leaves an everyday user at a console by default is answering the
wrong question.

The install runs **inside the target**, in a chroot, against a bind
mount of the repository — not with `pkg`'s `PKG_ROOT`. `PKG_ROOT`
relocates where *files* land but not the install database, so a
`PKG_ROOT` install would put the desktop on the target and record it in
the *live* system's database: an installed machine that does not know
what it has.

Then it declares what it did — `packages.novi-desktop = present`,
`services.seatd = on`, `services.novi-shell = on` — through
`novi-state set` against the target's document, so a fresh install boots
into a graphical session *and* reports `novi-state diff` clean rather
than showing drift about software it already has.

`--mirror URL` sets the installed machine's mirror. Without one, the
installer **comments the mirror line out**, because the shipped value
points at the installation medium and that path will not exist once the
medium is removed. Leaving it would give every installed machine a
`pkg sync` that fails with a confusing error about a directory nobody
chose.

### The live ISO still shows a desktop

A live ISO that can only show a console would be a real regression. The
"Live Desktop" menu entry passes `novi.live.desktop`, and `rc.init`
runs `novi-live-desktop`: `pkg sync` and `pkg install novi-desktop`
from the medium, into the tmpfs overlay, then `novi-state boot`.

It takes a few seconds and it is the package system demonstrating
itself rather than being described. Every failure in that helper is a
message and `exit 0` — a live session that could not fetch a desktop
should still reach a login prompt.

### The service definitions stay in the base

`seatd`, `novi-shell` and the `graphical` bundle remain in the compiled
s6-rc database even though their binaries do not. They are text, they
cost nothing, and a machine that installs `novi-desktop` should be able
to `novi-state set services.novi-shell on` without also needing a new
service database. s6-rc does not check that a run script's binary
exists, so a declared-off service pointing at a not-yet-installed
binary is inert, not broken.

## Alternatives Considered

**Two squashfs images, console and desktop.** Doubles the build, and
the ISO would carry both. A base plus a package pool is smaller and is
the mechanism the project already has.

**Keep the desktop in the live image, split only on install.** The live
image is the image; a split that does not apply to it is not a split.
It would also mean the live and installed systems differ in what they
contain, which is exactly the kind of divergence that makes bugs
un-reproducible.

**Persist the live overlay instead of installing.** Covered and
rejected in RFC 0003 for the same reason: two overlapping notions of
"what changed".

## Implementation status

- `tools/pkgsplit/pkgsplit.py` — the computed split, package
  assignment, dependency derivation, safety check
- `build/20-repo.sh` — rewritten to drive it
- `build/21-desktop-split.sh` — removes exactly the files 20 packaged,
  from the manifest 20 wrote (one source of truth, or the two drift)
- `build/22-live-desktop.sh`, `rootfs/usr/bin/novi-live-desktop`
- `scripts/mkiso.sh` — stages the repository, adds the Live Desktop
  entry, refuses to ship key material
- `packages/pkg` — local-directory mirrors
- `packages/novi-install` — `--profile`, `--mirror`
- `init/skel/rc.init` — the live-desktop hook
- `rootfs/etc/novi/pkg.conf` — `mirror = /run/live/novi-repo`

25 packages, 165 files, 8 MB out of the base image.

## Verification

QEMU, `-machine pc`, serial console, `virtio-gpu-pci` for the
graphical checks.

- **The base is console-only.** `/usr/bin/novi-shell`, `/usr/bin/foot`
  and `/usr/lib/libwlroots*` are absent from a booted live system, and
  `/usr/lib` contains exactly `libskarnet`.
- **The desktop installs from the medium with no network.** With one
  IPv4 address on the machine (loopback), `pkg sync` verified the index
  signature off `/run/live/novi-repo` and `pkg install novi-desktop`
  resolved and installed **25 packages in 6.8 seconds**, restoring
  `novi-shell`, `foot`, `libwlroots-0.18.so` and the fonts.
  `novi-state diff` clean afterwards.
- **A live desktop boot works end to end.** `novi.live.desktop` on the
  command line; the helper announced itself on the console, installed
  the desktop during boot, and `novi-shell` was running under
  `s6-supervise` with `s6-rc -a list` showing `novi-shell seatd` up and
  `novi-state diff` clean.
- **`novi-install --profile desktop` produces a machine that boots
  graphical.** Installed onto a blank disk from a live boot whose own
  base had no `novi-shell`, then cold-booted from that disk with the ISO
  detached: `novi-desk`, `/dev/vda1` mounted rw, 25 packages installed,
  `novi-shell` running against `/dev/dri/card0`, `novi-state diff`
  clean, `alice` present with her declared groups, and the mirror line
  correctly commented out.
- **The frame is a real compositor frame, not a text console.** The
  screendump came back **1280x800** — a DRM mode the compositor set, not
  the 720x400 VGA text mode — with a ~30-pixel band of `(24, 24, 32)`
  across the full width (the panel) carrying anti-aliased glyph pixels,
  over a black desktop. Confirming that took `-vga none`: with
  `-machine pc` QEMU adds a std VGA device alongside `virtio-gpu-pci`,
  `screendump` defaults to device 0, and the first attempt dutifully
  photographed the empty text console while the compositor rendered to
  the other one.

## Roadmap

- **A console ISO and a desktop ISO as separate downloads.** The split
  makes them possible; right now one ISO carries both paths.
- **`pkg` should know about dlopen.** The `PACKAGE_TABLE` sweep covers
  it today because the table names those libraries. A package format
  field for "loads these at runtime" would be better than a build-host
  table.
- **Split further.** `novi-shell` still pulls the whole wlroots stack;
  a machine that wants only `foot` under someone else's compositor
  should not need it. That is a packaging question, not a new
  mechanism.
- **Version constraints and upgrades across the split.** `pkg update`
  still compares against local archives rather than the index.
