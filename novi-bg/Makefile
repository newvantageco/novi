# ============================================================
# novi-bg — Makefile
#
# Cross-compiled by build/36-novi-bg.sh. A layer-shell client,
# same shape as novi-launcher's: layer-shell's XML is vendored under
# ../protocol because wlroots implements the server side internally
# and never installs an XML or a header for a CLIENT to consume.
#
# No fcft and no pixman library: this client draws no text and no
# glyphs, it fills a buffer with arithmetic. theme.h includes
# <pixman.h> for the colour type, so pixman's CFLAGS are needed --
# its library is not.
# ============================================================

CC ?= cc
PKG_CONFIG ?= pkg-config
WAYLAND_SCANNER ?= wayland-scanner
LAYER_SHELL_XML ?= ../protocol/wlr-layer-shell-unstable-v1.xml
# Not because anything here creates a popup: wlr-layer-shell's own
# generated code references xdg_popup_interface (a layer surface is
# allowed to parent one), so the link needs xdg-shell's private code
# whether or not this client ever asks for a popup. novi-launcher's
# Makefile documents the identical requirement.
XDG_SHELL_XML ?= /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml
DESTDIR ?=
PREFIX ?= /usr

PKGS = wayland-client

CFLAGS += -std=gnu11 -Wall -Wextra -Wno-unused-parameter \
	-I. -I../common $(shell $(PKG_CONFIG) --cflags $(PKGS) pixman-1)
LDLIBS += $(shell $(PKG_CONFIG) --libs --static $(PKGS)) -lrt -lm

all: novi-bg

wlr-layer-shell-unstable-v1-protocol.h: $(LAYER_SHELL_XML)
	$(WAYLAND_SCANNER) client-header $< $@

wlr-layer-shell-unstable-v1-protocol.c: $(LAYER_SHELL_XML)
	$(WAYLAND_SCANNER) private-code $< $@

xdg-shell-protocol.c: $(XDG_SHELL_XML)
	$(WAYLAND_SCANNER) private-code $< $@

novi-bg: main.c ../common/theme.c wlr-layer-shell-unstable-v1-protocol.c wlr-layer-shell-unstable-v1-protocol.h xdg-shell-protocol.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ main.c ../common/theme.c wlr-layer-shell-unstable-v1-protocol.c xdg-shell-protocol.c $(LDLIBS)

install: novi-bg
	install -D -m 755 novi-bg "$(DESTDIR)$(PREFIX)/bin/novi-bg"

clean:
	rm -f novi-bg wlr-layer-shell-unstable-v1-protocol.h wlr-layer-shell-unstable-v1-protocol.c xdg-shell-protocol.c

.PHONY: all install clean
