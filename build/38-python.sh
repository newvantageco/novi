#!/bin/bash
# ============================================================
# 38-python.sh — CPython, as a package
#
# Until this stage there was NO SCRIPTING LANGUAGE ON THIS SYSTEM. Not
# a slow one, not an old one -- none. No Python, no Perl, no Ruby.
# Every program in the image is C or a BusyBox ash script, and every
# tool anyone might want to bring here that is not written in C could
# not run at all, in principle.
#
# That is the same shape of gap RFC 0025 found in front of OpenGL, and
# it is bigger: the overwhelming majority of security, networking and
# automation tooling that exists is Python, and so is most of what a
# person writes for themselves on a machine they control.
#
#   bash build/38-python.sh
#
# A PACKAGE, NEVER THE BASE IMAGE. ~50 MB installed. RFC 0007 keeps
# the base console-only and small; a language runtime is exactly the
# kind of thing that belongs behind `pkg install`. It stages into
# ${BUILD_DIR}/stage-devtools alongside git and the ssh client, so
# 43-devtools-repo.sh publishes it with no change to that stage --
# its repo phase globs every directory there that has a MANIFEST.
#
# WHY THE STAGE NUMBER IS 38: 40+ is packaging, and 40-repo.sh must
# see a finished tree. This builds nothing into ${ROOTFS} at all, but
# it does READ from it (zlib, libffi, expat), so it has to run while
# those are still there -- i.e. before 41-desktop-split.sh takes them
# out.
#
# ── The thing to know before reading further: there is no ssl. ────────
#
# CPython's `_ssl` and `_hashlib` modules are written against OpenSSL
# specifically, and this project has refused to carry OpenSSL since
# RFC 0006 (novi-verify exists, all ~10 KB of it, so that checking a
# package signature does not mean linking libcrypto). RFC 0020 chose
# mbedTLS for curl and RFC 0021 chose wolfSSL for wpa_supplicant;
# CPython can use neither. So:
#
#   import ssl          -> ModuleNotFoundError
#   urllib.request.urlopen("https://...")  -> fails
#
# `hashlib` still works -- md5, sha1, sha2, sha3 and blake2 are
# ordinary built-in C modules in CPython and owe OpenSSL nothing; only
# the `_hashlib` accelerator and `pbkdf2_hmac`/`scrypt` are lost.
# HTTPS from a Python program on this system means `curl`, which is
# already a package and already verifies certificates properly.
#
# This is stated here, in the RFC, and in the package description
# rather than left to be discovered, because a Python that cannot
# reach an https:// URL is a Python that fails at the first line of
# most of the programs somebody would install it for.
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-versions.sh"

CROSS="${TOOLS}/bin/${TARGET_TRIPLE}"
[ -x "${CROSS}-gcc" ] || { echo "ERROR: ${CROSS}-gcc not found -- run build/02-toolchain.sh." >&2; exit 1; }

WORK="${BUILD_DIR}/python-build"
STAGE_DIR="${BUILD_DIR}/stage-devtools"
SRC="${WORK}/Python-${PYTHON_VERSION}"
JOBS="$(nproc)"

# The version this python's own module directory is named after, and
# the name of the host interpreter that has to exist. Derived, never
# written twice: PYTHON_VERSION is the only place a version appears.
PY_XY="${PYTHON_VERSION%.*}"

# ── The build host needs an interpreter of the SAME major.minor ───────
#
# Cross-compiling CPython is not like cross-compiling a C program. The
# build runs Python during `make`: it freezes the importlib bootstrap,
# generates several C files, runs setup.py to decide which extension
# modules can be built, and byte-compiles the whole standard library
# into __pycache__. None of that can run on the target, so configure
# takes --with-build-python and refuses anything but an exact
# major.minor match -- a 3.12 host cannot build a 3.11 target, because
# the .pyc magic number and the marshal format differ.
#
# Checked up front with a message that says what to install, for the
# same reason 05-kernel.sh checks for depmod and 06-wayland.sh checks
# for mako: an unmet build-host dependency should not surface three
# minutes in as an autoconf line nobody can interpret.
BUILD_PYTHON="$(command -v "python${PY_XY}" || true)"
if [ -z "${BUILD_PYTHON}" ]; then
    echo "ERROR: python${PY_XY} not found on the build host." >&2
    echo "" >&2
    echo "  Cross-compiling CPython ${PYTHON_VERSION} needs an interpreter of" >&2
    echo "  the same major.minor to run during the build (it freezes" >&2
    echo "  modules and byte-compiles the standard library)." >&2
    echo "" >&2
    echo "      apt-get install python${PY_XY}" >&2
    echo "" >&2
    exit 1
