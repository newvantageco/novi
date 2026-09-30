#!/bin/bash
# ============================================================
# 40-ncurses.sh — ncurses and readline, as packages
#
# RFC 0026 roadmap 2. A REPL where the up-arrow prints `^[[A` is a
# visibly unfinished interpreter, and `curses` is how a large class of
# terminal tooling draws.
#
#   bash build/40-ncurses.sh [ncurses|readline|package|all]
#
# ── WHY THIS NUMBER, AND WHY TWO STAGES MOVED ────────────────────────
#
# CPython detects readline and ncurses AT CONFIGURE TIME and builds
# `readline` and `_curses` as extension modules or does not build them
# at all -- so this has to run before the Python stage. Every number
# from 01 to 39 was taken, and the free range CLAUDE.md points at
# (40-49) sits AFTER Python's old 38.
#
# That is a gap in the rule rather than a violation of it: the
# numbering protects the 49/50 boundary between content and packaging,
# and says nothing about ordering WITHIN content. The free range being
# at the end means it cannot host a stage that must PRECEDE an existing
# one -- the first time that has come up here. So python moved 38 -> 41
# and novi-recon 39 -> 42, and this took 40. Four files mentioned
# either number; CLAUDE.md's warning that a renumber is "about thirty
# files, most of them documentation" is about the PACKAGING stages,
# which are named all over the prose. Two content stages are cheap.
#
# It must also run before 51-desktop-split.sh, like the Python stage,
# because 50-repo.sh has to see a finished tree.
#
# ── THE TERMINFO DATABASE IS NOT SHIPPED ─────────────────────────────
#
# ncurses' database is ~7 MB of entries for terminals nobody here has
# ever seen. `--with-fallbacks` compiles a named few straight into the
# library instead, so a lookup needs no files at all and the package
# stays small. `--disable-db-install` then keeps the database out.
#
# What that costs is exact and worth stating: a TERM this build has no
# fallback for gets NOTHING -- ncurses fails to initialise rather than
# degrading. So the list is the terminals this system actually
# produces, plus the ones a person arriving over ssh will announce:
#
#   linux             the kernel's own VGA console
#   foot              the terminal this project ships (RFC 0001)
#   xterm-256color    what nearly every remote terminal claims to be
#   screen-256color   screen and older tmux
#   tmux-256color     current tmux
#   vt100             the serial console, and the universal fallback
#   dumb              no capabilities at all, which is a real answer
#
# FOOT'S ENTRY IS DERIVED, NOT COPIED. This build host has no `foot`
# terminfo (checked: `infocmp foot` fails), so the fallback generator
# would have produced nothing for the one terminal this desktop ships.
# foot's own source tree carries `foot.info` as a meson template with
# `@default_terminfo@` placeholders; that is substituted and compiled
# into a private database here, which the generator then reads. A
# hand-copied entry would be a second copy of foot's capabilities to
# keep in sync with foot.
#
# ── TERM HAS TO BE SET, AND NOTHING WAS SETTING IT ───────────────────
#
# Found on a booted machine before any of this was built: `echo $TERM`
# on the console printed nothing at all. With an empty TERM neither
# readline nor curses can look anything up, so shipping both would
# have produced a REPL that still printed `^[[A` -- a feature that
# looks broken for a reason three layers away from where anyone would
# look. The gettys pass a TERMTYPE argument now (init/services/getty-*),
# which is base content and nothing to do with this package.
#
# ── readline is GPL-3.0-or-later ─────────────────────────────────────
#
# CPython's own licence is permissive and readline's is not. It ships
# as its own shared library, built unmodified from the pinned upstream
# tarball, with its COPYING in the package, and CPython's `readline`
# module links it dynamically -- the arrangement every distribution
# uses. The obligation is the one RFC 0031 had to learn about the OFL
# fonts: the licence travels with the thing. ncurses' own licence
# (MIT-like) ships the same way, for the same reason.
#
# libedit was the alternative -- BSD, and CPython 3.10+ accepts it via
# --with-readline=editline. It was not chosen because its readline
# emulation is incomplete in ways that show up as a REPL that ALMOST
# works, which is the failure mode this item exists to end.
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-versions.sh"

CROSS="${TOOLS}/bin/${TARGET_TRIPLE}"
[ -x "${CROSS}-gcc" ] || { echo "ERROR: ${CROSS}-gcc not found -- run build/02-toolchain.sh." >&2; exit 1; }

