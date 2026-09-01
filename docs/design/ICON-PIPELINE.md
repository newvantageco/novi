# Icon Pipeline — Design Proposal

- **Status:** Proposal (design doc, not an RFC — no new build dependency
  is being added to any shipped binary; see Recommendation)
- **Scope:** how simple flat/line-art icons (app-grid icons, status-bar
  icons like wifi/battery/power, a chevron, window-chrome dots, etc.)
  get onto screen in `novi-shell`, `novi-panel`, and `novi-launcher`.
- **Grounded in:** `novi-shell/main.c`, `novi-panel/main.c`,
  `novi-launcher/main.c` as they exist today, and
  `docs/PLATFORM-ROADMAP.md` §5 / `docs/rfcs/0001-desktop-wayland-compositor.md`.

> **Update since this doc was written:** the text-rendering side of
> "where this repo actually is today" below is now out of date —
> `novi-panel` and `novi-launcher` have since switched from the
> hand-rolled `FONT[]`/`draw_text()` bitmap font to real fcft+pixman
> glyph rendering (`../../common/text.h`), so both clients now link
> `pixman` (and `fcft`/`freetype`/`fontconfig`) already. That doesn't
> change this doc's icon-pipeline analysis or recommendation — icons
> are still a distinct problem from text glyphs (no image-loading
> capability exists for arbitrary bitmaps/SVGs), and the "extend
> draw_text()'s per-bit blit" option below is still evaluated on its
> own merits — but the `pixman` dependency this doc's later sections
> discuss adding is, for text at least, already present.

## Where this repo actually is today

There is **zero image-loading capability anywhere in this repo**. No
libpng, no stb_image, no anything. The three existing UI clients each
render entirely through `pixman`-backed shared-memory buffers
(`wl_shm`, `WLR_RENDERER=pixman` — no GLES2/Vulkan, per
`PLATFORM-ROADMAP.md` §5) using two primitives only:

- `draw_rect()` — a flat per-pixel loop that fills an axis-aligned box
  in one solid color (identical implementation duplicated in
  `novi-panel/main.c` and `novi-launcher/main.c`).
- `draw_text()` — walks a string, looks up each character in a small
  `static const struct glyph FONT[]` table, and blits each set bit of
  a **3×5 pixel** glyph as a `FONT_SCALE`-sized block via `draw_rect()`.

The glyph table itself is the load-bearing precedent: it's **hand-authored
and embedded as a plain C array**, deliberately not loaded from any font
format at runtime, and both files' comments explain why —
`novi-launcher/main.c`:

> "a font table copied from memory without a way to verify every byte
> against a real source isn't something to ship silently wrong. What's
> here is small enough to have been designed and visually verified
> pixel-by-pixel (via a QEMU screendump) rather than assumed correct."

Also load-bearing: `novi-panel/main.c` and `novi-launcher/main.c` each
keep their **own private copy** of `FONT[]`, explicitly rejecting a
shared library for a table "a handful of lines" long, since the two
clients need different (small, non-overlapping) glyph sets.

`foot` (the default terminal) is the one place in this repo that *does*
pull in a real text-rendering stack — freetype/fontconfig/fcft — but
that's a materially different problem (arbitrary program output needs
real Unicode shaping); it is not linked into `novi-shell`, `novi-panel`,
or `novi-launcher`, and nothing here proposes changing that.

## Options considered

### (a) Extend the existing pattern: pre-rasterized bitmap glyphs as C arrays

Author each icon (16×16 or 24×24, 1-bit or a small fixed palette) as a
packed bit array, the same shape as `FONT[]` but bigger, and blit it
with a generalized version of `draw_text()`'s per-bit `draw_rect()` loop.

- **Pros:** zero new dependencies, zero new runtime code paths (it's
  the exact mechanism already shipped, verified, and reviewed twice),
  trivially git-diffable, easy to pixel-verify via QEMU screendump the
  same way the font already was.
- **Cons:** hand-transcribing a 16×16+ bitmap (256+ bits) by eye is far
  more tedious and error-prone than a 3×5 digit glyph (15 bits) —
  this stops being a "handful of lines" exercise once you need
  dozens of icons (app grid: foot, files, web, editor, pkg, settings,
  security-tools, plus wifi/battery/power/chevron status glyphs). Also:
  no clean scaling story — nearest-neighbor upscaling a low-res bitmap
  (the way `FONT_SCALE` already blows up 3×5 blocks) looks fine for
  blocky digits but rough on curved shapes (a wifi arc, a rounded
  folder icon) at larger sizes.

### (b) A tiny hand-authored vector command format, rasterized at runtime

