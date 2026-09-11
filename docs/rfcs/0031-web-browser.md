# RFC 0031 — a web browser, and the stage range that ran out

**Status:** Implemented
**Depends on:** RFC 0007 (base/desktop split), RFC 0020 (HTTPS), RFC 0025 (Mesa), RFC 0027 (OpenSSL)

> **Summary.** `pkg install netsurf` puts NetSurf 3.11 on a Novi
> desktop: HTML and CSS, real HTTPS, no JavaScript. It is a package,
> never base. The one patch this needs is a port of libnsfb's Wayland
> surface from `wl_shell` — dead since 2016 — to xdg-shell, without
> which the browser starts, finds no shell global, and shows nothing.

## Motivation & Problem Statement

This desktop could open a terminal, a text editor, a file manager, an
image viewer, a settings window and a shortcut sheet. It could not open
a web page. For most people that is not one missing application among
several — it is the application, and its absence is the difference
between a desktop somebody could use for an afternoon and one they
could not.

The constraint that makes this hard is the same one that makes the rest
of Novi what it is. A modern browser engine is the largest C++ program
most distributions ship; Chromium wants its own build system, its own
toolchain assumptions, a GPU stack, and more build machine than this
whole project uses. RFC 0025 already recorded that this image has EGL
and GLESv2 and **no desktop `libGL`**, and that `-Dglx=disabled` is not
a gap to be closed but a consequence of never having had X.

So the question was never "which browser" in the abstract. It was
whether any browser at all could be built here as it stands.

## Decisions

### 1. NetSurf, and the arithmetic behind that.

NetSurf is C, builds with make, has its own layout engine and CSS
implementation, and its dependencies are thirteen small libraries the
same project maintains. Nothing in it wants a GPU, a JIT, or a C++
toolchain.

Every external library it needs was **already in this image**, and two
of them only because earlier RFCs put them there: curl and OpenSSL are
RFC 0020's and RFC 0027's, libpng and zlib are RFC 0007's, expat and
libwayland are the desktop's. That is the whole reason this was a
week's work rather than a subsystem — the browser is the first thing
built here that needed nothing new.

### 2. No JavaScript, and that is stated rather than discovered.

`NETSURF_USE_DUKTAPE=NO`. NetSurf can embed Duktape, and turning it on
is one flag; it is off because a browser that runs *some* JavaScript
badly is harder to reason about than one that runs none. A page that
needs scripting fails the same way every time and says so, rather than
rendering half of itself.

**This must be said wherever the browser is described.** "Novi has a
web browser" and "Novi can open most of the modern web" are different
claims and only the first is true. Sites that render their content from
JavaScript — which is most large sites — will show an empty page or a
noscript notice. Static pages, documentation, RFCs, plain HTML: those
work.

### 3. The framebuffer frontend, over a Wayland surface.

NetSurf has GTK, Qt and framebuffer frontends. GTK and Qt are not
happening here. The framebuffer frontend draws its own widgets into a
buffer that libnsfb puts on a surface, and libnsfb has a Wayland
backend (`NETSURF_FB_FRONTEND=wld`).

It shipped first with `NETSURF_FB_FONTLIB=internal`, a compiled-in
bitmap face, which made the one window on this desktop that renders the
most text the one window not drawing it in Inter. That is fixed — see
decision 8.

### 4. The patch, and why the build fails without it.

`patches/netsurf-libnsfb-xdg-shell.patch` ports `libnsfb/src/surface/wld.c`
from `wl_shell` to xdg-shell.

`wl_shell` was deprecated in 2016 and replaced by `xdg_shell`. wlroots
never implemented it and neither does novi-shell, so upstream libnsfb
**cannot open a window on this desktop at all**: it binds a global that
is not advertised, gets NULL, and carries on. The browser starts, the
process runs, and nothing is ever visible.

That is the worst failure shape there is, so the build stage **refuses
to continue** if the patch stops applying rather than producing a
browser that cannot open a window — the same rule `23-e2fsprogs.sh`
applies to its musl patch.

