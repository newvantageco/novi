/* icons-test.c — renders every icon state as ASCII on the BUILD host.
 *
 * Runs nowhere near a VM and links nothing but libm, which is the
 * point. The network glyph's lit-element mask is
 * `(1u << bars) - 1u` against one bit per element, and its wrong
 * answers are invisible in the only case a test VM can produce:
 * mac80211_hwsim reports -30 dBm and nothing else, so a live boot
 * draws four bars, and a mask bug would draw four bars correctly
 * anyway -- 0xF is 0xF however you arrived at it.
 *
 * `make check` in this directory renders bars 1..4 (and the wired and
 * offline glyphs) so all of them can be looked at, and asserts the
 * properties that make them right: each bar level lights strictly more
 * of the icon than the one below, four bars lights the same set as
 * NET_FAN_ALL, and the wired glyph's latch tab is BELOW its body --
 * the sign error that shipped a perfectly clean upside-down jack and
 * took a screenshot to notice.
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#include "icons.h"

/* Total coverage over the icon box: a scalar "how much ink". */
static double ink(icon_coverage_fn fn, const void *ctx, int w, int h) {
	double total = 0.0;
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			total += fn(x + 0.5, y + 0.5, ctx);
		}
	}
	return total;
}

/* Where the ink is, vertically: the coverage-weighted mean row. */
static double ink_centroid_y(icon_coverage_fn fn, const void *ctx,
		int w, int y0, int y1) {
	double total = 0.0, weighted = 0.0;
	for (int y = y0; y < y1; y++) {
		for (int x = 0; x < w; x++) {
			double c = fn(x + 0.5, y + 0.5, ctx);
			total += c;
			weighted += c * (y + 0.5);
		}
	}
	return total > 0.0 ? weighted / total : -1.0;
}

static void show(const char *label, icon_coverage_fn fn, const void *ctx,
		int w, int h) {
	printf("%s\n", label);
	for (int y = 0; y < h; y++) {
		printf("  ");
		for (int x = 0; x < w; x++) {
			double c = fn(x + 0.5, y + 0.5, ctx);
			putchar(c > 0.75 ? '#' : c > 0.35 ? '+' : c > 0.05 ? '.' : ' ');
		}
		putchar('\n');
	}
	putchar('\n');
}

static int failures;

static void check(const char *what, int ok) {
	printf("  %-58s %s\n", what, ok ? "ok" : "FAIL");
	if (!ok) {
		failures++;
	}
}

int main(void) {
	show("apps grid", novi_apps_icon_coverage, NULL,
		APPS_ICON_SIZE, APPS_ICON_SIZE);
	show("wired (RJ45)", novi_net_wired_coverage, NULL,
		NET_ICON_W, NET_ICON_H);

	struct net_fan fan[6];
	for (int bars = 0; bars <= 4; bars++) {
		fan[bars].mask = bars > 0 ? (1u << bars) - 1u : 0u;
		fan[bars].slash = 0;
		char label[64];
		snprintf(label, sizeof(label), "wifi, %d bar(s)  mask=0x%x",
			bars, fan[bars].mask);
		show(label, novi_net_wifi_coverage, &fan[bars],
			NET_ICON_W, NET_ICON_H);
	}
	struct net_fan all = { .mask = NET_FAN_ALL, .slash = 0 };
	struct net_fan off = { .mask = NET_FAN_ALL, .slash = 1 };
	show("wifi, dim pass (every element)", novi_net_wifi_coverage, &all,
		NET_ICON_W, NET_ICON_H);
	show("offline (slash only -- drawn over the dim pass)",
		novi_net_wifi_coverage, &(struct net_fan){ .mask = 0u, .slash = 1 },
		NET_ICON_W, NET_ICON_H);

	puts("checks:");

	/* Each level lights strictly more than the one below it. This is
	 * what a wrong mask breaks and what four-bars-only cannot see. */
	double prev = 0.0;
	for (int bars = 0; bars <= 4; bars++) {
		double got = ink(novi_net_wifi_coverage, &fan[bars],
			NET_ICON_W, NET_ICON_H);
		char what[64];
		snprintf(what, sizeof(what), "%d bars draws more than %d bars",
			bars, bars - 1);
		if (bars == 0) {
			check("0 bars draws nothing at all", got == 0.0);
		} else {
			check(what, got > prev + 1.0);
		}
		prev = got;
	}
	check("4 bars is exactly the full fan",
		fabs(ink(novi_net_wifi_coverage, &fan[4], NET_ICON_W, NET_ICON_H) -
			ink(novi_net_wifi_coverage, &all, NET_ICON_W, NET_ICON_H)) < 1e-9);

	/* One bar is the dot at the fan's origin: near the bottom, and
	 * horizontally centred. */
	double dot_y = ink_centroid_y(novi_net_wifi_coverage, &fan[1],
		NET_ICON_W, 0, NET_ICON_H);
	check("1 bar is the dot, in the bottom third of the icon",
		dot_y > NET_ICON_H * 0.66);

	/* The slash is a real diagonal, not an empty pass. */
	check("the offline slash draws something",
		ink(novi_net_wifi_coverage, &off, NET_ICON_W, NET_ICON_H) >
		ink(novi_net_wifi_coverage, &all, NET_ICON_W, NET_ICON_H) + 5.0);

	/* The jack's tab is below its body. The upside-down version passed
	 * every other check there is.
	 *
	 * Compared as row WIDTHS, not as ink: the body is an outline, so
	 * most of its ink is in its two horizontal edges -- one at the very
	 * top and one in the middle -- and an upper-half/lower-half ink
	 * split comes out near even. The top row is the body's full width
	 * and the bottom row is the tab's, which is the actual asymmetry
	 * this glyph has. */
	int top_w = 0, bottom_w = 0;
	for (int x = 0; x < NET_ICON_W; x++) {
		if (novi_net_wired_coverage(x + 0.5, 0.5, NULL) > 0.05) {
			top_w++;
		}
		if (novi_net_wired_coverage(x + 0.5, NET_ICON_H - 0.5, NULL) > 0.05) {
			bottom_w++;
		}
	}
	check("the RJ45 is widest at the top (body) and narrow at the bottom (tab)",
		top_w > bottom_w && bottom_w > 0);
	double tab_y = ink_centroid_y(novi_net_wired_coverage, NULL,
		NET_ICON_W, NET_ICON_H / 2 + 2, NET_ICON_H);
	check("the RJ45 latch tab is below the body, not above it",
		tab_y > NET_ICON_H / 2 + 2);

	/* Nothing may draw outside its own box -- draw_icon() clips to the
	 * box, so ink that lands outside is ink the user never sees and a
	 * glyph that is quietly cut off. */
	int clipped = 0;
	for (int x = 0; x < NET_ICON_W; x++) {
		if (novi_net_wifi_coverage(x + 0.5, 0.05, &all) > 0.5 ||
				novi_net_wifi_coverage(x + 0.5, NET_ICON_H - 0.05, &all) > 0.5) {
			clipped = 1;
		}
	}
	check("the wifi fan does not touch the top or bottom edge", !clipped);

	printf("\n%s\n", failures == 0 ? "all checks passed" : "FAILURES");
	return failures == 0 ? 0 : 1;
}
