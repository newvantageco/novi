# ============================================================
# novi-panel — Makefile
#
# Cross-compiled by build/10-novi-panel.sh against the wlroots stack
# build/06-wayland.sh built. Not meant to be run bare on a host
# system: CC/PKG_CONFIG/WAYLAND_SCANNER all need the cross-toolchain
# and rootfs paths build/00-versions.sh exports.
#
# Same layer-shell client shape as novi-launcher/Makefile -- see its
# comments for why both XDG_SHELL_XML and --static are needed here
# too (the xdg_popup_interface link and libffi Requires.private
# issues apply identically; this client just has no xkbcommon
# dependency, since it never touches keyboard input).
# ============================================================

CC ?= cc
PKG_CONFIG ?= pkg-config
WAYLAND_SCANNER ?= wayland-scanner
LAYER_SHELL_XML ?= ../protocol/wlr-layer-shell-unstable-v1.xml
XDG_SHELL_XML ?= /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml
DESTDIR ?=
PREFIX ?= /usr

PKGS = wayland-client

CFLAGS += -std=gnu11 -Wall -Wextra -Wno-unused-parameter \
	-I. $(shell $(PKG_CONFIG) --cflags $(PKGS))
LDLIBS += $(shell $(PKG_CONFIG) --libs --static $(PKGS))

all: novi-panel

wlr-layer-shell-unstable-v1-protocol.h: $(LAYER_SHELL_XML)
	$(WAYLAND_SCANNER) client-header $< $@

wlr-layer-shell-unstable-v1-protocol.c: $(LAYER_SHELL_XML)
	$(WAYLAND_SCANNER) private-code $< $@

xdg-shell-protocol.c: $(XDG_SHELL_XML)
	$(WAYLAND_SCANNER) private-code $< $@

novi-panel: main.c wlr-layer-shell-unstable-v1-protocol.c wlr-layer-shell-unstable-v1-protocol.h xdg-shell-protocol.c
	$(CC) $(CFLAGS) -o $@ main.c wlr-layer-shell-unstable-v1-protocol.c xdg-shell-protocol.c $(LDLIBS)

install: novi-panel
	install -D -m 755 novi-panel "$(DESTDIR)$(PREFIX)/bin/novi-panel"

clean:
	rm -f novi-panel wlr-layer-shell-unstable-v1-protocol.h wlr-layer-shell-unstable-v1-protocol.c xdg-shell-protocol.c

.PHONY: all install clean
