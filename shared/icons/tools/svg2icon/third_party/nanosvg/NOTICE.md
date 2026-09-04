# Vendored: nanosvg

`nanosvg.h` and `nanosvgrast.h` are byte-identical copies fetched directly
from upstream:

```
https://raw.githubusercontent.com/memononen/nanosvg/<commit>/src/nanosvg.h
https://raw.githubusercontent.com/memononen/nanosvg/<commit>/src/nanosvgrast.h
```

fetched at commit `239e102ec2c691f2902e20ace2ed36ee4a35cfe6` (`master`
branch, resolved via `git ls-remote` on 2026-09-01).

License: zlib (`LICENSE.txt` in this directory, fetched from the same
commit's `LICENSE.txt` and read before vendoring — permissive, compatible
with this repo's use, same discipline `ICON-PIPELINE.md` used for Lucide's
license).

This is **host-tool-only**: it is compiled solely by
`shared/icons/tools/svg2icon/Makefile`'s native (non-cross) `cc` and never
referenced by `build/02-toolchain.sh`, `build/03-base.sh`,
`scripts/mkinitramfs.sh`, or `scripts/mkiso.sh` — same category as
`nanosvg`/`nanosvgrast` in `ICON-PIPELINE.md`'s Stage 1 recommendation
and `depmod` in `build/05-kernel.sh`'s "needed on the build host, never
shipped" list. It never gets musl-cross-compiled and never appears in any
`.pkg.tar.gz`.

Do not hand-edit these files. To update, re-fetch both files and this
notice from a newer upstream commit.
