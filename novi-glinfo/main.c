/* novi-glinfo — what GL this machine actually has, from a client's side.
 *
 * RFC 0025 put Mesa in the image and verified the COMPOSITOR's own
 * gles2 renderer end to end: EGL, GLESv2, softpipe, GBM, DRM. It did
 * not verify a single thing about a CLIENT, and a client takes an
 * entirely different path -- EGL's Wayland platform, and buffer
 * sharing back to the compositor. That path is the whole point of
 * shipping Mesa (a compositor could have gone on using pixman
 * forever), and until this program ran, nothing had exercised it.
 *
 * It is also the tool a person needs the moment they act on RFC 0025's
 * one tunable. `display.renderer = gles2` on a machine with a real GPU
 * is a guess until something says which driver answered; "GL renderer:
 * softpipe" and "GL renderer: iris" look identical from the outside,
 * and the difference is the entire reason the key exists.
 *
 *   novi-glinfo              print EGL and GL strings, then exit
 *   novi-glinfo --frames N   also open a window and render N frames
 *
 * The default is SURFACELESS -- no window, no buffer, nothing on
 * screen. That is not laziness: "can a client get a working GL
 * context" and "can a client put GL output on the screen" are separate
 * questions with separate answers, and on this system they genuinely
 * differ depending on which renderer the compositor is running. Asking
 * them one at a time is what makes the answer legible. `--frames`
 * asks the second.
 */
#define _GNU_SOURCE
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <wayland-client.h>
#include <wayland-egl.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>

#include "xdg-shell-protocol.h"

#define WINDOW_W 320
#define WINDOW_H 240

struct glinfo {
	struct wl_display *display;
	struct wl_registry *registry;
	struct wl_compositor *compositor;
	struct xdg_wm_base *wm_base;

	struct wl_surface *surface;
	struct xdg_surface *xdg_surface;
	struct xdg_toplevel *toplevel;
	struct wl_egl_window *egl_window;

	EGLDisplay egl_display;
	EGLContext egl_context;
	EGLSurface egl_surface;
	EGLConfig egl_config;

	bool configured;
	bool closed;
};

/* Every EGL entry point returns a code rather than setting errno, and
 * the codes are the only way to tell "this machine has no GL" from
 * "this program asked for something silly". Printing the name matters:
 * EGL_BAD_ALLOC from eglCreateWindowSurface on a compositor that
 * cannot import GPU buffers is a completely different problem from
 * EGL_NOT_INITIALIZED, and a bare "failed" hides which one you have. */
static const char *egl_error_name(EGLint err) {
	switch (err) {
	case EGL_SUCCESS:             return "EGL_SUCCESS";
	case EGL_NOT_INITIALIZED:     return "EGL_NOT_INITIALIZED";
	case EGL_BAD_ACCESS:          return "EGL_BAD_ACCESS";
	case EGL_BAD_ALLOC:           return "EGL_BAD_ALLOC";
	case EGL_BAD_ATTRIBUTE:       return "EGL_BAD_ATTRIBUTE";
	case EGL_BAD_CONFIG:          return "EGL_BAD_CONFIG";
	case EGL_BAD_CONTEXT:         return "EGL_BAD_CONTEXT";
	case EGL_BAD_CURRENT_SURFACE: return "EGL_BAD_CURRENT_SURFACE";
	case EGL_BAD_DISPLAY:         return "EGL_BAD_DISPLAY";
	case EGL_BAD_MATCH:           return "EGL_BAD_MATCH";
	case EGL_BAD_NATIVE_WINDOW:   return "EGL_BAD_NATIVE_WINDOW";
	case EGL_BAD_PARAMETER:       return "EGL_BAD_PARAMETER";
	case EGL_BAD_SURFACE:         return "EGL_BAD_SURFACE";
	case EGL_CONTEXT_LOST:        return "EGL_CONTEXT_LOST";
	default:                      return "an unrecognised EGL error";
	}
}

static void fail(const char *what) {
	EGLint err = eglGetError();
	fprintf(stderr, "novi-glinfo: %s: %s (0x%x)\n", what,
		egl_error_name(err), (unsigned)err);
	exit(1);
}

