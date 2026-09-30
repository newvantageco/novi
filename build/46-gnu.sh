#!/bin/bash
# ============================================================
# 46-gnu.sh — GNU bash and coreutils, as packages
#
# RFC 0040. `docs/PLATFORM-ROADMAP.md` §5 has said this since it was
# written -- "Full GNU coreutils/util-linux/bash become an ordinary
# `pkg install` for any real interactive system" -- and it was never
# built. BusyBox is the right BASE userland and it is a SUBSET: the
# difference is a papercut a developer meets several times a day
# (`pgrep -c`, `sed -i` with a range, `find -printf`, `sort -h`, bash
# arrays and `[[ ]]`).
#
#   bash build/46-gnu.sh [bash|coreutils|package|all]
#
# ── WHY /usr/gnu AND NOT /usr/bin ────────────────────────────────────
#
# Because `pkg` HAS NO FILE-CONFLICT HANDLING. It extracts an archive
# over the root filesystem; there is no owner check, no conflict
# refusal, nothing. `/bin/ls` is a symlink to busybox, so a coreutils
# package shipping `/usr/bin/ls` would quietly take the name -- and
# `pkg remove coreutils` would then DELETE it, leaving a machine with
# no `ls` at all and no way for pkg to know it had done that.
#
# That is not a hypothetical about a future pkg: it is what the code
# does today, checked rather than assumed. So the packages install
# into a prefix of their own and PATH decides, which is additive,
# reversible, and leaves the base image byte for byte as it was.
#
# ── AND WHY A LOGIN SHELL IS THE RIGHT SCOPE ─────────────────────────
#
# `/etc/profile.d/gnu.sh` puts /usr/gnu/bin FIRST for interactive
# logins, and reaches nothing else. Services get their PATH from
# s6-linux-init-maker's `-p` (see build/04-s6.sh), not from
# /etc/profile -- so the person typing at a prompt gets GNU tools and
# every s6 service, uevent handler and boot script goes on running the
# busybox applets it was written and tested against.
#
# That split is the whole reason prepending is safe here. On a
# distribution where /etc/profile is the system's PATH it would not be.
#
# ── /bin/sh IS NOT REPOINTED, EVER ───────────────────────────────────
#
# Every `#!/bin/sh` script in this system was written against busybox
# ash and several depend on it (`packages/pkg` uses `set -o pipefail`,
# which ash has and dash does not -- CLAUDE.md has a whole section on
# that). Repointing /bin/sh at bash on a package install would change
# the interpreter for the entire system, including init. A person who
# wants bash as their shell has a declarative way to say so that
# already exists: `users.<name>.shell = /usr/gnu/bin/bash` (RFC 0005).
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-versions.sh"

PHASE="${1:-all}"
WORK="${BUILD_DIR}/gnu-build"
PREFIX="${BUILD_DIR}/gnu-target"
STAGE_DIR="${BUILD_DIR}/stage-devtools"
CROSS="${TOOLS}/bin/${TARGET_TRIPLE}"
# /usr/gnu, baked in at configure time. The binaries record it in
# their own --help output and coreutils uses it for its locale and
# charset tables, so it has to be the path on the TARGET and not the
# staging directory.
GNU_PREFIX="/usr/gnu"

[ -x "${CROSS}-gcc" ] || {
    echo "ERROR: ${CROSS}-gcc not found -- run build/02-toolchain.sh first." >&2
    exit 1
}

mkdir -p "${WORK}" "${PREFIX}"

# harden_flags() like every other first-party-adjacent build. These are
# packages rather than base content, so check-hardening.sh (which runs
# at 50-repo.sh over ${ROOTFS}) never sees them -- which is a reason to
# be careful here rather than a reason not to bother.
harden_flags

cross_env() {
    export CC="${CROSS}-gcc"
    export AR="${CROSS}-ar"
    export RANLIB="${CROSS}-ranlib"
    export STRIP="${CROSS}-strip"
}

