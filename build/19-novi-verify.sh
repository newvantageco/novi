#!/bin/bash
# ============================================================
# 19-novi-verify.sh — Build novi-verify, the Ed25519 verifier
#
# RFC 0006. `pkg` downloads code over a network and runs it as root.
# Verifying a SHA-256 out of the repository index protects the packages
# -- but only if the index itself is trustworthy, and nothing on the
# target could check a signature: no OpenSSL, no GnuPG, no libsodium in
# this base image, deliberately.
#
# So the base image gets a ~10 KB verifier rather than a TLS stack.
# TweetNaCl (public domain, tweetnacl.cr.yp.to, hash-pinned in
# 01-fetch.sh) is compiled straight into it -- one C file, no build
# system, no configuration, no assembly.
#
# Statically linked on purpose. This binary is the trust root for every
# package the system installs; it should not depend on a loader path or
# a shared library that a package could later replace.
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/00-versions.sh"

CC="${TOOLS}/bin/${TARGET_TRIPLE}-gcc"
[ -x "${CC}" ] || {
    echo "ERROR: ${CC} not found -- run build/02-toolchain.sh first." >&2
    exit 1
}

TN_DIR="${SOURCES}/tweetnacl-${TWEETNACL_VERSION}"
[ -f "${TN_DIR}/tweetnacl.c" ] || {
    echo "ERROR: ${TN_DIR}/tweetnacl.c not found -- run build/01-fetch.sh first." >&2
    exit 1
}

WORK="${BUILD_DIR}/novi-verify-build"
rm -rf "${WORK}"
mkdir -p "${WORK}"
cp "${TN_DIR}/tweetnacl.c" "${TN_DIR}/tweetnacl.h" "${WORK}/"
cp "${REPO_ROOT}/novi-verify/main.c" "${WORK}/"

echo ">>> Building novi-verify (static, musl) ..."
(
    cd "${WORK}"
    # -O2 rather than -O3: TweetNaCl is written to be readable and
    # constant-time, and there is nothing here worth chasing a compiler
    # for. -static because this is the trust root -- it must not resolve
    # through a shared library a package could later replace.
    # tweetnacl.c is vendored upstream and compiled separately without
    # -Wextra: it emits a handful of signed/unsigned comparison warnings
    # from its own FOR() macro, and patching vendored crypto to quiet a
    # style warning is a worse trade than not seeing them. Our own code
    # keeps the full warning set so its warnings stay visible.
    "${CC}" -O2 -c -o tweetnacl.o tweetnacl.c
    "${CC}" -O2 -Wall -Wextra -Werror -c -o main.o main.c
    "${CC}" -O2 -static -o novi-verify main.o tweetnacl.o
    "${TOOLS}/bin/${TARGET_TRIPLE}-strip" novi-verify
)

install -D -m 755 "${WORK}/novi-verify" "${ROOTFS}/usr/bin/novi-verify"
mkdir -p "${ROOTFS}/etc/novi/keys"

echo ""
echo "novi-verify installed:"
ls -la "${ROOTFS}/usr/bin/novi-verify"
file "${ROOTFS}/usr/bin/novi-verify" 2>/dev/null || true
