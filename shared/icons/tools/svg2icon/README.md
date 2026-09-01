# svg2icon

Offline SVG-to-bitmap generator — `docs/design/ICON-PIPELINE.md` Stage 1.

Reads the vendored icon set under `svg/` (see `svg/MANIFEST.md` for
provenance) and rasterizes each to the fixed size novi-shell / novi-panel
/ novi-launcher actually need, using [nanosvg](third_party/nanosvg/) (see
`third_party/nanosvg/NOTICE.md`). Output is `../icons_generated.c`
(`shared/icons/icons_generated.c`) — plain C, committed, reviewed like any
other diff, matching the discipline this repo already uses for its
hand-authored font tables. **Do not hand-edit that file** — re-run this
tool and commit its output instead.

## Host-only

This tool, and everything under it, is built with the build host's own
native `cc` and is **never** cross-compiled, packaged, or referenced by
`build/02-toolchain.sh`, `build/03-base.sh`, `scripts/mkinitramfs.sh`, or
`scripts/mkiso.sh` — the same category as `depmod` in
`build/05-kernel.sh`'s "needed on the build host, never shipped" list.
`nanosvg`/`nanosvgrast` never get musl-cross-compiled and never appear in
any `.pkg.tar.gz`.

## Usage

```sh
cd shared/icons/tools/svg2icon
make generate
```

This builds `svg2icon` (native), runs it, and prints an ASCII-art preview
of every icon to stdout as it's generated — the substitute, for this
host-only tool, for the QEMU screendump pixel-checks the rest of this
repo's UI work is verified with (there's no compositor to boot here, but
the generated bitmap *is* the final artifact, so looking at it directly
matters the same way). Review both the preview and the resulting
`../icons_generated.c` diff before committing.

## Adding a new icon

1. Fetch the real SVG source from Lucide (or Tabler, per
   `ICON-PIPELINE.md`'s fallback — check its license first, the same way
   Lucide's was checked) and add it under `svg/`.
2. Add its provenance to `svg/MANIFEST.md`.
3. Add the icon's enum value to `../icons.h`.
4. Add a matching entry to the `JOBS[]` table in `svg2icon.c`.
5. `make generate`, review the preview and the diff, commit both the new
   `.svg` and the regenerated `icons_generated.c`.

Purely parametric shapes that aren't really "icons" (a status dot, the
apps-button `layout-grid` glyph, window-chrome dots) skip this pipeline
entirely and stay hand-coded directly in the consuming client, per
`ICON-PIPELINE.md`'s Stage 2 recommendation and "First icon shipped"
section.
