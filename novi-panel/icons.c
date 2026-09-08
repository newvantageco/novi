/* icons.c — the geometry behind novi-panel's icons.
 *
 * Every shape here is described the same way: a signed distance to a
 * boundary, turned into per-pixel coverage. That is what makes them
 * antialiased for free and what makes a "stroke" a one-line change
 * from a fill (keep a band around zero instead of everything <= 0).
 *
 * Hand-coded parametric shapes rather than rasterized SVG, which is
 * docs/design/ICON-PIPELINE.md's own sanctioned category for exactly
 * this: the build host has no SVG rasterizer (checked -- no
 * rsvg-convert, ImageMagick, inkscape or cairosvg) and these shapes
 * are simple enough that the code IS the description.
 */
#include <math.h>

#include "icons.h"

/* Signed distance from (px,py), relative to a rounded box's own
 * center, to that box's boundary: negative inside, positive outside,
 * magnitude is the distance to the nearest edge (corner arc included).
 * Inigo Quilez's widely-used 2D rounded-box SDF formula (public
 * domain) -- the same one novi-shell's drop-shadow code uses, applied
 * here rather than shared, since these are separate client binaries
 * with no shared geometry module yet. */
double novi_rounded_box_sdf(double px, double py, double half_w,
		double half_h, double radius) {
	double qx = fabs(px) - half_w + radius;
	double qy = fabs(py) - half_h + radius;
	double outside_x = qx > 0.0 ? qx : 0.0;
	double outside_y = qy > 0.0 ? qy : 0.0;
	double outside = sqrt(outside_x * outside_x + outside_y * outside_y);
	double inside = qx > qy ? qx : qy;
	if (inside > 0.0) {
		inside = 0.0;
	}
	return outside + inside - radius;
}

/* Turns a signed distance into stroke coverage: keep a band of
 * half_stroke either side of the boundary, with one pixel of linear
 * falloff for the antialiasing. The apps icon worked this out inline;
 * the network glyph needs it six times, so it is a function now. */
double novi_stroke_coverage(double d, double half_stroke) {
	double coverage = 0.5 - (fabs(d) - half_stroke);
	if (coverage > 1.0) {
		return 1.0;
	}
	return coverage < 0.0 ? 0.0 : coverage;
}

/* Per-pixel coverage [0,1] of the apps-grid icon at icon-local
 * coordinates (x,y) -- see APPS_ICON_* for where the icon's exact
 * geometry (Lucide's layout-grid.svg) comes from. A "stroke" (the
 * icon is a line icon, not filled, per GUI-DESIGN-LANGUAGE.md §5) is
 * just "distance to the shape's boundary is within half the stroke
 * width," directly expressible from the same signed-distance value a
 * filled shape's own edge-antialiasing would use -- keeping a band
 * around zero instead of everything <= 0. Checks all four squares and
 * takes the strongest hit; they never overlap (there's a real gap
 * between them), so at most one is ever non-zero per pixel, but max()
 * is the correct combine for a union of independent shapes regardless. */
double novi_apps_icon_coverage(double x, double y, const void *ctx) {
	(void)ctx;
	static const double square_pos[4][2] = {
		{0, 0},
		{APPS_ICON_SQUARE + APPS_ICON_GAP, 0},
		{APPS_ICON_SQUARE + APPS_ICON_GAP, APPS_ICON_SQUARE + APPS_ICON_GAP},
		{0, APPS_ICON_SQUARE + APPS_ICON_GAP},
	};
	double half = APPS_ICON_SQUARE / 2.0;
	double half_stroke = APPS_ICON_STROKE / 2.0;
	double best = 0.0;
	for (int i = 0; i < 4; i++) {
		double cx = square_pos[i][0] + half;
		double cy = square_pos[i][1] + half;
		double d = novi_rounded_box_sdf(x - cx, y - cy, half, half, APPS_ICON_RADIUS);
		double coverage = novi_stroke_coverage(d, half_stroke);
		if (coverage > best) {
			best = coverage;
		}
	}
	return best;
}

/* ── The network glyphs ───────────────────────────────────────────────
 *
 * Both are drawn in icon-local coordinates with the fan's origin at the
 * bottom centre, which is where a wifi glyph's arcs are concentric.
 */
