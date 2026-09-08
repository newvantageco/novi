# novi-notify — Makefile
#
# Base image, not a desktop package: see main.c's header. Links libc
# and nothing else, so unlike every other client here it needs no
# desktop headers and no pkg-config.
CC ?= cc
DESTDIR ?=
PREFIX ?= /usr

CFLAGS += -std=gnu11 -Wall -Wextra

all: novi-notify

novi-notify: main.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ main.c

install: novi-notify
	install -D -m 755 novi-notify "$(DESTDIR)$(PREFIX)/bin/novi-notify"

clean:
	rm -f novi-notify

.PHONY: all install clean
