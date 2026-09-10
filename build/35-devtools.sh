#!/bin/bash
# ============================================================
# 35-devtools.sh — the packaged tools: git, ssh, curl, and a browser
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
#   bash build/35-devtools.sh [openssh|ca|curl|git|netsurf|repo|all]
#
# Phase order matters when run by hand: `git` links the curl that the
# `curl` phase staged, and `curl` links the mbedTLS that
# 31-mbedtls.sh built. `all` runs them in the right order; both check
# and refuse rather than producing a git with no https in it.
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
# GIT NOW HAS CURL, and therefore https:// remotes (RFC 0020). That
# was the one thing RFC 0019 deliberately left out, on the grounds that
# picking a TLS library deserved its own decision rather than being
# smuggled in behind a git package. RFC 0020 made it: mbedTLS, built by
# 31-mbedtls.sh, as a package.
#
# So this stage also builds curl and packages the certificate
# authorities. `ca-certificates` is the only new TRUST decision in any
# of this -- 143 organisations any one of which can vouch for any name
# -- which is why the bundle is hash-pinned in 01-fetch.sh alongside
# TweetNaCl, and why it is a package somebody can decline to install.
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/00-versions.sh"

CROSS="${TOOLS}/bin/${TARGET_TRIPLE}"
[ -x "${CROSS}-gcc" ] || { echo "ERROR: ${CROSS}-gcc not found -- run build/02-toolchain.sh." >&2; exit 1; }

WORK="${BUILD_DIR}/devtools-build"
STAGE_DIR="${BUILD_DIR}/stage-devtools"
# Where 31-mbedtls.sh left its headers and libraries. Not ${ROOTFS}:
# putting a TLS stack in the base image is the thing RFC 0020 exists
# to avoid.
TLS_DEPS="${BUILD_DIR}/tls-deps"
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

The daemon is a SEPARATE package, openssh-server -- host keys, a
privilege-separation account, an s6 service, a declared state key and
a hole in the firewall are five decisions, and RFC 0022 makes them.
Installing a client should not start a listener.
DOC
    echo "    openssh staged ($(du -sh "${files}" | cut -f1))"

    # ── openssh-server ────────────────────────────────────────────
    #
    # A SECOND package, from the same build, and the split is the
    # point rather than tidiness: `pkg install openssh` has to be able
    # to mean "I want to ssh out of here" without also meaning "the
    # world may ssh in". The three binaries below are exactly what a
    # listener needs and nothing that a client does.
    #
    # NO HOST KEY IS PACKAGED. Not here, not generated at build time,
    # not anywhere in the image -- a distribution that ships one ships
    # the same one to every machine that installs it. init/services/
    # sshd/run makes the machine's own on first start.
    #
    # sshd-session because OpenSSH 9.8 split the daemon (see above);
    # sftp-server because scp has spoken SFTP since OpenSSH 9.0, so
    # without it `scp` to this machine fails and `sftp` never worked.
    files="$(stage_pkg openssh-server "${OPENSSH_VERSION}" "openssh,zlib" \
        "OpenSSH daemon (ed25519 host keys only; RFC 0022)")"
    mkdir -p "${files}/usr/sbin" "${files}/usr/libexec" "${files}/etc/ssh"
    install -m 755 "${WORK}/openssh-${OPENSSH_VERSION}/sshd" \
        "${files}/usr/sbin/sshd"
    # /usr/libexec is compiled in, not chosen here: sshd execs
    # sshd-session by an absolute path baked at configure time, and
    # putting it anywhere else gives a daemon that accepts a
    # connection and dies.
    for b in sshd-session sftp-server; do
        install -m 755 "${WORK}/openssh-${OPENSSH_VERSION}/${b}" \
            "${files}/usr/libexec/${b}"
    done
    # Novi's own sshd_config, not the generated sshd_config.out. The
    # generated one is upstream's defaults with this build's paths
    # substituted in, and upstream's defaults are wrong for a machine
    # whose root account ships with an empty password field.
    install -m 644 "${REPO_ROOT}/rootfs/etc/ssh/sshd_config" \
        "${files}/etc/ssh/sshd_config"
    strip_tree "${files}"

    mkdir -p "${files}/usr/share/doc/openssh-server"
    cat > "${files}/usr/share/doc/openssh-server/README" <<'DOC'
