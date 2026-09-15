#!/bin/bash
# ============================================================
# test-pkg-cache-hash.sh — the cached archive nobody was hashing
#
# RFC 0006 is the package trust root: one signature over an index, and
# every archive's SHA-256 inside it. `pkg` said so, CLAUDE.md said so,
# and `fetch_from_mirror`'s own comment said "a cached copy still gets
# hashed. The cache is a directory anything with root can write to, and
# 'we downloaded it once' is not a statement about what is in it now."
#
# ALL OF THAT WAS TRUE OF THAT FUNCTION AND FALSE OF THE PROGRAM.
# `locate_pkg` searches /var/cache/pkg/archives and the on-media
# repository BEFORE the mirror and returned a match from either without
# hashing it -- so the verifying path was the one taken only when
# nothing local matched. A modified archive in the cache was installed
# as root, unverified, with a correctly signed index beside it naming a
# different hash.
#
# Found by rebuilding a package at the same version and watching the
# old bytes install. So the check that matters here is not "does a good
# archive install" -- it is "does a BAD one, already in the cache, get
# refused", which is the case that was silently passing.
# ============================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

# BASH, not `sh`: pkg is #!/bin/sh and uses `set -o pipefail` on
# purpose, because busybox ash has it and that is what runs on the
# target. /bin/sh on a CI runner is dash, which does not -- pkg would
# die on its second line and every check here would fail for a reason
# unrelated to the code. Running it under a shell it could never meet
# is not a test.
BUSYBOX=/build/rootfs/bin/busybox
if [ -x "${BUSYBOX}" ]; then
    SH=("${BUSYBOX}" ash); echo ">>> pkg archive verification, under the shipped busybox ash"
else
    SH=(bash); echo ">>> pkg archive verification, under host bash (no shipped busybox)"
fi

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL: $*" >&2; }
check(){ if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
contains() {
    case "$2" in *"$3"*) ok ;; *) bad "$1: '$3' not in output: $2" ;; esac
}

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/root" "$T/cache" "$T/repo" "$T/db" "$T/build/files/usr/bin"

# A real package, built by the real mkpkg, so the archive under test is
# the shape pkg actually unpacks rather than a tarball invented here.
cat > "$T/build/MANIFEST" <<EOF
name=demo
version=1.0
arch=x86_64
depends=
description=a package that exists only to be tampered with
EOF
printf '#!/bin/sh\necho good\n' > "$T/build/files/usr/bin/demo"
chmod 755 "$T/build/files/usr/bin/demo"
bash packages/mkpkg "$T/build" "$T/repo" >/dev/null 2>&1 \
    || { echo "mkpkg failed -- cannot run this test" >&2; exit 1; }

ARCHIVE="$(echo "$T"/repo/demo-1.0-*.pkg.tar.gz)"
GOOD_SHA="$(sha256sum "$ARCHIVE" | cut -d' ' -f1)"
SIZE="$(stat -c %s "$ARCHIVE")"

# An index naming the GOOD hash. No signature is involved: `pkg sync`
# is what verifies the signature, and what is under test here is what
# install does with an index it already trusts.
cat > "$T/index" <<EOF
# novi package index v1
# generated: $(date +%s)
# valid-until: $(( $(date +%s) + 86400 ))
demo|1.0|x86_64|${SIZE}|${GOOD_SHA}|$(basename "$ARCHIVE")||a package that exists only to be tampered with
EOF

# PKG_CACHE/PKG_REPO are not environment-overridable in pkg, so the
# test copy is doctored the way test-state-packages.sh doctors
# novi-state's database path: the thing under test is the decision, not
# how the paths are spelled.
sed -e "s#^PKG_CACHE=.*#PKG_CACHE=\"$T/cache\"#" \
    -e "s#^PKG_REPO=.*#PKG_REPO=\"$T/repo2\"#" \
    -e "s#^PKG_DB=.*#PKG_DB=\"$T/db\"#" \
    -e "s#^PKG_ROOT=.*#PKG_ROOT=\"$T/root\"#" \
    -e "s#^PKG_INDEX=.*#PKG_INDEX=\"\${PKG_INDEX:-$T/index}\"#" \
    -e '/^need_root$/d' -e 's/^need_root ".*"$//' \
    packages/pkg > "$T/pkg"
