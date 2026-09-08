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
# Taskbar (RFC 0001's minimize/restore): lists and controls novi-shell's
# open toplevels. Vendored under ../protocol/ for the same reason as
# LAYER_SHELL_XML -- wlroots implements the server side internally but
# never installs this XML or a generated header anywhere for a CLIENT
# to consume.
FOREIGN_TOPLEVEL_XML ?= ../protocol/wlr-foreign-toplevel-management-unstable-v1.xml
DESTDIR ?=
PREFIX ?= /usr

# fcft: real anti-aliased text rendering (see ../common/text.h),
# replacing the earlier 3x5 bitmap font placeholder. Pulls in
# freetype/fontconfig/pixman transitively via --static -- all already
# built for foot (build/09-foot.sh), no new dependency.
#
# libnl-genl-3.0: the network indicator asks the kernel for the WiFi
# signal over nl80211 (see netstat.c). This kernel has
# CONFIG_CFG80211_WEXT off, so /proc/net/wireless does not exist and
# netlink is the only interface there is. libnl is already in the base
# image for wpa_supplicant -- this is a new link, not a new dependency,
# and pkgsplit leaves the library in the base (wpa_supplicant needs it)
# while deriving nothing extra for this package.
PKGS = wayland-client fcft libnl-genl-3.0

CFLAGS += -std=gnu11 -Wall -Wextra -Wno-unused-parameter \
	-I. -I../common $(shell $(PKG_CONFIG) --cflags $(PKGS))
LDLIBS += $(shell $(PKG_CONFIG) --libs --static $(PKGS))

all: novi-panel

wlr-layer-shell-unstable-v1-protocol.h: $(LAYER_SHELL_XML)
	$(WAYLAND_SCANNER) client-header $< $@

wlr-layer-shell-unstable-v1-protocol.c: $(LAYER_SHELL_XML)
	$(WAYLAND_SCANNER) private-code $< $@

xdg-shell-protocol.c: $(XDG_SHELL_XML)
	$(WAYLAND_SCANNER) private-code $< $@

wlr-foreign-toplevel-management-unstable-v1-protocol.h: $(FOREIGN_TOPLEVEL_XML)
	$(WAYLAND_SCANNER) client-header $< $@

wlr-foreign-toplevel-management-unstable-v1-protocol.c: $(FOREIGN_TOPLEVEL_XML)
	$(WAYLAND_SCANNER) private-code $< $@

novi-panel: main.c netstat.c icons.c ../common/text.c wlr-layer-shell-unstable-v1-protocol.c wlr-layer-shell-unstable-v1-protocol.h xdg-shell-protocol.c wlr-foreign-toplevel-management-unstable-v1-protocol.c wlr-foreign-toplevel-management-unstable-v1-protocol.h
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ main.c netstat.c icons.c ../common/text.c wlr-layer-shell-unstable-v1-protocol.c xdg-shell-protocol.c wlr-foreign-toplevel-management-unstable-v1-protocol.c $(LDLIBS)

# Renders every icon state as ASCII and asserts the properties that
# make them right -- on the BUILD host, with the host compiler, linking
# only libm. See icons-test.c for why the states a VM can produce are
# not enough. `make check` here, and scripts/lint.sh runs it.
check: icons-test
	./icons-test

icons-test: icons-test.c icons.c icons.h
	cc -std=gnu11 -Wall -Wextra -O1 -I. -o $@ icons-test.c icons.c -lm

install: novi-panel
	install -D -m 755 novi-panel "$(DESTDIR)$(PREFIX)/bin/novi-panel"

clean:
	rm -f novi-panel icons-test wlr-layer-shell-unstable-v1-protocol.h wlr-layer-shell-unstable-v1-protocol.c xdg-shell-protocol.c wlr-foreign-toplevel-management-unstable-v1-protocol.h wlr-foreign-toplevel-management-unstable-v1-protocol.c

.PHONY: all check install clean
