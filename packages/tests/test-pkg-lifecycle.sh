#!/bin/bash
# ============================================================
# test-pkg-lifecycle.sh — the four scripts pkg runs as root
#
# `pkg` has run `scripts/{pre,post}-{install,remove}` as root since it
# was written. NOTHING SHIPPED ONE, so the mechanism was never
# exercised -- and RFC 0040 roadmap 5 was filed asking for a hook that
# already existed, which is the eleventh roadmap item in this
# repository found to be wrong about what is already built.
#
# Two defects the first exercise found:
#
#   THE ARGUMENTS DISAGREED WITH THE SPEC. `pkg-format.md` said all
#   four receive "one argument: the package version". The install pair
#   were passed `<name> <version>` and the remove pair only `<name>`,
#   so a script written from the document treats $1 as a version and
#   is handed a name. All four take `<name> <version>` now.
#
#   ONLY pre-install IS FATAL, and the table did not say so. That is
#   the design -- it runs before anything has moved -- but an
#   undocumented asymmetry in root-executed code is the kind of thing
#   somebody relies on backwards.
# ============================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

BUSYBOX=/build/rootfs/bin/busybox
if [ -x "${BUSYBOX}" ]; then
    SH=("${BUSYBOX}" ash); echo ">>> pkg lifecycle scripts, under the shipped busybox ash"
else
    SH=(bash); echo ">>> pkg lifecycle scripts, under host bash (no shipped busybox)"
fi

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL: $*" >&2; }
check(){ if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
contains() { case "$2" in *"$3"*) ok ;; *) bad "$1: '$3' not in: $2" ;; esac; }
absent()   { case "$2" in *"$3"*) bad "$1: '$3' should not be in: $2" ;; *) ok ;; esac; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/root/usr/bin" "$T/cache" "$T/repo" "$T/db" "$T/log"

sed -e "s#^PKG_CACHE=.*#PKG_CACHE=\"$T/cache\"#" \
    -e "s#^PKG_REPO=.*#PKG_REPO=\"$T/repo\"#" \
    -e "s#^PKG_DB=.*#PKG_DB=\"$T/db\"#" \
    -e "s#^PKG_ROOT=.*#PKG_ROOT=\"$T/root\"#" \
    -e 's|.*This operation requires root.*|    :|' \
    packages/pkg > "$T/pkg"
chmod 755 "$T/pkg"
run_pkg() { "${SH[@]}" "$T/pkg" "$@" 2>&1; }

# A package whose scripts record their own argv, so the CONTRACT is
# what is asserted rather than "a script ran".
build() {                       # build <name> <ver> <which...> ; SCRIPT_RC sets the exit
    local name="$1" version="$2"; shift 2
    local b="$T/b-$name"; rm -rf "$b"
    mkdir -p "$b/files/usr/bin" "$b/scripts"
    printf 'payload\n' > "$b/files/usr/bin/$name"
    local which
    for which in "$@"; do
        {
            echo '#!/bin/sh'
            echo "printf '%s argv=[%s]\\n' '$which' \"\$*\" >> \"$T/log/trace\""
            echo "exit \${SCRIPT_RC_$(echo "$which" | tr 'a-z-' 'A-Z_'):-0}"
        } > "$b/scripts/$which"
        chmod 755 "$b/scripts/$which"
    done
    { echo "name=$name"; echo "version=$version"; echo "arch=x86_64"
      echo "description=a package that records how its scripts were called"
    } > "$b/MANIFEST"
    bash packages/mkpkg "$b" "$T/repo" >/dev/null 2>&1 \
        || { echo "mkpkg failed for $name" >&2; exit 1; }
}
trace() { cat "$T/log/trace" 2>/dev/null; }
reset_trace() { : > "$T/log/trace"; }

build hooked 1.0 pre-install post-install pre-remove post-remove
H1="$(echo "$T"/repo/hooked-1.0-*.pkg.tar.gz)"

# ── 1. mkpkg carries the scripts into the archive ────────────────────
listing="$(tar -tzf "$H1")"
for w in pre-install post-install pre-remove post-remove; do
    contains "mkpkg ships scripts/$w" "$listing" "scripts/$w"
done

# ── 2. INSTALL runs both install scripts, in order, with <name> <version>
reset_trace
out="$(run_pkg install "$H1")"; rc=$?
check "install succeeds" "$rc" "0"
contains "pre-install ran"  "$(trace)" "pre-install argv=[hooked 1.0]"
contains "post-install ran" "$(trace)" "post-install argv=[hooked 1.0]"
absent   "no remove script ran on install" "$(trace)" "remove argv"
# Order matters: pre- must precede post-.
first="$(trace | head -1)"
contains "pre-install runs first" "$first" "pre-install"

