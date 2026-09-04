#!/bin/bash
# ============================================================
# 28-native-toolchain.sh — make Novi able to build its own software
#
# RFC 0015. Every binary on this system exists because it was
# cross-compiled somewhere else. That is how a distro starts and it is
# not where one can stay: it means the only machine that can add
# software to Novi is a machine that is not running Novi, and it means
# nobody can contribute without reproducing this entire build tree
# first.
#
# So: a NATIVE toolchain, built with the cross toolchain from
# 02-toolchain.sh, in four packages.
#
#   musl-dev   headers, libc.a and the crt objects. Without these a
#              compiler on the target can parse C and cannot link it.
#   binutils   as, ld, ar -- what gcc actually shells out to.
#   gcc        the compiler itself, C and C++.
#   make       because BusyBox has no make applet, and a compiler that
#              cannot follow a Makefile cannot build anything real.
#
# Packages, never the base image: this is ~150 MB of software that a
# console system has no use for. It lands in the repository (RFC 0006)
# alongside the desktop, so `pkg install gcc` is how you get it.
#
# The builds below are "cross-native": --build is this host, and both
# --host and --target are the Novi triple. That is a different and
# fussier thing than the cross-compiler in 02-toolchain.sh, which is
# --host=this-machine --target=novi. The distinction is the whole
# reason this stage exists: a cross-compiler RUNS here and PRODUCES
# Novi binaries; this one RUNS on Novi.
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/00-versions.sh"

CROSS="${TOOLS}/bin/${TARGET_TRIPLE}"
[ -x "${CROSS}-gcc" ] || { echo "ERROR: ${CROSS}-gcc not found -- run build/02-toolchain.sh." >&2; exit 1; }

BUILD_TRIPLE="$(gcc -dumpmachine)"
WORK="${BUILD_DIR}/native-toolchain"
STAGE_DIR="${BUILD_DIR}/stage-toolchain"
JOBS="$(nproc)"

ONLY="${1:-all}"

export PATH="${TOOLS}/bin:${PATH}"

# stage_pkg <name> <version> <depends> <description>
# Creates STAGE_DIR/<name>/{MANIFEST,files} and echoes the files dir.
stage_pkg() {
    local name="$1" version="$2" depends="$3" desc="$4" d="${STAGE_DIR}/$1"
    rm -rf "$d"; mkdir -p "$d/files"
    {
        echo "name=${name}"
        echo "version=${version}"
        echo "arch=${TARGET_ARCH}"
        echo "depends=${depends}"
        echo "description=${desc}"
    } > "$d/MANIFEST"
    printf '%s\n' "$d/files"
}

mkdir -p "${WORK}" "${STAGE_DIR}"

# ── musl-dev: headers, libc.a, crt objects ────────────────────────────────
#
# No build at all -- 02-toolchain.sh already produced every one of
# these into the sysroot; they have simply never been copied onto the
# target, because until now nothing on the target could have used
# them. The shared libc that programs LINK AGAINST at runtime is
# already in the base image; what is missing is everything you need to
# link something new: the headers, the static archive, and crt1.o /
# crti.o / crtn.o, which is what "compiler cannot create executables"
# actually means when a from-scratch toolchain says it.
if [ "$ONLY" = "all" ] || [ "$ONLY" = "musl-dev" ]; then
    echo ">>> Staging musl-dev ${MUSL_VERSION} ..."
    files="$(stage_pkg musl-dev "${MUSL_VERSION}" "" "musl libc headers, static library and startup objects")"
    mkdir -p "${files}/usr/include" "${files}/usr/lib"
    cp -a "${SYSROOT}/usr/include/." "${files}/usr/include/"
    for f in libc.a crt1.o crti.o crtn.o Scrt1.o rcrt1.o libm.a libpthread.a librt.a libdl.a libcrypt.a libutil.a libxnet.a libresolv.a; do
        [ -f "${SYSROOT}/usr/lib/${f}" ] && cp -a "${SYSROOT}/usr/lib/${f}" "${files}/usr/lib/" || true
    done
    # libc.so is a linker script on musl; the real shared object is
    # already in the base image as /lib/libc.musl-x86_64.so.1.
    [ -f "${SYSROOT}/usr/lib/libc.so" ] && cp -a "${SYSROOT}/usr/lib/libc.so" "${files}/usr/lib/" || true
    echo "    $(find "${files}" -type f | wc -l) files"
fi

