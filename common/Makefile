# common/Makefile — the host-side checks for shared code.
#
# There is no library to build here: common/*.c is compiled into each
# client by that client's own Makefile. This exists only for `check`,
# which scripts/lint.sh runs.
#
# theme-test links the REAL loader (theme.c) rather than
# reimplementing the parser, so what it asserts about the shipped
# palettes is what a client will actually load.
#
# NO EXTERNAL DEPENDENCIES, deliberately: it defines
# NOVI_THEME_NO_PIXMAN so theme.h skips the pixman include it only
# needs for NOVI_PIX(). The first version linked pixman's headers and
# broke CI, on a runner that has no graphics libraries and no reason
# to -- a test that checks a list of hex values should not need a
# rasteriser.

CC ?= cc
CFLAGS ?= -O1 -Wall -Wextra

check: theme-test
	@cd .. && common/theme-test

theme-test: theme-test.c theme.c theme.h
	$(CC) $(CFLAGS) -DNOVI_THEME_NO_PIXMAN -I. -o $@ theme-test.c theme.c -lm

clean:
	rm -f theme-test

.PHONY: check clean
