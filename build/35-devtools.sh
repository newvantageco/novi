#!/bin/bash
# ============================================================
# 35-devtools.sh — git and an ssh client, as packages
#
# RFC 0019. RFC 0015 put gcc, binutils, make and the musl headers on a
# running Novi and stopped one step short of usefulness: there is no
# way to GET source onto the machine. The honest description of a Novi
# developer box today is "you can compile what is already on the disk",
# and the only thing on the disk is Novi.
#
# NEITHER GOES IN THE BASE IMAGE. Same rule as the toolchain: built
# once here, staged, and published into the signed repository by
# 43-devtools-repo.sh -- because 40-repo.sh wipes and recreates the
# repository, so anything that adds to it has to run after, and this
# build has to run long before.
#
#   bash build/35-devtools.sh [openssh|git|repo|all]
#
# OPENSSH IS BUILT --without-openssl, and that is the only reason it is
# allowed in this image at all. This project has refused to carry a TLS
# stack since RFC 0006 -- novi-verify exists, all ~10 KB of it, so that
# checking a signature does not mean linking libcrypto -- and RFC 0009
# built wpa_supplicant with CONFIG_TLS=internal for the same reason. An
# ssh client dragging in OpenSSL would undo both.
#
# The cost is real: ed25519 keys ONLY. No RSA, no ECDSA, no
# certificates, no FIDO, no PKCS#11. Ciphers are chacha20-poly1305 and
# the internal AES-CTR set; KEX is curve25519-sha256. That is the right
# trade for a machine created now and a wall in front of an old
# RSA-only server, which is worth saying out loud rather than leaving
# to be discovered.
#
# GIT IS BUILT WITHOUT CURL, which means no `git clone https://`.
# Same argument: curl needs TLS. `git@host:repo` and `ssh://` work,
# and so does everything local. Closing the https gap means picking a
# TLS library, and the honest candidate -- mbedTLS, which RFC 0009
# already named as the way to WPA3 -- would serve WPA3, git and `pkg`
# at once. That is a decision to make once, on its own, not smuggled
# in behind a git package.
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/00-versions.sh"

CROSS="${TOOLS}/bin/${TARGET_TRIPLE}"
[ -x "${CROSS}-gcc" ] || { echo "ERROR: ${CROSS}-gcc not found -- run build/02-toolchain.sh." >&2; exit 1; }

WORK="${BUILD_DIR}/devtools-build"
STAGE_DIR="${BUILD_DIR}/stage-devtools"
JOBS="$(nproc)"
ONLY="${1:-all}"

mkdir -p "${WORK}" "${STAGE_DIR}"

# Both of these link zlib, which lives in the rootfs and which
# 41-desktop-split.sh moves out of it. Same guard as
# require_desktop_headers(), and for the same reason: in any tree where
# a full build has already run, this stage otherwise stops with
# "zlib.h: No such file or directory" and no clue what to do about it.
require_zlib() {
    if [ -f "${ROOTFS}/usr/include/zlib.h" ] && [ -e "${ROOTFS}/usr/lib/libz.so" ]; then
        return 0
    fi
    echo "ERROR: zlib is not in ${ROOTFS} (headers or library missing)." >&2
    echo "" >&2
    echo "  41-desktop-split.sh has moved it out -- zlib is a package." >&2
    echo "  Put it back before building against it:" >&2
    echo "" >&2
    echo "      bash scripts/restore-build-inputs.sh" >&2
    echo "" >&2
    echo "  Then re-run this stage, and re-run 40-repo.sh," >&2
    echo "  41-desktop-split.sh and the 42/43 publish stages." >&2
    exit 1
}

# stage_pkg <name> <version> <depends> <description>
# Identical in shape to 28-native-toolchain.sh's, deliberately: two
# stages that publish packages should describe them the same way.
# `depends` is COMMA-separated -- mkpkg rejects a space (RFC 0015).
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

strip_tree() {
    find "$1" -type f -perm -u+x -exec "${CROSS}-strip" --strip-unneeded {} + 2>/dev/null || true
}

