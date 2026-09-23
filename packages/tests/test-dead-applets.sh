#!/bin/bash
# kernel/dead-applets + scripts/prune-dead-applets.sh.
#
# The table says which busybox applets depend on which kernel symbol;
# the script reads the GENERATED kernel config and removes only the
# ones whose symbol is absent. Three things can go wrong silently and
# each is a check here:
#
#   - a typo'd applet name sits in the table forever doing nothing,
#   - a symbol that IS set still gets its command removed,
#   - a tree with no generated config yet gets its commands removed on
#     no evidence at all.
#
# It runs on the build host against fixtures, not against /build --
# the interesting cases are a config that says yes and one that says
# no, and a real tree only ever has one of them.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
REPO_ROOT="$(pwd)"
TABLE="${REPO_ROOT}/kernel/dead-applets"
PRUNE="${REPO_ROOT}/scripts/prune-dead-applets.sh"

pass=0; fail=0
ok()   { pass=$((pass+1)); }
bad()  { fail=$((fail+1)); echo "  FAIL: $*"; }
check(){ if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

# A fake rootfs with one symlink per name the table mentions, in the
# directory busybox would have put it. Every applet is seeded into all
# four so the script's own search finds it wherever it looks.
seed_rootfs() {
    local root="$1" a
    rm -rf "$root"; mkdir -p "$root"/{bin,sbin,usr/bin,usr/sbin,boot}
    # A REAL TARGET FOR THE LINKS, and that is not decoration. The
    # first version of this fixture left every symlink dangling and
    # `here()` below was `[ -e ]`, which FOLLOWS a symlink and is
    # false for a broken one -- so every applet read as "gone" whether
    # or not the script had run, and the removal checks passed with the
    # script replaced by `true`. Seventh time in this project that the
    # probe, not the thing probed, was the broken part. Both halves are
    # fixed: the target exists, and `here()` asks about the LINK.
    : > "$root/bin/busybox"
    while read -r a _sym _rest; do
        case "$a" in ''|'#'*) continue ;; esac
        ln -sf ../bin/busybox "$root/sbin/$a"
    done < "$TABLE"
}

here() { if [ -L "$1" ] || [ -e "$1" ]; then echo present; else echo gone; fi; }

echo "== the table itself"
[ -f "$TABLE" ] && ok || bad "kernel/dead-applets is missing"
[ -x "$PRUNE" ] && ok || bad "scripts/prune-dead-applets.sh is not executable"

# Every live line is <applet> <CONFIG_SYMBOL> <reason...>. A line with
# no reason is a line nobody can act on; a symbol not spelled CONFIG_
# can never match the generated config and would silently keep the
# applet forever.
rows=0
while read -r a sym rest; do
    case "$a" in ''|'#'*) continue ;; esac
    rows=$((rows+1))
    case "$sym" in CONFIG_[A-Z0-9_]*) ok ;; *) bad "$a: '$sym' is not a CONFIG_ symbol" ;; esac
    [ -n "$rest" ] && ok || bad "$a: no reason given"
done < "$TABLE"
[ "$rows" -gt 0 ] && ok || bad "the table has no entries"

# AN APPLET NAME THAT BUSYBOX DOES NOT HAVE IS DEAD WEIGHT IN A TABLE
# ABOUT DEAD WEIGHT. Derived from the shipped binary, skipped where
# there is not one (CI compiles nothing).
BB="${BB:-/build/rootfs/bin/busybox}"
if [ -x "$BB" ]; then
    applets="$("$BB" --list 2>/dev/null)"
    while read -r a _sym _rest; do
        case "$a" in ''|'#'*) continue ;; esac
        if printf '%s\n' "$applets" | grep -qx -- "$a"; then ok
        else bad "$a is in the table and is not a busybox applet"; fi
    done < "$TABLE"
else
    echo "  (no shipped busybox at $BB -- skipping the applet-name check)"
fi

echo "== a symbol that is NOT set removes the command"
seed_rootfs "$W/r1"
first="$(awk '!/^#/ && NF >= 3 { print $1; exit }' "$TABLE")"
firstsym="$(awk '!/^#/ && NF >= 3 { print $2; exit }' "$TABLE")"
: > "$W/none.config"
out="$(bash "$PRUNE" "$W/r1" "$W/none.config" 2>&1)"
check "removed $first" "$(here "$W/r1/sbin/$first")" "gone"
case "$out" in *"removed 
"*|*removed*) ok ;; *) bad "the run said nothing about removing anything" ;; esac

echo "== a symbol that IS set keeps the command"
seed_rootfs "$W/r2"
printf '%s=y\n' "$firstsym" > "$W/one.config"
bash "$PRUNE" "$W/r2" "$W/one.config" >/dev/null 2>&1
check "kept $first" "$(here "$W/r2/sbin/$first")" "present"

# =m counts too: a module is a kernel feature that exists.
seed_rootfs "$W/r3"
printf '%s=m\n' "$firstsym" > "$W/mod.config"
bash "$PRUNE" "$W/r3" "$W/mod.config" >/dev/null 2>&1
check "kept $first (=m)" "$(here "$W/r3/sbin/$first")" "present"

# And the shape the generated config actually uses for "no".
seed_rootfs "$W/r4"
printf '# %s is not set\n' "$firstsym" > "$W/notset.config"
bash "$PRUNE" "$W/r4" "$W/notset.config" >/dev/null 2>&1
check "removed $first (# is not set)" "$(here "$W/r4/sbin/$first")" "gone"

echo "== NO GENERATED CONFIG IS NOT A LICENCE TO DELETE"
# On a clean build the kernel has not run yet. Answering from nothing
# would remove every command in the table on no evidence -- the exact
# mistake the curated-config trap produces one step earlier.
seed_rootfs "$W/r5"
out="$(bash "$PRUNE" "$W/r5" 2>&1)"; rc=$?
check "exit status" "$rc" "0"
check "kept $first" "$(here "$W/r5/sbin/$first")" "present"
case "$out" in *"no generated kernel config"*) ok ;; *) bad "it did not say why it did nothing" ;; esac

echo "== the config in the image is found without being named"
# The kernel build copies its .config to ${ROOTFS}/boot/config-*, so a
# caller with no build tree (16-s6-rc-db.sh) still gets a real answer.
seed_rootfs "$W/r6"
: > "$W/r6/boot/config-6.10.3"
bash "$PRUNE" "$W/r6" >/dev/null 2>&1
check "removed $first from boot/config-*" \
      "$(here "$W/r6/sbin/$first")" "gone"

echo ""
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
