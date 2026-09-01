# shared/icons

The shared icon set consumed by `novi-shell`, `novi-panel`, and
`novi-launcher` — `docs/design/ICON-PIPELINE.md`'s two-stage pipeline.

- `icons.h` — hand-authored: the `enum novi_icon_id` contract and
  `struct novi_icon` layout (`{ w, h, coverage[] }`, an 8-bit
  alpha-coverage mask, colorless by design).
- `icons_generated.c` — **generated, do not hand-edit.** Produced by
  `tools/svg2icon/` (Stage 1) from the vendored SVG sources under
  `tools/svg2icon/svg/`. Regenerate with `make generate` in that
  directory after adding or changing an icon.
- `icon_blit.c` / `icon_blit.h` — `draw_icon()` (Stage 2): the runtime
  blit primitive, same shape as `draw_rect()`/`draw_text()` in
  `novi-panel/main.c` and `novi-launcher/main.c` — a real premultiplied
  "over" compositing loop (verified against real generated icon data: a
  fully-opaque draw matches pixel-for-pixel at every clipped and
  in-bounds coordinate, and an antialiased edge pixel blends strictly
  between source and destination rather than snapping to either). Zero
  new libraries linked.
- `tools/svg2icon/` — the offline, host-only generator (see its own
  `README.md`). Never cross-compiled or packaged.

## Status

Stage 1 (the generator) and Stage 2 (`draw_icon()`) are both built and
verified on the build host: `icons_generated.c` holds real rasterized
Lucide icons (`terminal`, `folder`, `globe`, `pencil`, `package`,
`settings`, `shield`, `wifi`, `battery`, `power`, `chevron-right`,
`chevron-down`), and `draw_icon()`'s compositing math has been checked
against that real data with a native (non-cross) test harness — not
QEMU-live-verified, since that needs each client actually calling
`draw_icon()` and a full cross-compile + boot, neither of which is
possible from a host-only tool's own test.

**Not yet done, and the natural next slice**: no client's `Makefile`
compiles `icons_generated.c`/`icon_blit.c` yet, and no client calls
`draw_icon()` — this directory is a complete, usable primitive sitting
next to `novi-shell/`, `novi-panel/`, `novi-launcher/`, not yet wired
into any of them. Per `ICON-PIPELINE.md`'s "Still open" list, the
natural first consumer is the app-grid icon set (once `novi-launcher`
has an app-grid view to put them in) or, more immediately available
today, a per-result icon next to each `novi-launcher` search match.
Status-bar icons (`wifi`/`battery`/`power`) are additionally blocked on
real data sources that don't exist yet, independent of the icon bitmaps
themselves being ready.