fi

# ── zlib, libffi and expat come out of ${ROOTFS} ──────────────────────
#
# All three are packages, so 41-desktop-split.sh moves them out and in
# any tree where a full build has run this stage would otherwise stop
# on "zlib.h: No such file or directory" with no clue what to do.
# Same guard, same wording, as 35-devtools.sh's require_zlib().
require_lib() {
    local header="$1" lib="$2" what="$3"
    if [ -f "${ROOTFS}/usr/include/${header}" ] && [ -e "${ROOTFS}/usr/lib/${lib}" ]; then
        return 0
    fi
    echo "ERROR: ${what} is not in ${ROOTFS} (header or library missing)." >&2
    echo "" >&2
    echo "  41-desktop-split.sh has moved it out -- it is a package." >&2
    echo "  Put it back before building against it:" >&2
    echo "" >&2
    echo "      bash scripts/restore-build-inputs.sh" >&2
    echo "" >&2
    echo "  Then re-run this stage, and re-run 40-repo.sh," >&2
    echo "  41-desktop-split.sh and the 42/43 publish stages." >&2
    exit 1
}
require_lib zlib.h   libz.so     "zlib"
require_lib ffi.h    libffi.so   "libffi"
require_lib expat.h  libexpat.so "expat"

rm -rf "${WORK}"
mkdir -p "${WORK}" "${STAGE_DIR}"
echo ">>> Unpacking CPython ${PYTHON_VERSION} ..."
tar xf "${SOURCES}/Python-${PYTHON_VERSION}.tar.xz" -C "${WORK}"

# harden_flags is deliberately NOT called here.
#
# Every other stage that builds a first-party binary calls it, and
# scripts/check-hardening.sh enforces the result. This one cannot: the
# flags it exports include -fPIE and -pie, and CPython builds ~40
# extension modules as SHARED OBJECTS from the same CFLAGS. -pie on a
# link that is producing a .so is a contradiction, and -fPIE (as
# opposed to -fPIC) is wrong for shared code. CPython's own configure
# already computes the right per-object flags -- CCSHARED=-fPIC for
# extensions, and it links the interpreter with -pie of its own accord
# when it can.
#
# The interpreter is checked afterwards for exactly the properties
# harden_flags exists to produce, rather than trusted; see the end of
# this file.
export CFLAGS="-O2 -fstack-protector-strong -D_FORTIFY_SOURCE=2"
export CPPFLAGS="-I${ROOTFS}/usr/include"
export LDFLAGS="-L${ROOTFS}/usr/lib -Wl,-z,relro,-z,now -Wl,-z,noexecstack -Wl,-rpath-link,${ROOTFS}/usr/lib"

# -pie is deliberately NOT in LDFLAGS, and there is no variable it
# could go in. Read Makefile.pre.in: LDSHARED and BLDSHARED -- the
# commands that link libpython and all ~40 extension modules -- both
# append $(PY_CORE_LDFLAGS), which is CONFIGURE_LDFLAGS plus
# LDFLAGS_NODIST. So EVERY LDFLAGS-shaped variable reaches a `-shared`
# link, and gcc given `-shared -pie` does not warn: it silently drops
# the -shared and tries to link an EXECUTABLE, which fails with
# "undefined reference to `main'" out of Scrt1.o. Verified with this
# toolchain rather than assumed.
#
# LINKFORSHARED is the one variable used ONLY on the two executable
# links (Makefile.pre.in lines 712 and 972, `python` and
# `_testembed`), so that is where -pie goes. Its configure-chosen
# value on Linux is "-Xlinker -export-dynamic" and it must be carried
# through, not replaced -- dropping it would leave C extensions unable
# to resolve symbols back into the interpreter.
LINKFORSHARED="-Xlinker -export-dynamic -pie"

