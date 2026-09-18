#!/bin/bash
# ============================================================
# test-pkg-conflicts.sh — the file nobody checked the owner of
#
# RFC 0040 roadmap 1. `pkg install` extracted an archive over the root
# filesystem with no owner check, no conflict refusal and no backup.
#
# THE BUG WAS LIVE, not hypothetical. Measured against this project's
# own repository: zero paths are shared between packages (pkgsplit
# derives them, so it could not be otherwise), and exactly ONE package
# overlays base content -- `binutils` ships `usr/bin/strings` where the
# base image has a symlink to busybox. So `pkg install novi-devel`
# silently took the name, and `pkg remove binutils` then DELETED
# `/usr/bin/strings`, leaving a machine without a command the base
# image had shipped. RFC 0040 put GNU coreutils under /usr/gnu rather
# than repeat that ~100 times.
#
# Four branches, and every one of them is provoked here rather than
# reasoned about:
#
#   own file      an upgrade. Must still work.
#   other package REFUSED.
#   unowned       REFUSED, unless the MANIFEST declares `replaces-files=`.
#   declared      installs, saves the original, and `pkg remove`
#                 PUTS IT BACK -- which is the half that makes the
#                 takeover reversible and so the half worth having.
# ============================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

# BASH, not `sh`: pkg is #!/bin/sh and uses `set -o pipefail`, which
# busybox ash has and dash does not. Same reasoning as
# test-pkg-cache-hash.sh -- running it under a shell it could never
# meet is not a test.
BUSYBOX=/build/rootfs/bin/busybox
if [ -x "${BUSYBOX}" ]; then
    SH=("${BUSYBOX}" ash); echo ">>> pkg file conflicts, under the shipped busybox ash"
else
    SH=(bash); echo ">>> pkg file conflicts, under host bash (no shipped busybox)"
fi

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL: $*" >&2; }
check(){ if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
contains() {
    case "$2" in *"$3"*) ok ;; *) bad "$1: '$3' not in output: $2" ;; esac
}
absent() {
    case "$2" in *"$3"*) bad "$1: '$3' should not be in output: $2" ;; *) ok ;; esac
}

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/root/usr/bin" "$T/root/bin" "$T/cache" "$T/repo" "$T/db"

# Same doctoring as test-pkg-cache-hash.sh: PKG_* are not
# environment-overridable, and need_root's message is replaced rather
# than its call site removed (the calls are bare `need_root` lines, so
# a line-anchored pattern silently matched nothing the first time
# somebody tried that).
sed -e "s#^PKG_CACHE=.*#PKG_CACHE=\"$T/cache\"#" \
    -e "s#^PKG_REPO=.*#PKG_REPO=\"$T/repo\"#" \
    -e "s#^PKG_DB=.*#PKG_DB=\"$T/db\"#" \
    -e "s#^PKG_ROOT=.*#PKG_ROOT=\"$T/root\"#" \
    -e 's|.*This operation requires root.*|    :|' \
    packages/pkg > "$T/pkg"
chmod 755 "$T/pkg"
run_pkg() { "${SH[@]}" "$T/pkg" "$@" 2>&1; }

# Build a package with mkpkg -- the real one, so the archive under
# test is the shape pkg actually unpacks.
mkpkg_one() {
    local name="$1" version="$2" path="$3" body="$4" replaces="${5:-}"
    local b="$T/build-$name"
    rm -rf "$b"
    mkdir -p "$b/files/$(dirname "$path")"
    printf '%s\n' "$body" > "$b/files/$path"
    chmod 755 "$b/files/$path"
    {
        echo "name=$name"
        echo "version=$version"
        echo "arch=x86_64"
        [ -n "$replaces" ] && echo "replaces-files=$replaces"
        echo "description=a package built to collide with something"
    } > "$b/MANIFEST"
    bash packages/mkpkg "$b" "$T/repo" >/dev/null 2>&1 \
        || { echo "mkpkg failed for $name" >&2; exit 1; }
}

mkpkg_one alpha 1.0 usr/bin/tool 'alpha'
mkpkg_one alpha 2.0 usr/bin/tool 'alpha2'
mkpkg_one beta  1.0 usr/bin/tool 'beta'
mkpkg_one gamma 1.0 usr/bin/strings 'gnu strings'
mkpkg_one delta 1.0 usr/bin/strings 'gnu strings' 'usr/bin/strings'
mkpkg_one epsil 1.0 etc/keep.conf 'replacement' 'etc/keep.conf'

A1="$(echo "$T"/repo/alpha-1.0-*.pkg.tar.gz)"
A2="$(echo "$T"/repo/alpha-2.0-*.pkg.tar.gz)"
B1="$(echo "$T"/repo/beta-1.0-*.pkg.tar.gz)"
G1="$(echo "$T"/repo/gamma-1.0-*.pkg.tar.gz)"
D1="$(echo "$T"/repo/delta-1.0-*.pkg.tar.gz)"
E1="$(echo "$T"/repo/epsil-1.0-*.pkg.tar.gz)"

# ── 1. A package installs onto an empty root ─────────────────────────
out="$(run_pkg install "$A1")"; rc=$?
check "first install succeeds" "$rc" "0"
[ -f "$T/root/usr/bin/tool" ] && ok || bad "first install: file not written"

# ── 2. AN UPGRADE IS NOT A CONFLICT ──────────────────────────────────
# The common case, and the one a naive "does this path exist?" check
# breaks. If this fails the feature is unusable.
out="$(run_pkg install "$A2")"; rc=$?
check "upgrading the same package succeeds" "$rc" "0"
absent "an upgrade is not reported as a conflict" "$out" "would overwrite"
check "the upgrade's content landed" "$(cat "$T/root/usr/bin/tool")" "alpha2"