openssh-server — sshd, off until you say otherwise.

  novi-state set services.sshd on
  novi-state set network.firewall.allow 22
  novi-state apply

Two keys, not one. Enabling a daemon does not open a port: that
something listens and that the world may reach it are separate
decisions (RFC 0016, RFC 0022). `novi-state apply` tells you when you
have done the first and not the second.

THE HOST KEY IS MADE ON THIS MACHINE, the first time the service
starts, and is ed25519 because this OpenSSH has no OpenSSL and so no
RSA or ECDSA (RFC 0019). Nothing in the image contains a host key.

ROOT CANNOT LOG IN OVER SSH and password authentication is on. Those
two go together: the shipped root account has an EMPTY password field,
so `PermitRootLogin no` is what stops the first machine to open port 22
from handing itself to whoever gets there first. sshd also refuses
empty passwords outright, and accounts novi-state creates start
locked -- so a fresh install is unreachable until somebody with the
console deliberately gives an account a password or an
authorized_keys.

  ssh-keygen -t ed25519            # on the machine you connect FROM
  cat ~/.ssh/id_ed25519.pub | ssh ... >> ~/.ssh/authorized_keys
DOC
    echo "    openssh-server staged ($(du -sh "${files}" | cut -f1))"
    echo "    test-only (NOT in the image): ${BUILD_DIR}/ssh-test/sshd"
fi

# ── ca-certificates ───────────────────────────────────────────────────
#
# Mozilla's root store as curl.se publishes it. No conversion, no
# rehashing, no c_rehash symlink farm: mbedTLS and curl both read one
# concatenated PEM file, and a directory of hashed symlinks exists for
# OpenSSL's benefit, which is not present here.
if [ "$ONLY" = "all" ] || [ "$ONLY" = "ca" ]; then
    echo ">>> Staging ca-certificates (${CACERT_DATE}) ..."
    src="${SOURCES}/cacert-${CACERT_DATE}.pem"
    [ -f "${src}" ] || { echo "ERROR: ${src} not found -- run build/01-fetch.sh." >&2; exit 1; }

    files="$(stage_pkg ca-certificates "${CACERT_DATE//-/.}" "" \
        "Mozilla's CA root store (${CACERT_DATE}) -- 143 certificates")"
    install -D -m 644 "${src}" "${files}/etc/ssl/certs/ca-certificates.crt"

    # /etc/ssl/cert.pem -> certs/ca-certificates.crt.
    #
    # OpenSSL (RFC 0027) is configured --openssldir=/etc/ssl, so its
    # DEFAULT verify paths are ${SSL_CERT_FILE:-/etc/ssl/cert.pem} and
    # ${SSL_CERT_DIR:-/etc/ssl/certs}. The directory lookup is by
    # subject hash and finds nothing in a directory holding one bundle
    # file, so without this symlink `python3 -c "import ssl;
    # ssl.create_default_context()"` loads ZERO certificates and every
    # https connection fails to verify -- on a machine where the
    # bundle is sitting right there. curl is unaffected (it is built
    # with the bundle path compiled in), which is exactly the kind of
    # asymmetry that makes this look like a Python bug.
    #
    # It belongs to this package rather than to openssl because it is a
    # statement about where the cert store is, and this package is the
    # cert store. Alpine ships the same link for the same reason.
    ln -sf certs/ca-certificates.crt "${files}/etc/ssl/cert.pem"

    mkdir -p "${files}/usr/share/doc/ca-certificates"
    cat > "${files}/usr/share/doc/ca-certificates/README" <<DOC
ca-certificates — Mozilla's root store, ${CACERT_DATE}.

  /etc/ssl/certs/ca-certificates.crt

This is the list of organisations whose word this machine accepts about
who a server is. There are 143 of them, and ANY ONE of them can issue a
certificate for ANY name. That is the deal the web makes; Novi does not
improve on it and does not pretend to.

