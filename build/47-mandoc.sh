#!/bin/bash
# ============================================================
# 47-mandoc.sh — a `man` that can actually display a page
#
# RFC 0040 roadmap 2.
#
#   bash build/47-mandoc.sh [build|package|all]
#
# ── THE BASE ALREADY HAD A `man`, AND IT COULD NEVER WORK ────────────
#
# busybox ships a `man` applet, so `/usr/bin/man` has existed on every
# Novi image ever built. It shells out to `tbl`, `nroff` and `col` --
# none of which are in this system -- so `man ls` prints
#
#     sh: 1: tbl: not found
#     sh: 1: col: not found
#
# and nothing else. Measured with the shipped busybox binary on the
# build host, not assumed. A command that cannot work is worse than a
# command that is absent (RFC 0026's argument for deleting `idle3`),
# and this one had been shipping for the life of the project.
#
# Meanwhile RFC 0040's own build was producing 102 man pages, 916 KB of
# them, and throwing every one away because nothing could read them.
#
# ── mandoc, NOT groff ────────────────────────────────────────────────
#
# One self-contained C program, ISC-licensed, no dependencies, ~600 KB
# installed -- against groff's several megabytes and a Perl dependency
# for parts of it. It is what Alpine, OpenBSD and Void ship, and its
# whole design is "format man(7) and mdoc(7) without a roff".
#
# ── IT IS THE FIRST REAL USER OF `replaces-files=` ───────────────────
#
# mandoc installs `/usr/bin/man`, which is busybox's. RFC 0040 roadmap
# 1 had just made pkg refuse exactly that -- so this package declares
# the takeover, pkg saves the busybox symlink, and `pkg remove man`
# puts it back. The mechanism was built for binutils' `strings` and
# the next package needed it, which is a reasonable sign it was the
# right shape.
#
# ── configure RUNS ITS TESTS, WHICH A CROSS BUILD CANNOT ─────────────
#
# `runtest` compiles a probe and then executes it, so every answer
# would come back "no" here and mandoc would build against a libc it
# invented. `configure.local` is upstream's documented override and
# `runtest` skips any test whose variable is already set.
#
# Every answer below is a MEASURED FACT ABOUT THIS musl, read out of
# the sysroot with `nm` and `ls`, not a guess: musl has strlcpy,
# strlcat, reallocarray, mkstemps and strcasestr; it does not have
# recallocarray, strtonum, getprogname or fts; <err.h> and <endian.h>
# are there and <sys/endian.h> and <fts.h> are not.
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-versions.sh"

PHASE="${1:-all}"
WORK="${BUILD_DIR}/mandoc-build"
PREFIX="${BUILD_DIR}/mandoc-target"
STAGE_DIR="${BUILD_DIR}/stage-devtools"
CROSS="${TOOLS}/bin/${TARGET_TRIPLE}"
SRC="${WORK}/mandoc-${MANDOC_VERSION}"

[ -x "${CROSS}-gcc" ] || {
    echo "ERROR: ${CROSS}-gcc not found -- run build/02-toolchain.sh first." >&2
    exit 1
}

harden_flags
mkdir -p "${WORK}" "${PREFIX}"

# zlib, for gzipped man pages -- `read.c` includes <zlib.h>
# unconditionally in 1.14.6, so this is not optional. It comes from
# ${ROOTFS} like every other library a stage links, which is why this
# stage has to run BEFORE 51-desktop-split.sh takes the headers out.
#
# DYNAMIC, and so `depends=zlib`. Static would make `man` work on a
# console base with nothing else installed, at the cost of a second
# copy of zlib on every machine that has the package -- and "one
# library, one CVE to watch" is the same argument that made bash link
# the packaged readline rather than the one it bundles.
ZLIB_H="${ROOTFS}/usr/include/zlib.h"
[ -f "${ZLIB_H}" ] || {
    echo "ERROR: ${ZLIB_H} is missing." >&2
    echo "       mandoc includes <zlib.h> unconditionally. In a clean build" >&2
    echo "       this stage runs before 51-desktop-split.sh and the header" >&2
    echo "       is there; in a split tree, run scripts/restore-build-inputs.sh" >&2
    echo "       or a real 'bash build.sh --from 06 --to 49'." >&2
    exit 1
}