JOBS="$(nproc)"
WORK="${BUILD_DIR}/ncurses-build"
PREFIX="${BUILD_DIR}/ncurses-target"     # for LINKING, never ${ROOTFS}
STAGE_DIR="${BUILD_DIR}/stage-devtools"
TIDIR="${WORK}/terminfo-host"            # a private database, build host only

FALLBACKS="linux,foot,xterm-256color,screen-256color,tmux-256color,vt100,dumb"

PHASE="${1:-all}"

# ── Build-host tools this needs, checked up front ─────────────────────
#
# Same rule as 05-kernel.sh checking for depmod and the Mesa stage
# checking for python-mako: a missing build-host tool must be a
# sentence, not a failure forty minutes in. ncurses' fallback generator
# is a shell script that runs the HOST's tic and infocmp -- it cannot
# use the ones it is cross-building, which do not run here.
need_host_tool() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: '$1' is not on PATH." >&2
        echo "       ncurses' fallback generator runs the BUILD HOST's tic and" >&2
        echo "       infocmp; the cross-built ones do not run here. Install" >&2
        echo "       your distribution's ncurses tools (Debian/Ubuntu:" >&2
        echo "       'apt install ncurses-bin')." >&2
        exit 1
    }
}

prepare_terminfo() {
    need_host_tool tic
    need_host_tool infocmp

    rm -rf "${TIDIR}"
    mkdir -p "${TIDIR}"

    # foot's entry, substituted out of foot's own source. The tarball is
    # already fetched for 09-foot.sh.
    local foot_src="${WORK}/foot-src"
    rm -rf "${foot_src}"
    mkdir -p "${foot_src}"
    tar xf "${SOURCES}/foot-${FOOT_VERSION}.tar.gz" -C "${foot_src}"
    local info
    info="$(find "${foot_src}" -name foot.info -print -quit)"
    [ -n "${info}" ] || { echo "ERROR: no foot.info in foot-${FOOT_VERSION}.tar.gz." >&2; exit 1; }

    sed 's/@default_terminfo@/foot/g' "${info}" > "${WORK}/foot.info"
    TERMINFO="${TIDIR}" tic -x -o "${TIDIR}" "${WORK}/foot.info" \
        >"${WORK}/tic.log" 2>&1 \
        || { echo "ERROR: tic refused foot.info:" >&2; cat "${WORK}/tic.log" >&2; exit 1; }

    # A wildcard that matches nothing is silent (CLAUDE.md, the firmware
    # extraction). Prove the entry is there before trusting the build.
    TERMINFO="${TIDIR}" infocmp foot >/dev/null 2>&1 || {
        echo "ERROR: compiled foot.info but 'infocmp foot' still finds nothing." >&2
        exit 1
    }
    echo "   foot terminfo compiled from foot-${FOOT_VERSION}'s own foot.info"
}