echo ">>> Configuring ..."
(
    cd "${SRC}"
    # Autoconf tests it cannot run, answered by hand:
    #
    #   ac_cv_file__dev_ptmx  the kernel sets CONFIG_UNIX98_PTYS, so
    #                         /dev/ptmx exists on the target. Answering
    #                         "no" silently disables openpty(), and with
    #                         it the pty module and everything that
    #                         drives a subprocess through a terminal.
    #   ac_cv_file__dev_ptc   an AIX device. Not here.
    #   ac_cv_buggy_getaddrinfo
    #                         the test COMPILES AND RUNS a program to
    #                         see whether the libc resolves "localhost"
    #                         wrongly. musl does not; a cross build
    #                         cannot find out, and the default when it
    #                         cannot is to assume the worst and disable
    #                         the socket module's getaddrinfo entirely.
    #
    # --disable-test-modules drops Lib/test, ~25 MB of the standard
    # library that exists to test CPython itself. --without-ensurepip
    # because there is no pip: pip fetches over https, which this build
    # has none of (see the header), so shipping it would be shipping a
    # tool that cannot do its one job.
    ./configure \
        --build="$(gcc -dumpmachine)" \
        --host="${TARGET_TRIPLE}" \
        --prefix=/usr \
        --with-build-python="${BUILD_PYTHON}" \
        --with-system-ffi \
        --with-system-expat \
        --with-ensurepip=no \
        --disable-test-modules \
        --enable-shared \
        --without-static-libpython \
        ac_cv_file__dev_ptmx=yes \
        ac_cv_file__dev_ptc=no \
        ac_cv_buggy_getaddrinfo=no >"${WORK}/configure.log" 2>&1 \
        || { tail -40 "${WORK}/configure.log" >&2; exit 1; }
)

echo ">>> Building (this takes a few minutes) ..."
make -C "${SRC}" -j"${JOBS}" LINKFORSHARED="${LINKFORSHARED}" \
    >"${WORK}/build.log" 2>&1 \
    || { tail -60 "${WORK}/build.log" >&2; exit 1; }

# ── Which modules did NOT get built, and is that the expected set? ────
#
# CPython does not fail a build over a module it could not build; it
# prints a paragraph and carries on. That is the correct behaviour for
# a language that runs on everything, and it is exactly the failure
# shape this repository keeps getting caught by: the build succeeds,
# the artifact is missing something, and nothing says so at a moment
# anyone is reading. `import ssl` failing on the target is a five-line
# fix here and an afternoon there.
#
# So the set of missing modules is compared against the set this build
# EXPECTS to be missing, and anything else is printed loudly. It is not
# a hard failure -- CPython's module list shifts between point releases
# and a build that stops because `_dbm` moved would be worse than one
# that says so.
EXPECTED_MISSING="_ssl _hashlib _sqlite3 _bz2 _lzma _curses _curses_panel _tkinter _gdbm _dbm _uuid readline nis ossaudiodev spwd _crypt"
# The block ends with a sentence, not a blank line -- "To find the
# necessary bits, look in setup.py ..." -- and ranging to /^$/ swallows
# it, so every word of that sentence came back as an unexpected missing
# module. Range to the sentence and drop both bounds.
MISSING="$(sed -n '/The necessary bits to build these optional modules were not found/,/^To find the necessary bits/p' \
    "${WORK}/build.log" | sed '1d;$d' | tr -s ' \n' '\n' | grep -v '^$' || true)"
UNEXPECTED=""
for m in ${MISSING}; do
    case " ${EXPECTED_MISSING} " in
        *" ${m} "*) ;;
        *) UNEXPECTED="${UNEXPECTED} ${m}" ;;
    esac
done
if [ -n "${UNEXPECTED}" ]; then
    echo ""
    echo "WARNING: extension modules missing that this build did not expect:"
    echo "        ${UNEXPECTED}"
    echo "        (grep 'optional modules' ${WORK}/build.log for the whole list)"
    echo ""
fi