# ── 3. THE VERSION IS $2, NOT $1 ─────────────────────────────────────
# The spec said these take "one argument: the package version". If a
# script is handed only the version, or the name in $2, this fires.
contains "argv is <name> then <version>" "$(trace)" "argv=[hooked 1.0]"
absent   "the version is not passed alone" "$(trace)" "argv=[1.0]"

# ── 4. REMOVE runs both remove scripts, with the SAME contract ───────
# This is the half that was wrong: the remove pair got only the name.
reset_trace
out="$(run_pkg remove hooked)"; rc=$?
check "remove succeeds" "$rc" "0"
contains "pre-remove gets name and version"  "$(trace)" "pre-remove argv=[hooked 1.0]"
contains "post-remove gets name and version" "$(trace)" "post-remove argv=[hooked 1.0]"
first="$(trace | head -1)"
contains "pre-remove runs first" "$first" "pre-remove"
[ -f "$T/root/usr/bin/hooked" ] && bad "remove left the payload behind" || ok

# ── 5. A FAILING pre-install ABORTS, AND NOTHING IS EXTRACTED ────────
# The one fatal script. If this regresses, a package that refused the
# machine installs onto it anyway.
reset_trace
out="$(SCRIPT_RC_PRE_INSTALL=1 run_pkg install "$H1")"; rc=$?
[ "$rc" -ne 0 ] && ok || bad "a failing pre-install did not abort (rc=$rc)"
[ -f "$T/root/usr/bin/hooked" ] && bad "pre-install failed but files were extracted" || ok
[ -d "$T/db/hooked" ] && bad "pre-install failed but the package was registered" || ok
absent "post-install did not run after a fatal pre-install" "$(trace)" "post-install"

# ── 6. A FAILING post-install WARNS AND THE INSTALL STANDS ───────────
# The other side of the asymmetry. Aborting here would leave a
# half-installed package, which is worse than either outcome.
reset_trace
out="$(SCRIPT_RC_POST_INSTALL=1 run_pkg install "$H1")"; rc=$?
check "a failing post-install does not fail the install" "$rc" "0"
contains "it says so" "$out" "post-install script exited non-zero"
[ -f "$T/root/usr/bin/hooked" ] && ok || bad "post-install failure lost the files"
[ -d "$T/db/hooked" ] && ok || bad "post-install failure lost the registration"

# ── 7. A FAILING post-remove WARNS AND THE REMOVAL STANDS ────────────
reset_trace
out="$(SCRIPT_RC_POST_REMOVE=1 run_pkg remove hooked)"; rc=$?
check "a failing post-remove does not fail the removal" "$rc" "0"
contains "it says so" "$out" "post-remove script exited non-zero"
[ -d "$T/db/hooked" ] && bad "post-remove failure left the package registered" || ok

# ── 8. A PACKAGE WITH NO SCRIPTS IS UNAFFECTED ───────────────────────
# Every package this repository ships is in this case, so a regression
# here breaks everything rather than nothing.
build plain 1.0
P1="$(echo "$T"/repo/plain-1.0-*.pkg.tar.gz)"
reset_trace
out="$(run_pkg install "$P1")"; rc=$?
check "a package with no scripts installs" "$rc" "0"
absent "and runs nothing" "$out" "script..."
check "no trace was written" "$(trace)" ""
out="$(run_pkg remove plain)"; rc=$?
check "and removes" "$rc" "0"

# ── 9. THE SCRIPTS ARE KEPT FOR REMOVAL, NOT READ FROM THE ARCHIVE ───
# pre-remove runs long after the archive is gone, so pkg copies
# scripts/ into the database at install time. If that stops happening
# the remove pair silently never runs again.
run_pkg install "$H1" >/dev/null 2>&1
[ -x "$T/db/hooked/scripts/pre-remove" ] && ok \
    || bad "scripts were not copied into the install database"
run_pkg remove hooked >/dev/null 2>&1