build_bash() {
    echo ">>> bash ${GNU_BASH_VERSION}"
    rm -rf "${WORK}/bash-${GNU_BASH_VERSION}"
    tar -xf "${SOURCES}/bash-${GNU_BASH_VERSION}.tar.gz" -C "${WORK}"
    (
        cd "${WORK}/bash-${GNU_BASH_VERSION}"
        cross_env
        # --with-installed-readline: bash BUNDLES a copy of readline
        # and links it statically by default, which would put a second
        # readline on a machine that already has one as a package (RFC
        # 0026 built it for Python). One library, one CVE to watch, one
        # GPL-3 COPYING already travelling in the `readline` package --
        # the same argument `pkg rdeps` makes about having one
        # implementation of a question.
        #
        # --without-bash-malloc: bash's own allocator is tuned for
        # glibc-era assumptions and is a known source of trouble on
        # musl; every musl distribution turns it off.
        #
        # bash_cv_* are the run-tests autoconf cannot run when cross
        # compiling. Each answer is a fact about musl, not a guess:
        # musl's getcwd(NULL, 0) mallocs (yes), its printf handles %ll
        # and long doubles (yes), it has no /dev/fd at configure time
        # on the BUILD host's terms but the target does (rc.init
        # creates it -- CLAUDE.md's own /dev/fd section), and job
        # control works.
        ./configure \
            --host="${TARGET_TRIPLE}" \
            --build="$(uname -m)-pc-linux-gnu" \
            --prefix="${GNU_PREFIX}" \
            --without-bash-malloc \
            --with-curses \
            --enable-readline \
            --with-installed-readline \
            --disable-nls \
            bash_cv_getcwd_malloc=yes \
            bash_cv_job_control_missing=present \
            bash_cv_sys_named_pipes=present \
            bash_cv_func_sigsetjmp=present \
            bash_cv_printf_a_format=yes \
            bash_cv_unusable_rtsigs=no \
            bash_cv_wcwidth_broken=no \
            bash_cv_dev_fd=whacky \
            CFLAGS="${CFLAGS}" LDFLAGS="${LDFLAGS}" \
            CPPFLAGS="-I${BUILD_DIR}/ncurses-target/usr/include" \
            LDFLAGS="${LDFLAGS} -L${BUILD_DIR}/ncurses-target/usr/lib -Wl,-rpath-link,${BUILD_DIR}/ncurses-target/usr/lib"
        make -j"$(nproc)"
        # THE LOADABLE BUILTINS ARE NOT BUILT, and the reason is a trap
        # this repository has already recorded once. `make install`
        # recurses into examples/loadables, which links SHARED OBJECTS
        # -- and `-pie` from harden_flags reaches that link through
        # LDFLAGS. RFC 0026 found the same thing in CPython:
        # **gcc given `-shared -pie` does not warn**, it drops the
        # `-shared` and links an executable, which then fails on
        # undefined references. Here it was fourteen of bash's own
        # symbols plus `warning: creating DT_TEXTREL in a PIE`.
        #
        # The top-level makefile prefixes that recursion with `-`, so
        # the failure is IGNORED: `make install` exits 0 having printed
        # `Error 2 (ignored)` in the middle of its output. A build that
        # reports success while a subdirectory failed is exactly the
        # shape this project keeps getting caught by, so rather than
        # leave it in the log, the recursion is pointed at a directory
        # whose Makefile does nothing. Nothing here packages the
        # loadables -- they are `examples/`, and bash works without
        # them.
        mkdir -p "${WORK}/no-loadables"
        printf 'all install install-strip uninstall clean:\n\t@:\n' \
            > "${WORK}/no-loadables/Makefile"
        make install DESTDIR="${PREFIX}" LOADABLES_DIR="${WORK}/no-loadables"
    )
    echo "    bash: $(du -h "${PREFIX}${GNU_PREFIX}/bin/bash" | cut -f1)"
}