The generated half — `xdg-shell-protocol.c` and `.h` from
`wayland-scanner` — is deliberately **not** in the patch file. It is ~88
KB of machine output; a diff of it is not something anyone can review,
and generating it at build time from the rootfs's own `xdg-shell.xml`
is a derived answer that cannot rot.

### 5. It is a package, and it is not base.

Same call as every other application: a console-only Novi has no
Wayland compositor, and a browser on it would be 6 MB of unreachable
code. `depends=` names curl, openssl, libpng, zlib, expat and wayland —
so installing it installs what it needs, and on a machine with no
desktop it plainly says what it wants.

### 6. This image now runs two TLS stacks in one process.

`netsurf-fb`'s `DT_NEEDED` names `libcurl.so`, `libssl.so` and
`libcrypto.so`. curl here is built against **mbedTLS** (RFC 0020) and
NetSurf links **OpenSSL** (RFC 0027) directly, for certificate-chain
inspection — so a single process carries both.

That is not a rule being broken. RFC 0020's rule is about the **base
image**, which still ships no TLS library at all, and RFC 0006's is
about the **trust path**, where `novi-verify` is still static TweetNaCl
and reaches neither. This project has now had to recover that precise
reading four times (RFC 0021, RFC 0026, RFC 0027, here); the vague
version of the rule would have blocked every one of them.

