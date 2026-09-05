# ============================================================
# novi-files — Makefile
#
# Cross-compiled by build/20-novi-files.sh against the wlroots stack
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

# fcft: text. xkbcommon: keysyms (no text entry here, so no
# xkb_state_key_get_utf8()). pixman: the render target. Plus
# ../shared/icons, for the folder and file glyphs -- the same
# generated icon set novi-launcher draws its search results with.
PKGS = wayland-client xkbcommon fcft pixman-1

CFLAGS += -std=gnu11 -Wall -Wextra -Wno-unused-parameter \
	-I. -I../common -I../shared/icons $(shell $(PKG_CONFIG) --cflags $(PKGS))
LDLIBS += $(shell $(PKG_CONFIG) --libs --static $(PKGS))

all: novi-files

xdg-shell-client-protocol.h: $(XDG_SHELL_XML)
	$(WAYLAND_SCANNER) client-header $< $@

xdg-shell-protocol.c: $(XDG_SHELL_XML)
	$(WAYLAND_SCANNER) private-code $< $@

novi-files: main.c ../common/text.c ../shared/icons/icon_blit.c ../shared/icons/icons_generated.c xdg-shell-protocol.c xdg-shell-client-protocol.h
	$(CC) $(CFLAGS) -o $@ main.c ../common/text.c ../shared/icons/icon_blit.c ../shared/icons/icons_generated.c xdg-shell-protocol.c $(LDLIBS)

install: novi-files
	install -D -m 755 novi-files "$(DESTDIR)$(PREFIX)/bin/novi-files"

clean:
	rm -f novi-files xdg-shell-client-protocol.h xdg-shell-protocol.c

.PHONY: all install clean
