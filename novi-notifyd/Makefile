# ============================================================
# novi-notifyd — Makefile
#
# Cross-compiled by build/36-novi-notifyd.sh. A layer-shell client,
# same shape as novi-launcher's: layer-shell's XML is vendored under
# ../protocol because wlroots implements the server side internally
# and never installs an XML or a header for a CLIENT to consume.
#
# No xkbcommon: this surface has keyboard-interactivity NONE and
# never sees a key.
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

PKGS = wayland-client fcft pixman-1

CFLAGS += -std=gnu11 -Wall -Wextra -Wno-unused-parameter \
	-I. -I../common -I../shared/icons $(shell $(PKG_CONFIG) --cflags $(PKGS))
LDLIBS += $(shell $(PKG_CONFIG) --libs --static $(PKGS)) -lrt -lm

all: novi-notifyd

wlr-layer-shell-unstable-v1-protocol.h: $(LAYER_SHELL_XML)
	$(WAYLAND_SCANNER) client-header $< $@

wlr-layer-shell-unstable-v1-protocol.c: $(LAYER_SHELL_XML)
	$(WAYLAND_SCANNER) private-code $< $@

xdg-shell-protocol.c: $(XDG_SHELL_XML)
	$(WAYLAND_SCANNER) private-code $< $@

novi-notifyd: main.c ../common/text.c ../common/theme.c ../shared/icons/icon_blit.c ../shared/icons/icons_generated.c wlr-layer-shell-unstable-v1-protocol.c wlr-layer-shell-unstable-v1-protocol.h xdg-shell-protocol.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ main.c ../common/text.c ../common/theme.c ../shared/icons/icon_blit.c ../shared/icons/icons_generated.c wlr-layer-shell-unstable-v1-protocol.c xdg-shell-protocol.c $(LDLIBS)

install: novi-notifyd
	install -D -m 755 novi-notifyd "$(DESTDIR)$(PREFIX)/bin/novi-notifyd"

clean:
	rm -f novi-notifyd wlr-layer-shell-unstable-v1-protocol.h wlr-layer-shell-unstable-v1-protocol.c xdg-shell-protocol.c

.PHONY: all install clean