# ── make ──────────────────────────────────────────────────────────────────
if [ "$ONLY" = "all" ] || [ "$ONLY" = "make" ]; then
    echo ">>> Building GNU make ${MAKE_VERSION} ..."
    rm -rf "${WORK}/make-${MAKE_VERSION}"
    tar -xf "${SOURCES}/make-${MAKE_VERSION}.tar.gz" -C "${WORK}"
    (
        cd "${WORK}/make-${MAKE_VERSION}"
        ./configure --build="${BUILD_TRIPLE}" --host="${TARGET_TRIPLE}" \
            --prefix=/usr --without-guile >/dev/null
        make -j"${JOBS}" >/dev/null
    )
    files="$(stage_pkg make "${MAKE_VERSION}" "musl-dev" "GNU make")"
    make -C "${WORK}/make-${MAKE_VERSION}" DESTDIR="${files}" install >/dev/null
    rm -rf "${files}/usr/share/info" "${files}/usr/share/man" "${files}/usr/share/locale"
    "${CROSS}-strip" "${files}/usr/bin/make" 2>/dev/null || true
    echo "    $(du -sh "${files}" | cut -f1)"
fi

# ── binutils (native) ─────────────────────────────────────────────────────
if [ "$ONLY" = "all" ] || [ "$ONLY" = "binutils" ]; then
    echo ">>> Building native binutils ${BINUTILS_VERSION} (this takes a while) ..."
    rm -rf "${WORK}/binutils-${BINUTILS_VERSION}" "${WORK}/build-binutils"
    tar -xf "${SOURCES}/binutils-${BINUTILS_VERSION}.tar.xz" -C "${WORK}"
    mkdir -p "${WORK}/build-binutils"
    (
        cd "${WORK}/build-binutils"
        # --with-sysroot=/ : the on-target ld must look in the real
        # root, not in this build host's sysroot path, which will not
        # exist on the machine running it.
        #
        # --disable-gprofng, named rather than worked around: gprofng
        # calls fopen64/fseeko64/ftello64, and musl 1.2.4 removed the
        # LFS64 aliases (every off_t is already 64-bit there, so the
        # separate names had no reason to exist). It is a profiler, and
        # this is the same breakage e2fsprogs needed a patch for in RFC
        # 0008 -- patching a profiler nobody has asked for, to ship it
        # in a compiler package, is work for its own sake.
        "../binutils-${BINUTILS_VERSION}/configure" \
            --build="${BUILD_TRIPLE}" --host="${TARGET_TRIPLE}" --target="${TARGET_TRIPLE}" \
            --prefix=/usr --with-sysroot=/ \
            --disable-nls --disable-multilib --disable-werror \
            --enable-deterministic-archives --disable-gdb --disable-gdbserver \
            --disable-gprofng >/dev/null
        make -j"${JOBS}" >/dev/null
    )
    files="$(stage_pkg binutils "${BINUTILS_VERSION}" "musl-dev" "GNU assembler, linker and binary utilities")"
    make -C "${WORK}/build-binutils" DESTDIR="${files}" install >/dev/null
    rm -rf "${files}/usr/share/info" "${files}/usr/share/man" "${files}/usr/share/locale" "${files}/usr/share/doc"
    find "${files}" -type f -perm -u+x -exec "${CROSS}-strip" --strip-unneeded {} \; 2>/dev/null || true
    echo "    $(du -sh "${files}" | cut -f1)"
fi

