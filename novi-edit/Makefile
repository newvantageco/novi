# ============================================================
# novi-edit — Makefile
#
# Cross-compiled by build/29-novi-edit.sh against the wlroots stack
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

# fcft: real anti-aliased text rendering (see ../common/text.h), same
# pipeline every other GUI client here uses. xkbcommon: keysym AND
# UTF-8 decoding -- an editor needs xkb_state_key_get_utf8(), which is
# the only thing that gets a non-US layout right.
# pixman: the render target, shared with every other client here.
PKGS = wayland-client xkbcommon fcft pixman-1

CFLAGS += -std=gnu11 -Wall -Wextra -Wno-unused-parameter \
	-I. -I../common $(shell $(PKG_CONFIG) --cflags $(PKGS))
LDLIBS += $(shell $(PKG_CONFIG) --libs --static $(PKGS))

all: novi-edit

xdg-shell-client-protocol.h: $(XDG_SHELL_XML)
	$(WAYLAND_SCANNER) client-header $< $@

xdg-shell-protocol.c: $(XDG_SHELL_XML)
	$(WAYLAND_SCANNER) private-code $< $@

novi-edit: main.c ../common/text.c xdg-shell-protocol.c xdg-shell-client-protocol.h
	$(CC) $(CFLAGS) -o $@ main.c ../common/text.c xdg-shell-protocol.c $(LDLIBS)

install: novi-edit
	install -D -m 755 novi-edit "$(DESTDIR)$(PREFIX)/bin/novi-edit"

clean:
	rm -f novi-edit xdg-shell-client-protocol.h xdg-shell-protocol.c

.PHONY: all install clean
