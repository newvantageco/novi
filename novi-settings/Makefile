# ============================================================
# novi-settings — Makefile
#
# Cross-compiled by build/14-novi-settings.sh against the wlroots stack
# build/06-wayland.sh built. Not meant to be run bare on a host system:
# CC/PKG_CONFIG/WAYLAND_SCANNER all need the cross-toolchain and
# rootfs paths build/00-versions.sh exports.
#
# Unlike every other client in this repo (novi-launcher/novi-panel/
# novi-lockscreen, all layer-shell), this is a plain xdg-shell app --
# a real, decorated, closable window like foot, not an overlay. That
# means it needs xdg-shell's CLIENT header (client-header), not just
# private-code for a link-time interface-symbol workaround the way
# every layer-shell client's Makefile uses xdg-shell today.
# ============================================================

CC ?= cc
PKG_CONFIG ?= pkg-config
WAYLAND_SCANNER ?= wayland-scanner
XDG_SHELL_XML ?= /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml
DESTDIR ?=
PREFIX ?= /usr

# fcft: real anti-aliased text rendering (see ../common/text.h), same
# pipeline every other GUI client here uses. xkbcommon: real keysym
# decoding for the password fields, same as novi-lockscreen.
PKGS = wayland-client xkbcommon fcft

CFLAGS += -std=gnu11 -Wall -Wextra -Wno-unused-parameter \
	-I. -I../common $(shell $(PKG_CONFIG) --cflags $(PKGS))
LDLIBS += $(shell $(PKG_CONFIG) --libs --static $(PKGS))

all: novi-settings

xdg-shell-client-protocol.h: $(XDG_SHELL_XML)
	$(WAYLAND_SCANNER) client-header $< $@

xdg-shell-protocol.c: $(XDG_SHELL_XML)
	$(WAYLAND_SCANNER) private-code $< $@

novi-settings: main.c ../common/text.c xdg-shell-protocol.c xdg-shell-client-protocol.h
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ main.c ../common/text.c xdg-shell-protocol.c $(LDLIBS)

install: novi-settings
	install -D -m 755 novi-settings "$(DESTDIR)$(PREFIX)/bin/novi-settings"

clean:
	rm -f novi-settings xdg-shell-client-protocol.h xdg-shell-protocol.c

.PHONY: all install clean
