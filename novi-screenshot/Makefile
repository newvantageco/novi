# ============================================================
# novi-screenshot — Makefile
#
# Cross-compiled by build/12-novi-screenshot.sh against the wlroots
# stack build/06-wayland.sh built. Not meant to be run bare on a host
# system: CC/PKG_CONFIG/WAYLAND_SCANNER all need the cross-toolchain
# and rootfs paths build/00-versions.sh exports.
#
# Unlike novi-launcher/novi-panel, this client never creates a
# wl_surface (no layer-shell, no xdg-shell, no xkbcommon, no fcft) --
# it only talks to wl_shm and zwlr_screencopy_manager_v1, so it needs
# neither LAYER_SHELL_XML nor XDG_SHELL_XML nor their xdg_popup-link
# workaround (see novi-launcher/Makefile's comment on that).
# ============================================================

CC ?= cc
PKG_CONFIG ?= pkg-config
WAYLAND_SCANNER ?= wayland-scanner
# wlroots implements the server side internally but never installs
# this XML or a generated header anywhere for a CLIENT to consume --
# same situation as LAYER_SHELL_XML / FOREIGN_TOPLEVEL_XML in the
# other clients' Makefiles.
SCREENCOPY_XML ?= ../protocol/wlr-screencopy-unstable-v1.xml
DESTDIR ?=
PREFIX ?= /usr

PKGS = wayland-client

CFLAGS += -std=gnu11 -Wall -Wextra -Wno-unused-parameter \
	-I. $(shell $(PKG_CONFIG) --cflags $(PKGS))
LDLIBS += $(shell $(PKG_CONFIG) --libs --static $(PKGS))

all: novi-screenshot

wlr-screencopy-unstable-v1-protocol.h: $(SCREENCOPY_XML)
	$(WAYLAND_SCANNER) client-header $< $@

wlr-screencopy-unstable-v1-protocol.c: $(SCREENCOPY_XML)
	$(WAYLAND_SCANNER) private-code $< $@

novi-screenshot: main.c wlr-screencopy-unstable-v1-protocol.c wlr-screencopy-unstable-v1-protocol.h
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ main.c wlr-screencopy-unstable-v1-protocol.c $(LDLIBS)

install: novi-screenshot
	install -D -m 755 novi-screenshot "$(DESTDIR)$(PREFIX)/bin/novi-screenshot"

clean:
	rm -f novi-screenshot wlr-screencopy-unstable-v1-protocol.h wlr-screencopy-unstable-v1-protocol.c

.PHONY: all install clean