build_mandoc() {
    echo ">>> mandoc ${MANDOC_VERSION}"
    rm -rf "${SRC}"
    tar -xf "${SOURCES}/mandoc-${MANDOC_VERSION}.tar.gz" -C "${WORK}"

    # NEED_GNU_SOURCE is set by configure only when a test RUNS and
    # succeeds with -D_GNU_SOURCE. With the answers supplied manually
    # no test runs, so nothing sets it -- and musl hides strcasestr,
    # vasprintf, strsep and getsubopt behind it. Declaring them present
    # without the feature-test macro is a build that fails on four
    # implicit declarations, so it goes in CFLAGS by hand.
    cat > "${SRC}/configure.local" <<LOCAL
CC="${CROSS}-gcc"
AR="${CROSS}-ar"
CFLAGS="${CFLAGS} -D_GNU_SOURCE -I${ROOTFS}/usr/include"
LDFLAGS="${LDFLAGS} -L${ROOTFS}/usr/lib -Wl,-rpath-link,${ROOTFS}/usr/lib"
PREFIX="/usr"
BINDIR="/usr/bin"
SBINDIR="/usr/bin"
MANDIR="/usr/share/man"
OSNAME="Novi Linux"

# Where a page is looked for. /usr/share/man is the base and the
# packages that ship pages; /usr/gnu/share/man is RFC 0040's prefix,
# and without it \`man ls\` would find nothing on a machine that has
# just installed coreutils.
MANPATH_DEFAULT="/usr/share/man:/usr/gnu/share/man:/usr/local/share/man"

# No pager is assumed. \`less\` is not in this system; busybox has
# \`more\`, and mandoc falls back to writing to stdout when the pager
# cannot be run, which is the honest behaviour for a machine piping
# the output anyway.
BINM_PAGER="more"

# Measured against this musl, not guessed -- see the header.
HAVE_ATTRIBUTE=1
HAVE_CMSG=1
HAVE_DIRENT_NAMLEN=0
HAVE_EFTYPE=0
HAVE_ENDIAN=1
HAVE_ERR=1
HAVE_FTS=0
HAVE_FTS_COMPARE_CONST=0
HAVE_GETLINE=1
HAVE_GETSUBOPT=1
HAVE_ISBLANK=1
HAVE_LESS_T=0
HAVE_MKDTEMP=1
HAVE_MKSTEMPS=1
HAVE_NANOSLEEP=1
HAVE_NTOHL=1
HAVE_O_DIRECTORY=1
HAVE_OHASH=0
HAVE_PATH_MAX=1
HAVE_PLEDGE=0
HAVE_PROGNAME=0
HAVE_REALLOCARRAY=1
HAVE_RECALLOCARRAY=0
HAVE_RECVMSG=1
HAVE_REWB_BSD=0
HAVE_REWB_SYSV=0
HAVE_SANDBOX_INIT=0
HAVE_STRCASESTR=1
HAVE_STRINGLIST=0
HAVE_STRLCAT=1
HAVE_STRLCPY=1
HAVE_STRNDUP=1
HAVE_STRPTIME=1
HAVE_STRSEP=1
HAVE_STRTONUM=0
HAVE_SYS_ENDIAN=0
HAVE_VASPRINTF=1
HAVE_WCHAR=1
LD_NANOSLEEP=
LD_RECVMSG=
LD_OHASH=
LOCAL

    (
        cd "${SRC}"
        ./configure
        make -j"$(nproc)"
        make DESTDIR="${PREFIX}" install
    )

    # THE ARTIFACT, NOT THE LOG. configure prints what it decided and
    # carries on either way; what matters is that a target binary came
    # out and that it is the target's.
    local bin="${PREFIX}/usr/bin/mandoc"
    [ -x "${bin}" ] || { echo "ERROR: no mandoc binary at ${bin}." >&2; exit 1; }
    readelf -h "${bin}" | grep -q 'X86-64' || {
        echo "ERROR: ${bin} is not an x86-64 binary." >&2; exit 1; }
    echo "    mandoc: $(du -h "${bin}" | cut -f1)"
}

package() {
    echo ">>> Staging the man package into ${STAGE_DIR}"
    local d="${STAGE_DIR}/man"
    [ -x "${PREFIX}/usr/bin/mandoc" ] || {
        echo "ERROR: nothing built -- run '$0 build' first." >&2; exit 1; }

    rm -rf "${d}"
    install -d "${d}/files/usr/bin" "${d}/files/usr/share/licenses/man" \
               "${d}/files/etc"
    local p hits=0
    for p in mandoc man apropos whatis makewhatis soelim; do
        if [ -f "${PREFIX}/usr/bin/${p}" ] || [ -L "${PREFIX}/usr/bin/${p}" ]; then
            cp -a "${PREFIX}/usr/bin/${p}" "${d}/files/usr/bin/"
            hits=$((hits + 1))
        fi
    done
    # `man` and `mandoc` are the two that must exist: the rest are
    # links mandoc's own install may or may not make, and a package
    # that quietly shipped neither would install and do nothing.
    for p in mandoc man; do
        [ -e "${d}/files/usr/bin/${p}" ] || {
            echo "ERROR: man package has no ${p}." >&2; exit 1; }
    done
    find "${d}/files" -type f -perm -u+x \
        -exec "${CROSS}-strip" --strip-unneeded {} + 2>/dev/null || true

    # mandoc's own man pages, so `man man` works on a machine that has
    # only installed this.
    if [ -d "${PREFIX}/usr/share/man" ]; then
        install -d "${d}/files/usr/share/man"
        cp -a "${PREFIX}/usr/share/man/." "${d}/files/usr/share/man/"
    fi

    install -m 644 "${SRC}/LICENSE" \
        "${d}/files/usr/share/licenses/man/LICENSE" 2>/dev/null || {
        echo "ERROR: no LICENSE found to ship with the package." >&2; exit 1; }

    {
        echo "name=man"
        echo "version=${MANDOC_VERSION}"
        echo "arch=${TARGET_ARCH}"
        # THE DECLARATION (RFC 0040 roadmap 1). /usr/bin/man is
        # busybox's symlink in the base; pkg refuses to take a path
        # nothing owns unless the package says so, saves the original,
        # and restores it on removal.
        echo "depends=zlib"
        echo "replaces-files=usr/bin/man"
        echo "description=mandoc -- a man(7) and mdoc(7) formatter, and the man/apropos/whatis commands. The base image's busybox \`man\` shells out to nroff and col, which this system does not have, so it could never display a page"
    } > "${d}/MANIFEST"
    echo "   staged man: ${hits} program(s), $(du -sh "${d}/files" | cut -f1)"
    echo ""
    echo "Publish it with:  bash build/53-devtools-repo.sh"
}

case "${PHASE}" in
    build)   build_mandoc ;;
    package) package ;;
    all)     build_mandoc; package ;;
    *) echo "usage: $0 [build|package|all]" >&2; exit 2 ;;
esac
