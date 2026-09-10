/* common/theme-test.c — the palette invariants, asserted on the host.
 *
 * RFC 0030's roadmap item 2. Both bugs that RFC found were found BY
 * LOOKING: `paper` was shipped, a screendump was taken, and two things
 * that had been wrong for the life of their files became obvious. That
 * worked, and it does not scale -- the next palette mistake needs
 * somebody to boot an image, switch themes and notice.
 *
 * So: every shipped theme is parsed by the REAL loader (common/theme.c,
 * linked here, not a reimplementation of it -- a second parser is a
 * second thing to get wrong) and checked against the invariants §1 of
 * the design language actually states. No Wayland, no compositor, no
 * VM; it builds with the host compiler and runs in the lint pass, the
 * same argument novi-panel/icons-test.c makes about icon geometry.
 *
 * WHAT THIS CAN AND CANNOT CATCH. It checks the palette as a
 * DOCUMENT: that the layers are ordered, that text is readable on the
 * ground it sits on, that a token is not missing. It cannot catch a
 * client that ignores the palette and draws its own hex (that is the
 * three greps in CLAUDE.md) or arithmetic that mangles a token on its
 * way to a pixel (that was novi-shell's unsigned wrap). Those are
 * different bug classes with different tools; this one is for the
 * theme files.
 */
#include "theme.h"

#include <dirent.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int checks;
static int failures;

static void ok(int cond, const char *theme, const char *what)
{
	checks++;
	if (!cond) {
		failures++;
		fprintf(stderr, "FAIL: %s: %s\n", theme, what);
	}
}

/* Relative luminance, WCAG 2.x. Not "average the channels": the eye is
 * far more sensitive to green than to blue, and a naive mean calls
 * pure blue and pure green equally bright -- which would pass a
 * contrast check on text nobody can read. */
static double lum(uint32_t c)
{
	double ch[3] = { NOVI_R(c) / 255.0, NOVI_G(c) / 255.0, NOVI_B(c) / 255.0 };
	for (int i = 0; i < 3; i++) {
		ch[i] = ch[i] <= 0.04045 ? ch[i] / 12.92
				         : pow((ch[i] + 0.055) / 1.055, 2.4);
	}
	return 0.2126 * ch[0] + 0.7152 * ch[1] + 0.0722 * ch[2];
}

static double contrast(uint32_t a, uint32_t b)
{
	double la = lum(a), lb = lum(b);
	if (la < lb) { double t = la; la = lb; lb = t; }
	return (la + 0.05) / (lb + 0.05);
}

/* base -> panel -> card is an ELEVATION LADDER and must be monotonic.
 * bg.card-raised is NOT the fourth rung of it.
 *
 * That distinction is the first thing this test taught me, by failing
 * on `paper` when it had no business failing. theme.h says what each
 * token is: base is "desktop, behind everything", panel is
 * "non-floating chrome", card is "floating cards, toasts, windows" --
 * three grounds, each further forward. card-raised is "a card on a
 * card; hovered row", which is a VARIANT of card, not a storey above
 * it.
 *
 * On a light palette card is often pure white, and then a hovered row
 * on it can only go darker. Asserting one direction across all four
 * therefore fails a palette that is completely correct. `paper` does
 * exactly this: 0.854 -> 0.930 -> 1.000 up the ladder, then 0.821 for
 * the hovered row.
 *
 * The direction of the ladder itself is deliberately not fixed. §1
 * says "a fixed step lighter than the one below", which was written by
 * somebody thinking only about dark palettes; what actually matters is
 * that it does not WANDER, because elevation has to read from colour
 * alone before any shadow is drawn. */
static void check_elevation(const struct novi_palette *p, const char *name)
{
	double l[3] = { lum(p->bg_base), lum(p->bg_panel), lum(p->bg_card) };
	int rising = 1, falling = 1;

	for (int i = 1; i < 3; i++) {
		if (l[i] <= l[i - 1]) rising = 0;
		if (l[i] >= l[i - 1]) falling = 0;
	}
	ok(rising || falling, name,
	   "bg.base -> bg.panel -> bg.card must move monotonically");

	/* The hovered row only has to be a VISIBLE step off the card it
	 * sits on; which way is the palette's business. */
	ok(contrast(p->bg_card_raised, p->bg_card) >= 1.04, name,
	   "bg.card-raised must be a visible step from bg.card");
}