/* ── Wayland ───────────────────────────────────────────────────── */

static void wm_base_ping(void *data, struct xdg_wm_base *b, uint32_t serial) {
	xdg_wm_base_pong(b, serial);
}
static const struct xdg_wm_base_listener wm_base_listener = {
	.ping = wm_base_ping,
};

static void registry_global(void *data, struct wl_registry *registry,
		uint32_t name, const char *interface, uint32_t version) {
	struct glinfo *g = data;
	if (strcmp(interface, wl_compositor_interface.name) == 0) {
		g->compositor = wl_registry_bind(registry, name,
			&wl_compositor_interface, 4);
	} else if (strcmp(interface, xdg_wm_base_interface.name) == 0) {
		g->wm_base = wl_registry_bind(registry, name,
			&xdg_wm_base_interface, 1);
		xdg_wm_base_add_listener(g->wm_base, &wm_base_listener, g);
	}
}
static void registry_global_remove(void *data, struct wl_registry *r,
		uint32_t name) {}
static const struct wl_registry_listener registry_listener = {
	.global = registry_global,
	.global_remove = registry_global_remove,
};

static void xdg_surface_configure(void *data, struct xdg_surface *s,
		uint32_t serial) {
	struct glinfo *g = data;
	xdg_surface_ack_configure(s, serial);
	g->configured = true;
}
static const struct xdg_surface_listener xdg_surface_listener = {
	.configure = xdg_surface_configure,
};

static void toplevel_configure(void *data, struct xdg_toplevel *t,
		int32_t w, int32_t h, struct wl_array *states) {}
static void toplevel_close(void *data, struct xdg_toplevel *t) {
	struct glinfo *g = data;
	g->closed = true;
}
static const struct xdg_toplevel_listener toplevel_listener = {
	.configure = toplevel_configure,
	.close = toplevel_close,
};

/* ── Reporting ─────────────────────────────────────────────────── */

/* Mesa's software rasterisers name themselves in GL_RENDERER, and
 * saying so out loud is most of this program's value. A person who has
 * just set `display.renderer = gles2` expecting their GPU to be used
 * cannot tell from "Mesa" alone whether anything changed -- and
 * software rendering is not a failure, so it must not read as one. */
static bool renderer_is_software(const char *renderer) {
	if (renderer == NULL) {
		return false;
	}
	return strstr(renderer, "softpipe") != NULL ||
		strstr(renderer, "llvmpipe") != NULL ||
		strstr(renderer, "swrast") != NULL ||
		strstr(renderer, "SWR") != NULL;
}

static void print_strings(struct glinfo *g) {
	const char *gl_renderer = (const char *)glGetString(GL_RENDERER);

	printf("EGL vendor        %s\n", eglQueryString(g->egl_display, EGL_VENDOR));
	printf("EGL version       %s\n", eglQueryString(g->egl_display, EGL_VERSION));
	printf("EGL client APIs   %s\n",
		eglQueryString(g->egl_display, EGL_CLIENT_APIS));
	printf("GL vendor         %s\n", (const char *)glGetString(GL_VENDOR));
	printf("GL renderer       %s\n", gl_renderer);
	printf("GL version        %s\n", (const char *)glGetString(GL_VERSION));
	printf("GLSL version      %s\n",
		(const char *)glGetString(GL_SHADING_LANGUAGE_VERSION));
	printf("acceleration      %s\n", renderer_is_software(gl_renderer)
		? "software (no GPU driver answered)"
		: "hardware (a GPU driver answered)");
}

/* ── Rendering ─────────────────────────────────────────────────── */

/* Deliberately the dumbest possible frame: glClear to a known colour
 * and swap. There is no shader, no geometry and no texture, because
 * the question being asked is not "does GL work" -- the strings above
 * already answered that -- it is "will the compositor ACCEPT what a GL
 * client produces". A cleared buffer tests that as well as a rotating
 * cube does, and when it fails it fails in one place. */
