# Vendored SVG sources

Each file here is byte-identical to Lucide's upstream source, fetched
directly (not hand-transcribed) from:

```
https://raw.githubusercontent.com/lucide-icons/lucide/<commit>/icons/<name>.svg
```

fetched at commit `dce50dd0c9d6d55dde2a8880732bbe2acc6ba29e` (`main` branch,
resolved via `git ls-remote` on 2026-09-01). License: ISC (Lucide Icons and
Contributors) + MIT (Feather-derived icons) — see
`docs/design/ICON-PIPELINE.md`'s "Icon set decision" section, where the
license text was read directly from Lucide's `LICENSE` file before any
icon here was vendored.

| File | Lucide name | Used for |
|---|---|---|
| `terminal.svg` | `terminal` | app-grid: foot |
| `folder.svg` | `folder` | app-grid: files |
| `globe.svg` | `globe` | app-grid: web |
| `pencil.svg` | `pencil` | app-grid: editor |
| `package.svg` | `package` | app-grid: pkg |
| `settings.svg` | `settings` | app-grid: settings |
| `shield.svg` | `shield` | app-grid: security tools |
| `wifi.svg` | `wifi` | status bar |
| `battery.svg` | `battery` | status bar |
| `power.svg` | `power` | status bar |
| `chevron-right.svg` | `chevron-right` | disclosure (collapsed) |
| `chevron-down.svg` | `chevron-down` | disclosure (expanded) |

`layout-grid` (the apps button) is deliberately **not** here — per
`ICON-PIPELINE.md`'s "First icon shipped" section, that one stayed a
hand-coded parametric shape (`novi-panel/main.c`'s `apps_icon_coverage()`)
since four rounded rects don't need the SVG pipeline. Do not add it here;
adding an SVG-driven `ICON_LAYOUT_GRID` would just be a second,
redundant, harder-to-audit implementation of the same glyph.

Do not hand-edit these files. To add or update an icon, fetch it fresh
from upstream, update this manifest's table and commit line, and re-run
`svg2icon` (see `../README.md`).