# ── Stage ─────────────────────────────────────────────────────────────
D="${STAGE_DIR}/python"
rm -rf "${D}"; mkdir -p "${D}/files"
echo ">>> Installing into the staging tree ..."
# `altinstall` deliberately, then the unversioned names by hand.
# `make install` also writes /usr/bin/python3 and /usr/bin/python; the
# first is wanted, the second is not -- `python` meaning python3 is a
# convention some distributions adopted and some refused, and a
# script whose shebang says `python` should say what it means.
make -C "${SRC}" DESTDIR="${D}/files" LINKFORSHARED="${LINKFORSHARED}" \
    altinstall >"${WORK}/install.log" 2>&1 \
    || { tail -40 "${WORK}/install.log" >&2; exit 1; }

ln -sf "python${PY_XY}"        "${D}/files/usr/bin/python3"
ln -sf "python${PY_XY}-config" "${D}/files/usr/bin/python3-config"
ln -sf "pydoc${PY_XY}"         "${D}/files/usr/bin/pydoc3"
ln -sf "idle${PY_XY}"          "${D}/files/usr/bin/idle3" 2>/dev/null || true
# idle needs tkinter, which is not built. Do not ship a command that
# cannot start.
rm -f "${D}/files/usr/bin/idle3" "${D}/files/usr/bin/idle${PY_XY}"

"${CROSS}-strip" --strip-unneeded "${D}/files/usr/bin/python${PY_XY}" 2>/dev/null || true
find "${D}/files/usr/lib/python${PY_XY}/lib-dynload" -name '*.so' \
    -exec "${CROSS}-strip" --strip-unneeded {} + 2>/dev/null || true
find "${D}/files/usr/lib" -maxdepth 1 -name 'libpython*.so*' -type f \
    -exec "${CROSS}-strip" --strip-unneeded {} + 2>/dev/null || true

# Nothing here can use these: there is no compiler in this package (that
# is `novi-devel`, RFC 0015) and no pip. The static library alone is
# 30-odd MB.
rm -f "${D}/files/usr/lib/libpython${PY_XY}.a"
rm -rf "${D}/files/usr/lib/python${PY_XY}/test" \
       "${D}/files/usr/lib/python${PY_XY}/idlelib" \
       "${D}/files/usr/lib/python${PY_XY}/tkinter" \
       "${D}/files/usr/lib/python${PY_XY}/turtledemo"

{
    echo "name=python"
    echo "version=${PYTHON_VERSION}"
    echo "arch=${TARGET_ARCH}"
    echo "depends=zlib,libffi,expat"
    echo "description=CPython ${PYTHON_VERSION} -- no ssl module (this system carries no OpenSSL); use curl for https"
} > "${D}/MANIFEST"

# ── Check the artifact, not the flags ─────────────────────────────────
#
# harden_flags() was not used (see above), so the one thing it is for is
# verified directly on the interpreter: a PIE, so the kernel's
# RANDOMIZE_BASE has something to randomise. Every binary in this image
# was type=EXEC once, under a kernel configured to protect them.
TYPE="$("${CROSS}-readelf" -h "${D}/files/usr/bin/python${PY_XY}" | sed -n 's/^ *Type: *\([A-Z]*\).*/\1/p')"
if [ "${TYPE}" != "DYN" ]; then
    echo "ERROR: /usr/bin/python${PY_XY} is ${TYPE}, not a PIE (DYN)." >&2
    echo "       The kernel sets RANDOMIZE_BASE; a type=EXEC binary is not" >&2
    echo "       covered by it. See CLAUDE.md, 'the kernel was hardened and" >&2
    echo "       the userland was not'." >&2
    exit 1
fi

echo ""
echo ">>> Staged under ${D}"
echo "    interpreter : $(du -h "${D}/files/usr/bin/python${PY_XY}" | cut -f1)"
echo "    total       : $(du -sh "${D}/files" | cut -f1)"
echo "    modules     : $(find "${D}/files/usr/lib/python${PY_XY}/lib-dynload" -name '*.so' | wc -l) extension modules"
if [ -n "${MISSING}" ]; then
    echo "    not built   : $(printf '%s' "${MISSING}" | tr '\n' ' ')"
fi
echo ""
echo "Publish it with:  bash build/43-devtools-repo.sh"