# ── OpenSSH (client only) ─────────────────────────────────────────────
if [ "$ONLY" = "all" ] || [ "$ONLY" = "openssh" ]; then
    require_zlib
    echo ">>> Building OpenSSH ${OPENSSH_VERSION} (no OpenSSL) ..."
    rm -rf "${WORK}/openssh-${OPENSSH_VERSION}"
    tar xf "${SOURCES}/openssh-${OPENSSH_VERSION}.tar.gz" -C "${WORK}"
    (
        cd "${WORK}/openssh-${OPENSSH_VERSION}"
        # --without-zlib-version-check is a CROSS-COMPILE necessity, not
        # a shortcut. OpenSSH's check compiles a program that calls
        # zlibVersion() and RUNS it; cross-compiling, it cannot, so it
        # concludes "zlib too old" about zlib 1.3.1 and tells you to
        # upgrade past 1.2.3. Same shape as skalibs' run-time sysdep
        # checks (see CLAUDE.md): any autoconf test that needs to
        # execute its own output is a wall when the output does not run
        # on this machine.
        ./configure \
            --host="${TARGET_TRIPLE}" \
            --prefix=/usr \
            --sysconfdir=/etc/ssh \
            --without-openssl \
            --without-pam \
            --without-selinux \
            --without-kerberos5 \
            --without-libedit \
            --with-zlib="${ROOTFS}/usr" \
            --without-zlib-version-check \
            --disable-strip \
            --disable-utmp --disable-wtmp --disable-lastlog >/dev/null
        # ssh_config.out is a make target, not a source file: the
        # Makefile substitutes this build's real paths into
        # ssh_config. Naming the binaries individually rather than
        # running `make` keeps sshd, sftp-server and ssh-sk-helper
        # from being built at all -- this package is a client.
        make -j"${JOBS}" ssh scp sftp ssh-add ssh-agent ssh-keygen ssh-keyscan \
            ssh_config.out >/dev/null

        # sshd and sftp-server, BUILT AND NEVER INSTALLED. They are the
        # test peer: a client that has not talked to a server is an
        # assertion, and `git clone ssh://` cannot be verified without
        # something listening. Same bargain 25-wifi.sh makes with
        # hostapd (RFC 0009) -- a test dependency in the shipped image
        # would be a worse trade than an untested feature, so this goes
        # to ${BUILD_DIR}/ssh-test and is delivered to a VM on a
        # separate disk.
        #
        # TWO binaries, not one. OpenSSH 9.8 split the daemon: `sshd`
        # is now only the listener, and it execs `sshd-session` for
        # each connection, from the compiled-in /usr/libexec path.
        # Building `sshd` alone
        # produces a daemon that starts, accepts a connection and dies
        # with "sshd-session does not exist or is not executable".
        make -j"${JOBS}" sshd sshd-session sftp-server \
            sshd_config.out >/dev/null
    )

    mkdir -p "${BUILD_DIR}/ssh-test"
    for b in sshd sshd-session sftp-server; do
        install -m 755 "${WORK}/openssh-${OPENSSH_VERSION}/${b}" \
            "${BUILD_DIR}/ssh-test/${b}"
    done
    install -m 644 "${WORK}/openssh-${OPENSSH_VERSION}/sshd_config.out" \
        "${BUILD_DIR}/ssh-test/sshd_config"
    strip_tree "${BUILD_DIR}/ssh-test"

    files="$(stage_pkg openssh "${OPENSSH_VERSION}" "zlib" \
        "OpenSSH client (ed25519 only -- built without OpenSSL)")"
    mkdir -p "${files}/usr/bin" "${files}/etc/ssh"
    for b in ssh scp sftp ssh-add ssh-agent ssh-keygen ssh-keyscan; do
        install -m 755 "${WORK}/openssh-${OPENSSH_VERSION}/${b}" "${files}/usr/bin/${b}"
    done
    # The generated ssh_config, not the source template: configure
    # substitutes the paths this build actually uses into it.
    install -m 644 "${WORK}/openssh-${OPENSSH_VERSION}/ssh_config.out" \
        "${files}/etc/ssh/ssh_config"
    strip_tree "${files}"

    mkdir -p "${files}/usr/share/doc/openssh"
    cat > "${files}/usr/share/doc/openssh/README" <<'DOC'
openssh — the ssh client, built without OpenSSL.

  ssh-keygen -t ed25519      make a key
  ssh user@host              connect
  scp / sftp                 copy files

ED25519 KEYS ONLY. There is no RSA, no ECDSA, no DSA, no certificate
support, no FIDO tokens and no PKCS#11 here -- all of that lives in
OpenSSL, which this image deliberately does not carry (RFC 0006,
RFC 0009, RFC 0019). Ciphers are chacha20-poly1305 and AES-CTR; key
exchange is curve25519-sha256.

Every forge accepts ed25519. An old server with only an RSA host key
does not, and there is no way around that from here.

There is no sshd in this package: a listening service needs host keys,
a privilege-separation user, an s6 service, a declared state key and a
hole in the firewall. Each of those deserves a deliberate decision.
DOC
    echo "    openssh staged ($(du -sh "${files}" | cut -f1))"
    echo "    test-only (NOT in the image): ${BUILD_DIR}/ssh-test/sshd"
fi

