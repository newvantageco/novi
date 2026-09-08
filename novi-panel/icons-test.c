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
	show("power", novi_power_coverage, NULL, POWER_ICON_W, POWER_ICON_H);
	show("health warning", novi_warn_coverage, NULL, WARN_ICON_W, WARN_ICON_H);

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

	struct vol_glyph vol[3];
	for (int n = 0; n < 3; n++) {
		vol[n].arcs = n > 0 ? (1u << n) - 1u : 0u;
		vol[n].muted = 0;
		char label[64];
		snprintf(label, sizeof(label), "volume, %d arc(s)  arcs=0x%x",
			n, vol[n].arcs);
		show(label, novi_volume_coverage, &vol[n], VOL_ICON_W, VOL_ICON_H);
	}
	struct vol_glyph vol_muted = { .arcs = 0u, .muted = 1 };
	show("volume, muted", novi_volume_coverage, &vol_muted,
		VOL_ICON_W, VOL_ICON_H);

	puts("checks:");

	{
		/* The warning triangle. Its failure mode is being clipped by
		 * its own icon box -- the mistake the wifi fan's outermost arc
		 * made -- which reads as a flat-topped or flat-sided shape and
		 * is nearly invisible at 16px. Assert the box's border rows
		 * and columns are empty, so a clipped glyph fails here rather
		 * than looking slightly wrong on screen forever. */
		double edge = 0.0;
		for (int x = 0; x < WARN_ICON_W; x++) {
			edge += novi_warn_coverage(x + 0.5, 0.5, NULL);
			edge += novi_warn_coverage(x + 0.5, WARN_ICON_H - 0.5, NULL);
		}
		for (int y = 0; y < WARN_ICON_H; y++) {
			edge += novi_warn_coverage(0.5, y + 0.5, NULL);
			edge += novi_warn_coverage(WARN_ICON_W - 0.5, y + 0.5, NULL);
		}
		check("warn: nothing touches the icon box's border", edge < 0.05);
		/* The exclamation has to be there: a bare triangle is a
		 * different symbol. */
		double bar = novi_warn_coverage(WARN_ICON_W / 2.0,
			(WARN_BAR_TOP + WARN_BAR_BOTTOM) / 2.0, NULL);
		double dot = novi_warn_coverage(WARN_ICON_W / 2.0, WARN_DOT_Y, NULL);
		double gap = novi_warn_coverage(WARN_ICON_W / 2.0,
			(WARN_BAR_BOTTOM + WARN_DOT_Y) / 2.0, NULL);
		check("warn: the exclamation's bar is drawn", bar > 0.7);
		check("warn: its dot is drawn", dot > 0.7);
		check("warn: there is a gap between the bar and the dot", gap < 0.35);
		/* Wider at the bottom than the top -- it is a triangle. */
		double top_ink = ink(novi_warn_coverage, NULL, WARN_ICON_W, 4);
		double all_ink = ink(novi_warn_coverage, NULL, WARN_ICON_W, WARN_ICON_H);
		check("warn: most of its ink is below the top quarter",
			top_ink < all_ink * 0.25);
	}

	/* The power glyph. Its two failure modes are both invisible in a
	 * screenshot at 16px -- a gap that has closed up reads as a plain
	 * ring, and a stem that has slipped reads as a slightly thick
	 * one -- so they are asserted rather than looked at. */
	{
		/* Top row of the ring, either side of the stem: there must be
		 * ink out at the sides and none immediately beside the stem,
		 * which is what "there is a gap" means at this size. */
		double cy = POWER_ICON_H / 2.0;
		double gap_y = cy - POWER_RING_R;
		double at_stem = novi_power_coverage(POWER_ICON_W / 2.0 + 1.6,
			gap_y + 0.5, NULL);
		double at_side = novi_power_coverage(POWER_ICON_W / 2.0 - POWER_RING_R,
			cy + 0.5, NULL);
		check("power: nothing drawn just right of the stem, at the gap",
			at_stem < 0.05);
		check("power: the ring is drawn at its left extreme",
			at_side > 0.5);
		/* The stem must cross the ring's top, not stop short of it. */
		double above_ring = novi_power_coverage(POWER_ICON_W / 2.0,
			cy - POWER_RING_R - 0.5, NULL);
		check("power: the stem reaches past the ring's top", above_ring > 0.5);
		/* And it must not run out of the bottom. */
		double below_centre = novi_power_coverage(POWER_ICON_W / 2.0,
			cy + 2.0, NULL);
		check("power: the stem does not run below the centre",
			below_centre < 0.05);
		/* Ink sits above the middle: a power symbol is top-heavy. */
		double c = ink_centroid_y(novi_power_coverage, NULL,
			POWER_ICON_W, 0, POWER_ICON_H);
		check("power: its ink centroid is above the icon's middle",
			c > 0.0 && c < POWER_ICON_H / 2.0);
	}

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

	/* The volume glyph. Its states differ only in a few pixels at the
	 * right-hand end, so every one of these is a thing a screenshot
	 * would not settle. */
	{
		/* The body is drawn in EVERY state, muted included. An
		 * indicator that disappears at zero volume cannot tell you the
		 * volume is at zero -- and the muted branch returns early, so
		 * it is exactly the branch that could drop the body. */
		double body_only = ink(novi_volume_coverage, &vol[0],
			VOL_ICON_W, VOL_ICON_H);
		check("volume: the speaker body is drawn with no arcs",
			body_only > 10.0);
		/* Left of the cone's tip is body and nothing else, in every
		 * state -- so it is the body's own ink, isolated. */
		int tip_col = (int)(VOL_ICON_W / 2.0 + VOL_TIP_X);
		double body_muted = 0.0, body_loud = 0.0;
		for (int y = 0; y < VOL_ICON_H; y++) {
			for (int x = 0; x < tip_col; x++) {
				body_muted += novi_volume_coverage(x + 0.5, y + 0.5, &vol_muted);
				body_loud  += novi_volume_coverage(x + 0.5, y + 0.5, &vol[2]);
			}
		}
		check("volume: muted and loud draw the identical body",
			fabs(body_muted - body_loud) < 1e-9 && body_muted > 8.0);

		/* The polygon is CLOSED. Leaving the last segment out opens
		 * the speaker's flat left end into a C -- which at this size
		 * reads as a slightly thin speaker, not as a bug. */
		double left_edge = novi_volume_coverage(
			VOL_ICON_W / 2.0 - 7.8, VOL_ICON_H / 2.0, &vol[0]);
		check("volume: the body's flat left end is closed", left_edge > 0.7);

		/* Each arc count lights strictly more than the one below --
		 * the wifi mask lesson, in a glyph with two elements instead
		 * of four. */
		double a0 = ink(novi_volume_coverage, &vol[0], VOL_ICON_W, VOL_ICON_H);
		double a1 = ink(novi_volume_coverage, &vol[1], VOL_ICON_W, VOL_ICON_H);
		double a2 = ink(novi_volume_coverage, &vol[2], VOL_ICON_W, VOL_ICON_H);
		check("volume: one arc draws more than none", a1 > a0 + 1.0);
		check("volume: two arcs draw more than one", a2 > a1 + 1.0);

		/* Muted is the cross INSTEAD of the arcs, never as well:
		 * both together are two statements about one thing and at
		 * 16px they smudge into each other. */
		double muted_all = ink(novi_volume_coverage, &vol_muted,
			VOL_ICON_W, VOL_ICON_H);
		check("volume: muted draws more than the bare body",
			muted_all > a0 + 1.0);
		/* Probed at 45 degrees around the arc, NOT at its rightmost
		 * point: the cross reaches that far too, so a probe there
		 * cannot tell an arc from the cross and the check passes
		 * whatever the code does. It failed here first, which is the
		 * assertion doing its job on the test rather than the glyph. */
		double at_arc = novi_volume_coverage(
			VOL_ICON_W / 2.0 + VOL_TIP_X + VOL_ARC2 * 0.7071,
			VOL_ICON_H / 2.0 + VOL_ARC2 * 0.7071, &vol_muted);
		check("volume: muted draws no arc where the outer arc would be",
			at_arc < 0.05);
		double at_cross = novi_volume_coverage(VOL_ICON_W / 2.0 + VOL_X_CX,
			VOL_ICON_H / 2.0, &vol_muted);
		check("volume: the muted cross meets at its centre", at_cross > 0.5);

		/* Nothing touches the icon box's border. Same assertion the
		 * warning triangle carries, for the same reason: the outer
		 * arc plus half a stroke is exactly the quantity that gets
		 * clipped flat when a radius grows. */
		double edge = 0.0;
		for (int x = 0; x < VOL_ICON_W; x++) {
			edge += novi_volume_coverage(x + 0.5, 0.5, &vol[2]);
			edge += novi_volume_coverage(x + 0.5, VOL_ICON_H - 0.5, &vol[2]);
			edge += novi_volume_coverage(x + 0.5, 0.5, &vol_muted);
			edge += novi_volume_coverage(x + 0.5, VOL_ICON_H - 0.5, &vol_muted);
		}
		for (int y = 0; y < VOL_ICON_H; y++) {
			edge += novi_volume_coverage(0.5, y + 0.5, &vol[2]);
			edge += novi_volume_coverage(VOL_ICON_W - 0.5, y + 0.5, &vol[2]);
			edge += novi_volume_coverage(0.5, y + 0.5, &vol_muted);
			edge += novi_volume_coverage(VOL_ICON_W - 0.5, y + 0.5, &vol_muted);
		}
		check("volume: nothing touches the icon box's border", edge < 0.05);
	}

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