#define NET_ORIGIN_X (NET_ICON_W / 2.0)
/* Two pixels up from the bottom, not one. At NET_ICON_H - 1.0 the dot
 * (radius NET_DOT_RADIUS, plus half a pixel of antialiasing falloff)
 * ran past the bottom of the icon box, and draw_icon() clips to that
 * box -- so the glyph shipped with its origin dot shaved flat.
 * icons-test.c asserts the fan touches neither edge, which is the
 * check that found it; nothing about the live screenshot said so. */
#define NET_ORIGIN_Y (NET_ICON_H - 2.0)

double novi_net_wifi_coverage(double x, double y, const void *ctx) {
	const struct net_fan *fan = ctx;
	double dx = x - NET_ORIGIN_X;
	double dy = y - NET_ORIGIN_Y;
	double r = sqrt(dx * dx + dy * dy);
	double half_stroke = NET_ICON_STROKE / 2.0;
	double best = 0.0;

	if (fan->mask & 1u) {
		/* The dot is filled, not stroked: a 1px ring at this size
		 * reads as a smudge rather than as the "you are here" mark the
		 * fan opens from. */
		double coverage = 0.5 - (r - NET_DOT_RADIUS);
		if (coverage > 1.0) {
			coverage = 1.0;
		}
		if (coverage > best) {
			best = coverage;
		}
	}

	/* An arc is a circle's stroke restricted to the upper wedge. The
	 * wedge test is on r, not on a fixed y, so the fan opens at a
	 * constant angle instead of getting wider as it goes out. */
	if (-dy >= NET_FAN_SLOPE * r) {
		static const double radius[3] = { NET_ARC1, NET_ARC2, NET_ARC3 };
		for (int i = 0; i < 3; i++) {
			if ((fan->mask & (2u << i)) == 0) {
				continue;
			}
			double coverage = novi_stroke_coverage(r - radius[i], half_stroke);
			if (coverage > best) {
				best = coverage;
			}
		}
	}

	/* Offline gets a slash across the fan, because a fan with no lit
	 * elements and a fan whose signal could not be read look identical
	 * and mean different things. Drawn by rotating the point 45 degrees
	 * and reusing the axis-aligned rounded-box SDF -- a rotated thin
	 * box is still a thin box in its own frame. */
	if (fan->slash) {
		double cx = x - NET_ICON_W / 2.0;
		double cy = y - NET_ICON_H / 2.0;
		double rx = (cx + cy) * 0.70710678;
		double ry = (cy - cx) * 0.70710678;
		double d = novi_rounded_box_sdf(rx, ry, 0.0, NET_ICON_H * 0.62, 0.0);
		double coverage = novi_stroke_coverage(d, half_stroke);
		if (coverage > best) {
			best = coverage;
		}
	}
	return best;
}

/* An RJ45 jack: a stroked rounded body with the latch tab below it.
 * Two shapes and a union, the same construction as the apps grid.
 *
 * NET_WIRED_BODY_CY / _TAB_CY are the shapes' centres in icon-local
 * coordinates, y growing DOWNWARD like every other pixel coordinate
 * here -- so a positive value is below the middle. Getting that sign
 * backwards is not a subtle bug and it is not a loud one either: the
 * first version passed `cy + 1.5`, which places a centre at -1.5, and
 * drew a perfectly clean jack upside down with its tab off the top of
 * the icon box. It took a screenshot to see, which is this repo's
 * standing advice about GUI bugs, applied to a five-line function.
 *
 * The two boxes overlap by a fraction of a pixel on purpose: at this
 * stroke width a gap between them reads as two shapes rather than one
 * plug. */
#define NET_WIRED_BODY_CY (-1.2)
#define NET_WIRED_TAB_CY 3.8

double novi_net_wired_coverage(double x, double y, const void *ctx) {
	(void)ctx;
	double cx = x - NET_ICON_W / 2.0;
	double cy = y - NET_ICON_H / 2.0;
	double half_stroke = NET_ICON_STROKE / 2.0;

	double body = novi_rounded_box_sdf(cx, cy - NET_WIRED_BODY_CY, 6.0, 3.6, 1.3);
	double tab = novi_rounded_box_sdf(cx, cy - NET_WIRED_TAB_CY, 2.2, 1.6, 0.6);
	double best = novi_stroke_coverage(body, half_stroke);
	double t = novi_stroke_coverage(tab, half_stroke);
	return t > best ? t : best;
}


