#!/bin/bash
# ============================================================
# 20-repo.sh — Build and sign the first-party package repository
#
# RFC 0006. `pkg` and `mkpkg` have worked for a while and there has
# never been anything to point them at. This stage produces one: a
# signed repository under ${BUILD_DIR}/repo, ready to be served over
# HTTP (or copied to a mirror) and consumed by `pkg sync`.
#
# WHAT GOES IN IT, and why these specifically: the desktop. §2 of the
# platform roadmap wants a small native base with everything else
# delivered as packages, and the desktop is the largest thing currently
# baked into the base image that a console-only machine has no use for.
# Packaging it is the first real step of that split -- these packages
# are built from exactly the binaries the earlier stages produced, so
# the repository's contents and the image's contents cannot drift.
#
# THE SIGNING KEY. This generates a development key under
# ${BUILD_DIR}/keys on first run and installs its PUBLIC half into the
# image at /etc/novi/keys/novi-repo.pub. That is correct for a build
# you run yourself -- you are the publisher, and trusting your own
# repository is the point. It is NOT how a release should work: a real
# release key lives offline, only its public half is ever in a tree
# like this one, and signing happens on a machine that is not the build
# host. The private key is deliberately left in ${BUILD_DIR} (which is
# never squashed into the image) rather than anywhere under the repo
# checkout, so it cannot be committed by accident.
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/00-versions.sh"

REPO_OUT="${REPO_OUT:-${BUILD_DIR}/repo}"
KEY_DIR="${KEY_DIR:-${BUILD_DIR}/keys}"
KEY_FILE="${KEY_DIR}/novi-repo.key"
STAGE_DIR="${BUILD_DIR}/repo-staging"

command -v openssl &>/dev/null || {
    echo "ERROR: openssl is required to sign the repository index." >&2
    exit 1
}

# ── Signing key ───────────────────────────────────────────────────────────
mkdir -p "${KEY_DIR}"
chmod 700 "${KEY_DIR}"
if [[ ! -f "${KEY_FILE}" ]]; then
    echo ">>> Generating a development repository signing key ..."
    echo "    ${KEY_FILE}  (private -- never copy this into the image)"
    openssl genpkey -algorithm ED25519 -out "${KEY_FILE}" 2>/dev/null
    chmod 600 "${KEY_FILE}"
fi

# ── Package definitions ───────────────────────────────────────────────────
#
# name|version|depends|description|file [file ...]
#
# Paths are relative to ${ROOTFS}. A package whose files are all
# missing is skipped with a warning rather than shipped empty: the
# desktop stages (06..14) are separate from this one and someone may
# reasonably have built only the base.
PACKAGES=(
"fcft|${FCFT_VERSION}||Font loading and glyph rasterisation library|usr/lib/libfcft.so usr/lib/libfcft.so.3 usr/lib/libfcft.so.3.5.1"
"foot|${FOOT_VERSION}|fcft|Fast, lightweight Wayland terminal emulator|usr/bin/foot usr/bin/footclient"
"novi-shell|${OS_VERSION}||The Novi Wayland compositor (RFC 0001)|usr/bin/novi-shell"
"novi-panel|${OS_VERSION}||Top bar and taskbar for the Novi desktop|usr/bin/novi-panel"
"novi-launcher|${OS_VERSION}||Alt+Space application launcher and symbol picker|usr/bin/novi-launcher"
"novi-settings|${OS_VERSION}||Settings: account and declared system state|usr/bin/novi-settings"
"novi-lockscreen|${OS_VERSION}||Super+L session lock|usr/bin/novi-lockscreen"
"novi-screenshot|${OS_VERSION}||PrintScreen screen capture|usr/bin/novi-screenshot"
)

rm -rf "${STAGE_DIR}" "${REPO_OUT}"
mkdir -p "${STAGE_DIR}" "${REPO_OUT}"

built=0
skipped=()
for spec in "${PACKAGES[@]}"; do
    IFS='|' read -r name version depends description files <<< "${spec}"

    # Only ship what actually exists.
    present=()
    for f in ${files}; do
        [[ -e "${ROOTFS}/${f}" ]] && present+=("${f}")
    done
    if (( ${#present[@]} == 0 )); then
        skipped+=("${name}")
        continue
    fi

    stage="${STAGE_DIR}/${name}"
    mkdir -p "${stage}/files"
    for f in "${present[@]}"; do
        mkdir -p "${stage}/files/$(dirname "${f}")"
        # -a: these are the built artifacts themselves, symlinks
        # (libfcft.so -> libfcft.so.3) included. Dereferencing them
        # would triple the package size and break the soname the
        # dynamic linker actually looks for.
        cp -a "${ROOTFS}/${f}" "${stage}/files/${f}"
    done

    {
        echo "name=${name}"
        echo "version=${version}"
        echo "arch=${TARGET_ARCH}"
        [[ -n "${depends}" ]] && echo "depends=${depends}"
        echo "description=${description}"
    } > "${stage}/MANIFEST"

    bash "${REPO_ROOT}/packages/mkpkg" "${stage}" "${REPO_OUT}" >/dev/null
    echo "    packaged ${name} ${version}"
    built=$(( built + 1 ))
done

(( built > 0 )) || {
    echo "ERROR: no packages could be built -- run the desktop stages (06..14) first." >&2
    exit 1
}
if (( ${#skipped[@]} > 0 )); then
    echo ">>> Skipped (not built in this rootfs): ${skipped[*]}"
fi

# ── Index + signature ─────────────────────────────────────────────────────
echo ">>> Indexing and signing ..."
sh "${REPO_ROOT}/packages/mkrepo" "${REPO_OUT}" --key "${KEY_FILE}"

# ── Trust the key in the image ────────────────────────────────────────────
install -D -m 644 "${REPO_OUT}/index.pub" "${ROOTFS}/etc/novi/keys/novi-repo.pub"

echo ""
echo "Repository built: ${REPO_OUT}"
ls -la "${REPO_OUT}" | head -20
echo ""
echo "Serve it and point a machine at it:"
echo "    (cd ${REPO_OUT} && python3 -m http.server 8000)"
echo "    # on the target: mirror = http://<host>:8000  in /etc/novi/pkg.conf"
