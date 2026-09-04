/* svg2icon -- offline SVG-to-bitmap generator (ICON-PIPELINE.md Stage 1).
 *
 * Host-only, never cross-compiled or packaged (see
 * third_party/nanosvg/NOTICE.md). Reads the fixed, known-at-build-time
 * icon set under svg/, rasterizes each to the exact sizes novi-shell /
 * novi-panel / novi-launcher actually need, and writes
 * ../../icons_generated.c (shared/icons/icons_generated.c): plain C
 * arrays of 8-bit alpha coverage (0 = transparent, 255 = fully covered),
 * the same "generated once, committed,
 * reviewed like any other diff" discipline the hand-authored FONT[] table
 * used before it, except the source of truth here is a real vendored SVG
 * file instead of hand-counted bits.
 *
 * Also prints an ASCII-art preview of every icon it generates, at the
 * size it was actually rasterized -- the substitute, in this host-only
 * tool, for the QEMU screendump pixel-checks the rest of this repo's UI
 * work is verified with: there is no compositor to boot here, but the
 * generated bitmap *is* the final artifact, so looking directly at it
 * (rather than trusting the rasterizer blindly) is the same discipline
 * applied to the thing that's actually different this time.
 */

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define NANOSVG_IMPLEMENTATION
#include "third_party/nanosvg/nanosvg.h"
#define NANOSVGRAST_IMPLEMENTATION
#include "third_party/nanosvg/nanosvgrast.h"

struct icon_job {
	const char *enum_name;   /* ICON_xxx, must match shared/icons/icons.h */
	const char *c_name;      /* array name in generated output */
	const char *svg_path;    /* relative to this tool's directory */
	int size;                /* square output size in pixels */
};

/* Lucide's icons are all authored on a 24x24 viewBox (confirmed by
 * reading every vendored file's <svg> tag before this table was written,
 * not assumed) -- app-grid icons are rasterized 1:1 at that native size,
 * status-bar/disclosure glyphs at the smaller 16x16 ICON-PIPELINE.md
 * calls for. */
static const struct icon_job JOBS[] = {
	{ "ICON_TERMINAL",      "icon_terminal_px",      "svg/terminal.svg",      24 },
	{ "ICON_FOLDER",        "icon_folder_px",        "svg/folder.svg",        24 },
	{ "ICON_GLOBE",         "icon_globe_px",         "svg/globe.svg",         24 },
	{ "ICON_PENCIL",        "icon_pencil_px",        "svg/pencil.svg",        24 },
	{ "ICON_PACKAGE",       "icon_package_px",       "svg/package.svg",       24 },
	{ "ICON_SETTINGS",      "icon_settings_px",      "svg/settings.svg",      24 },
	{ "ICON_SHIELD",        "icon_shield_px",        "svg/shield.svg",        24 },
	{ "ICON_WIFI",          "icon_wifi_px",          "svg/wifi.svg",          16 },
	{ "ICON_BATTERY",       "icon_battery_px",       "svg/battery.svg",       16 },
	{ "ICON_POWER",         "icon_power_px",         "svg/power.svg",         16 },
	{ "ICON_CHEVRON_RIGHT", "icon_chevron_right_px", "svg/chevron-right.svg", 16 },
	{ "ICON_CHEVRON_DOWN",  "icon_chevron_down_px",  "svg/chevron-down.svg",  16 },
};

/* nanosvg parses colors from a fixed keyword/hex table and has no notion
 * of CSS custom properties -- Lucide's source SVGs use
 * stroke="currentColor" (meant to inherit a color from CSS context,
 * meaningless outside a browser). Since this pipeline only keeps
 * coverage (the alpha channel) and throws the color away regardless
 * (draw_icon() applies its own fg_color at blit time -- see
 * icon_blit.h), any concrete color placeholder works; substituting a
 * real hex color here avoids relying on nanosvg's unspecified fallback
 * for a color keyword it doesn't recognize. */
static char *load_and_patch_svg(const char *path) {
	FILE *f = fopen(path, "rb");
	if (!f) {
		fprintf(stderr, "svg2icon: cannot open %s: %s\n", path, strerror(errno));
		return NULL;
	}
	fseek(f, 0, SEEK_END);
	long len = ftell(f);
	fseek(f, 0, SEEK_SET);
	char *raw = malloc((size_t)len + 1);
	if (fread(raw, 1, (size_t)len, f) != (size_t)len) {
		fprintf(stderr, "svg2icon: short read on %s\n", path);
		fclose(f);
		free(raw);
		return NULL;
	}
	fclose(f);
	raw[len] = '\0';

	/* "currentColor" (12 bytes) -> "#000000" (7 bytes) + padding spaces,
	 * done in place since the replacement is never longer than the
	 * original -- nsvgParse() is also fine with the trailing spaces
	 * inside an attribute value. */
	char *out = malloc((size_t)len + 1);
	const char *needle = "currentColor";
	size_t needle_len = strlen(needle);
	const char *src = raw;
	char *dst = out;
	while (*src) {
		if (strncmp(src, needle, needle_len) == 0) {
			memcpy(dst, "#000000", 7);
			dst += 7;
			src += needle_len;
		} else {
			*dst++ = *src++;
		}
	}
	*dst = '\0';
	free(raw);
	return out;
}