/* ── The power glyph ──────────────────────────────────────────────────
 *
 * A ring with a gap at the top and a vertical stem through it. Drawn
 * parametrically like every other glyph in this file rather than
 * pulled from shared/icons: those are 8-bit coverage bitmaps behind a
 * different blitter, and this panel's draw_icon() takes a coverage
 * FUNCTION so that icons-test.c can render every state on the build
 * host. A glyph that arrives as a bitmap cannot be asserted about, and
 * the whole reason this file exists is that the wifi fan's bug was
 * invisible in the one state a VM can produce.
 */
double novi_power_coverage(double x, double y, const void *ctx) {
	(void)ctx;
	double cx = POWER_ICON_W / 2.0;
	double cy = POWER_ICON_H / 2.0;
	double dx = x - cx;
	double dy = y - cy;
	double half_stroke = POWER_ICON_STROKE / 2.0;

	/* The ring, minus the wedge at the top. -dy is "above the centre",
	 * so the gap test only ever removes material from the top. */
	double best = 0.0;
	if (!(-dy > 0.0 && fabs(dx) <= POWER_GAP_HALF * -dy)) {
		double r = sqrt(dx * dx + dy * dy);
		best = novi_stroke_coverage(r - POWER_RING_R, half_stroke);
	}

	/* The stem: a vertical segment from just above the centre up
	 * through the gap. Distance to a segment, which for a vertical one
	 * is |dx| inside its span and the distance to the nearer end
	 * outside it -- so the cap is round, matching the ring's own
	 * stroke. */
	double top = -POWER_STEM_TOP;
	double bottom = -POWER_STEM_BOTTOM;
	double sy = dy < top ? dy - top : (dy > bottom ? dy - bottom : 0.0);
	double stem = novi_stroke_coverage(sqrt(dx * dx + sy * sy), half_stroke);
	if (stem > best) {
		best = stem;
	}
	return best;
}

/* ── The health warning glyph ─────────────────────────────────────────
 *
 * A rounded triangle with an exclamation in it. Drawn as the distance
 * to each of its three edges rather than as a filled shape, so the
 * outline has the same stroke weight as every other glyph on this bar.
 */
static double seg_distance(double px, double py, double ax, double ay,
		double bx, double by) {
	double vx = bx - ax, vy = by - ay;
	double wx = px - ax, wy = py - ay;
	double len2 = vx * vx + vy * vy;
	double t = len2 > 0.0 ? (wx * vx + wy * vy) / len2 : 0.0;
	if (t < 0.0) {
		t = 0.0;
	} else if (t > 1.0) {
		t = 1.0;
	}
	double dx = wx - t * vx, dy = wy - t * vy;
	return sqrt(dx * dx + dy * dy);
}

double novi_warn_coverage(double x, double y, const void *ctx) {
	(void)ctx;
	double half_stroke = WARN_ICON_STROKE / 2.0;
	/* Corners pulled in by the corner radius, so the rounded joins sit
	 * inside the icon box instead of being clipped by it -- the same
	 * mistake the wifi fan's outermost arc made before NET_ARC3 was
	 * checked against NET_ICON_H. */
	double inset = half_stroke + WARN_TRI_RADIUS;
	double apex_x = WARN_ICON_W / 2.0;
	double apex_y = inset;
	double left_x = inset, right_x = WARN_ICON_W - inset;
	double base_y = WARN_ICON_H - inset;

	double d = seg_distance(x, y, apex_x, apex_y, left_x, base_y);
	double d2 = seg_distance(x, y, apex_x, apex_y, right_x, base_y);
	double d3 = seg_distance(x, y, left_x, base_y, right_x, base_y);
	if (d2 < d) {
		d = d2;
	}
	if (d3 < d) {
		d = d3;
	}
	double best = novi_stroke_coverage(d, half_stroke);

	/* The exclamation. */
	double bar = seg_distance(x, y, apex_x, WARN_BAR_TOP, apex_x, WARN_BAR_BOTTOM);
	double bar_cov = novi_stroke_coverage(bar, half_stroke * 0.85);
    if (bar_cov > best) {
		best = bar_cov;
	}
	/* A FILLED disc, not a ring: a zero-radius "segment" with a round
	 * cap, the same shape the power glyph's stem end uses. Drawn as a
	 * ring it was 1.5px of ink either side of a hole nothing could
	 * see, which is how it ran into the base line below it. */
	double dx = x - apex_x, dy = y - WARN_DOT_Y;
	double dot = novi_stroke_coverage(sqrt(dx * dx + dy * dy), WARN_DOT_HALF);
	if (dot > best) {
		best = dot;
	}
	return best;
}
