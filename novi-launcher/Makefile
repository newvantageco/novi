# ============================================================
# novi-launcher — Makefile
#
# Cross-compiled by build/08-novi-launcher.sh against the wlroots
# stack build/06-wayland.sh built. Not meant to be run bare on a host
# system: CC/PKG_CONFIG/WAYLAND_SCANNER all need the cross-toolchain
# and rootfs paths build/00-versions.sh exports.
# ============================================================

CC ?= cc
PKG_CONFIG ?= pkg-config
WAYLAND_SCANNER ?= wayland-scanner
# Same vendored copy novi-shell uses (repo root, not duplicated here) --
# see novi-shell/Makefile's comment for why this has to be vendored at
# all (wlroots never installs it or a generated header anywhere).
LAYER_SHELL_XML ?= ../protocol/wlr-layer-shell-unstable-v1.xml
# zwlr_layer_surface_v1::get_popup takes an xdg_popup object argument,
# so the generated layer-shell code's message-signature table
# references &xdg_popup_interface as an extern symbol -- confirmed by
# a failed link ("undefined reference to xdg_popup_interface") even
# though this client never calls get_popup or touches xdg_popup at
# all. Generating xdg-shell's own client-side interface descriptor and
# linking it in is the real fix (it's what actually defines that
# symbol), not a workaround.
XDG_SHELL_XML ?= /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml
DESTDIR ?=
PREFIX ?= /usr

# fcft: real anti-aliased text rendering (see ../common/text.h),
# replacing the earlier 3x5 bitmap font placeholder. Pulls in
# freetype/fontconfig/pixman transitively via --static -- all already
# built for foot (build/09-foot.sh), no new dependency.
PKGS = wayland-client xkbcommon fcft

CFLAGS += -std=gnu11 -Wall -Wextra -Wno-unused-parameter \
	-I. -I../common $(shell $(PKG_CONFIG) --cflags $(PKGS))
# --static (not plain --libs): wayland-client.pc declares libffi only
# under Requires.private, so plain --libs omits -lffi entirely. libffi
# actually is built and present in the rootfs (unlike the libinput/
# libevdev situation novi-shell's Makefile works around with
# --allow-shlib-undefined) -- confirmed by hand: the link fails with
# "libffi.so.8, needed by libwayland-client.so, not found" because the
# static linker only consults -L for a DIRECTLY named -l<lib>, never
# for a shared library's own transitive DT_NEEDED entries, so just
# having -L/.../lib on the command line isn't enough; --static expands
# Requires.private recursively and adds the explicit -lffi that fixes
# this correctly, rather than papering over it.
LDLIBS += $(shell $(PKG_CONFIG) --libs --static $(PKGS))

all: novi-launcher

# Unlike novi-shell (a layer-shell *server*, whose request-handling is
# already compiled into libwlroots.so), this is a layer-shell *client*:
# nothing implements the request-marshalling code for us, so both the
# header and the private-code (marshalling) have to be generated here.
wlr-layer-shell-unstable-v1-protocol.h: $(LAYER_SHELL_XML)
	$(WAYLAND_SCANNER) client-header $< $@

wlr-layer-shell-unstable-v1-protocol.c: $(LAYER_SHELL_XML)
	$(WAYLAND_SCANNER) private-code $< $@

# Client-side only (main.c never includes the xdg-shell header) --
# this .c file exists solely to provide xdg_popup_interface's
# definition for the linker; see the XDG_SHELL_XML comment above.
xdg-shell-protocol.c: $(XDG_SHELL_XML)
	$(WAYLAND_SCANNER) private-code $< $@

novi-launcher: main.c ../common/text.c wlr-layer-shell-unstable-v1-protocol.c wlr-layer-shell-unstable-v1-protocol.h xdg-shell-protocol.c
	$(CC) $(CFLAGS) -o $@ main.c ../common/text.c wlr-layer-shell-unstable-v1-protocol.c xdg-shell-protocol.c $(LDLIBS)

install: novi-launcher
	install -D -m 755 novi-launcher "$(DESTDIR)$(PREFIX)/bin/novi-launcher"

clean:
	rm -f novi-launcher wlr-layer-shell-unstable-v1-protocol.h wlr-layer-shell-unstable-v1-protocol.c xdg-shell-protocol.c

.PHONY: all install clean