build_ncurses() {
    echo ">>> ncurses ${NCURSES_VERSION}"
    prepare_terminfo

    local src="${WORK}/ncurses-${NCURSES_VERSION}"
    rm -rf "${src}"
    tar xf "${SOURCES}/ncurses-${NCURSES_VERSION}.tar.gz" -C "${WORK}"

    # --enable-widec gives libncursesw: CPython's _curses is written
    #   against the wide-character API and a narrow build gives an
    #   interpreter that cannot print a non-ASCII character in a window.
    # --with-termlib=tinfo keeps the terminal-description half in its own
    #   library, which is what readline actually links -- so a program
    #   that only needs termcap does not drag the whole screen library.
    # --enable-pc-files so readline's and CPython's configure can find
    #   this by pkg-config rather than by guessing paths.
    # --disable-db-install: see the header. The fallbacks are the database.
    # --without-manpages/--without-tests/--without-ada/--without-cxx-binding:
    #   none of it can run here and all of it is size.
    # BUILD_CC is the host compiler for the few generator programs that
    #   have to RUN during the build (make_hash, make_keys). Without it
    #   they are built with the cross compiler and the build dies trying
    #   to execute them.
    (
        cd "${src}"
        TERMINFO="${TIDIR}" \
        TIC_PATH="$(command -v tic)" \
        INFOCMP_PATH="$(command -v infocmp)" \
        ./configure \
            --build="$(gcc -dumpmachine)" \
            --host="${TARGET_TRIPLE}" \
            --prefix=/usr \
            --with-build-cc=gcc \
            --with-shared \
            --without-normal \
            --without-debug \
            --enable-widec \
            --with-termlib=tinfo \
            --enable-pc-files \
            --with-pkg-config-libdir=/usr/lib/pkgconfig \
            --with-fallbacks="${FALLBACKS}" \
            --disable-db-install \
            --without-manpages \
            --without-tests \
            --without-ada \
            --without-cxx-binding \
            --disable-stripping \
            >"${WORK}/ncurses-configure.log" 2>&1 \
            || { tail -40 "${WORK}/ncurses-configure.log" >&2; exit 1; }

        make -j"${JOBS}" >"${WORK}/ncurses-build.log" 2>&1 \
            || { tail -60 "${WORK}/ncurses-build.log" >&2; exit 1; }
        rm -rf "${PREFIX}"
        make install DESTDIR="${PREFIX}" >"${WORK}/ncurses-install.log" 2>&1 \
            || { tail -40 "${WORK}/ncurses-install.log" >&2; exit 1; }
    )

    # A fallback that did not compile in is the whole failure this stage
    # can have and it is SILENT: the library builds, installs and works
    # for every terminal except the one nobody tested. The generated
    # table is a C file, so check it -- and check the RESULT rather than
    # the generator's intent. MKfallback.sh writes a
    # "fallback entries for: ..." comment straight from its argument
    # list, so a name it then failed to produce still appears there;
    # what only a real entry produces is an alias_data line.
    #
    # (The first version of this check looked for the bare name in
    # quotes and reported all seven missing on a build where all seven
    # were present -- the data reads "linux|Linux console", not
    # "linux". The probe was the broken thing, for the third time in
    # this session's work. Read what the generator actually writes.)
    local fb="${src}/ncurses/fallback.c"
    [ -f "${fb}" ] || { echo "ERROR: ncurses built no fallback.c." >&2; exit 1; }
    local missing=""
    local n
    for n in ${FALLBACKS//,/ }; do
        grep -q "_alias_data\[\] = \"${n}|" "${fb}" || missing="${missing} ${n}"
    done
    if [ -n "${missing}" ]; then
        echo "ERROR: these terminals are not in the compiled-in fallbacks:${missing}" >&2
        echo "       A TERM with no fallback and no database gets NOTHING -- ncurses" >&2
        echo "       fails to initialise rather than degrading. Check the build" >&2
        echo "       host has an entry for each ('infocmp <name>')." >&2
        exit 1
    fi
    echo "   fallbacks compiled in: ${FALLBACKS//,/ }"

    # THE LIBRARY'S NAME IS READ, NEVER ASSUMED. The first version of
    # this stage ended with two `ln -sf` lines "fixing up" the
    # unsuffixed names -- and `--with-termlib=tinfo` had already
    # installed a correct `libtinfo.so -> libtinfo.so.6`, so the ln
    # REPLACED it with a dangling link to a libtinfow.so that does not
    # exist. readline then failed on `cannot find -ltinfow`, naming a
    # library this stage had invented. What `--enable-widec` suffixes
    # and what it does not is a configure-time decision; the `.pc`
    # files are where that decision is written down.
    local pc="${PREFIX}/usr/lib/pkgconfig"
    [ -f "${pc}/tinfo.pc" ] || { echo "ERROR: ncurses installed no tinfo.pc." >&2; exit 1; }
    TERMLIB="$(sed -n 's/^Libs:.*-l\([a-z0-9]*tinfo[a-z0-9]*\).*/\1/p' "${pc}/tinfo.pc" | head -1)"
    [ -n "${TERMLIB}" ] || { echo "ERROR: cannot read the terminal library's name out of tinfo.pc." >&2; exit 1; }
    [ -e "${PREFIX}/usr/lib/lib${TERMLIB}.so" ] || {
        echo "ERROR: tinfo.pc names -l${TERMLIB} but lib${TERMLIB}.so is not there." >&2
        exit 1
    }
    echo "   terminal library: -l${TERMLIB}"
    echo "${TERMLIB}" > "${WORK}/termlib"
}

build_readline() {
    echo ">>> readline ${READLINE_VERSION}"
    local src="${WORK}/readline-${READLINE_VERSION}"
    rm -rf "${src}"
    tar xf "${SOURCES}/readline-${READLINE_VERSION}.tar.gz" -C "${WORK}"

    # Written down by the ncurses phase, from ncurses' own tinfo.pc.
    # Running this phase alone after a tree was built elsewhere is a
    # normal thing to do, so say what is missing rather than linking
    # against a name nobody chose.
    local termlib
    [ -f "${WORK}/termlib" ] || {
        echo "ERROR: ${WORK}/termlib is missing -- run '$0 ncurses' first." >&2
        exit 1
    }
    termlib="$(cat "${WORK}/termlib")"

    # -rpath-link for the SIXTH time in this repository (nftables,
    # git/curl, the meson cross file, novi-glinfo, NetSurf, now here):
    # libreadline.so names libtinfow.so.6 in its DT_NEEDED and -L does
    # not resolve a shared library's own dependencies.
    #
    # bash_cv_wcwidth_broken=no: the test COMPILES AND RUNS a program to
    # ask the libc whether wcwidth() reports 0 for a combining
    # character. musl's does not; a cross build cannot find out, and the
    # default when it cannot is to assume broken -- which makes readline
    # mis-measure every line containing one.
    (
        cd "${src}"
        CC="${CROSS}-gcc" \
        AR="${CROSS}-ar" \
        RANLIB="${CROSS}-ranlib" \
        CPPFLAGS="-I${PREFIX}/usr/include -I${PREFIX}/usr/include/ncursesw" \
        LDFLAGS="-L${PREFIX}/usr/lib -Wl,-rpath-link,${PREFIX}/usr/lib" \
        ./configure \
            --build="$(gcc -dumpmachine)" \
            --host="${TARGET_TRIPLE}" \
            --prefix=/usr \
            --with-curses \
            --enable-shared \
            --disable-static \
            bash_cv_wcwidth_broken=no \
            >"${WORK}/readline-configure.log" 2>&1 \
            || { tail -40 "${WORK}/readline-configure.log" >&2; exit 1; }

        # SHLIB_LIBS is how readline's own makefile names what its
        # shared library links against. Left to itself it picks
        # `-lcurses` or nothing, and a libreadline.so with no
        # DT_NEEDED on the terminal library loads and then cannot move
        # a cursor.
        make -j"${JOBS}" SHLIB_LIBS="-L${PREFIX}/usr/lib -l${termlib}" \
            >"${WORK}/readline-build.log" 2>&1 \
            || { tail -60 "${WORK}/readline-build.log" >&2; exit 1; }
        make install DESTDIR="${PREFIX}" \
            >"${WORK}/readline-install.log" 2>&1 \
            || { tail -40 "${WORK}/readline-install.log" >&2; exit 1; }
    )

    # Check the artifact, not the flags (CLAUDE.md). A libreadline that
    # does not NEED a terminal library is the silent half-working build.
    local need
    # The REAL file, not every name that points at it: the glob matches
    # libreadline.so.8 as well as libreadline.so.8.2 and readelf follows
    # both, which printed the dependency list twice.
    local lib
    lib="$(find "${PREFIX}/usr/lib" -maxdepth 1 -name 'libreadline.so.*' -type f -print -quit)"
    [ -n "${lib}" ] || { echo "ERROR: no libreadline.so was installed." >&2; exit 1; }
    need="$("${CROSS}-readelf" -d "${lib}" 2>/dev/null \
            | sed -n 's/.*NEEDED.*\[\(.*\)\].*/\1/p' | tr '\n' ' ')"
    case "${need}" in
        *tinfo*|*ncurses*) : ;;
        *)  echo "ERROR: libreadline.so does not NEED a terminal library." >&2
            echo "       DT_NEEDED is: ${need}" >&2
            echo "       It would load and then be unable to move the cursor." >&2
            exit 1 ;;
    esac
    echo "   libreadline NEEDED: ${need}"
}

