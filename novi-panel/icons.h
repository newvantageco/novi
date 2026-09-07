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

#endif
