# ============================================================
# novi-lockscreen — Makefile
#
# Cross-compiled by build/13-novi-lockscreen.sh against the wlroots
# stack build/06-wayland.sh built. Not meant to be run bare on a host
# system: CC/PKG_CONFIG/WAYLAND_SCANNER all need the cross-toolchain
# and rootfs paths build/00-versions.sh exports.
#
# Same layer-shell client shape as novi-launcher/Makefile -- see its
# comments for why both XDG_SHELL_XML and --static are needed here too
# (the xdg_popup_interface link and libffi Requires.private issues
# apply identically).
# ============================================================

CC ?= cc
PKG_CONFIG ?= pkg-config
WAYLAND_SCANNER ?= wayland-scanner
LAYER_SHELL_XML ?= ../protocol/wlr-layer-shell-unstable-v1.xml
XDG_SHELL_XML ?= /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml
DESTDIR ?=
PREFIX ?= /usr

# fcft: real anti-aliased text rendering (see ../common/text.h), same
# pipeline novi-launcher/novi-panel already use. xkbcommon: real
# password-entry keysym decoding, same as novi-launcher's typed input.
PKGS = wayland-client xkbcommon fcft

CFLAGS += -std=gnu11 -Wall -Wextra -Wno-unused-parameter \
	-I. -I../common $(shell $(PKG_CONFIG) --cflags $(PKGS))
LDLIBS += $(shell $(PKG_CONFIG) --libs --static $(PKGS))

all: novi-lockscreen

wlr-layer-shell-unstable-v1-protocol.h: $(LAYER_SHELL_XML)
	$(WAYLAND_SCANNER) client-header $< $@

wlr-layer-shell-unstable-v1-protocol.c: $(LAYER_SHELL_XML)
	$(WAYLAND_SCANNER) private-code $< $@

# Client-side only -- provides xdg_popup_interface's definition for the
# linker, since the layer-shell code's get_popup message references it
# even though this client never calls it. See novi-launcher/Makefile's
# identical comment.
xdg-shell-protocol.c: $(XDG_SHELL_XML)
	$(WAYLAND_SCANNER) private-code $< $@

novi-lockscreen: main.c ../common/text.c wlr-layer-shell-unstable-v1-protocol.c wlr-layer-shell-unstable-v1-protocol.h xdg-shell-protocol.c
	$(CC) $(CFLAGS) -o $@ main.c ../common/text.c wlr-layer-shell-unstable-v1-protocol.c xdg-shell-protocol.c $(LDLIBS)

install: novi-lockscreen
	install -D -m 755 novi-lockscreen "$(DESTDIR)$(PREFIX)/bin/novi-lockscreen"

clean:
	rm -f novi-lockscreen wlr-layer-shell-unstable-v1-protocol.h wlr-layer-shell-unstable-v1-protocol.c xdg-shell-protocol.c

.PHONY: all install clean
