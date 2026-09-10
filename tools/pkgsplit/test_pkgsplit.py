#!/usr/bin/env python3
"""Host tests for pkgsplit's meta-package checks.

These exist because the thing they check is otherwise almost
impossible to watch fail. `40-repo.sh` wipes /build/repo before
running pkgsplit and refuses outright on an already-split rootfs, so
provoking the error for real costs a full content rebuild -- and
CLAUDE.md's rule is that a check nobody has seen fail is a check
nobody knows works.

Run by scripts/lint.sh.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pkgsplit  # noqa: E402  (importing it also runs its own table check)

checks = 0


def ok(cond, what):
    global checks
    checks += 1
    if not cond:
        raise SystemExit("FAIL: %s" % what)


# ── check_meta_members_built ─────────────────────────────────────────
#
# The regression: this used to be a silent filter
# (`[d for d in deps if d in contents]`), so a client missing from the
# build came out as a meta-package with one fewer name and no error.
# `pkg install novi-desktop` then succeeded and produced a desktop with
# no wallpaper and no notifications.

got = pkgsplit.check_meta_members_built(
    "novi-desktop", ["novi-shell", "novi-panel"],
    {"novi-shell": [], "novi-panel": [], "unrelated": []})
ok(got == ["novi-shell", "novi-panel"], "all members present passes through unchanged")

try:
    pkgsplit.check_meta_members_built(
        "novi-desktop", ["novi-shell", "novi-bg", "novi-notifyd"],
        {"novi-shell": []})
    ok(False, "an absent member must raise")
except SystemExit as e:
    msg = str(e)
    ok("novi-bg" in msg and "novi-notifyd" in msg, "the error names every absent member")
    ok("novi-shell" not in msg.split("A meta-package")[0], "it does not name members that ARE present")
    ok("--to 39" in msg, "it points at the correct rebuild range")

# The empty case is not an error: a meta-package with no members is
# odd but it is not this check's business to have an opinion.
ok(pkgsplit.check_meta_members_built("x", [], {}) == [], "no members is not a failure")

# ── the table check that already existed ─────────────────────────────
#
# Importing pkgsplit runs _check_meta_covers_first_party() at module
# scope, so reaching this line at all means every OS-category package
# in PACKAGE_TABLE is named by some meta-package. Assert the inverse
# direction explicitly too, since that is the pairing that matters.
covered = set()
for _, _, _, deps in pkgsplit.META_PACKAGES:
    covered.update(deps)
os_pkgs = {n for n, cat, _, _ in pkgsplit.PACKAGE_TABLE if cat == "OS"}
ok(os_pkgs <= covered, "every OS-category package is named by a meta-package")

print("pkgsplit: %d checks passed" % checks)