static void check_theme(const struct novi_palette *p, const char *name)
{
	check_elevation(p, name);

	/* Body text on the surfaces it is actually drawn on. 4.5:1 is
	 * WCAG AA for normal text; this desktop's body size is 13px,
	 * which is squarely "normal". */
	ok(contrast(p->text_primary, p->bg_base) >= 4.5, name,
	   "text.primary on bg.base must reach 4.5:1");
	ok(contrast(p->text_primary, p->bg_panel) >= 4.5, name,
	   "text.primary on bg.panel must reach 4.5:1");
	ok(contrast(p->text_primary, p->bg_card) >= 4.5, name,
	   "text.primary on bg.card must reach 4.5:1");

	/* Secondary is deliberately quieter, so it gets AA-large (3:1)
	 * rather than 4.5. Muted is quieter still and is not asserted:
	 * it is for text whose job is to recede. */
	ok(contrast(p->text_secondary, p->bg_card) >= 3.0, name,
	   "text.secondary on bg.card must reach 3:1");

	/* THE ONE A DARK PALETTE HIDES. text.on-accent is the only
	 * token whose ground is not a background layer, so it is the
	 * easiest to set by copying the theme above it and never
	 * looking -- and on a light palette the correct answer flips
	 * from near-black to near-white. */
	ok(contrast(p->text_on_accent, p->accent) >= 4.5, name,
	   "text.on-accent on accent must reach 4.5:1");

	/* accent.active is DARKER than accent, so a pressed control sinks
	 * in -- theme.h says so, and both a dark and a light palette
	 * agree on it.
	 *
	 * accent.hover only has to DIFFER. "Hover is lighter" is dark-
	 * palette thinking, and this test asserted it until `paper`
	 * refused: on a light ground the more prominent colour is the
	 * darker one, so paper goes accent -> hover -> active all
	 * downwards and is right to. */
	ok(contrast(p->accent_hover, p->accent) >= 1.04, name,
	   "accent.hover must be a visible step from accent");
	ok(lum(p->accent_active) < lum(p->accent), name,
	   "accent.active must be darker than accent (a pressed control sinks)");

	/* accent.subtle is a wash BEHIND a selected row, so text has to
	 * survive on it -- it is a background, whatever its name says. */
	ok(contrast(p->text_primary, p->accent_subtle) >= 4.5, name,
	   "text.primary on accent.subtle must reach 4.5:1");

	/* The status colours have to be READABLE where they are drawn.
	 *
	 * Not "distinguishable from each other by luminance", which is
	 * what this checked first and which is the wrong instrument:
	 * green and red are told apart by HUE, and a correct pair can sit
	 * at almost identical brightness. paper's are 1.29 apart and
	 * axiom's 1.65 -- both fine, and a threshold that passed one
	 * would have failed the other for no reason. Distinguishing them
	 * for a colour-blind reader is a real problem and it is not one a
	 * contrast ratio can speak to; it is why the panel pairs its
	 * health colour with a glyph rather than relying on the hue. */
	ok(contrast(p->status_success, p->bg_card) >= 3.0, name,
	   "status.success must be readable on bg.card");
	ok(contrast(p->status_error, p->bg_card) >= 3.0, name,
	   "status.error must be readable on bg.card");
	ok(contrast(p->status_warning, p->bg_card) >= 3.0, name,
	   "status.warning must be readable on bg.card");
	ok(p->status_success != p->status_error &&
	   p->status_success != p->status_warning &&
	   p->status_warning != p->status_error, name,
	   "the three status colours must not be equal");

	/* A border that cannot be seen against the card it outlines is
	 * not a border. Deliberately loose: these are hairlines and are
	 * meant to be quiet. */
	ok(contrast(p->border_subtle, p->bg_card) >= 1.05, name,
	   "border.subtle must be visible against bg.card");
	ok(contrast(p->border_strong, p->border_subtle) >= 1.05, name,
	   "border.strong must differ from border.subtle");
}

int main(void)
{
	const char *dir = "rootfs/usr/share/novi/themes";
	DIR *d = opendir(dir);
	struct dirent *e;
	int themes = 0;

	if (d == NULL) {
		fprintf(stderr, "FAIL: cannot open %s (run from the repo root)\n", dir);
		return 1;
	}
	while ((e = readdir(d)) != NULL) {
		char name[64];
		size_t n = strlen(e->d_name);
		struct novi_palette p;

		if (n < 7 || strcmp(e->d_name + n - 6, ".theme") != 0)
			continue;
		if (n - 6 >= sizeof name)
			continue;
		memcpy(name, e->d_name, n - 6);
		name[n - 6] = '\0';

		/* novi_theme_read() reads NOVI_THEME_DIR, which is an
		 * absolute path on the target. Parse the repo copy
		 * directly instead -- same loader, same file. */
		if (!novi_theme_read_from(dir, name, &p)) {
			fprintf(stderr, "FAIL: %s: could not be parsed\n", name);
			failures++;
			continue;
		}
		themes++;
		check_theme(&p, name);
	}
	closedir(d);

	/* A test that silently checked nothing would pass. The shipped
	 * set is four; fewer than that means the glob or the path is
	 * wrong, not that the palettes are fine. */
	if (themes < 4) {
		fprintf(stderr, "FAIL: found %d theme(s), expected at least 4"
			" -- is the path right?\n", themes);
		failures++;
	}

	if (failures > 0) {
		fprintf(stderr, "theme: %d check(s) FAILED of %d across %d theme(s)\n",
			failures, checks, themes);
		return 1;
	}
	printf("theme: %d checks passed across %d themes\n", checks, themes);
	return 0;
}
