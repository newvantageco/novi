# ============================================================
# novi-shell — Makefile
#
# Cross-compiled by build/07-novi-shell.sh against the wlroots stack
# build/06-wayland.sh already produced. Not meant to be run bare on a
# host system: CC/PKG_CONFIG/WAYLAND_SCANNER/XDG_SHELL_XML all need
# the cross-toolchain and rootfs paths build/00-versions.sh exports.
# ============================================================

CC ?= cc
PKG_CONFIG ?= pkg-config
WAYLAND_SCANNER ?= wayland-scanner
XDG_SHELL_XML ?= /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml
# wlr-layer-shell-unstable-v1.xml is vendored in protocol/ (MIT-style
# license, header intact) rather than read from an installed system
# path: wlroots does not install this XML or its generated protocol
# header anywhere -- it's wlroots' own bundled "wlr-protocols" source,
# compiled directly into libwlroots.so, with no public install path.
# wlr_layer_shell_v1.h (which IS installed) still needs the generated
# wlr-layer-shell-unstable-v1-protocol.h at compile time for its enums
# (ZWLR_LAYER_SHELL_V1_LAYER_* etc.) via a quoted #include that falls
# back to -I. -- confirmed by reading wlroots' own protocol/meson.build
# and its installed .pc Cflags (just "-I${includedir}/wlroots-0.18",
# nothing protocol-related). Every wlroots-based compositor (sway
# included) vendors this same XML for the same reason. Lives under
# ../protocol/ (repo root, not novi-shell/) since novi-launcher and any
# future layer-shell client need this exact same file too.
LAYER_SHELL_XML ?= ../protocol/wlr-layer-shell-unstable-v1.xml
DESTDIR ?=
PREFIX ?= /usr

PKGS = wlroots-0.18 wayland-server xkbcommon

CFLAGS += -std=gnu11 -Wall -Wextra -Wno-unused-parameter -DWLR_USE_UNSTABLE \
	-I. $(shell $(PKG_CONFIG) --cflags $(PKGS))
# --allow-shlib-undefined: libwlroots.so's own private transitive deps
# (libinput -> libevdev/mtdev in particular) aren't fully declared in
# every upstream .pc's Requires.private -- confirmed by hand: even
# `pkg-config --libs --static` (which expands Requires.private
# recursively) still left libinput.so's own libevdev/mtdev symbols
# unresolved at link time, because libinput.pc itself declares no
# Requires.private at all, so there's nothing for --static to expand.
# This isn't a workaround for a bug in our code -- it restores normal
# ELF dynamic-linking semantics (a shared library's own private
# transitive dependencies are the dynamic loader's job to resolve at
# runtime, not the static linker's job to see at build time), rather
# than hand-listing every private dependency's private dependencies
# ourselves and having that list silently go stale.
LDLIBS += $(shell $(PKG_CONFIG) --libs $(PKGS)) -Wl,--allow-shlib-undefined

all: novi-shell

xdg-shell-protocol.h: $(XDG_SHELL_XML)
	$(WAYLAND_SCANNER) server-header $< $@

xdg-shell-protocol.c: $(XDG_SHELL_XML)
	$(WAYLAND_SCANNER) private-code $< $@

# Server-header only: the layer-shell protocol implementation itself
# (opcode marshalling) is already compiled into libwlroots.so -- we
# only need the enum/struct declarations wlr_layer_shell_v1.h's quoted
# #include expects to find on the compiler's -I path.
wlr-layer-shell-unstable-v1-protocol.h: $(LAYER_SHELL_XML)
	$(WAYLAND_SCANNER) server-header $< $@

novi-shell: main.c xdg-shell-protocol.c xdg-shell-protocol.h wlr-layer-shell-unstable-v1-protocol.h
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ main.c xdg-shell-protocol.c $(LDLIBS)

install: novi-shell
	install -D -m 755 novi-shell "$(DESTDIR)$(PREFIX)/bin/novi-shell"

clean:
	rm -f novi-shell xdg-shell-protocol.h xdg-shell-protocol.c wlr-layer-shell-unstable-v1-protocol.h

.PHONY: all install clean