# ── git ───────────────────────────────────────────────────────────────
if [ "$ONLY" = "all" ] || [ "$ONLY" = "git" ]; then
    require_zlib
    echo ">>> Building git ${GIT_VERSION} (no curl, no OpenSSL) ..."
    rm -rf "${WORK}/git-${GIT_VERSION}"
    tar xf "${SOURCES}/git-${GIT_VERSION}.tar.xz" -C "${WORK}"

    files="$(stage_pkg git "${GIT_VERSION}" "openssh,zlib" \
        "Git, over ssh and locally (built without curl)")"

    # Every NO_ here removes a dependency this image does not have,
    # not a feature of git's object model:
    #   NO_OPENSSL   git falls back to its own collision-detecting
    #                SHA-1, which is what upstream uses without it
    #   NO_CURL      no https:// remote helper -- see the header
    #   NO_EXPAT     http-push, which needs curl anyway
    #   NO_PERL      git-send-email, add--interactive, git-svn
    #   NO_PYTHON    git-p4
    #   NO_TCLTK     git gui, gitk
    #   NO_GETTEXT   no message catalogues; git speaks English here
    #   NO_REGEX=NeedsStartEnd
    #                musl's regexec() has no REG_STARTEND -- that is a
    #                BSD extension glibc also carries -- so git uses
    #                its own bundled regex. git's own #error names
    #                this exact flag, which is the kindest possible
    #                way for an upstream to handle a libc difference
    #   NO_INSTALL_HARDLINKS is deliberately NOT set: git installs ~130
    #                names for one binary, and hardlinks are what keep
    #                that from being 130 copies. tar preserves them, so
    #                the package stays small.
    (
        cd "${WORK}/git-${GIT_VERSION}"
        make -j"${JOBS}" \
            CC="${CROSS}-gcc" AR="${CROSS}-ar" \
            CFLAGS="-O2 -I${ROOTFS}/usr/include" \
            LDFLAGS="-L${ROOTFS}/usr/lib" \
            prefix=/usr \
            NO_OPENSSL=1 NO_CURL=1 NO_EXPAT=1 \
            NO_PERL=1 NO_PYTHON=1 NO_TCLTK=1 NO_GETTEXT=1 \
            NO_REGEX=NeedsStartEnd \
            >/dev/null
        make install \
            CC="${CROSS}-gcc" AR="${CROSS}-ar" \
            CFLAGS="-O2 -I${ROOTFS}/usr/include" \
            LDFLAGS="-L${ROOTFS}/usr/lib" \
            prefix=/usr DESTDIR="${files}" \
            NO_OPENSSL=1 NO_CURL=1 NO_EXPAT=1 \
            NO_PERL=1 NO_PYTHON=1 NO_TCLTK=1 NO_GETTEXT=1 \
            NO_REGEX=NeedsStartEnd \
            >/dev/null
    )
    strip_tree "${files}"

    mkdir -p "${files}/usr/share/doc/git"
    cat > "${files}/usr/share/doc/git/README" <<'DOC'
git — over ssh and locally.

  git clone git@host:user/repo.git
  git clone ssh://host/path/to/repo
  git clone /path/on/this/machine

NO https:// REMOTES. This git is built without curl, because curl needs
a TLS stack and this image deliberately has none (RFC 0006, RFC 0019).
`git clone https://...` fails with "Unable to find remote helper for
'https'" -- that is this, not a broken install. Use the ssh URL; every
forge offers one.

Also absent, for want of an interpreter: git-send-email, git-svn and
`git add -i` (perl), git-p4 (python), git gui and gitk (tcl/tk).
DOC
    echo "    git staged ($(du -sh "${files}" | cut -f1))"
fi

# ── Publish (called by 43-devtools-repo.sh, never by `all`) ───────────
if [ "$ONLY" = "repo" ]; then
    REPO_OUT="${BUILD_DIR}/repo"
    KEY_FILE="${BUILD_DIR}/keys/novi-repo.key"
    [ -d "${REPO_OUT}" ] || { echo "ERROR: ${REPO_OUT} not found -- run build/40-repo.sh first." >&2; exit 1; }
    [ -f "${KEY_FILE}" ] || { echo "ERROR: signing key ${KEY_FILE} not found." >&2; exit 1; }

    echo ">>> Packaging the developer tools into ${REPO_OUT} ..."
    for d in "${STAGE_DIR}"/*/; do
        [ -f "${d}/MANIFEST" ] || continue
        bash "${REPO_ROOT}/packages/mkpkg" "${d}" "${REPO_OUT}" >/dev/null
        echo "    $(basename "${d}")"
    done

    echo ">>> Re-indexing and re-signing ..."
    sh "${REPO_ROOT}/packages/mkrepo" "${REPO_OUT}" --key "${KEY_FILE}"
fi

echo ">>> Staged under ${STAGE_DIR}"
ls -1 "${STAGE_DIR}" 2>/dev/null || true