It is still worth stating plainly: **network traffic from this browser
is validated by two independent implementations depending on which
component made the request**, and only one of them (curl's) has ever
been exercised by this project's HTTPS verification triple.

### 7. Where the stage goes, and the renumber that is now due.

The build phase lives in `35-devtools.sh`, not `build/44-netsurf.sh`,
and the reason is a constraint with no remaining slack.

It **reads** `${ROOTFS}` — wayland, libpng, zlib and expat headers —
which `51-desktop-split.sh` removes, so it must run before 51. It
**publishes** into a repository `50-repo.sh` wipes, so its package must
be written after 50. That is the "build early, publish late" split that
35, 38 and 39 already use.

CLAUDE.md records this trap biting twice, and both times the resolution
was to move the packaging stages up to make room. **This was the third
time and the room was gone: every number from 01 to 39 was taken**, so
the browser became a phase here rather than a stage of its own.

That renumber has since been done — the packaging stages are 50..53 and
**40–49 is free for content**. The browser stayed a phase of 35 because
moving it now would be churn for its own sake: its build-early /
publish-late constraint is real either way, and 35 is where it works.
A *new* content stage takes a number in 40–49.

### 8. The browser draws in this desktop's own faces.

`NETSURF_FB_FONTLIB=freetype`, `NETSURF_FB_FONTPATH` pointed at the
`fonts-inter` and `fonts-jetbrains-mono` directories, and each of the
ten `NETSURF_FB_FONT_*` faces named.

The first version of this RFC called wiring real type in "a bigger
change than this RFC". It is not: freetype is a fontlib upstream
already supports (`frontends/framebuffer/font_freetype.c`), and
freetype has been in this build since stage 06 for fcft — so this is a
new **link**, not a new dependency. `NETSURF_FB_FONTPATH` feeds
`respaths` in `gui.c` and `fb_new_face()` resolves each name through
`filepath_sfind()` against it, so the faces are plain filenames.

**Sans-serif bold is Inter SemiBold, not Bold.** SemiBold is what
`NOVI_FONT_TITLE` uses; matching the desktop beats matching the CSS
keyword.

**Italic came next, and it was not a nicety.** The first pass shipped
Regular/Medium/SemiBold — the three faces §2's type scale names,
because *nothing in this desktop's own UI is italic* — and a screendump
confirmed `<i>` rendering upright. But **a web page is not this UI.**
`<em>`, citations and titles are italic constantly, and with no italic
face every one of them rendered identically to body text: emphasis, the
entire point of the markup, was **invisible**. That is a correctness
problem in a browser rather than a matter of taste. `Inter-Italic.ttf`
and `Inter-SemiBoldItalic.ttf` were already inside the zip
`09-foot.sh` downloads, so it cost ~840 KB and two lines. SemiBoldItalic
to match the upright bold, for the same reason.

**There is a real serif now: Source Serif 4** (OFL-1.1, pinned at
4.004, its own `fonts-source-serif` package). `font-family: serif` and
the default serif of an unstyled page used to land on Inter — a sans,
silently, with nothing to say so, because every other face falls back
to the one below it and this one had nothing below it.

It is **not** a member of `novi-desktop`. Only NetSurf renders a serif,
so it rides on `netsurf`'s `depends=`: a desktop that never draws a web
page has no use for one, and shipping it anyway is the dead weight RFC
0007 says is not inert.

**Two faces, not four, and NetSurf decides that.** Its framebuffer
frontend has `NETSURF_FB_FONT_SERIF` and `NETSURF_FB_FONT_SERIF_BOLD`
and no italic option at all — checked in
`frontends/framebuffer/Makefile`, not assumed. So `<em>` inside a serif
paragraph renders upright, which is the frontend's limit rather than a
missing font, and installing an italic nothing can select would be
weight for nothing.

Cursive and fantasy still map to Inter. Only the sans-serif face is
fatal if missing (`font_freetype.c` returns false and the browser
exits); every other face falls back to the one below it, which is why
these gaps degrade rather than crash.

**Verified on a booted desktop**, on a page with one line each of
`font-family: serif`, serif bold, `sans-serif` and `monospace`: three
visibly different families, the serif with real bracket serifs and a
real bold rather than a synthesised one. `fonts-source-serif` arrived
as a dependency of `netsurf` without being asked for, which is the
derived `depends=` doing its job.

**All three families now ship their licence.** OFL-1.1 requires the
licence to travel with the font, and it was not travelling: Inter's
`LICENSE.txt` and JetBrains Mono's `OFL.txt` were sitting unread in
their zips. Source Serif forced the question, because its release asset
contains font files and nothing else — the text is fetched separately
and installed beside the faces, and the other two are fixed with it.

**`fonts-inter`, `fonts-jetbrains-mono` and `fonts-source-serif` are
named in `depends=` by hand, because nothing can derive them.** pkgsplit reads `DT_NEEDED`,
and a `.ttf` opened by path at runtime appears in no ELF header — the
same blind spot that hides libdrm's `dlopen`'d drivers (RFC 0007),
wearing a different costume. Without them the package installs, the
browser starts, fails to find its default font, and exits.

## What was verified

The stage was run from a **wiped** `/build/netsurf-build`, so what
follows is a reproducible build and not a warm tree: 2.7 MB staged, a
2,606,672-byte stripped `netsurf-fb`, and a `DT_NEEDED` list that is
musl only —

```
libexpat.so.1  libz.so.1  libcurl.so.4  libssl.so.3
libcrypto.so.3  libpng16.so.16  libwayland-client.so.0  libc.so
```

The packaging stages (then `40..43`, now `50..53`) then produced a
repository of **54 packages** (139 MB on the
ISO), `netsurf-3.11-x86_64.pkg.tar.gz` at 1,026,298 bytes among them.

On a booted live image, driven over QMP:

| | result |
|---|---|
| `pkg sync` | signature on the repository index **verified**; 54 packages available |
| `pkg install netsurf` | dependencies resolved and installed in order — mbedtls 3.6.2, ca-certificates, curl 8.11.1, openssl 3.5.8, then netsurf 3.11 — each `sha256 verified` |
| `netsurf-fb http://10.0.2.2:8099/` | **`Done (0.2s)`** |

The page was served over plain HTTP from the build host and is a real
layout test rather than a "it started" test. In the screendump the
browser has:

- **a window with novi-shell's own chrome** — title bar reading
  `NetSurf`, the three control dots, the drop shadow — and a `NetSurf`
  entry in the panel's taskbar beside `foot`;
- **CSS actually applied**: the teal `h1` with its 3px
  `border-bottom`, the tinted box with a 6px `border-left`, a table
  with borders and a shaded header row, and the closing line in
  italic. None of that is default rendering.

So the whole path is exercised end to end: libcurl fetched it, NetSurf's
own engine parsed and laid it out, libnsfb painted it into a
`wl_shm` buffer, and the patched xdg-shell surface put it on the
screen under the compositor's decoration.

**Typography, on the same booted machine** (`NETSURF_FB_FONTLIB=freetype`):
the heading, body, table and status line render in **Inter**, and
`<code>`/`<pre>` in **JetBrains Mono**, anti-aliased. `<b>` genuinely
selects Inter SemiBold. Both documented gaps were confirmed **on
screen** rather than reasoned about: on the first pass a paragraph
marked `<i>` rendered upright and a `font-family: serif` line rendered
in Inter. Shipping the two italic faces fixed the first, confirmed on a clean
06..39 rebuild: the same page re-rendered with `<i>` genuinely slanted
and `<b><i>` in SemiBoldItalic, while the `font-family: serif` line
still falls back to Inter, as designed.
`netsurf-fb`'s `DT_NEEDED` gained `libfreetype.so.6`, and the package
index carries
`curl,openssl,libpng,zlib,expat,wayland,freetype,fonts-inter,fonts-jetbrains-mono`.

**What was not tested.** HTTPS from this browser (the VM has no route
to the public internet in this harness — curl's TLS path has RFC 0020's
verification triple behind it, NetSurf's OpenSSL certificate-inspection
path has nothing); JavaScript, because there is none; and any page not
written for this test. Nothing here has run on physical hardware.

## Consequences

- **`icon=globe` finally means what its own comment says.**
  `ICON_GLOBE` is annotated "app-grid: web" in `shared/icons/icons.h`
  and had been novi-view's icon since the viewer shipped, because
  `resolve_icon_name()` never listed `image` and `globe` was the
  nearest thing offered. `ICON_IMAGE` was already vendored and already
  generated for novi-files; it just needed a row in the table. No new
  asset, and the Apps grid no longer shows two globes.
- **Fifth `-Wl,-rpath-link`** in this repository, after nftables,
  git/curl, the meson cross file and novi-glinfo. `libcurl.so`'s
  `DT_NEEDED` names `libmbedtls.so.21`, and `-L` does not let the
  linker resolve a shared library's own dependencies: the link fails on
  undefined `mbedtls_*` symbols, from a library whose own source
  contains none of them.
- **`CFLAGS=` on NetSurf's make command line deletes NetSurf's own
  include paths.** Its buildsystem does `CFLAGS += …`, and a variable
  set on the command line overrides every assignment in the makefile,
  `+=` included. The build then dies on its own headers. They go in the
  **environment**. That is RFC 0021's wolfSSL `.config` trap one level
  out, and it caught this build too.
- **The build directory is named after HOST and TARGET but not after
  the compiler.** A first attempt compiled the tree with the build
  host's gcc (the buildsystem derives `CC` from `HOST` only when its
  origin is `default`, and the browser's makefile does not take that
  path); naming `CC=` and `AR=` explicitly fixed the compiler but left
  glibc objects behind, and the musl link failed on `__snprintf_chk`
  and `__memset_chk` — fortify symbols that belong to a libc this image
  does not have. **The error names the libc you are linking, not the
  one that built the object.** The stage extracts the tree fresh.
- **`NETSURF_USE_LIBICONV_PLUG=YES`** means "iconv is part of libc",
  which is true of musl. `NO` links `-liconv`, which does not exist
  here and never will.

## Roadmap

1. ~~fcft in libnsfb~~ — **done**, and by a shorter route than this
   RFC first assumed: freetype rather than fcft, which upstream
   already supports. See decision 8. Italic followed immediately, and
   **the serif is in too** — Source Serif 4, a new pinned source and a
   design decision, which is why it took longer than the italics.
2. **JavaScript, or a decision not to.** Duktape is one flag and a real
   question: it is an interpreter with no JIT, so it is slow, and slow
   scripting on pages written for fast scripting may be worse than
   none. Measure before turning it on.
3. **The OpenSSL/mbedTLS split is worth removing.** Two TLS
   implementations in one process is a maintenance surface nobody
   chose; building curl against OpenSSL would collapse it to one, at
   the cost of changing what RFC 0020 decided.
4. **Nothing here has been tested against a hostile page.** A layout
   engine parsing arbitrary HTML off the network is among the larger
   attack surfaces this project has ever shipped, and it ships with
   none of the sandboxing a mainstream browser would put around it.
   That is worth saying out loud rather than leaving implied.