What it does do is make the set explicit: the file is hash-pinned at
build time (build/01-fetch.sh), versioned by the date it was published,
and shipped as a package you can decline to install. Nothing in the
base image needs it -- \`pkg\` trusts an Ed25519 signature over the
repository index, not the transport (RFC 0006).

To trust something else as well, append it to the file. There is no
update-ca-certificates here: the bundle is a package, and replacing it
is \`pkg update\`.
DOC
    echo "    ca-certificates staged ($(du -sh "${files}" | cut -f1))"
fi

# ── curl ──────────────────────────────────────────────────────────────
if [ "$ONLY" = "all" ] || [ "$ONLY" = "curl" ]; then
    require_zlib
    [ -f "${TLS_DEPS}/lib/libmbedtls.so" ] || {
        echo "ERROR: mbedTLS not found in ${TLS_DEPS} -- run build/31-mbedtls.sh." >&2
        exit 1
    }
    echo ">>> Building curl ${CURL_VERSION} (mbedTLS) ..."
    rm -rf "${WORK}/curl-${CURL_VERSION}"
    tar xf "${SOURCES}/curl-${CURL_VERSION}.tar.xz" -C "${WORK}"
    (
        cd "${WORK}/curl-${CURL_VERSION}"
        # Everything switched off here is a dependency this image does
        # not have or a protocol git never asks for. A smaller curl is
        # a smaller thing to be wrong -- and in an image whose split is
        # computed from what is present, unused code is not inert.
        #
        # --with-ca-bundle names the path the ca-certificates package
        # installs, so the default works with no configuration at all.
        #
        # There is no --without-ssl here and there must not be: curl
        # treats it as "no TLS at all" and refuses outright when a
        # backend is also named ("--without-ssl has been set together
        # with an explicit option to use an ssl library"). Naming
        # --with-mbedtls IS the exclusion -- curl builds exactly the
        # backends it is told to.
        # --build is given EXPLICITLY, and that is not decoration.
        # curl's configure has a "checking run-time libs availability"
        # test guarded by `if test "x$cross_compiling" != xyes` -- it
        # compiles a program, runs it, and fails the build when it
        # cannot. With only --host, autoconf did not conclude it was
        # cross-compiling and ran the test, which died with "one or
        # more libs available at link-time are not available run-time"
        # naming -lmbedtls: a message about the target's runtime linker
        # produced by trying to execute a target binary here. Naming
        # both triples makes autoconf certain.
        ./configure \
            --build="$(gcc -dumpmachine)" \
            --host="${TARGET_TRIPLE}" \
            --prefix=/usr \
            --with-mbedtls="${TLS_DEPS}" \
            --with-ca-bundle=/etc/ssl/certs/ca-certificates.crt \
            --without-libssh2 --without-libssh --without-libidn2 \
            --without-brotli --without-zstd --without-libpsl \
            --without-nghttp2 --without-ngtcp2 --without-librtmp \
            --with-zlib="${ROOTFS}/usr" \
            --disable-ldap --disable-ldaps --disable-rtsp --disable-dict \
            --disable-telnet --disable-tftp --disable-pop3 --disable-imap \
            --disable-smb --disable-smtp --disable-gopher --disable-mqtt \
            --disable-manual --enable-shared --disable-static >/dev/null
        make -j"${JOBS}" >/dev/null
    )

    files="$(stage_pkg curl "${CURL_VERSION}" "mbedtls,ca-certificates,zlib" \
        "curl and libcurl, over mbedTLS")"
    make -C "${WORK}/curl-${CURL_VERSION}" install DESTDIR="${files}" >/dev/null
    # The .la files record the build host's absolute paths and are read
    # by nothing on the target -- the same trap 33-nftables.sh
    # documents, one directory later.
    rm -f "${files}"/usr/lib/*.la
    strip_tree "${files}"
    echo "    curl staged ($(du -sh "${files}" | cut -f1))"
fi

# ── git ───────────────────────────────────────────────────────────────
if [ "$ONLY" = "all" ] || [ "$ONLY" = "git" ]; then
    require_zlib
    echo ">>> Building git ${GIT_VERSION} (no curl, no OpenSSL) ..."
    rm -rf "${WORK}/git-${GIT_VERSION}"
    tar xf "${SOURCES}/git-${GIT_VERSION}.tar.xz" -C "${WORK}"

    [ -d "${STAGE_DIR}/curl/files/usr/include" ] || {
        echo "ERROR: curl has not been staged -- run this stage's 'curl' phase" >&2
        echo "       (and build/31-mbedtls.sh) before 'git'." >&2
        exit 1
    }
    files="$(stage_pkg git "${GIT_VERSION}" "openssh,curl,zlib" \
        "Git, over https, ssh and locally")"

    # -rpath-link, not just -L, and this is the second time this repo
    # has learned it (see 33-nftables.sh, CLAUDE.md). Linking git means
    # pulling in libcurl.so, whose DT_NEEDED names libmbedtls.so.21 --
    # and the linker has to FIND that file to resolve the symbols
    # libcurl refers to. Without it: five "undefined reference to
    # `mbedtls_ssl_conf_ca_chain'" from a library that exports every
    # one of them, sitting in a directory already named with -L.
    GIT_LDFLAGS="-L${ROOTFS}/usr/lib -L${TLS_DEPS}/lib"
    GIT_LDFLAGS="${GIT_LDFLAGS} -L${STAGE_DIR}/curl/files/usr/lib"
    GIT_LDFLAGS="${GIT_LDFLAGS} -Wl,-rpath-link,${ROOTFS}/usr/lib"
    GIT_LDFLAGS="${GIT_LDFLAGS} -Wl,-rpath-link,${TLS_DEPS}/lib"
    GIT_LDFLAGS="${GIT_LDFLAGS} -Wl,-rpath-link,${STAGE_DIR}/curl/files/usr/lib"

    # Every NO_ here removes a dependency this image does not have,
    # not a feature of git's object model:
    #   NO_OPENSSL   git falls back to its own collision-detecting
    #                SHA-1, which is what upstream uses without it
    #   NO_EXPAT     the dumb http-push protocol, which no forge has
    #                spoken for a decade; git-remote-https does not
    #                need it
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
            LDFLAGS="${GIT_LDFLAGS}" \
            prefix=/usr \
            NO_OPENSSL=1 NO_EXPAT=1 \
            CURL_CONFIG=false \
            CURL_CFLAGS="-I${STAGE_DIR}/curl/files/usr/include" \
            CURL_LDFLAGS="-L${STAGE_DIR}/curl/files/usr/lib -lcurl" \
            NO_PERL=1 NO_PYTHON=1 NO_TCLTK=1 NO_GETTEXT=1 \
            NO_REGEX=NeedsStartEnd \
            >/dev/null
        make install \
            CC="${CROSS}-gcc" AR="${CROSS}-ar" \
            CFLAGS="-O2 -I${ROOTFS}/usr/include" \
            LDFLAGS="${GIT_LDFLAGS}" \
            prefix=/usr DESTDIR="${files}" \
            NO_OPENSSL=1 NO_EXPAT=1 \
            CURL_CONFIG=false \
            CURL_CFLAGS="-I${STAGE_DIR}/curl/files/usr/include" \
            CURL_LDFLAGS="-L${STAGE_DIR}/curl/files/usr/lib -lcurl" \
            NO_PERL=1 NO_PYTHON=1 NO_TCLTK=1 NO_GETTEXT=1 \
            NO_REGEX=NeedsStartEnd \
            >/dev/null
    )
    strip_tree "${files}"

    mkdir -p "${files}/usr/share/doc/git"
    cat > "${files}/usr/share/doc/git/README" <<'DOC'