build_coreutils() {
    echo ">>> coreutils ${COREUTILS_VERSION}"
    rm -rf "${WORK}/coreutils-${COREUTILS_VERSION}"
    tar -xf "${SOURCES}/coreutils-${COREUTILS_VERSION}.tar.xz" -C "${WORK}"
    (
        cd "${WORK}/coreutils-${COREUTILS_VERSION}"
        cross_env
        # --enable-no-install-program: `kill`, `uptime`, `hostname` and
        # `stty` are shipped by busybox in the BASE and this package is
        # additive, so shadowing them on PATH would change the answer
        # for tools nobody asked to replace. `arch` is `uname -m`.
        #
        # FORCE_UNSAFE_CONFIGURE=1: coreutils' configure refuses to run
        # as root because `make check` as root can damage the machine.
        # This container is root and nothing here runs the test suite
        # on the build host -- these are TARGET binaries, which cannot
        # run here at all.
        #
        # gl_cv_* are gnulib's run-tests. musl's getcwd, printf and
        # nanosleep are all the POSIX behaviour gnulib probes for; the
        # alternative is gnulib substituting a replacement for a
        # function that is already correct.
        FORCE_UNSAFE_CONFIGURE=1 ./configure \
            --host="${TARGET_TRIPLE}" \
            --build="$(uname -m)-pc-linux-gnu" \
            --prefix="${GNU_PREFIX}" \
            --disable-nls \
            --disable-rpath \
            --without-openssl \
            --enable-no-install-program=kill,uptime,hostname,arch,stty \
            CFLAGS="${CFLAGS}" LDFLAGS="${LDFLAGS}" \
            gl_cv_func_getcwd_null=yes \
            gl_cv_func_getcwd_path_max=yes \
            gl_cv_func_printf_directive_n=yes \
            gl_cv_func_nanosleep=yes \
            gl_cv_func_working_mktime=yes \
            ac_cv_func_working_mktime=yes
        # `-shared -pie` FOR THE THIRD TIME IN THIS REPOSITORY, and it
        # fails the same way every time: gcc DOES NOT WARN, it drops
        # the `-shared`, links an executable and dies on `undefined
        # reference to 'main'` from Scrt1.o. RFC 0026 hit it on
        # CPython's ~40 extension-module links; build/46-gnu.sh's own
        # bash phase hit it on the loadable builtins; here it is
        # `src/libstdbuf.so`, the preload library `stdbuf` needs.
        #
        # automake's generated LINK line is
        # `$(CCLD) ... $(src_libstdbuf_so_LDFLAGS) $(LDFLAGS) -o $@`,
        # so the hardening LDFLAGS land after the `-shared`. Filtering
        # `-pie` out of that ONE rule keeps relro, BIND_NOW and
        # noexecstack on the shared object and drops only the flag
        # that cannot apply to it -- where dropping `stdbuf` would
        # have been a tool missing from a package that claims to be
        # the full coreutils.
        #
        # APPENDED, NOT SED'D IN PLACE: automake writes that rule
        # across two lines with a backslash continuation, so `$(LDFLAGS)`
        # is on the second one and a line-anchored substitution cannot
        # see it -- which is how the first attempt at this "succeeded"
        # by matching nothing. A later simple assignment wins in GNU
        # make, so the override goes at the end of the file and does
        # not care how upstream lays the rule out.
        grep -q '^src_libstdbuf_so_LINK = ' Makefile || {
            echo "ERROR: coreutils' Makefile has no src_libstdbuf_so_LINK rule." >&2
            echo "       The -shared/-pie fix here no longer applies." >&2
            exit 1
        }
        #
        # AND THE OBJECT NEEDS THE SAME TREATMENT, which the link error
        # only reveals once the link flags are right: automake's
        # compile rule is `... $(src_libstdbuf_so_CFLAGS) $(CFLAGS)`,
        # so upstream's own `-fPIC` comes FIRST and the hardening
        # `-fPIE` after it wins. The result links as far as
        # `relocation R_X86_64_PC32 against symbol 'stderr' can not be
        # used when making a shared object; recompile with -fPIC` --
        # which is the same bug as the `-pie` one, on the compiler
        # rather than the linker, and it stayed hidden behind it.
        # A target-specific variable is exactly the tool: it applies to
        # this one object and nothing else in the tree.
        {
            echo ""
            echo "src_libstdbuf_so_LINK = \$(CCLD) \$(src_libstdbuf_so_CFLAGS) \\"
            echo "\t\$(CFLAGS) \$(src_libstdbuf_so_LDFLAGS) \\"
            echo "\t\$(filter-out -pie,\$(LDFLAGS)) -o \$@"
            echo "src/libstdbuf_so-libstdbuf.o: CFLAGS := \$(filter-out -fPIE,\$(CFLAGS)) -fPIC"
        } | sed 's/\\t/\t/' >> Makefile
        make -j"$(nproc)"
        # The artifact, not the flags -- CLAUDE.md's rule about
        # check-hardening.sh, one level down. A PT_INTERP here would
        # mean gcc had linked an executable again.
        if readelf -l src/libstdbuf.so 2>/dev/null | grep -q INTERP; then
            echo "ERROR: src/libstdbuf.so was linked as an executable." >&2
            echo "       -pie reached a -shared link again." >&2
            exit 1
        fi
        make install DESTDIR="${PREFIX}"
    )
    local n
    n="$(find "${PREFIX}${GNU_PREFIX}/bin" -type f | wc -l)"
    echo "    coreutils: ${n} program(s) installed into ${GNU_PREFIX}/bin"
}

# THE DROP-IN IS ITS OWN PACKAGE FILE, not base content, because it
# must arrive and leave with the tools it points at. A PATH entry for
# a directory that does not exist is harmless and is also a line
# somebody has to wonder about.
write_profile_drop_in() {
    local d="$1"
    install -d "${d}/files/etc/profile.d"
    cat > "${d}/files/etc/profile.d/gnu.sh" <<'DROPIN'
# GNU coreutils and bash, ahead of the busybox applets of the same
# name (RFC 0040). LOGIN SHELLS ONLY: /etc/profile is not what gives
# an s6 service its PATH, so every service, uevent handler and boot
# script goes on running the applets it was written against.
#
# Delete this file to go back to busybox at a prompt without
# uninstalling anything.
[ -d /usr/gnu/bin ] && export PATH="/usr/gnu/bin:${PATH}"
DROPIN
    chmod 644 "${d}/files/etc/profile.d/gnu.sh"
}

