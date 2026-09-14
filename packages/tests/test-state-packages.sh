#!/bin/bash
# ============================================================
# test-state-packages.sh — the packages.* domain, and the removal it
# refuses
#
# RFC 0002's roadmap called `packages.*` "the one that makes 'commit
# your machine, reproduce it elsewhere' literally true". The observer
# and the converger have existed in novi-state for some time; nothing
# had ever tested them, and the roadmap still listed the domain as
# work not yet done.
#
# What is worth asserting here is not that `pkg install` gets called --
# it is the REMOVAL. `pkg remove` run by a person warns that other
# packages depend on this one and proceeds, which is right: they typed
# it and they are reading the warning. Convergence is a document being
# applied at boot with nobody there, so it refuses instead, and the
# refusal has to be visible, has to name what is in the way, and must
# not take the rest of the document down with it.
#
# Run against the shipped busybox ash where there is one.
# ============================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

BUSYBOX=/build/rootfs/bin/busybox
if [ -x "${BUSYBOX}" ]; then
    SH=("${BUSYBOX}" ash)
    echo ">>> packages.* domain, under the shipped busybox ash"
else
    SH=(sh)
    echo ">>> packages.* domain, under host sh (no shipped busybox found)" >&2
fi

SHELL_CMD="${SH[*]}"

checks=0
fail=0
note() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }
did() { checks=$((checks + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
DB="${TMP}/db"
mkdir -p "${DB}" "${TMP}/bin"

# Both tools hardcode the install database's path, which is right for
# them and unreachable for a test. Redirected with a sed rather than by
# adding an environment override to production code purely so a test
# can reach it -- the call test-power-idle.sh makes over /run/novi/idle.
sed "s|/var/lib/pkg/installed|${DB}|g" packages/novi-state > "${TMP}/novi-state"
sed "s|^PKG_DB=\"/var/lib/pkg/installed\"|PKG_DB=\"${DB}\"|" packages/pkg > "${TMP}/pkg"
chmod +x "${TMP}/novi-state" "${TMP}/pkg"

# `pkg` on PATH, because novi-state finds it with `command -v pkg`.
# install and remove only RECORD what they were asked to do: this is a
# test of the engine's decisions, and a converger that decided
# correctly and a package manager that worked are two different
# claims. `rdeps` is the real thing, so what novi-state refuses on is
# what pkg actually computes.
# `rdeps` is delegated to the real thing through the SAME shell this
# test runs everything else under. The first version's `#!/bin/sh`
# handed pkg to dash, which rejects `set -o pipefail` -- and that
# accident is what exposed a real bug in the converger, which treated
# the failed query as "nothing depends on it" and removed the package.
cat > "${TMP}/bin/pkg" <<PKGSTUB
#!/bin/sh
case "\$1" in
    install)
        printf 'install %s\n' "\$2" >> "${TMP}/pkg.log"
        mkdir -p "${DB}/\$2"
        printf 'name=%s\nversion=1.0\ndepends=\n' "\$2" > "${DB}/\$2/MANIFEST"
        ;;
    remove)
        printf 'remove %s\n' "\$2" >> "${TMP}/pkg.log"
        rm -rf "${DB}/\$2"
        ;;
    rdeps)
        # An older pkg that has never heard of this subcommand prints
        # its usage and exits non-zero. Simulated on demand, because
        # the converger's behaviour when the query FAILS is a
        # different decision from its behaviour when the query says
        # "nothing".
        [ -f "${TMP}/rdeps-broken" ] && exit 1
        exec ${SHELL_CMD} "${TMP}/pkg" "\$@"
        ;;
    *)  exec ${SHELL_CMD} "${TMP}/pkg" "\$@" ;;
esac
PKGSTUB
chmod +x "${TMP}/bin/pkg"

installed() {
    mkdir -p "${DB}/$1"
    # `key=value`, no spaces -- pkg's manifest_field() greps for
    # "^key=" and a prettier file parses as nothing at all.
    cat > "${DB}/$1/MANIFEST" <<M
name=$1
version=1.0
depends=${2:-}
M
}

state() {
    PATH="${TMP}/bin:${PATH}" \
    NOVI_STATE_FILE="${TMP}/system.conf" \
    NOVI_STATE_GENERATIONS="${TMP}/generations" \
    "${SH[@]}" "${TMP}/novi-state" "$@" 2>&1
}