# EVERY PATTERN IS CHECKED, not just the total, and that is not
# belt-and-braces: the first version counted files and passed with
# THREE of its five patterns matching nothing. `libtinfow.so*` (the
# name this build does not use -- see build_ncurses) and a
# `libform w.so*` with a space in it both quietly contributed zero,
# and the package shipped without the terminal library that
# libreadline.so NEEDs. A wildcard that matches nothing is silent:
# CLAUDE.md records it about a tar extraction that shipped 393 MB of
# firmware with no iwlwifi in it. Same bug, same afternoon's lesson.
stage_pkg() {
    local name="$1" version="$2" desc="$3" depends="$4"
    shift 4
    local d="${STAGE_DIR}/${name}"
    rm -rf "${d}"
    mkdir -p "${d}/files/usr/lib" "${d}/files/usr/share/licenses/${name}"
    local pat hits empty=""
    for pat in "$@"; do
        hits=0
        local f
        for f in ${PREFIX}/usr/lib/${pat}; do
            [ -e "${f}" ] || continue
            # readline's `make install` renames the previous library to
            # `.old` rather than removing it. Dead weight in a package
            # is not inert (RFC 0007): it is bytes on every machine that
            # installs this, and a second copy of a library for anything
            # reading the directory.
            case "${f}" in *.old) continue ;; esac
            cp -a "${f}" "${d}/files/usr/lib/"
            hits=$((hits + 1))
        done
        [ "${hits}" -gt 0 ] || empty="${empty} ${pat}"
    done
    if [ -n "${empty}" ]; then
        echo "ERROR: ${name}: these patterns matched nothing:${empty}" >&2
        echo "       A wildcard that matches nothing is silent, so this is a" >&2
        echo "       package that builds, signs and installs without the file." >&2
        exit 1
    fi
    local n
    n="$(find "${d}/files/usr/lib" -mindepth 1 | wc -l)"
    find "${d}/files" -name '*.so*' -type f -exec "${CROSS}-strip" --strip-unneeded {} + 2>/dev/null || true
    {
        echo "name=${name}"
        echo "version=${version}"
        echo "arch=${TARGET_ARCH}"
        [ -n "${depends}" ] && echo "depends=${depends}"
        echo "description=${desc}"
    } > "${d}/MANIFEST"
    echo "   staged ${name} (${n} file(s), $(du -sh "${d}/files" | cut -f1))"
}