static void print_ascii_preview(const uint8_t *coverage, int size) {
	/* Two ramps of density per row-pair would be nicer, but a flat
	 * 4-level ramp sampled straight from the coverage byte is enough to
	 * visually confirm shape/proportions against the real icon by eye. */
	static const char ramp[] = " .:+#";
	for (int y = 0; y < size; y++) {
		for (int x = 0; x < size; x++) {
			uint8_t c = coverage[y * size + x];
			int level = (c * 4) / 255;
			if (level > 4) level = 4;
			fputc(ramp[level], stdout);
			fputc(ramp[level], stdout); /* double width: roughly square cells in a terminal */
		}
		fputc('\n', stdout);
	}
}

static int generate_one(const struct icon_job *job, FILE *out) {
	char *patched = load_and_patch_svg(job->svg_path);
	if (!patched) return -1;

	NSVGimage *image = nsvgParse(patched, "px", 96);
	free(patched);
	if (!image) {
		fprintf(stderr, "svg2icon: failed to parse %s\n", job->svg_path);
		return -1;
	}

	float scale = (float)job->size / image->width;
	int size = job->size;
	uint8_t *rgba = calloc((size_t)size * (size_t)size, 4);
	NSVGrasterizer *rast = nsvgCreateRasterizer();
	nsvgRasterize(rast, image, 0, 0, scale, rgba, size, size, size * 4);
	nsvgDeleteRasterizer(rast);
	nsvgDelete(image);

	uint8_t *coverage = malloc((size_t)size * (size_t)size);
	for (int i = 0; i < size * size; i++) {
		coverage[i] = rgba[i * 4 + 3]; /* alpha channel only */
	}
	free(rgba);

	printf("== %s (%s, %dx%d) ==\n", job->enum_name, job->svg_path, size, size);
	print_ascii_preview(coverage, size);
	printf("\n");

	fprintf(out, "/* %s -- generated from %s at %dx%d. */\n",
		job->c_name, job->svg_path, size, size);
	fprintf(out, "static const uint8_t %s[%d] = {\n", job->c_name, size * size);
	for (int y = 0; y < size; y++) {
		fprintf(out, "\t");
		for (int x = 0; x < size; x++) {
			fprintf(out, "%3u,", coverage[y * size + x]);
		}
		fprintf(out, "\n");
	}
	fprintf(out, "};\n\n");

	free(coverage);
	return 0;
}

int main(void) {
	const char *out_path = "../../icons_generated.c";
	FILE *out = fopen(out_path, "w");
	if (!out) {
		fprintf(stderr, "svg2icon: cannot open %s for writing: %s\n",
			out_path, strerror(errno));
		return 1;
	}

	fprintf(out, "/* GENERATED FILE -- do not hand-edit.\n");
	fprintf(out, " * Produced by shared/icons/tools/svg2icon/svg2icon.c (ICON-PIPELINE.md\n");
	fprintf(out, " * Stage 1) from the vendored SVG sources under\n");
	fprintf(out, " * shared/icons/tools/svg2icon/svg/ (see that directory's MANIFEST.md for\n");
	fprintf(out, " * provenance). Re-run `make generate` in that directory to regenerate\n");
	fprintf(out, " * after adding or changing an icon, then review the diff. */\n\n");
	fprintf(out, "#include <stdint.h>\n");
	fprintf(out, "#include \"icons.h\"\n\n");

	int failed = 0;
	size_t n = sizeof(JOBS) / sizeof(JOBS[0]);
	for (size_t i = 0; i < n; i++) {
		if (generate_one(&JOBS[i], out) != 0) failed = 1;
	}

	fprintf(out, "const struct novi_icon novi_icons[NOVI_ICON_COUNT] = {\n");
	for (size_t i = 0; i < n; i++) {
		fprintf(out, "\t[%s] = { %d, %d, %s },\n",
			JOBS[i].enum_name, JOBS[i].size, JOBS[i].size, JOBS[i].c_name);
	}
	fprintf(out, "};\n");

	fclose(out);

	if (failed) {
		fprintf(stderr, "svg2icon: one or more icons failed, %s is incomplete\n", out_path);
		return 1;
	}
	printf("svg2icon: wrote %s (%zu icons)\n", out_path, n);
	return 0;
}