# ── 3. ANOTHER PACKAGE'S FILE IS REFUSED ─────────────────────────────
out="$(run_pkg install "$B1")"; rc=$?
[ "$rc" -ne 0 ] && ok || bad "a second owner for one path was allowed (rc=$rc)"
contains "the refusal names the path" "$out" "usr/bin/tool"
contains "the refusal names the owner" "$out" "owned by alpha"
check "the other package's file is untouched" "$(cat "$T/root/usr/bin/tool")" "alpha2"
[ -d "$T/db/beta" ] && bad "beta was registered despite being refused" || ok

# ── 4. AN UNOWNED FILE IS REFUSED TOO ────────────────────────────────
# This is the /bin/ls case: base content, owned by no package. A
# symlink, because that is what busybox applets are -- and `-e` is
# FALSE for a dangling one, which is why the check tests -L as well.
ln -s ../../bin/busybox "$T/root/usr/bin/strings"
out="$(run_pkg install "$G1")"; rc=$?
[ "$rc" -ne 0 ] && ok || bad "an unowned path was silently taken (rc=$rc)"
contains "the refusal says nothing owns it" "$out" "not owned by any package"
check "the base symlink survived" "$(readlink "$T/root/usr/bin/strings")" "../../bin/busybox"

# ── 5. `replaces-files=` IS THE DECLARATION THAT ALLOWS IT ─────────────────
out="$(run_pkg install "$D1")"; rc=$?
check "a declared takeover installs" "$rc" "0"
contains "it says it took something over" "$out" "taking over 1 declared path"
check "the package's file is in place" "$(cat "$T/root/usr/bin/strings")" "gnu strings"
[ -f "$T/db/delta/adopted" ] && ok || bad "no record of what was replaced"
contains "the record knows it was a symlink" "$(cat "$T/db/delta/adopted")" "link usr/bin/strings"

# ── 6. AND REMOVAL PUTS THE ORIGINAL BACK ────────────────────────────
# The whole point. Before this, `pkg remove binutils` deleted
# /usr/bin/strings and the machine lost a command the base had.
out="$(run_pkg remove delta)"; rc=$?
check "removing a package that adopted a path succeeds" "$rc" "0"
[ -L "$T/root/usr/bin/strings" ] && ok || bad "the symlink was not restored"
check "and it points where it did" "$(readlink "$T/root/usr/bin/strings")" "../../bin/busybox"

# ── 7. A REGULAR FILE IS SAVED AND RESTORED BY CONTENT ───────────────
# The symlink case is a readlink and a ln -s; a real file has to be
# copied aside, which is a different branch.
mkdir -p "$T/root/etc"
printf 'the original\n' > "$T/root/etc/keep.conf"
out="$(run_pkg install "$E1")"; rc=$?
check "a declared takeover of a regular file installs" "$rc" "0"
check "the package's content is live" "$(cat "$T/root/etc/keep.conf")" "replacement"
out="$(run_pkg remove epsil)"; rc=$?
check "removing it succeeds" "$rc" "0"
check "the original file came back" "$(cat "$T/root/etc/keep.conf")" "the original"

# ── 8. THE EXTRACT DIRECTORY IS WIPED BETWEEN PACKAGES ───────────────
# Not a conflict rule -- a bug the conflict rule EXPOSED. The cleanup
# at the end of install_pkg_file only runs on the success path, and the
# "already installed at this version" early return skips it, so the
# next `tar -xzf` merged into a directory still holding the previous
# package's tree. Before anything read that list it silently recorded
# another package's files as this one's, and `pkg remove` would have
# deleted them. Reproduced here by installing a package that is
# already present (the early return) and then a different one.
# ONE INVOCATION, and that detail is the whole reproduction: PKG_TMP
# is `/tmp/pkg.$$`, so the leftovers only survive WITHIN a single run
# of pkg. The first version of this check used two separate calls and
# therefore could not fail with the bug put back -- a probe that
# cannot fail on the bug it names, for the fifth or sixth time in this
# repository. It is how the live case happened too: one
# `pkg install a b c ...` over six packages, several already present.
mkpkg_one zeta 1.0 usr/bin/zeta 'zeta'
Z1="$(echo "$T"/repo/zeta-1.0-*.pkg.tar.gz)"
out="$(run_pkg install "$A2" "$Z1")"; rc=$?
contains "an already-present version returns early" "$out" "already installed"
check "and the package after it in the same run installs" "$rc" "0"
# The database must record ONLY zeta's own file -- with the bug, it
# also lists alpha's, and `pkg remove zeta` would delete it.
check "and records only its own file" "$(cat "$T/db/zeta/files")" "usr/bin/zeta"

# ── 9. --overwrite IS THE OPERATOR'S ESCAPE HATCH ────────────────────
# And it is deliberately not something a MANIFEST can ask for: a
# package saying `replaces-files=` is declaring one path and saving it; a
# person typing --overwrite is answering for whatever is in the way.
out="$(run_pkg install --overwrite "$B1")"; rc=$?
check "--overwrite installs over another package's file" "$rc" "0"
contains "--overwrite still says what it did" "$out" "overwriting files this package does not own"
check "beta's content is now live" "$(cat "$T/root/usr/bin/tool")" "beta"

echo ">>> pkg file conflicts: $((PASS + FAIL)) check(s), ${FAIL} failure(s)"
[ "$FAIL" -eq 0 ]