package() {
    echo ">>> Staging packages into ${STAGE_DIR}"
    mkdir -p "${STAGE_DIR}"

    # Written down by the ncurses phase, from ncurses' own tinfo.pc --
    # running `package` alone is a normal thing to do.
    [ -f "${WORK}/termlib" ] || {
        echo "ERROR: ${WORK}/termlib is missing -- run '$0 ncurses' first." >&2
        exit 1
    }
    TERMLIB="$(cat "${WORK}/termlib")"

    stage_pkg ncurses "${NCURSES_VERSION}" \
        "ncurses ${NCURSES_VERSION} -- terminal handling, with a compiled-in terminfo set" \
        "" "libncursesw.so*" "lib${TERMLIB}.so*" "libformw.so*" \
        "libmenuw.so*" "libpanelw.so*"

    stage_pkg readline "${READLINE_VERSION}" \
        "GNU readline ${READLINE_VERSION} -- line editing and history (GPL-3.0-or-later)" \
        "ncurses" 'libreadline.so*' 'libhistory.so*'

    # THE LICENCE TRAVELS WITH THE THING (RFC 0031's OFL lesson). Both
    # of these are copyleft or attribution-requiring and neither text
    # was going to arrive any other way.
    local lic
    lic="$(find "${WORK}/readline-${READLINE_VERSION}" -maxdepth 1 -name COPYING -print -quit)"
    [ -n "${lic}" ] || { echo "ERROR: readline's COPYING is not in its tarball." >&2; exit 1; }
    install -D -m 644 "${lic}" "${STAGE_DIR}/readline/files/usr/share/licenses/readline/COPYING"

    lic="$(find "${WORK}/ncurses-${NCURSES_VERSION}" -maxdepth 1 -name COPYING -print -quit)"
    [ -n "${lic}" ] || { echo "ERROR: ncurses' COPYING is not in its tarball." >&2; exit 1; }
    install -D -m 644 "${lic}" "${STAGE_DIR}/ncurses/files/usr/share/licenses/ncurses/COPYING"

    echo
    echo "Publish them with:  bash build/53-devtools-repo.sh"
}

mkdir -p "${WORK}"
case "${PHASE}" in
    ncurses)  build_ncurses ;;
    readline) build_readline ;;
    package)  package ;;
    all)      build_ncurses; build_readline; package ;;
    *) echo "usage: $0 [ncurses|readline|package|all]" >&2; exit 1 ;;
esac