# WHAT GOES IN THE PACKAGE IS DERIVED FROM THE TREE; WHAT MUST BE
# THERE IS A FLOOR. The first version named all 103 programs by hand
# and the check fired on its second run: `chcon` and `runcon` are
# SELinux tools coreutils does not build without libselinux, which
# this system does not have and whose kernel half was never in the
# config either (CLAUDE.md records `CONFIG_SECURITY_SELINUX` claimed
# for a kernel that never had it). A hand-written list drifts from
# what the build produces -- pkgsplit's whole argument -- so the sweep
# takes whatever was built and a short floor asserts that the build
# did not silently lose something a person would reach for first.
stage_one() {
    local name="$1" version="$2" desc="$3" depends="$4" srcdir="$5"
    shift 5
    local d="${STAGE_DIR}/${name}"
    rm -rf "${d}"
    install -d "${d}/files${GNU_PREFIX}/bin" \
               "${d}/files/usr/share/licenses/${name}"
    local missing=""
    local prog
    for prog in "$@"; do
        [ -f "${PREFIX}${GNU_PREFIX}/bin/${prog}" ] || missing="${missing} ${prog}"
    done
    if [ -n "${missing}" ]; then
        echo "ERROR: ${name}: the build did not produce:${missing}" >&2
        echo "       These are the floor -- a package claiming to be" >&2
        echo "       ${name} without them is a package that installs" >&2
        echo "       and then cannot do the first thing asked of it." >&2
        exit 1
    fi
    local hits=0 f
    for f in "${PREFIX}${GNU_PREFIX}/bin"/*; do
        [ -f "${f}" ] || continue
        case "${name}:$(basename "${f}")" in
            # bash's tree also holds bashbug, a shell script that mails
            # a bug report through a `sendmail` this system does not
            # have. A command that cannot work is worse than one that
            # is absent (RFC 0026's argument for deleting `idle3`).
            bash:bash) ;;
            bash:*) continue ;;
            coreutils:bash|coreutils:bashbug) continue ;;
        esac
        cp -a "${f}" "${d}/files${GNU_PREFIX}/bin/"
        hits=$((hits + 1))
    done
    [ "${hits}" -gt 0 ] || {
        echo "ERROR: ${name}: nothing was copied into the package." >&2
        exit 1
    }
    # THE MAN PAGES SHIP NOW (RFC 0040 roadmap 2). They were built all
    # along -- 102 of them, 916 KB -- and thrown away, because the only
    # `man` on the machine was busybox's applet, which shells out to
    # `nroff` and `col` and could never display a page. `man` is a
    # package now, so the pages have a reader and this is the other
    # half of that item.
    #
    # Not gzipped: mandoc reads both, the saving is under 600 KB, and a
    # plain file is one a person can `cat`.
    if [ -d "${PREFIX}${GNU_PREFIX}/share/man" ]; then
        install -d "${d}/files${GNU_PREFIX}/share/man"
        local sect page base
        for sect in "${PREFIX}${GNU_PREFIX}/share/man"/man*; do
            [ -d "${sect}" ] || continue
            for page in "${sect}"/*; do
                [ -f "${page}" ] || continue
                base="$(basename "${page}")"
                # Only the pages for programs THIS package ships --
                # the two share a prefix, so a blind copy would put
                # bash's page in coreutils and every coreutils page in
                # bash. Keyed on the file that is actually installed.
                [ -f "${d}/files${GNU_PREFIX}/bin/${base%.*}" ] || continue
                install -d "${d}/files${GNU_PREFIX}/share/man/$(basename "${sect}")"
                cp -a "${page}" \
                   "${d}/files${GNU_PREFIX}/share/man/$(basename "${sect}")/"
            done
        done
    fi

    # A PROGRAM IS NOT ALWAYS ONE FILE, and the floor above checked the
    # wrong thing on its first run. `stdbuf` is a launcher for
    # ${GNU_PREFIX}/libexec/coreutils/libstdbuf.so -- it sets LD_PRELOAD
    # to it -- so packaging ${GNU_PREFIX}/bin alone shipped a `stdbuf`
    # that installed, ran, and answered
    # `stdbuf: failed to find 'libstdbuf.so'`. The floor named `stdbuf`
    # precisely because it was the program most likely to go missing,
    # and then asserted the presence of the half that was there.
    # Watched live on a booted machine, which is the only place it
    # could have shown.
    if [ -d "${PREFIX}${GNU_PREFIX}/libexec/${name}" ]; then
        install -d "${d}/files${GNU_PREFIX}/libexec/${name}"
        cp -a "${PREFIX}${GNU_PREFIX}/libexec/${name}"/. \
              "${d}/files${GNU_PREFIX}/libexec/${name}/"
    fi
    find "${d}/files" -type f -perm -u+x -exec "${CROSS}-strip" --strip-unneeded {} + 2>/dev/null || true
    # GPL-3.0-or-later, both of them. The licence travels with the
    # thing -- RFC 0031's rule about the OFL fonts, RFC 0026's about
    # readline.
    local lic="${srcdir}/COPYING"
    [ -f "${lic}" ] || {
        echo "ERROR: ${name}: no COPYING at ${lic} to ship with the package." >&2
        exit 1
    }
    install -m 644 "${lic}" "${d}/files/usr/share/licenses/${name}/COPYING"
    {
        echo "name=${name}"
        echo "version=${version}"
        echo "arch=${TARGET_ARCH}"
        [ -n "${depends}" ] && echo "depends=${depends}"
        echo "description=${desc}"
    } > "${d}/MANIFEST"
    echo "   staged ${name}: ${hits} program(s), $(du -sh "${d}/files" | cut -f1)"
}

# The half `stdbuf` needs, asserted in the STAGED PACKAGE rather than
# in the build tree -- the question is what a machine installing this
# will have, not what the build produced.
stage_one_and_check_libstdbuf() {
    stage_one "$@"
    local so="${STAGE_DIR}/coreutils/files${GNU_PREFIX}/libexec/coreutils/libstdbuf.so"
    [ -f "${so}" ] || {
        echo "ERROR: coreutils: ${so#"${STAGE_DIR}/coreutils/files"} is not in the package." >&2
        echo "       \`stdbuf\` is a launcher for that library and answers" >&2
        echo "       \"failed to find 'libstdbuf.so'\" without it." >&2
        exit 1
    }
}

package() {
    echo ">>> Staging packages into ${STAGE_DIR}"
    mkdir -p "${STAGE_DIR}"

    [ -x "${PREFIX}${GNU_PREFIX}/bin/bash" ] || {
        echo "ERROR: no bash in ${PREFIX}${GNU_PREFIX}/bin -- run '$0 bash' first." >&2
        exit 1
    }
    [ -x "${PREFIX}${GNU_PREFIX}/bin/ls" ] || {
        echo "ERROR: no coreutils in ${PREFIX}${GNU_PREFIX}/bin -- run '$0 coreutils' first." >&2
        exit 1
    }

    # The floor: the programs whose absence would make the package a
    # lie, plus `stdbuf`, which is the one that needed a build fix and
    # so is the one most likely to go missing again.
    # (`sed`, `grep` and `awk` are deliberately NOT here: they are
    # their own GNU packages, and naming one in a floor for this one
    # would be a check that could never pass.)
    local FLOOR="ls cp mv rm mkdir cat head tail sort uniq wc cut tr
        date du df stat ln readlink realpath install printf echo test true
        false sha256sum md5sum base64 seq shuf nproc timeout stdbuf"
    # shellcheck disable=SC2086
    stage_one_and_check_libstdbuf coreutils "${COREUTILS_VERSION}" \
        "GNU coreutils -- the full versions of the file, shell and text utilities BusyBox ships a subset of. Installs under /usr/gnu/bin and goes ahead of the applets on a login shell's PATH; the base image is untouched" \
        "" "${WORK}/coreutils-${COREUTILS_VERSION}" ${FLOOR}
    write_profile_drop_in "${STAGE_DIR}/coreutils"

    stage_one bash "${GNU_BASH_VERSION}" \
        "GNU bash -- arrays, [[ ]], process substitution, programmable completion. /bin/sh stays BusyBox ash: declare users.<name>.shell = /usr/gnu/bin/bash to log in with it" \
        "readline,ncurses" "${WORK}/bash-${GNU_BASH_VERSION}" bash

    echo ""
    echo "Publish them with:  bash build/53-devtools-repo.sh"
}

case "${PHASE}" in
    bash)      build_bash ;;
    coreutils) build_coreutils ;;
    package)   package ;;
    all)       build_bash; build_coreutils; package ;;
    *)
        echo "usage: $0 [bash|coreutils|package|all]" >&2
        exit 2 ;;
esac
