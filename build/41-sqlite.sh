#!/bin/bash
# ============================================================
# 41-sqlite.sh — SQLite, as a package
#
# RFC 0026 roadmap 3: "sqlite3, which is what most local-state Python
# assumes exists". It is the database a program reaches for when it
# wants to keep something between runs and does not want a server --
# which on a system with no server of any kind is the only kind of
# database there is.
#
#   bash build/41-sqlite.sh [sqlite|package|all]
#
# ── WHY 41, WHEN 38 AND 39 ARE FREE ──────────────────────────────────
#
# Two constraints, and they bracket this stage from both sides.
#
# AFTER 40: the CLI shell links the readline built there. A shell
# without line editing is the "almost works" failure 40's own header
# argues against, so this cannot precede it.
#
# BEFORE the Python stage: CPython decides at CONFIGURE time whether
# `_sqlite3` exists and says nothing afterwards -- exactly the trap
# readline and _curses set for 40. So python moved 41 -> 43 and
# novi-recon 42 -> 44, which is the second time those two have shifted
# for a build input of Python's.
#
# 38 and 39 ARE free -- vacated by that first renumber, and nobody
# noticed, because a vacated number does not announce itself. They are
# no use here: 38 is before 40, and this has to be after it. Worth
# knowing anyway, since CLAUDE.md's "01-39 were all taken" is a
# sentence about a moment rather than a fact.
#
# ── THE AMALGAMATION, NOT THE SOURCE TREE ────────────────────────────
#
# Upstream ships sqlite3.c: the whole library as ONE 9 MB translation
# unit, which is both the supported way to build it and the reason a
# database engine costs one stage here. The "autoconf" bundle wraps it
# in a configure script (autosetup, not GNU autoconf, despite the
# name) and adds shell.c for the CLI.
#
# ── LICENCE: PUBLIC DOMAIN, AND THE BINARY IS NOT ────────────────────
#
# SQLite itself is dedicated to the public domain, so unlike readline
# and the fonts there is no text that has to travel with it. The CLI
# is another matter: it links GPL-3 readline, so `sqlite3` as a
# BINARY is a combined work under those terms. That is what every
# distribution ships and it is fine here -- readline's COPYING is in
# the readline package, which this one depends on, so the licence
# travels with the thing exactly as RFC 0031 learned it must.
#
# ── WHAT IS TURNED ON, AND WHY IT IS NOT "EVERYTHING" ────────────────
#
# FTS5, JSON1 (on by default since 3.38), R*Tree and math functions.
# Those are what a Python program written elsewhere expects to find:
# `json_extract` in a query and an FTS5 virtual table are ordinary,
# and discovering they are missing happens at runtime, in a query, on
# somebody else's machine. ICU is NOT enabled -- it is a ~30 MB
# dependency this system does not have, for collations most programs
# never ask for.
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-versions.sh"

CROSS="${TOOLS}/bin/${TARGET_TRIPLE}"
[ -x "${CROSS}-gcc" ] || { echo "ERROR: ${CROSS}-gcc not found -- run build/02-toolchain.sh." >&2; exit 1; }

JOBS="$(nproc)"
WORK="${BUILD_DIR}/sqlite-build"
PREFIX="${BUILD_DIR}/sqlite-target"       # for LINKING, never ${ROOTFS}
NCURSES_PREFIX="${BUILD_DIR}/ncurses-target"
STAGE_DIR="${BUILD_DIR}/stage-devtools"
SRC_DIR="${WORK}/sqlite-autoconf"

PHASE="${1:-all}"

# SQLITE_ENABLE_* rather than ./configure switches: the amalgamation
# takes its feature set from the compiler command line, which is how
# upstream documents it.
SQLITE_FEATURES="
    -DSQLITE_ENABLE_FTS5=1
    -DSQLITE_ENABLE_RTREE=1
    -DSQLITE_ENABLE_MATH_FUNCTIONS=1
    -DSQLITE_ENABLE_COLUMN_METADATA=1
    -DSQLITE_SECURE_DELETE=1
    -DSQLITE_ENABLE_DBSTAT_VTAB=1
"