git — over ssh and locally.

  git clone https://host/user/repo.git
  git clone git@host:user/repo.git
  git clone ssh://host/path/to/repo
  git clone /path/on/this/machine

https works through curl and mbedTLS (RFC 0020), and verifies the
server against /etc/ssl/certs/ca-certificates.crt -- the
ca-certificates package. Without that package installed, every https
clone fails at certificate verification, which is the correct
behaviour and not a bug.

Absent, for want of an interpreter: git-send-email, git-svn and
`git add -i` (perl), git-p4 (python), git gui and gitk (tcl/tk).
DOC
    echo "    git staged ($(du -sh "${files}" | cut -f1))"
fi

# ── NetSurf (a web browser) ───────────────────────────────────────────
if [ "$ONLY" = "all" ] || [ "$ONLY" = "netsurf" ]; then
    require_zlib
    echo ">>> Building NetSurf ${NETSURF_VERSION} ..."

    # WHY THIS IS A PHASE OF 35-devtools.sh AND NOT ITS OWN STAGE.
    #
    # It wants to be `build/44-netsurf.sh` and it cannot be. The
    # ordering constraint is real in both directions: it READS
    # ${ROOTFS} (wayland, libpng, zlib and expat headers), which
    # 41-desktop-split.sh removes, so it must run before 41; and it
    # PUBLISHES into a repository 40-repo.sh wipes, so its package must
    # be written after 40. That is exactly the "build early, publish
    # late" split 35, 38 and 39 already use -- and every number from 01
    # to 39 is taken.
    #
    # CLAUDE.md records this trap biting twice before, and the
    # resolution both times was to move the PACKAGING stages up to make
    # room. This is the third time, and the room is now gone entirely:
    # whoever adds the next content stage has to do that renumber
    # (40..43 -> 50..53) rather than squeeze another phase in here.
    NS_SRC="${SOURCES}/netsurf-all-${NETSURF_VERSION}.tar.gz"
    [ -f "${NS_SRC}" ] || { echo "ERROR: ${NS_SRC} not found -- run build/01-fetch.sh." >&2; exit 1; }

    NS_WORK="${BUILD_DIR}/netsurf-build"
    NS_TREE="${NS_WORK}/netsurf-all-${NETSURF_VERSION}"
    NS_INST="${NS_WORK}/inst"
    rm -rf "${NS_WORK}"
    mkdir -p "${NS_WORK}" "${NS_INST}"
    tar xzf "${NS_SRC}" -C "${NS_WORK}"

    # The one patch, and it FAILS THE BUILD if it stops applying.
    #
    # libnsfb's Wayland surface binds wl_shell, deprecated in 2016 and
    # never implemented by wlroots or novi-shell -- so upstream cannot
    # open a window on this desktop at all. Silently building an
    # unpatched browser would produce a binary that starts, finds no
    # shell global and does nothing visible, which is the worst
    # possible failure to ship. Same rule 23-e2fsprogs.sh applies to
    # its musl patch.
    echo "  -> libnsfb: wl_shell -> xdg-shell"
    ( cd "${NS_TREE}" && patch -p1 --forward --silent \
        < "${REPO_ROOT}/patches/netsurf-libnsfb-xdg-shell.patch" ) || {
        echo "ERROR: patches/netsurf-libnsfb-xdg-shell.patch no longer applies to" >&2
        echo "       netsurf-all-${NETSURF_VERSION}. Do not build without it: the" >&2
        echo "       result is a browser that cannot open a window, and says" >&2
        echo "       nothing about why." >&2
        exit 1
    }

    # The generated half of that patch. Not in the .patch file because
    # it is generated rather than written, and a diff of 84 KB of
    # machine output is not a thing anyone can review.
    XDG_XML="${ROOTFS}/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml"
    [ -f "${XDG_XML}" ] || { echo "ERROR: ${XDG_XML} not found -- run build/06-wayland.sh." >&2; exit 1; }
    wayland-scanner client-header "${XDG_XML}" \
        "${NS_TREE}/libnsfb/src/surface/xdg-shell-protocol.h"
    wayland-scanner private-code "${XDG_XML}" \
        "${NS_TREE}/libnsfb/src/surface/xdg-shell-protocol.c"
    sed -i 's#+= wld.c$#+= wld.c xdg-shell-protocol.c#' \
        "${NS_TREE}/libnsfb/src/surface/Makefile"
    grep -q 'xdg-shell-protocol.c' "${NS_TREE}/libnsfb/src/surface/Makefile" || {
        echo "ERROR: could not add xdg-shell-protocol.c to libnsfb's surface Makefile." >&2
        exit 1
    }

    NS_CURL="${STAGE_DIR}/curl/files/usr"
    NS_SSL="${BUILD_DIR}/openssl-target/usr"
    NS_TLS="${BUILD_DIR}/tls-deps"
    for d in "${NS_CURL}/lib/pkgconfig" "${NS_SSL}/lib/pkgconfig"; do
        [ -d "$d" ] || { echo "ERROR: $d not found -- run build/35-devtools.sh curl and build/32-openssl.sh first." >&2; exit 1; }
    done

    # CFLAGS and LDFLAGS go in the ENVIRONMENT, never on the make
    # command line. NetSurf's buildsystem does `CFLAGS += ...`, and a
    # variable set on the command line overrides every assignment in
    # the makefile including `+=` -- so passing them there deletes
    # NetSurf's own include paths and the build dies on its own
    # headers. Same trap RFC 0021 records for wolfSSL's generated
    # .config, one level out.
    #
    # -rpath-link for the FIFTH time in this repository: libcurl.so's
    # DT_NEEDED names libmbedtls.so.21, and -L alone does not let the
    # linker resolve a shared library's own dependencies. Without it
    # the link fails on seventeen undefined mbedtls_* symbols from a
    # library that has none of them in its own source.
    export PATH="${NS_INST}/bin:${TOOLS}/bin:${PATH}"
    export PKG_CONFIG_PATH="${NS_INST}/lib/pkgconfig:${NS_CURL}/lib/pkgconfig:${NS_SSL}/lib/pkgconfig:${ROOTFS}/usr/lib/pkgconfig"
    export CFLAGS="-I${ROOTFS}/usr/include -I${NS_CURL}/include -I${NS_SSL}/include"
    export LDFLAGS="-L${ROOTFS}/usr/lib -L${NS_CURL}/lib -L${NS_SSL}/lib -L${NS_TLS}/lib -Wl,-rpath-link,${ROOTFS}/usr/lib:${NS_CURL}/lib:${NS_SSL}/lib:${NS_TLS}/lib"

    # nsgenbind is a BUILD-HOST tool (it generates JavaScript bindings),
    # so it is built for the build machine with the target's flags
    # unset -- pointing a host compiler at the target's headers is how
    # you get a host binary that will not link.
    echo "  -> nsgenbind (build host)"
    ( cd "${NS_TREE}" && env -u CFLAGS -u LDFLAGS \
        make -C nsgenbind install HOST="$(gcc -dumpmachine)" \
            PREFIX="${NS_INST}" NSSHARED="${NS_TREE}/buildsystem" \
            DESTDIR= Q=@ >/dev/null )

    # The libraries, in dependency order: libcss and libdom need
    # libparserutils and libwapcaplet installed first, and libsvgtiny
    # needs libdom.
    for L in libnslog libwapcaplet libparserutils libcss libhubbub libdom \
             libnsbmp libnsgif libnsutils libutf8proc libnspsl libsvgtiny libnsfb; do
        echo "  -> ${L}"
        ( cd "${NS_TREE}" && make -C "${L}" install HOST="${TARGET_TRIPLE}" \
            PREFIX="${NS_INST}" NSSHARED="${NS_TREE}/buildsystem" \
            DESTDIR= Q=@ WARNFLAGS='-Wall -W -Wno-error' >/dev/null )
    done

    # CC and AR are named EXPLICITLY. The buildsystem derives them from
    # HOST only when their origin is `default`, and the browser's own
    # makefile does not take that path -- the first attempt compiled
    # the whole of NetSurf with the build host's gcc and failed at the
    # link on /usr/bin/ld.
    #
    # A second, quieter consequence: the build directory is named after
    # HOST and TARGET but NOT after the compiler, so switching
    # compilers silently reuses objects built by the other one. That
    # surfaced as undefined references to __snprintf_chk and
    # __memset_chk -- glibc's fortify symbols -- from a musl link. The
    # tree is extracted fresh above, which is the fix.
    #
    # NETSURF_USE_LIBICONV_PLUG=YES means "iconv is part of libc",
    # which is true of musl. NO makes it link -liconv, a library that
    # does not exist here and never will.
    echo "  -> netsurf (framebuffer frontend, Wayland surface)"
    # FONTS: freetype against THIS DESKTOP'S OWN FACES, not the
    # built-in bitmap font.
    #
    # NETSURF_FB_FONTLIB=internal is a compiled-in bitmap face, and it
    # made the one window on this desktop that renders the most text
    # the one window not drawing it in Inter -- the most visible
    # violation of the design language in the image. freetype is a
    # supported fontlib upstream (frontends/framebuffer/font_freetype.c)
    # and freetype itself has been in this build since stage 06, for
    # fcft. So this is a new LINK, not a new dependency.
    #
    # NETSURF_FB_FONTPATH feeds respaths (frontends/framebuffer/gui.c),
    # and fb_new_face() resolves each name through filepath_sfind()
    # against it -- so these are plain filenames, and the directories
    # are where the fonts-* packages put them.
    #
    # WHAT THIS IMAGE DOES NOT HAVE, stated rather than left to be
    # discovered against a real page:
    #   * NO SERIF FACE AT ALL. `font-family: serif` and the default
    #     serif of an unstyled page both land on Inter. That is wrong
    #     typographically and it is what shipping one sans and one
    #     mono costs; adding a serif is a design decision and a new
    #     package, not a flag.
    #   * NO CURSIVE OR FANTASY. Those map to Inter too.
    # SemiBold rather than Bold for the bold face because SemiBold is
    # what NOVI_FONT_TITLE uses -- matching the desktop beats matching
    # the CSS keyword.
    NS_FONTS="NETSURF_FB_FONTLIB=freetype
        NETSURF_FB_FONTPATH=/usr/share/fonts/inter:/usr/share/fonts/jetbrains-mono
        NETSURF_FB_FONT_SANS_SERIF=Inter-Regular.ttf
        NETSURF_FB_FONT_SANS_SERIF_BOLD=Inter-SemiBold.ttf
        NETSURF_FB_FONT_SANS_SERIF_ITALIC=Inter-Italic.ttf
        NETSURF_FB_FONT_SANS_SERIF_ITALIC_BOLD=Inter-SemiBoldItalic.ttf
        NETSURF_FB_FONT_SERIF=Inter-Regular.ttf
        NETSURF_FB_FONT_SERIF_BOLD=Inter-SemiBold.ttf
        NETSURF_FB_FONT_MONOSPACE=JetBrainsMono-Regular.ttf
        NETSURF_FB_FONT_MONOSPACE_BOLD=JetBrainsMono-Bold.ttf
        NETSURF_FB_FONT_CURSIVE=Inter-Regular.ttf
        NETSURF_FB_FONT_FANTASY=Inter-Regular.ttf"

    NS_OPTS="HOST=${TARGET_TRIPLE} TARGET=framebuffer PREFIX=/usr
        CC=${TARGET_TRIPLE}-gcc AR=${TARGET_TRIPLE}-ar
        NETSURF_FB_FRONTEND=wld ${NS_FONTS}
        NETSURF_USE_DUKTAPE=NO NETSURF_USE_HARU_PDF=NO
        NETSURF_USE_LIBICONV_PLUG=YES NETSURF_USE_JPEG=NO
        NETSURF_USE_WEBP=NO NETSURF_USE_VIDEO=NO"

    # fonts-inter and fonts-jetbrains-mono are named by hand because
    # NOTHING CAN DERIVE THEM. pkgsplit reads DT_NEEDED, and a .ttf
    # opened by path at runtime appears in no ELF header -- the same
    # blind spot that hides libdrm's dlopen'd drivers, wearing a
    # different costume. Without them the browser installs, starts,
    # fails to find its default font and exits: font_freetype.c treats
    # a missing sans-serif as fatal, correctly.
    files="$(stage_pkg netsurf "${NETSURF_VERSION}" \
        "curl,openssl,libpng,zlib,expat,wayland,freetype,fonts-inter,fonts-jetbrains-mono" \
        "NetSurf ${NETSURF_VERSION} -- a small web browser. Renders HTML and CSS; NO JavaScript in this build")"
    # shellcheck disable=SC2086
    ( cd "${NS_TREE}" && make -C netsurf ${NS_OPTS} Q=@ \
        WARNFLAGS='-Wall -W -Wno-error' >/dev/null )
    # shellcheck disable=SC2086
    ( cd "${NS_TREE}" && make -C netsurf install ${NS_OPTS} DESTDIR="${files}" \
        Q=@ WARNFLAGS='-Wall -W -Wno-error' >/dev/null )

    strip_tree "${files}"

    # A launcher entry, so it is reachable with a mouse. The binary is
    # `netsurf-fb`, which is what the framebuffer frontend installs
    # itself as -- not renamed, because a person reading `ps` should
    # see the name upstream gave it.
    install -d "${files}/usr/share/novi/apps"
    cat > "${files}/usr/share/novi/apps/netsurf.app" <<APP
name=Web
exec=/usr/bin/netsurf-fb
icon=globe
description=NetSurf -- a small web browser
APP

    echo "  -> staged $(du -sh "${files}" | cut -f1)"
    "${CROSS}-readelf" -d "${files}/usr/bin/netsurf-fb" | grep NEEDED || true
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
