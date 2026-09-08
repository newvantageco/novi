/* icons.h — novi-panel's icon geometry.
 *
 * Pure functions of a point, with no Wayland, no pixels and no libc
 * beyond math.h. Split out of main.c for one concrete reason: the
 * network glyph's lit-element mask is arithmetic
 * ((1u << bars) - 1u against a bit per element) whose only wrong
 * answers are invisible in the case a test VM can produce. hwsim
 * reports -30 dBm and nothing else, so a live boot draws four bars and
 * four bars only -- and a mask bug would still draw four bars
 * correctly, because 0xF is 0xF however you got there.
 *
 * Geometry that can be rendered on the build host is geometry whose
 * every state can be checked (icons-test.c). Same argument as
 * reproducing BusyBox fdisk's partition bug with a sparse file instead
 * of a VM (RFC 0018): when a thing can be tested without booting, test
 * it without booting.
 */
#ifndef NOVI_PANEL_ICONS_H
#define NOVI_PANEL_ICONS_H

/* ── The apps grid (Lucide "layout-grid") ─────────────────────────── */
#define APPS_ICON_SQUARE 7
#define APPS_ICON_GAP 4
#define APPS_ICON_RADIUS 1
#define APPS_ICON_STROKE 2
#define APPS_ICON_SIZE (2 * APPS_ICON_SQUARE + APPS_ICON_GAP)

/* ── The network glyphs ───────────────────────────────────────────── */
#define NET_ICON_W 18
#define NET_ICON_H 13
#define NET_ICON_STROKE 1.7
#define NET_DOT_RADIUS 1.15
/* Arc radii, innermost first. The outermost plus half a stroke has to
 * fit inside NET_ICON_H, or the fan is clipped flat at the top. */
#define NET_ARC1 3.6
#define NET_ARC2 6.6
#define NET_ARC3 9.6
/* How far above the horizontal the fan opens: a point belongs to an
 * arc only where -y >= NET_FAN_SLOPE * r, so 0.62 gives roughly a
 * 104-degree fan, which is what the glyph reads as at this size. */
#define NET_FAN_SLOPE 0.62

/* Which elements the fan draws this pass: bit 0 is the dot, bits 1..3
 * the arcs outward. Two passes with complementary masks give a lit
 * prefix over a dim remainder without the blitter knowing anything
 * about signal strength. */
#define NET_FAN_ALL 0xfu

struct net_fan {
	unsigned mask;
	int slash; /* the offline diagonal */
};

/* ── The power glyph (Lucide "power") ─────────────────────────────── */
#define POWER_ICON_W 16
#define POWER_ICON_H 16
#define POWER_ICON_STROKE 1.7
/* The ring, and the gap at its top the stem passes through. The gap is
 * an angle rather than a box so it stays centred whatever the radius:
 * a point is on the ring only where it is outside the wedge
 * |x| <= POWER_GAP_HALF * -y, which for 0.42 opens roughly 46 degrees. */
#define POWER_RING_R 5.2
#define POWER_GAP_HALF 0.42
/* How far up the stem reaches from the centre. Slightly past the ring,
 * which is what makes the glyph read as a power symbol rather than a
 * broken circle. */
#define POWER_STEM_TOP 6.6
#define POWER_STEM_BOTTOM 0.6

/* ── The health warning glyph (Lucide "triangle-alert") ───────────── */
#define WARN_ICON_W 16
#define WARN_ICON_H 14
#define WARN_ICON_STROKE 1.7
#define WARN_TRI_RADIUS 1.2
/* The exclamation inside it: a stroke and a dot, both on the vertical
 * centre line. The stroke's span and the dot's centre are y offsets
 * from the icon's top. */
/* These four are tight against the triangle's own base line, and the
 * first attempt had the dot merged into it -- no dot, no gap, just a
 * bar, which reads as a completely different symbol. Caught by the
 * host test, not by looking: at 16px a swallowed dot and a short bar
 * are the same handful of pixels. */
#define WARN_BAR_TOP 4.0
#define WARN_BAR_BOTTOM 7.3
#define WARN_DOT_Y 9.5
#define WARN_DOT_HALF 0.9

/* ── The volume glyph (Lucide "volume-2" / "volume-x") ────────────── */
/* 20 wide and 16 tall, both larger than the network glyph's box, and
 * both because this glyph genuinely is larger: a speaker plus two
 * waves spans more than a fan does, and squeezing it into the
 * neighbouring icon's box just clips the ends off. The border
 * assertion in icons-test.c found each edge in turn. */
#define VOL_ICON_W 20
/* 16, not 14, and the two extra rows are the speaker's own. The cone's
 * mouth spans +/-5.5 about the centre; half a stroke and a pixel of
 * antialiasing put ink at 0.15 and 13.85 in a 14-row box, so the glyph
 * bled into both border rows. Caught by the same border assertion the
 * warning triangle carries -- at this size a mouth clipped flat top
 * and bottom just reads as a slightly boxy speaker. */
#define VOL_ICON_H 16
#define VOL_ICON_STROKE 1.7
/* Lucide's speaker polygon, scaled from its 24px box into this one and
 * expressed as offsets from the icon's centre. Six points, closed --
 * the throat is the flat left end, the cone flares right. Kept as a
 * traced polygon rather than "a box and a triangle" because the two
 * meet at a shoulder, and a union of two shapes draws that seam. */
#define VOL_BODY_POINTS 6
/* Where the sound comes out: the arcs are centred on the cone's tip,
 * not on the icon, so they stay concentric with the thing making them
 * whatever the radii become. */
#define VOL_TIP_X (-0.8)
#define VOL_ARC1 3.0
#define VOL_ARC2 5.6
/* How far off the horizontal the arcs open, mirroring NET_FAN_SLOPE:
 * a point is on an arc only where dx >= VOL_FAN_SLOPE * r, which at
 * 0.55 opens roughly 113 degrees to the right. */
#define VOL_FAN_SLOPE 0.55
/* The muted cross, in place of the arcs rather than on top of them.
 * A speaker with both waves AND a cross is two statements about the
 * same thing, and at 16px they simply overlap into a smudge. */
#define VOL_X_CX 4.2
#define VOL_X_HALF 2.2

/* Which arcs this pass draws: bit 0 is the inner, bit 1 the outer.
 * `muted` replaces them entirely. The body is always drawn -- an
 * indicator that vanishes at zero volume is one that cannot tell you
 * the volume is at zero. */
struct vol_glyph {
	unsigned arcs;
	int muted;
};

/* A per-pixel coverage mask, in icon-local coordinates. `ctx` carries
 * whatever the particular glyph needs (which arcs are lit, for the
 * wifi fan) and is ignored by glyphs that need nothing. */
typedef double (*icon_coverage_fn)(double x, double y, const void *ctx);

double novi_rounded_box_sdf(double px, double py, double half_w,
	double half_h, double radius);
double novi_stroke_coverage(double d, double half_stroke);

double novi_apps_icon_coverage(double x, double y, const void *ctx);
double novi_net_wifi_coverage(double x, double y, const void *ctx);
double novi_net_wired_coverage(double x, double y, const void *ctx);
double novi_power_coverage(double x, double y, const void *ctx);
double novi_warn_coverage(double x, double y, const void *ctx);
double novi_volume_coverage(double x, double y, const void *ctx);

#endif