build_sqlite() {
    echo ">>> SQLite ${SQLITE_VERSION}"

    [ -d "${NCURSES_PREFIX}/usr/lib" ] || {
        echo "ERROR: ${NCURSES_PREFIX} is not there -- run build/40-ncurses.sh first." >&2
        echo "       The CLI links that readline; see this stage's header for why" >&2
        echo "       it is not optional." >&2
        exit 1
    }

    rm -rf "${WORK}"; mkdir -p "${WORK}"
    tar xf "${SOURCES}/${SQLITE_TARBALL}" -C "${WORK}"
    local extracted
    extracted="$(find "${WORK}" -maxdepth 1 -type d -name 'sqlite-autoconf-*' -print -quit)"
    [ -n "${extracted}" ] || { echo "ERROR: ${SQLITE_TARBALL} did not contain a sqlite-autoconf-* directory." >&2; exit 1; }
    mv "${extracted}" "${SRC_DIR}"

    # The version in the tarball decides what gets packaged, not the
    # pin: they are two statements about the same thing and only one of
    # them is the bytes on disk. Upstream's VERSION file is the source.
    local real
    real="$(cat "${SRC_DIR}/VERSION")"
    [ "${real}" = "${SQLITE_VERSION}" ] || {
        echo "ERROR: SQLITE_VERSION says ${SQLITE_VERSION}, the tarball says ${real}." >&2
        echo "       SQLITE_URL and SQLITE_VERSION are spelled separately (the URL" >&2
        echo "       carries a year directory that does not follow from the" >&2
        echo "       version), so they can disagree. Fix 00-versions.sh." >&2
        exit 1
    }

    rm -rf "${PREFIX}"

    # --with-readline-ldflags/-cflags rather than letting it look:
    # autosetup's probe compiles and RUNS nothing, but it does search
    # the BUILD HOST's paths, and a cross build that finds the host's
    # readline links a library that cannot load on the target. Naming
    # both is also -rpath-link for the SEVENTH time in this repository
    # (nftables, git/curl, the meson cross file, novi-glinfo, NetSurf,
    # readline itself, now here): libreadline.so names the terminal
    # library in its own DT_NEEDED and -L does not resolve that.
    local termlib="tinfo"
    [ -f "${BUILD_DIR}/ncurses-build/termlib" ] && termlib="$(cat "${BUILD_DIR}/ncurses-build/termlib")"

    (
        cd "${SRC_DIR}"
        CC="${CROSS}-gcc" \
        AR="${CROSS}-ar" \
        RANLIB="${CROSS}-ranlib" \
        CFLAGS="-O2 $(printf '%s' "${SQLITE_FEATURES}" | tr -s '[:space:]' ' ')" \
        ./configure \
            --host="${TARGET_TRIPLE}" \
            --prefix=/usr \
            --disable-static \
            --disable-static-shell \
            --soname=legacy \
            --enable-readline \
            --with-readline-cflags="-I${NCURSES_PREFIX}/usr/include" \
            --with-readline-ldflags="-L${NCURSES_PREFIX}/usr/lib -lreadline -l${termlib} -Wl,-rpath-link,${NCURSES_PREFIX}/usr/lib" \
            >"${WORK}/configure.log" 2>&1 \
            || { tail -40 "${WORK}/configure.log" >&2; exit 1; }

        make -j"${JOBS}" >"${WORK}/make.log" 2>&1 \
            || { tail -40 "${WORK}/make.log" >&2; exit 1; }
        make install DESTDIR="${PREFIX}" >>"${WORK}/make.log" 2>&1 \
            || { tail -40 "${WORK}/make.log" >&2; exit 1; }
    )

    # SQLITE'S SHARED LIBRARY HAS NO SONAME BY DEFAULT, and that is
    # upstream's deliberate choice -- autosetup's sqlite-handle-soname
    # says "this project has no direct use for soname, so default to
    # none". What it costs a distribution is that every consumer
    # records the FILENAME it happened to link against: here that was
    # `libsqlite3.so`, the development symlink, so the runtime package
    # would have had to ship a dev symlink for anything to start, and
    # an ABI bump would be invisible to the loader. `--soname=legacy`
    # is `libsqlite3.so.0`, which is what every distribution passes.
    # Checked on the artifact rather than trusted, because the default
    # is silent in both directions.
    local soname
    soname="$("${CROSS}-readelf" -d "${PREFIX}/usr/lib/libsqlite3.so.${SQLITE_VERSION}" 2>/dev/null \
        | sed -n 's/.*SONAME.*\[\(.*\)\].*/\1/p')"
    [ "${soname}" = "libsqlite3.so.0" ] || {
        echo "ERROR: libsqlite3 has SONAME '${soname:-<none>}', expected libsqlite3.so.0." >&2
        echo "       Without one, every consumer records the filename it linked" >&2
        echo "       against and the versioning scheme does nothing." >&2
        exit 1
    }
    echo "   SONAME ${soname}"

    # READLINE IS THE HALF THAT CAN SILENTLY NOT HAPPEN. configure
    # reports what it found and carries on either way, so the shell
    # builds, installs and runs with no line editing at all -- and a
    # missing up-arrow in a REPL is exactly the failure RFC 0026
    # roadmap 2 exists to have ended. Ask the BINARY, not the log.
    local needed
    needed="$("${CROSS}-readelf" -d "${PREFIX}/usr/bin/sqlite3" 2>/dev/null || true)"
    case "${needed}" in
        *libreadline*) echo "   sqlite3 links libreadline: line editing is in" ;;
        *)
            echo "ERROR: ${PREFIX}/usr/bin/sqlite3 does not NEED libreadline." >&2
            echo "       configure found no usable readline and said so only in" >&2
            echo "       ${WORK}/configure.log. A shell with no line editing is" >&2
            echo "       the 'almost works' failure 40-ncurses.sh's header is" >&2
            echo "       about; this is not shipped that way." >&2
            grep -i readline "${WORK}/configure.log" | head -5 >&2 || true
            exit 1 ;;
    esac

    echo "   built:"
    echo "     $(ls -la "${PREFIX}/usr/lib/libsqlite3.so."*.*.* 2>/dev/null | awk '{print $5, $9}')"
    echo "     $(ls -la "${PREFIX}/usr/bin/sqlite3" | awk '{print $5, $9}')"
}