# ── gcc (native) ──────────────────────────────────────────────────────────
#
# The long pole, and the fussy one. Three things make a cross-native
# gcc different from the cross-compiler 02-toolchain.sh already built:
#
#  - --with-sysroot=/ is what gets BAKED IN, because on the machine
#    that runs this compiler the root filesystem is the sysroot.
#    --with-build-sysroot points at where those same headers and libs
#    live *here*, so the build can find them without writing this
#    host's paths into the installed compiler.
#  - --disable-bootstrap. A bootstrap builds the compiler three times
#    to check it can compile itself, which requires RUNNING it -- and
#    these binaries do not run on this machine.
#  - The libraries gcc needs (GMP, MPFR, MPC) have to exist for the
#    TARGET. GCC's own in-tree build handles that when their sources
#    are unpacked inside the gcc tree, which is what download_prerequisites
#    does; 02-toolchain.sh already relies on the same mechanism.
#
# libsanitizer is disabled: it does not build against musl without
# patches, it is the single largest component here, and nothing in this
# distro uses it yet. Named rather than silently dropped.
if [ "$ONLY" = "all" ] || [ "$ONLY" = "gcc" ]; then
    echo ">>> Building native gcc ${GCC_VERSION} (this takes a long while) ..."
    rm -rf "${WORK}/gcc-${GCC_VERSION}" "${WORK}/build-gcc"
    tar -xf "${SOURCES}/gcc-${GCC_VERSION}.tar.xz" -C "${WORK}"
    (
        cd "${WORK}/gcc-${GCC_VERSION}"
        [ -d gmp ] || ./contrib/download_prerequisites >/dev/null 2>&1 || true
    )
    mkdir -p "${WORK}/build-gcc"
    (
        cd "${WORK}/build-gcc"
        "../gcc-${GCC_VERSION}/configure" \
            --build="${BUILD_TRIPLE}" --host="${TARGET_TRIPLE}" --target="${TARGET_TRIPLE}" \
            --prefix=/usr \
            --with-sysroot=/ --with-build-sysroot="${SYSROOT}" \
            --enable-languages=c,c++ \
            --disable-bootstrap --disable-multilib --disable-nls \
            --disable-libsanitizer --disable-libssp --disable-libmudflap \
            --disable-werror --enable-default-pie --enable-default-ssp \
            --with-native-system-header-dir=/usr/include >/dev/null
        make -j"${JOBS}" >/dev/null
    )
    files="$(stage_pkg gcc "${GCC_VERSION}" "musl-dev,binutils" "GNU Compiler Collection (C and C++)")"
    make -C "${WORK}/build-gcc" DESTDIR="${files}" install >/dev/null
    rm -rf "${files}/usr/share/info" "${files}/usr/share/man" "${files}/usr/share/locale" "${files}/usr/share/doc"
    # GCC installs its runtime libraries to /usr/lib64 on x86_64, from
    # a multilib convention this target does not have: musl's dynamic
    # linker searches /lib:/usr/local/lib:/usr/lib and nothing else, so
    # libstdc++.so.6 and libgcc_s.so.1 shipped in a directory nothing
    # would ever look in. C compiled and ran; C++ compiled, linked, and
    # died at exec with "Error loading shared library libstdc++.so.6".
    # One directory, and only the second language noticed.
    if [ -d "${files}/usr/lib64" ]; then
        mkdir -p "${files}/usr/lib"
        cp -a "${files}/usr/lib64/." "${files}/usr/lib/"
        rm -rf "${files}/usr/lib64"
    fi

    # cc is what a great deal of software actually invokes.
    ln -sf gcc "${files}/usr/bin/cc"
    # Strip EVERY ELF, not just /usr/bin. The compiler proper is not in
    # /usr/bin -- cc1, cc1plus and lto1 live in libexec and are 340 MB
    # each with debug symbols attached, which is 1.0 GB of the 1.2 GB
    # this package would otherwise be. Debug symbols for the compiler
    # are of use to people debugging the compiler.
    find "${files}" -type f \( -perm -u+x -o -name '*.so*' -o -name '*.a' \) \
        -exec "${CROSS}-strip" --strip-unneeded {} \; 2>/dev/null || true
    echo "    $(du -sh "${files}" | cut -f1)"
fi

# ── Into the repository ───────────────────────────────────────────────────
#
# 20-repo.sh builds packages by running pkgsplit over the rootfs, which
# is the right tool for the desktop split and the wrong one here: none
# of this is IN the rootfs, and none of it should be. So these are
# packaged directly and the index is re-signed over the whole
# directory. mkrepo indexes whatever it finds, so adding to an existing
# repository is just running it again -- with the same key, so the
# public half already in the image stays valid.
if [ "$ONLY" = "all" ] || [ "$ONLY" = "repo" ]; then
    REPO_OUT="${BUILD_DIR}/repo"
    KEY_FILE="${BUILD_DIR}/keys/novi-repo.key"
    [ -d "${REPO_OUT}" ] || { echo "ERROR: ${REPO_OUT} not found -- run build/20-repo.sh first." >&2; exit 1; }
    [ -f "${KEY_FILE}" ] || { echo "ERROR: signing key ${KEY_FILE} not found." >&2; exit 1; }

    echo ">>> Packaging the toolchain into ${REPO_OUT} ..."
    for d in "${STAGE_DIR}"/*/; do
        [ -f "${d}/MANIFEST" ] || continue
        bash "${REPO_ROOT}/packages/mkpkg" "${d}" "${REPO_OUT}" >/dev/null
        echo "    $(basename "${d}")"
    done

    echo ">>> Re-indexing and re-signing ..."
    sh "${REPO_ROOT}/packages/mkrepo" "${REPO_OUT}" --key "${KEY_FILE}"

    # A meta-package, the same shape as novi-desktop: one name that
    # pulls the whole thing in, so "make this machine able to build
    # software" is one command rather than four.
    files="$(stage_pkg novi-devel "${GCC_VERSION}" "musl-dev,binutils,gcc,make" "Everything needed to build software on Novi itself")"
    mkdir -p "${files}/usr/share/doc/novi-devel"
    cat > "${files}/usr/share/doc/novi-devel/README" <<'DOC'
novi-devel — Novi can build its own software.

  gcc / cc     C and C++ compiler
  as, ld, ar   assembler, linker, archiver (binutils)
  make         GNU make
  /usr/include musl and Linux headers, libc.a, crt objects

Everything here was cross-compiled once, by build/28-native-toolchain.sh,
so that nothing after it has to be.
DOC
    bash "${REPO_ROOT}/packages/mkpkg" "${STAGE_DIR}/novi-devel" "${REPO_OUT}" >/dev/null
    sh "${REPO_ROOT}/packages/mkrepo" "${REPO_OUT}" --key "${KEY_FILE}"
    echo "    novi-devel"
fi

echo ">>> Staged under ${STAGE_DIR}"
ls -1 "${STAGE_DIR}"