# ── 1. the observer reads the install database, not a cache ──────────
rm -rf "${DB:?}"/*
installed foot
printf 'packages.foot = present\n' > "${TMP}/system.conf"
did; case "$(state diff 2>&1 || true)" in
    *"packages.foot"*) note "an installed package must not report as drift" ;;
    *) ;;
esac
rm -rf "${DB:?}/foot"
did; case "$(state diff 2>&1 || true)" in
    *"packages.foot"*) ;;
    *) note "a declared package that is not installed must report as drift" ;;
esac

# ── 2. present installs ──────────────────────────────────────────────
: > "${TMP}/pkg.log"
printf 'packages.foot = present\n' > "${TMP}/system.conf"
state apply >/dev/null 2>&1
did; grep -qx "install foot" "${TMP}/pkg.log" ||
    note "packages.X = present must install X (log: $(cat "${TMP}/pkg.log"))"

# ── 3. absent removes, when nothing needs it ─────────────────────────
: > "${TMP}/pkg.log"
rm -rf "${DB:?}"/*
installed foot
printf 'packages.foot = absent\n' > "${TMP}/system.conf"
state apply >/dev/null 2>&1
did; grep -qx "remove foot" "${TMP}/pkg.log" ||
    note "packages.X = absent must remove X when nothing depends on it"

# ── 4. ...and REFUSES when something does ────────────────────────────
# This is the whole reason this domain needed a test. `pkg remove`
# warns and proceeds; an unattended converger must not.
: > "${TMP}/pkg.log"
rm -rf "${DB:?}"/*
installed libpng
installed novi-view "libpng,zlib"
printf 'packages.libpng = absent\n' > "${TMP}/system.conf"
out="$(state apply)"; rc=$?
did; [ "$rc" -ne 0 ] ||
    note "an apply that could not converge a key must exit non-zero"
did; ! grep -q "^remove libpng$" "${TMP}/pkg.log" ||
    note "a package something depends on must NOT be removed"
did; case "$out" in
    *"novi-view"*) ;;
    *) note "the refusal must name what is in the way (got: $out)" ;;
esac
did; [ -f "${DB}/libpng/MANIFEST" ] ||
    note "the package must still be installed after the refusal"
# It is DRIFT afterwards, not a converged machine: the document says
# absent and the package is there. Reporting it as converged would be
# the engine hiding its own refusal.
did; case "$(state diff 2>&1 || true)" in
    *"packages.libpng"*) ;;
    *) note "a refused removal must go on reporting as drift" ;;
esac

# ── 4b. a query that FAILED is not an empty answer ───────────────────
# The refusal is only as good as the question behind it. A pkg too old
# to know `rdeps` exits non-zero, and a converger that reads that as
# "nothing depends on it" removes the package -- a refusal degrading
# into permission at exactly the moment it is least justified. The
# first version of this converger did that, and the first version of
# this test could not see it: with a working stub the failing branch
# never runs.
: > "${TMP}/pkg.log"
rm -rf "${DB:?}"/*
installed libpng
: > "${TMP}/rdeps-broken"
printf 'packages.libpng = absent\n' > "${TMP}/system.conf"
out="$(state apply)"; rc=$?
did; [ "$rc" -ne 0 ] || note "a failed rdeps query must fail the apply"
did; [ ! -s "${TMP}/pkg.log" ] ||
    note "a package must not be removed on the strength of a query that failed"
did; case "$out" in
    *rdeps*) ;;
    *) note "the refusal should say the query is what failed (got: $out)" ;;
esac
rm -f "${TMP}/rdeps-broken"

# ── 5. one key that cannot converge must not take the rest ───────────
# CLAUDE.md's own rule, and packages.* is where it will actually bite:
# a refusal here is routine, not exceptional. `packages.libpng` sorts
# before `packages.zzz`, so a die() that ended the script would leave
# zzz uninstalled and say nothing.
: > "${TMP}/pkg.log"
rm -rf "${DB:?}"/*
installed libpng
installed novi-view "libpng"
printf 'packages.libpng = absent\npackages.zzz = present\n' > "${TMP}/system.conf"
state apply >/dev/null 2>&1
did; grep -qx "install zzz" "${TMP}/pkg.log" ||
    note "a refused key must not stop the keys sorted after it"

# ── 5b. a key that was only EARLY is retried ─────────────────────────
# Declaring a package and the package that depends on it absent in one
# edit is the obvious way to say "take both of these off", and the
# dependency sorts first (l < n), so its removal is refused before the
# dependant has gone. The passes exist for exactly this; a failed key
# struck off for the whole apply defeats them, and the symptom is a
# document that needs applying twice with no hint that it does.
: > "${TMP}/pkg.log"
rm -rf "${DB:?}"/*
installed libpng
installed novi-view "libpng"
printf 'packages.libpng = absent\npackages.novi-view = absent\n' > "${TMP}/system.conf"
state apply >/dev/null 2>&1; rc=$?
did; grep -qx "remove novi-view" "${TMP}/pkg.log" ||
    note "the dependant must be removed"
did; grep -qx "remove libpng" "${TMP}/pkg.log" ||
    note "and the dependency too, in the SAME apply (log: $(tr '\n' ' ' < "${TMP}/pkg.log"))"
did; [ "$rc" -eq 0 ] ||
    note "an apply that converged everything in the end must exit 0"

# ── 6. a value that is neither ───────────────────────────────────────
: > "${TMP}/pkg.log"
rm -rf "${DB:?}"/*
printf 'packages.foot = yes\n' > "${TMP}/system.conf"
out="$(state apply)"; rc=$?
did; [ "$rc" -ne 0 ] || note "an unusable value must fail the apply"
did; [ ! -s "${TMP}/pkg.log" ] ||
    note "an unusable value must not reach pkg at all (log: $(cat "${TMP}/pkg.log"))"
did; case "$out" in
    *present*absent*|*absent*present*) ;;
    *) note "the error should say what the two usable values are" ;;
esac

# ── 7. pkg rdeps, which is what the refusal is built on ──────────────
rm -rf "${DB:?}"/*
installed libpng
installed novi-view "libpng,zlib"
installed novi-edit "fcft"
rdeps() { "${SH[@]}" "${TMP}/pkg" rdeps "$@" 2>/dev/null; }
did; [ "$(rdeps libpng)" = "novi-view" ] ||
    note "rdeps must find a dependant named in a comma list (got: $(rdeps libpng))"
did; [ -z "$(rdeps novi-view)" ] ||
    note "a package nothing depends on must report nothing"
# A package whose NAME IS A PREFIX of a real dependency must not match:
# `zlib` is in novi-view's list, `zl` is not, and a substring test says
# it is.
installed zl
did; [ -z "$(rdeps zl)" ] ||
    note "a name that is only a prefix of a dependency must not match"

if [ "${fail}" -ne 0 ]; then
    echo "packages domain: ${fail} check(s) FAILED of ${checks}" >&2
    exit 1
fi
echo "packages domain: ${checks} checks passed"