package() {
    echo ">>> Staging sqlite into ${STAGE_DIR}"
    [ -f "${PREFIX}/usr/bin/sqlite3" ] || {
        echo "ERROR: ${PREFIX} has no sqlite3 -- run '$0 sqlite' first." >&2
        exit 1
    }
    local d="${STAGE_DIR}/sqlite"
    rm -rf "${d}"
    mkdir -p "${d}/files/usr/lib" "${d}/files/usr/bin"

    # Every pattern is checked on its own. Counting the total and
    # comparing it against zero is what let the ncurses package ship
    # without libtinfo while three of its five patterns matched
    # nothing -- a wildcard that matches nothing is silent.
    local pat hits f empty=""
    for pat in 'libsqlite3.so*'; do
        hits=0
        for f in ${PREFIX}/usr/lib/${pat}; do
            [ -e "${f}" ] || continue
            cp -a "${f}" "${d}/files/usr/lib/"
            hits=$((hits + 1))
        done
        [ "${hits}" -gt 0 ] || empty="${empty} ${pat}"
    done
    [ -z "${empty}" ] || {
        echo "ERROR: sqlite: these patterns matched nothing:${empty}" >&2
        exit 1
    }
    cp -a "${PREFIX}/usr/bin/sqlite3" "${d}/files/usr/bin/"

    find "${d}/files" \( -name '*.so*' -o -name sqlite3 \) -type f \
        -exec "${CROSS}-strip" --strip-unneeded {} + 2>/dev/null || true

    # ncurses is not a second-guess: it is what libreadline.so NEEDs,
    # and pkg resolves depends= by name rather than by walking the
    # graph a second time.
    {
        echo "name=sqlite"
        echo "version=${SQLITE_VERSION}"
        echo "arch=${TARGET_ARCH}"
        echo "depends=readline,ncurses"
        echo "description=SQLite ${SQLITE_VERSION} -- an embedded SQL database, with FTS5, JSON and R*Tree. Public domain; the CLI links GPL-3 readline"
    } > "${d}/MANIFEST"

    echo "   staged sqlite ($(du -sh "${d}/files" | cut -f1))"
    echo
    echo "Publish it with:  bash build/53-devtools-repo.sh"
}

mkdir -p "${WORK}"
case "${PHASE}" in
    sqlite)  build_sqlite ;;
    package) package ;;
    all)     build_sqlite; package ;;
    *) echo "usage: $0 [sqlite|package|all]" >&2; exit 1 ;;
esac
