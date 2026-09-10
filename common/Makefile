# common/Makefile — the host-side checks for shared code.
#
# There is no library to build here: common/*.c is compiled into each
# client by that client's own Makefile. This exists only for `check`,
# which scripts/lint.sh runs.
#
# theme-test links the REAL loader (theme.c) rather than
# reimplementing the parser, so what it asserts about the shipped
# palettes is what a client will actually load. It needs pixman's
# headers because theme.h's NOVI_PIX() produces a pixman_color_t --
# headers only, nothing is linked from it.

CC ?= cc
CFLAGS ?= -O1 -Wall -Wextra
PIXMAN_CFLAGS := $(shell pkg-config --cflags pixman-1 2>/dev/null)

check: theme-test
	@cd .. && common/theme-test

theme-test: theme-test.c theme.c theme.h
	$(CC) $(CFLAGS) $(PIXMAN_CFLAGS) -I. -o $@ theme-test.c theme.c -lm

clean:
	rm -f theme-test

.PHONY: check clean
