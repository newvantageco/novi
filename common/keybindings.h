/* keybindings.h — every keyboard shortcut this desktop has, once.
 *
 * novi-shell DISPATCHES from this table and novi-launcher --keys
 * DISPLAYS it. That is the whole reason it exists as a shared header
 * rather than as a nice list in the overlay: a shortcut sheet
 * maintained separately from the code that implements the shortcuts
 * drifts, and a sheet that drifts is worse than no sheet at all --
 * it is a document that confidently tells you the wrong key. This
 * repository has made the same call before, about `restore-build-
 * inputs.sh` restoring what the manifest names instead of "everything
 * except a blocklist": a derived answer cannot rot, a hand-maintained
 * second copy has to be updated by whoever adds the next entry, with
 * nothing to tell them.
 *
 * So there is exactly one way to add a shortcut to this desktop:
 * add a row here and handle its action in novi-shell. Forgetting the
 * second half gives you a row the compositor ignores; there is no way
 * at all to get a working binding that the sheet does not list.
 *
 * WHY A SHEET EXISTS. Until this, every binding below lived only in
 * novi-shell's own switch statement. A person who booted this image
 * had no way to discover Alt+Space, Super+L, Super+Escape or any of
 * the rest short of reading the source -- and a desktop whose keys
 * are undiscoverable is one you cannot use, however good the keys
 * are. GNOME and Pop!_OS both ship exactly this window; that is where
 * the idea comes from, and it was the most conspicuous thing this
 * desktop was missing.
 *
 * Included by exactly one translation unit per binary (each client's
 * main.c), so the `static const` table is one copy per program.
 *
 * xkbcommon only -- no wlroots. novi-launcher links xkbcommon and
 * links no wlroots, so the modifier bits below are OURS and novi-shell
 * maps them onto WLR_MODIFIER_* at the point of comparison. A header
 * shared by two binaries may only depend on what both of them have.
 */
#ifndef NOVI_KEYBINDINGS_H
#define NOVI_KEYBINDINGS_H

#include <xkbcommon/xkbcommon-keysyms.h>

#define NOVI_MOD_NONE  0u
#define NOVI_MOD_ALT   (1u << 0)
#define NOVI_MOD_LOGO  (1u << 1)
#define NOVI_MOD_SHIFT (1u << 2)

enum novi_action {
	NOVI_ACT_CYCLE_NEXT,
	NOVI_ACT_CYCLE_PREV,
	NOVI_ACT_LAUNCHER,
	NOVI_ACT_TERMINAL,
	NOVI_ACT_CLOSE,
	NOVI_ACT_WORKSPACE,
	NOVI_ACT_WORKSPACE_MOVE,
	NOVI_ACT_LOCK,
	NOVI_ACT_POWER_MENU,
	NOVI_ACT_SYMBOLS,
	NOVI_ACT_SHORTCUTS,
	NOVI_ACT_THEMES,
	NOVI_ACT_SCREENSHOT,
	NOVI_ACT_VOLUME_UP,
	NOVI_ACT_VOLUME_DOWN,
	NOVI_ACT_VOLUME_MUTE,
	NOVI_ACT_QUIT,
};

/* `sym` is the keysym to match. Two rows need more than that:
 * Super+[1-9] is nine keys, each with a shifted keysym of its own
 * (Super+Shift+3 arrives as XKB_KEY_numbersign, not XKB_KEY_3 -- see
 * workspace_digit_for_keysym() in novi-shell). DIGIT_RANGE says "match
 * any digit, and pass which one to the action", so those rows drive
 * dispatch like every other row rather than being display-only
 * entries sitting next to a hand-written special case. Display-only
 * rows are the drift this file exists to prevent, so there are none.
 */
#define NOVI_BIND_DIGIT_RANGE (1u << 0)
/* Runs even while the session is locked. Only the media keys carry it:
 * changing the volume discloses nothing and unlocks nothing, and
 * refusing it means you cannot silence a machine you have just locked
 * and walked away from. Made a property of the row rather than a
 * branch in novi-shell so that the policy is visible in the same place
 * as the binding it applies to -- "which keys work on the lock screen"
 * is a security question, and a security question answered by control
 * flow three functions away is one nobody re-reads. */
#define NOVI_BIND_WHEN_LOCKED (1u << 1)

/* MATCHING, in two passes, and the two passes are not fussiness.
 *
 * Pass 1 wants an exact modifier match, pass 2 accepts a row whose
 * modifiers are a subset of those held. Neither alone is right:
 *
 *   - Subset alone cannot tell Super+3 from Super+Shift+3, so moving a
 *     window to a workspace would just switch to it.
 *   - Exact alone breaks Alt+Shift+Tab, because most layouts deliver
 *     it as ISO_Left_Tab with the shift bit ALSO set -- the row names
 *     Alt because the keysym already carries the shift, so an exact
 *     comparison against Alt|Shift never matches.
 *
 * Exact-then-subset gives both, and reproduces what the hand-written
 * switch did before this table existed.
 *
 * Letter rows are written lowercase and compared through
 * xkb_keysym_to_lower(), so Super+Q works with Caps Lock on without
 * the sheet carrying a second row for the capital. */

