# ============================================================
# novi-view — Makefile
#
# Cross-compiled by build/22-novi-view.sh against the wlroots stack
# build/06-wayland.sh built. Not meant to be run bare on a host system:
# CC/PKG_CONFIG/WAYLAND_SCANNER all need the cross-toolchain and
# rootfs paths build/00-versions.sh exports.
#
# A plain xdg-shell app -- a real, decorated, closable window like foot
# and novi-settings, not a layer-shell overlay. That means it needs
# xdg-shell's CLIENT header (client-header), not just private-code the
# way the layer-shell clients use it.
# ============================================================

CC ?= cc
PKG_CONFIG ?= pkg-config
WAYLAND_SCANNER ?= wayland-scanner
XDG_SHELL_XML ?= /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml
DESTDIR ?=
PREFIX ?= /usr

# libpng16 for PNG decode (build/21-imagelibs.sh); it pulls zlib in
# through its own .pc. fcft for the status bar, xkbcommon for keysyms,
# pixman for the render target. No icons: this window is the image.
PKGS = wayland-client xkbcommon fcft pixman-1 libpng16

CFLAGS += -std=gnu11 -Wall -Wextra -Wno-unused-parameter \
	-I. -I../common $(shell $(PKG_CONFIG) --cflags $(PKGS))
LDLIBS += $(shell $(PKG_CONFIG) --libs --static $(PKGS))

all: novi-view

xdg-shell-client-protocol.h: $(XDG_SHELL_XML)
	$(WAYLAND_SCANNER) client-header $< $@

xdg-shell-protocol.c: $(XDG_SHELL_XML)
	$(WAYLAND_SCANNER) private-code $< $@

novi-view: main.c ../common/text.c xdg-shell-protocol.c xdg-shell-client-protocol.h
	$(CC) $(CFLAGS) -o $@ main.c ../common/text.c xdg-shell-protocol.c $(LDLIBS)

install: novi-view
	install -D -m 755 novi-view "$(DESTDIR)$(PREFIX)/bin/novi-view"

clean:
	rm -f novi-view xdg-shell-client-protocol.h xdg-shell-protocol.c

.PHONY: all install clean
