# ============================================================
# novi-glinfo — Makefile
#
# Cross-compiled by build/37-novi-glinfo.sh. A plain xdg-shell client,
# unlike novi-bg and novi-launcher: this one wants an ordinary window,
# not a layer surface, so it needs no vendored wlr-layer-shell XML --
# xdg-shell's own XML ships with wayland-protocols.
#
# The only client in this repository that links EGL and GLESv2, which
# is the entire point of it: RFC 0025 verified the compositor's use of
# them and nothing had ever verified a client's.
# ============================================================

CC ?= cc
PKG_CONFIG ?= pkg-config
WAYLAND_SCANNER ?= wayland-scanner
XDG_SHELL_XML ?= /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml
DESTDIR ?=
PREFIX ?= /usr

# wayland-egl is libwayland's own, not Mesa's: it turns a wl_surface
# into the EGLNativeWindowType the EGL driver expects. egl and glesv2
# are Mesa's, and their .pc files only exist once build/06-wayland.sh
# section 13 has run.
PKGS = wayland-client wayland-egl egl glesv2

CFLAGS += -std=gnu11 -Wall -Wextra -Wno-unused-parameter \
	-I. $(shell $(PKG_CONFIG) --cflags $(PKGS))
LDLIBS += $(shell $(PKG_CONFIG) --libs $(PKGS))

all: novi-glinfo

xdg-shell-protocol.h: $(XDG_SHELL_XML)
	$(WAYLAND_SCANNER) client-header $< $@

xdg-shell-protocol.c: $(XDG_SHELL_XML)
	$(WAYLAND_SCANNER) private-code $< $@

SRCS = main.c xdg-shell-protocol.c

novi-glinfo: $(SRCS) xdg-shell-protocol.h
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(SRCS) $(LDLIBS)

install: novi-glinfo
	install -D -m 755 novi-glinfo "$(DESTDIR)$(PREFIX)/bin/novi-glinfo"

clean:
	rm -f novi-glinfo xdg-shell-protocol.h xdg-shell-protocol.c

.PHONY: all install clean