Author each icon as a short list of draw commands (line segments, rects,
circles/arcs) and write a small runtime rasterizer (Bresenham line,
midpoint circle, scanline polygon fill) on top of the existing pixel
buffer. Note: **pixman itself does not give you this for free** — it's
a low-level compositing/blit library (rectangles, image composition,
affine transforms on existing bitmaps), not a path-stroking vector
renderer like cairo; the "pixman can composite arbitrary shapes" framing
undersells the work — the shape-drawing algorithms would have to be
written from scratch, just as `draw_rect`/`draw_text` were.

- **Pros:** resolution-independent (multiply coordinates, not pixels),
  very compact per-icon authoring (a chevron is genuinely "two line
  segments"; a wifi glyph is genuinely "three arcs + a dot"), no
  external dependency, and the rasterization primitives (line, circle,
  filled polygon) are textbook/deterministic — easy to reason about
  and verify, unlike parsing someone else's format.
- **Cons:** real new code to write and get pixel-correct (line/circle
  rasterization has real edge cases — endpoint handling, anti-aliasing
  or its deliberate absence, thickness). Reasonable for a *handful* of
  simple parametric glyphs (a status dot, a chevron/disclosure
  triangle, three window-chrome dots) but doesn't scale well as the
  primary authoring path for real multi-stroke pictographic icons
  (a "files" folder icon, a "settings" gear) — those are exactly what
  SVG icon sets already exist to solve, and hand-encoding their curves
  as line/arc lists by eye reintroduces the same
  transcribe-without-a-way-to-verify risk the font's own header comment
  warns against.

### (c) Pull in a minimal SVG rasterizer (e.g. nanosvg) at runtime

Link `nanosvg`/`nanosvgrast` (single-header, ~2000-2500 lines,
permissively licensed — zlib, to the best of my knowledge; **verify the
license file directly before vendoring, this environment cannot fetch
it**) into `novi-shell`/`novi-panel`/`novi-launcher`, parse real SVG
icons, rasterize at startup or per-frame.

- **Pros:** real vector fidelity, and it means icons can be sourced
  directly and mechanically from any standard permissively-licensed SVG
  icon set (see Icon set recommendation below) instead of hand-transcribed.
- **Cons:** this is a new runtime dependency baked into three shipped
  binaries that today have deliberately stayed dependency-free for
  exactly this kind of thing (see the font comments above), it moves
  parsing/rasterization work into the render path or startup path of
  processes that currently do neither, and — most importantly — it's
  unnecessary to pay that cost at runtime at all, once you notice the
  actual icon set is small, fixed, and known entirely at build time.
  Nothing in this UI loads an arbitrary/user-supplied icon at runtime
  (unlike, say, a real desktop's per-app `.desktop`-file icon lookup);
  every icon this doc's mockup needs is known in advance.

### (d) What's actually recommended: (c) as an offline/host-side tool, (a) as the shipped runtime format, (b) for a handful of parametric glyphs

Given that every icon needed is fixed and known ahead of time, there's no
reason to link an SVG rasterizer into the compositor or its clients at
all — only to **use one once, on the build host, to generate the same
kind of plain bitmap C array the font already uses.** This keeps the
shipped binaries exactly as dependency-free as they are today while
removing the "transcribe curves by eye" problem that makes hand-authored
bitmaps painful past digit-sized glyphs.

## Recommendation

**Two-stage pipeline: offline SVG→bitmap generation (host tool, not
shipped), runtime blit via the existing font-table pattern (shipped,
unchanged in spirit).**

### Stage 1 — offline, host-only, never cross-compiled or packaged

- A small host tool (e.g. `tools/svg2icon/`, a short C program or Python
  script using `nanosvg`+`nanosvgrast`) reads real SVG source icons and
  rasterizes each to the exact fixed sizes actually needed — e.g. 16×16
  for status-bar glyphs (wifi/battery/power/chevron), 24×24 or 32×32 for
  app-grid icons — as 1-bit or 2-bit (foreground/background/one accent)
  packed bitmaps.
- This tool is explicitly **excluded from `build/02-toolchain.sh`
  cross-compilation and from `mkinitramfs.sh`/`mkiso.sh` rootfs
  packaging** — same category as `depmod` in `05-kernel.sh`'s "needed on
  the build host, never shipped" list. `nanosvg` never gets
  musl-cross-compiled and never appears in any `.pkg.tar.gz`.
- Output is **committed as plain generated C source** (not regenerated
  on every build) — a human or agent runs the tool once per icon
  add/change, reviews the generated diff (still pixel-checkable via a
  small preview, the same discipline the font used), and commits the
  result. This preserves the "verified against a real source, not
  assumed correct" property the font comments care about, while making
  the *source of truth* a real SVG file (reviewable, standard,
  re-rasterizable) instead of hand-counted bits.
- Needing HiDPI variants later is just generating an additional fixed
  size (e.g. `_32` alongside `_16`) at this stage — no runtime scaling
  logic needed, sidestepping option (a)'s "nearest-neighbor upscaling
  looks rough on curves" problem entirely.

### Stage 2 — runtime, shipped, same shape as today

- A generalized `draw_icon()` — the same per-bit `draw_rect()` blit loop
  `draw_text()` already does, just reading a fixed W×H bitmap instead of
  a 3×5 glyph — added alongside the existing `draw_rect()`/`draw_text()`
  primitives in each client. Zero new libraries linked into
  `novi-shell`, `novi-panel`, or `novi-launcher`.
- For the small set of purely parametric shapes that aren't really
  "icons" (a colored up/down status dot, three window-chrome title-bar
  dots, a disclosure chevron for the launcher's expandable "security
  tools" section) — hand-code these directly as `draw_rect`/a small
  `draw_circle` helper, per option (b), rather than routing them through
  the SVG pipeline at all. They're cheap, few, and don't benefit from
  vector-source authoring the way a multi-stroke pictographic icon does.

### File organization

Icons are needed by **all three** existing clients (and any future
widget/notification client — see `WIDGET-NOTIFICATION-ARCHITECTURE.md`),
unlike the font, which stayed intentionally per-client because each
client's glyph *set* barely overlapped. A dozens-of-icons set duplicated
three-to-four ways stops being "a handful of lines" — so, unlike the
font, this should be a shared source tree:

```
shared/icons/                  (new top-level dir, sibling to
                                 novi-shell/, novi-panel/, novi-launcher/
                                 — not nested under novi-shell/, since
                                 novi-shell is only one of several
                                 consumers)
├── icons.h                    struct novi_icon { id, w, h, bpp, pixels };
│                               enum { ICON_WIFI, ICON_BATTERY,
│                               ICON_POWER, ICON_CHEVRON_RIGHT,
│                               ICON_APP_FILES, ICON_APP_WEB, ... };
├── icons_generated.c          the generated, committed bitmap arrays
│                               (Stage 1 output — do not hand-edit)
├── icon_blit.c / icon_blit.h  draw_icon(px, stride_px, buf_w, buf_h,
│                               x, y, icon_id, fg_color[, bg_color])
│                               — same shape as draw_text(), shared
│                               instead of duplicated since the set is
│                               large and genuinely common across clients
└── tools/svg2icon/            host-only offline generator (Stage 1).
                                 Never referenced by build/02-toolchain.sh,
                                 build/03-base.sh, mkinitramfs.sh, or
                                 mkiso.sh — a human/agent runs it by hand
                                 and commits icons_generated.c.
```

Each client's `Makefile` compiles `shared/icons/icons_generated.c` and
`shared/icons/icon_blit.c` directly into its own binary (source-level
inclusion in the build, not a shared `.so`) — consistent with this
repo's all-static-linking posture (musl, static BusyBox) rather than
introducing the first shared library between Novi's own UI binaries.

### Icon set recommendation (for a human/future agent to act on — this
environment cannot fetch anything, so this is not verified or vendored here)

**Lucide** (https://lucide.dev) is the primary recommendation: an
actively-maintained fork of Feather Icons, **ISC licensed** (permissive,
GPL-compatible), consistent 24×24 grid, ~1.5–2px stroke flat line-art
style — a direct style match for the mockup's "simple flat/line-art icon
+ text label" grid, and it already has named icons for essentially every
glyph this mockup needs: `terminal` (foot), `folder`/`files`, `globe`
(web), `pencil`/`file-edit` (editor), `package` (pkg), `settings`
(settings), `shield` (security tools section), `wifi`, `battery`,
`power`, `chevron-right`/`chevron-down` (disclosure). **Tabler Icons**
(https://tabler.io/icons, MIT licensed, similarly large, similar 2px
stroke weight) is a reasonable secondary source for anything Lucide
lacks. Both are large, well-known, permissively licensed sets — but
double-check the current license text on each before vendoring, this
recommendation is from training knowledge, not a live fetch.

Feather Icons itself (the original, MIT) is now effectively superseded
by Lucide upstream and not separately recommended.

## Summary

| | Runtime cost | Authoring cost | Dependency footprint |
|---|---|---|---|
| (a) hand bitmaps only | none (existing pattern) | high past digit-sized glyphs | none |
| (b) hand vector commands | small new rasterizer | good for simple shapes, bad for real icons | none |
| (c) SVG rasterizer at runtime | new dependency in shipped binaries | best (real SVG source) | real, avoidable |
| **(d) recommended: (c) offline + (a) runtime + (b) for parametrics** | **none (same blit pattern)** | **best (real SVG source, generated not transcribed)** | **zero in shipped binaries** |
