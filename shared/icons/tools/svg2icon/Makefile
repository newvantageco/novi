# svg2icon -- host-only, native build. Deliberately NOT part of
# build/02-toolchain.sh cross-compilation and never invoked by
# scripts/mkinitramfs.sh or scripts/mkiso.sh (see
# third_party/nanosvg/NOTICE.md). Always uses the build host's own `cc`,
# regardless of any cross CC exported by the main build scripts.
CC := cc
CFLAGS := -O2 -Wall -Wextra
LDLIBS := -lm

.PHONY: generate clean

svg2icon: svg2icon.c third_party/nanosvg/nanosvg.h third_party/nanosvg/nanosvgrast.h
	$(CC) $(CFLAGS) -o $@ svg2icon.c $(LDLIBS)

# Regenerate ../../icons_generated.c (shared/icons/icons_generated.c) from
# svg/*.svg. Run by hand after adding or changing an icon; review the
# diff before committing.
generate: svg2icon
	./svg2icon

clean:
	rm -f svg2icon