chmod 755 "$T/pkg"
run_pkg() { PKG_INDEX="$T/index" "${SH[@]}" "$T/pkg" "$@" 2>&1; }

# ── 1. A cached archive that matches the index installs ──────────────
mkdir -p "$T/cache"
cp "$ARCHIVE" "$T/cache/"
out="$(run_pkg install demo)"; rc=$?
check "good cached archive installs" "$rc" "0"
contains "good cached archive is verified" "$out" "sha256 verified"
[ -f "$T/root/usr/bin/demo" ] && ok || bad "good archive: file not installed"

# ── 2. A TAMPERED cached archive is refused ──────────────────────────
# This is the case that passed before the fix -- silently, installing
# the tampered bytes as root.
rm -rf "$T/root" "$T/db"; mkdir -p "$T/root" "$T/db"
cat > "$T/build/files/usr/bin/demo" <<'EOF'
#!/bin/sh
echo pwned
EOF
rm -rf "$T/evil"; mkdir -p "$T/evil"
bash packages/mkpkg "$T/build" "$T/evil" >/dev/null 2>&1
cp "$T/evil"/demo-1.0-*.pkg.tar.gz "$T/cache/"
EVIL_SHA="$(sha256sum "$T/cache/$(basename "$ARCHIVE")" | cut -d' ' -f1)"
[ "$EVIL_SHA" != "$GOOD_SHA" ] && ok || bad "the tampered archive hashes the same -- the test proves nothing"

out="$(run_pkg install demo)"; rc=$?
[ "$rc" -ne 0 ] && ok || bad "tampered cached archive: pkg exited 0"
contains "tampered archive is named" "$out" "does not match the index"
if [ -f "$T/root/usr/bin/demo" ]; then
    bad "TAMPERED ARCHIVE WAS INSTALLED: $(cat "$T/root/usr/bin/demo")"
else ok; fi
# ...and the bad copy is gone from the cache rather than waiting for
# the next install to try it again.
[ -f "$T/cache/$(basename "$ARCHIVE")" ] && bad "tampered archive left in the cache" || ok

# ── 3. A tampered archive in the REPO directory is skipped, not
#       deleted -- it may be read-only media and is never ours to edit.
rm -rf "$T/root" "$T/db" "$T/cache"; mkdir -p "$T/root" "$T/db" "$T/cache" "$T/repo2"
cp "$T/evil"/demo-1.0-*.pkg.tar.gz "$T/repo2/"
out="$(run_pkg install demo)"; rc=$?
[ "$rc" -ne 0 ] && ok || bad "tampered repo archive: pkg exited 0"
[ -f "$T/repo2/$(basename "$ARCHIVE")" ] && ok || bad "pkg deleted a file in the repo directory"
[ -f "$T/root/usr/bin/demo" ] && bad "tampered repo archive was installed" || ok

# ── 4. An archive the index says nothing about is not blocked ────────
# There is no published hash to check it against, so refusing would
# make an unindexed local repository unusable rather than safer. What
# governs that case is whether there is a signed index at all, which is
# `pkg sync`'s business and not this function's.
rm -rf "$T/root" "$T/db" "$T/cache" "$T/repo2"; mkdir -p "$T/root" "$T/db" "$T/cache" "$T/repo2"
printf '#!/bin/sh\necho good\n' > "$T/build/files/usr/bin/demo"
sed 's/^name=demo$/name=other/' "$T/build/MANIFEST" > "$T/build/MANIFEST.new"
mv "$T/build/MANIFEST.new" "$T/build/MANIFEST"
bash packages/mkpkg "$T/build" "$T/repo2" >/dev/null 2>&1
out="$(run_pkg install other)"; rc=$?
check "unindexed archive still installs" "$rc" "0"
[ -f "$T/root/usr/bin/demo" ] && ok || bad "unindexed archive: file not installed"

echo ">>> pkg archive verification: $((PASS + FAIL)) check(s), ${FAIL} failure(s)"
[ "$FAIL" -eq 0 ]