# ── 10. THE DERIVED MAN-INDEX REFRESH ────────────────────────────────
# Not a script: pkg refreshes an index when a package installed pages
# into the directory it covers. Three packages here ship man pages and
# a fourth would have been forgotten, which is why the trigger is what
# was installed rather than what somebody remembered to write.
#
# A STAND-IN `makewhatis` on PATH, because the real one is a target
# binary. It records its argv, which is the whole contract.
mkdir -p "$T/bin"
cat > "$T/bin/makewhatis" <<MW
#!/bin/sh
echo "makewhatis \$*" >> "$T/log/mw"
MW
chmod 755 "$T/bin/makewhatis"
PATH="$T/bin:$PATH"; export PATH
mw() { cat "$T/log/mw" 2>/dev/null; }
mw_reset() { : > "$T/log/mw"; }

# A package that ships a man page, and one that ships none.
manpkg() {
    local name="$1" dir="$2" page="$3" deps="${4:-}"
    local b="$T/b-$name"; rm -rf "$b"
    mkdir -p "$b/files/$dir/man1" "$b/files/usr/bin"
    printf '.TH X 1\n' > "$b/files/$dir/man1/$page.1"
    printf 'x\n' > "$b/files/usr/bin/$name"
    { echo "name=$name"; echo "version=1.0"; echo "arch=x86_64"
      [ -n "$deps" ] && echo "depends=$deps"
      echo "description=ships a manual page"; } > "$b/MANIFEST"
    bash packages/mkpkg "$b" "$T/repo" >/dev/null 2>&1 \
        || { echo "mkpkg failed for $name" >&2; exit 1; }
}
manpkg pagesa usr/gnu/share/man aa
manpkg pagesb usr/gnu/share/man bb
manpkg pagesd usr/gnu/share/man dd pagesb
manpkg pagesc usr/share/man cc
PA="$(echo "$T"/repo/pagesa-1.0-*.pkg.tar.gz)"
PC="$(echo "$T"/repo/pagesc-1.0-*.pkg.tar.gz)"

mkdir -p "$T/root/usr/gnu/share/man" "$T/root/usr/share/man"
mw_reset
out="$(run_pkg install "$PA")"; rc=$?
check "a package shipping man pages installs" "$rc" "0"
contains "its directory was indexed" "$(mw)" "/usr/gnu/share/man"

# ── 11. ONCE PER INVOCATION, NOT ONCE PER PACKAGE ────────────────────
# makewhatis re-reads every page in the directory, so two packages
# landing in one tree must not mean two passes over it.
#
# IT HAS TO BE TWO PACKAGES IN ONE INVOCATION, and the first version of
# this check installed one -- where per-package and per-invocation are
# the same number, so moving the call into install_pkg_file left it
# passing. `pagesd` depends on `pagesb` and both ship into
# /usr/gnu/share/man, which also drives the DEPENDENCY path: pkg
# installs a dependency inside a `printf | while` SUBSHELL, so this is
# the case a variable-accumulating implementation loses.
PD="$(echo "$T"/repo/pagesd-1.0-*.pkg.tar.gz)"
mw_reset
out="$(run_pkg install "$PD")"; rc=$?
check "a package and its dependency install" "$rc" "0"
[ -f "$T/root/usr/gnu/share/man/man1/bb.1" ] && ok || bad "the dependency's page is missing"
[ -f "$T/root/usr/gnu/share/man/man1/dd.1" ] && ok || bad "the package's page is missing"
n="$(mw | grep -c '/usr/gnu/share/man$' || true)"
check "two packages, one pass over the directory" "$n" "1"

# And a second directory in the same invocation is its own pass.
mw_reset
run_pkg install "$PC" >/dev/null 2>&1
n="$(mw | grep -c '/usr/share/man$' || true)"
check "a different directory is indexed too" "$n" "1"

# ── 12. A PACKAGE WITH NO PAGES TRIGGERS NOTHING ─────────────────────
mw_reset
run_pkg install "$P1" >/dev/null 2>&1
check "no pages, no index run" "$(mw)" ""

# ── 13. NO makewhatis ON THE MACHINE MEANS NO-OP, NOT AN ERROR ───────
# Every machine that has not installed `man` is in this case, so a
# regression here breaks every install rather than none.
PB="$(echo "$T"/repo/pagesb-1.0-*.pkg.tar.gz)"
mv "$T/bin/makewhatis" "$T/bin/makewhatis.off"
out="$(run_pkg install "$PB")"; rc=$?
check "install succeeds with no formatter present" "$rc" "0"
absent "and says nothing about indexing" "$out" "could not index"
mv "$T/bin/makewhatis.off" "$T/bin/makewhatis"

echo ">>> pkg lifecycle scripts: $((PASS + FAIL)) check(s), $FAIL failure(s)"
[ "$FAIL" -eq 0 ] || exit 1