struct novi_binding {
	unsigned mods;
	xkb_keysym_t sym;
	unsigned flags;
	enum novi_action action;
	/* Shown by novi-launcher --keys. `group` sorts the sheet and is
	 * searchable, so typing "window" finds the window bindings even
	 * when the word is in none of their descriptions. */
	const char *group;
	const char *keys;
	const char *what;
};

/* Ordered as the sheet reads, not as the compositor tests: the sheet
 * is the thing a person looks at, and the dispatch loop does not care.
 * Windows first because that is what a new user does first.
 *
 * The key text uses the names printed on a keyboard (Super, not Logo
 * or Meta; Return, not Enter -- though every keyboard disagrees about
 * that one) and a thin ellipsis for the digit ranges. */
static const struct novi_binding NOVI_BINDINGS[] = {
	{ NOVI_MOD_ALT, XKB_KEY_Tab, 0, NOVI_ACT_CYCLE_NEXT,
	  "Windows", "Alt + Tab", "Switch to the next window" },
	/* Most layouts report Shift+Tab as ISO_Left_Tab rather than as Tab
	 * with the shift bit set, which is why this row's modifier is Alt
	 * alone and its keysym carries the shift. */
	{ NOVI_MOD_ALT, XKB_KEY_ISO_Left_Tab, 0, NOVI_ACT_CYCLE_PREV,
	  "Windows", "Alt + Shift + Tab", "Switch to the previous window" },
	{ NOVI_MOD_LOGO, XKB_KEY_Return, 0, NOVI_ACT_TERMINAL,
	  "Windows", "Super + Return", "Open a terminal" },
	{ NOVI_MOD_LOGO, XKB_KEY_q, 0, NOVI_ACT_CLOSE,
	  "Windows", "Super + Q", "Close the focused window" },

	{ NOVI_MOD_LOGO, XKB_KEY_1, NOVI_BIND_DIGIT_RANGE, NOVI_ACT_WORKSPACE,
	  "Workspaces", "Super + 1…9", "Switch to a workspace" },
	{ NOVI_MOD_LOGO | NOVI_MOD_SHIFT, XKB_KEY_1, NOVI_BIND_DIGIT_RANGE,
	  NOVI_ACT_WORKSPACE_MOVE,
	  "Workspaces", "Super + Shift + 1…9", "Move the window to a workspace" },

	{ NOVI_MOD_ALT, XKB_KEY_space, 0, NOVI_ACT_LAUNCHER,
	  "Finding things", "Alt + Space", "Search apps, or do a sum" },
	{ NOVI_MOD_LOGO, XKB_KEY_period, 0, NOVI_ACT_SYMBOLS,
	  "Finding things", "Super + .", "Pick a symbol to copy" },
	{ NOVI_MOD_LOGO, XKB_KEY_slash, 0, NOVI_ACT_SHORTCUTS,
	  "Finding things", "Super + /", "Show this list" },
	{ NOVI_MOD_LOGO, XKB_KEY_t, 0, NOVI_ACT_THEMES,
	  "Finding things", "Super + T", "Change the colour theme" },
	{ NOVI_MOD_NONE, XKB_KEY_Print, 0, NOVI_ACT_SCREENSHOT,
	  "Finding things", "Print Screen", "Save a screenshot" },

	{ NOVI_MOD_NONE, XKB_KEY_XF86AudioRaiseVolume, NOVI_BIND_WHEN_LOCKED, NOVI_ACT_VOLUME_UP,
	  "Sound", "Volume Up", "Louder" },
	{ NOVI_MOD_NONE, XKB_KEY_XF86AudioLowerVolume, NOVI_BIND_WHEN_LOCKED, NOVI_ACT_VOLUME_DOWN,
	  "Sound", "Volume Down", "Quieter" },
	{ NOVI_MOD_NONE, XKB_KEY_XF86AudioMute, NOVI_BIND_WHEN_LOCKED, NOVI_ACT_VOLUME_MUTE,
	  "Sound", "Mute", "Mute or unmute" },

	{ NOVI_MOD_LOGO, XKB_KEY_l, 0, NOVI_ACT_LOCK,
	  "Session", "Super + L", "Lock the screen" },
	{ NOVI_MOD_LOGO, XKB_KEY_Escape, 0, NOVI_ACT_POWER_MENU,
	  "Session", "Super + Escape", "Lock, suspend, restart or shut down" },
	/* Listed even though it is a development convenience rather than
	 * part of RFC 0001's spec. A key that ends your session without
	 * warning is exactly the key a sheet must not omit -- leaving it
	 * out does not stop anyone pressing it, it only stops them
	 * understanding what happened. */
	{ NOVI_MOD_ALT, XKB_KEY_Escape, 0, NOVI_ACT_QUIT,
	  "Session", "Alt + Escape", "Quit the desktop (returns to a console)" },
};

#define NOVI_BINDINGS_COUNT \
	(sizeof(NOVI_BINDINGS) / sizeof(NOVI_BINDINGS[0]))

#endif