static bool render_frames(struct glinfo *g, int frames) {
	for (int i = 0; i < frames && !g->closed; i++) {
		/* A colour per frame, so a screenshot says WHICH frame it
		 * caught rather than merely that something was drawn. */
		float t = frames > 1 ? (float)i / (float)(frames - 1) : 0.0f;
		glViewport(0, 0, WINDOW_W, WINDOW_H);
		glClearColor(0.11f, 0.29f + 0.4f * t, 0.35f + 0.2f * t, 1.0f);
		glClear(GL_COLOR_BUFFER_BIT);

		if (eglSwapBuffers(g->egl_display, g->egl_surface) != EGL_TRUE) {
			EGLint err = eglGetError();
			fprintf(stderr, "novi-glinfo: frame %d: eglSwapBuffers failed: "
				"%s (0x%x)\n", i, egl_error_name(err), (unsigned)err);
			return false;
		}
		/* Round-trip so the compositor has actually seen the commit
		 * before the next frame is drawn -- otherwise "N frames
		 * swapped" is a claim about this process and not about the
		 * compositor, which is the thing under test. */
		wl_display_roundtrip(g->display);
	}
	printf("frames            %d swapped and committed\n", frames);
	return true;
}

int main(int argc, char *argv[]) {
	struct glinfo g = {0};
	int frames = 0;

	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--frames") == 0 && i + 1 < argc) {
			frames = atoi(argv[++i]);
			if (frames < 1) {
				fprintf(stderr, "novi-glinfo: --frames needs a count >= 1\n");
				return 1;
			}
		} else if (strcmp(argv[i], "-h") == 0 ||
				strcmp(argv[i], "--help") == 0) {
			printf("novi-glinfo — what GL this machine actually has\n\n"
				"  novi-glinfo              print EGL and GL strings\n"
				"  novi-glinfo --frames N   also render N frames to a window\n\n"
				"The renderer the COMPOSITOR uses is a separate setting:\n"
				"  novi-state set display.renderer gles2   # or pixman, auto\n");
			return 0;
		} else {
			fprintf(stderr, "novi-glinfo: unknown argument '%s'\n", argv[i]);
			return 1;
		}
	}

	g.display = wl_display_connect(NULL);
	if (g.display == NULL) {
		fprintf(stderr, "novi-glinfo: no Wayland display "
			"(is WAYLAND_DISPLAY set, and is a compositor running?)\n");
		return 1;
	}
	g.registry = wl_display_get_registry(g.display);
	wl_registry_add_listener(g.registry, &registry_listener, &g);
	wl_display_roundtrip(g.display);

	if (g.compositor == NULL) {
		fprintf(stderr, "novi-glinfo: the compositor offers no wl_compositor\n");
		return 1;
	}

	/* eglGetPlatformDisplay, not eglGetDisplay. The old call takes an
	 * opaque native handle and GUESSES the platform from it, which on
	 * a machine that could plausibly mean X11, GBM or Wayland is a
	 * guess with three wrong answers available. Mesa here is built
	 * `-Dplatforms=wayland`, so naming the platform is also the check
	 * that it was. */
	PFNEGLGETPLATFORMDISPLAYEXTPROC get_platform_display =
		(PFNEGLGETPLATFORMDISPLAYEXTPROC)
		eglGetProcAddress("eglGetPlatformDisplayEXT");
	if (get_platform_display != NULL) {
		g.egl_display = get_platform_display(EGL_PLATFORM_WAYLAND_EXT,
			g.display, NULL);
	} else {
		g.egl_display = eglGetDisplay((EGLNativeDisplayType)g.display);
	}
	if (g.egl_display == EGL_NO_DISPLAY) {
		fail("could not open an EGL display on the Wayland platform");
	}

	EGLint major = 0, minor = 0;
	if (eglInitialize(g.egl_display, &major, &minor) != EGL_TRUE) {
		fail("eglInitialize");
	}
	if (eglBindAPI(EGL_OPENGL_ES_API) != EGL_TRUE) {
		fail("eglBindAPI(EGL_OPENGL_ES_API)");
	}

	static const EGLint config_attrs[] = {
		EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
		EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
		EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8,
		EGL_ALPHA_SIZE, 8,
		EGL_NONE,
	};
	EGLint n = 0;
	if (eglChooseConfig(g.egl_display, config_attrs, &g.egl_config, 1, &n)
			!= EGL_TRUE || n < 1) {
		fail("no EGL config with a GLES2-renderable 8888 window");
	}

	static const EGLint context_attrs[] = {
		EGL_CONTEXT_CLIENT_VERSION, 2,
		EGL_NONE,
	};
	g.egl_context = eglCreateContext(g.egl_display, g.egl_config,
		EGL_NO_CONTEXT, context_attrs);
	if (g.egl_context == EGL_NO_CONTEXT) {
		fail("eglCreateContext");
	}

	if (frames > 0) {
		if (g.wm_base == NULL) {
			fprintf(stderr, "novi-glinfo: the compositor offers no "
				"xdg_wm_base, so there is no way to open a window\n");
			return 1;
		}
		g.surface = wl_compositor_create_surface(g.compositor);
		g.xdg_surface = xdg_wm_base_get_xdg_surface(g.wm_base, g.surface);
		xdg_surface_add_listener(g.xdg_surface, &xdg_surface_listener, &g);
		g.toplevel = xdg_surface_get_toplevel(g.xdg_surface);
		xdg_toplevel_add_listener(g.toplevel, &toplevel_listener, &g);
		xdg_toplevel_set_title(g.toplevel, "novi-glinfo");
		xdg_toplevel_set_app_id(g.toplevel, "novi-glinfo");
		/* Commit with no buffer first, then wait: an xdg_surface is
		 * not configured until the compositor says so, and attaching
		 * before that is a protocol error. Same initial-commit rule
		 * novi-shell's own decoration code has to obey from the other
		 * side. */
		wl_surface_commit(g.surface);
		while (!g.configured && wl_display_dispatch(g.display) != -1) {
		}

		g.egl_window = wl_egl_window_create(g.surface, WINDOW_W, WINDOW_H);
		if (g.egl_window == NULL) {
			fprintf(stderr, "novi-glinfo: wl_egl_window_create failed\n");
			return 1;
		}
		g.egl_surface = eglCreateWindowSurface(g.egl_display, g.egl_config,
			(EGLNativeWindowType)g.egl_window, NULL);
		if (g.egl_surface == EGL_NO_SURFACE) {
			fail("eglCreateWindowSurface");
		}
		if (eglMakeCurrent(g.egl_display, g.egl_surface, g.egl_surface,
				g.egl_context) != EGL_TRUE) {
			fail("eglMakeCurrent (windowed)");
		}
	} else {
		/* Surfaceless. EGL_KHR_surfaceless_context is what makes this
		 * legal; without it there is no way to have a current context
		 * and no window, and the strings below could only be read by
		 * putting something on screen. Mesa has had it for years, but
		 * check rather than assume -- an unchecked eglMakeCurrent with
		 * EGL_NO_SURFACE fails with EGL_BAD_MATCH, which says nothing
		 * about the actual reason. */
		const char *exts = eglQueryString(g.egl_display, EGL_EXTENSIONS);
		if (exts == NULL ||
				strstr(exts, "EGL_KHR_surfaceless_context") == NULL) {
			fprintf(stderr, "novi-glinfo: this EGL has no "
				"EGL_KHR_surfaceless_context; re-run with --frames 1 "
				"to query through a real window instead\n");
			return 1;
		}
		if (eglMakeCurrent(g.egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE,
				g.egl_context) != EGL_TRUE) {
			fail("eglMakeCurrent (surfaceless)");
		}
	}

	printf("EGL platform      Wayland (%d.%d)\n", (int)major, (int)minor);
	printf("EGL surface       %s\n", frames > 0
		? "a real window" : "surfaceless (no window)");
	print_strings(&g);

	bool ok = true;
	if (frames > 0) {
		ok = render_frames(&g, frames);
	}

	/* No teardown beyond this: the process is about to exit and the
	 * kernel is better at releasing these than a hand-written cleanup
	 * path that only ever runs on the success case. */
	return ok ? 0 : 1;
}
