#!/bin/bash
# ============================================================
# 30-repo.sh — Build and sign the first-party package repository
#
# RFC 0006 gave `pkg` something to fetch from. RFC 0007 decides WHAT is
# in it: the desktop, so the base image can stop carrying it.
#
# The file set is not hand-listed. tools/pkgsplit/pkgsplit.py computes
# it from the ELF dependency graph -- closure(NEEDED) from the desktop
# binaries, minus closure(NEEDED) from everything else that ships --
# and fails the build if anything left in the base still links against
# something being moved out. A hand-written list is how a split rots:
# someone adds a library in 06-wayland.sh, nobody updates the list, and
# the "console-only" image quietly grows a Wayland stack again.
#
# Inter-package dependencies are computed the same way, by mapping each
# NEEDED soname back to its owning package. `wlroots depends on
# libdisplay-info, libdrm, libinput, libudev, libxkbcommon, pixman,
# seatd, wayland` is read out of the binaries, not typed in.
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
MANIFEST="${BUILD_DIR}/repo-desktop-files.list"
READELF="${TOOLS}/bin/${TARGET_TRIPLE}-readelf"

command -v openssl &>/dev/null || {
    echo "ERROR: openssl is required to sign the repository index." >&2
    exit 1
}
command -v python3 &>/dev/null || {
    echo "ERROR: python3 is required (tools/pkgsplit)." >&2
    exit 1
}
[ -x "${READELF}" ] || {
    echo "ERROR: ${READELF} not found -- run build/02-toolchain.sh first." >&2
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

# ── Work out the split and stage every package ────────────────────────────
echo ">>> Computing the base/desktop split from the ELF dependency graph ..."
rm -rf "${STAGE_DIR}" "${REPO_OUT}"
mkdir -p "${STAGE_DIR}" "${REPO_OUT}"

python3 "${REPO_ROOT}/tools/pkgsplit/pkgsplit.py" \
    --rootfs   "${ROOTFS}" \
    --readelf  "${READELF}" \
    --stage    "${STAGE_DIR}" \
    --arch     "${TARGET_ARCH}" \
    --versions "${SCRIPT_DIR}/00-versions.sh" \
    --manifest "${MANIFEST}"

# ── Build them ────────────────────────────────────────────────────────────
echo ">>> Packaging ..."
count=0
for stage in "${STAGE_DIR}"/*/; do
    [[ -f "${stage}/MANIFEST" ]] || continue
    bash "${REPO_ROOT}/packages/mkpkg" "${stage}" "${REPO_OUT}" >/dev/null
    count=$(( count + 1 ))
done
(( count > 0 )) || {
    echo "ERROR: no packages were built -- run the desktop stages (06..14) first." >&2
    exit 1
}
echo "    ${count} package(s) built"

# ── Index + signature ─────────────────────────────────────────────────────
echo ">>> Indexing and signing ..."
sh "${REPO_ROOT}/packages/mkrepo" "${REPO_OUT}" --key "${KEY_FILE}"

# ── Trust the key in the image ────────────────────────────────────────────
install -D -m 644 "${REPO_OUT}/index.pub" "${ROOTFS}/etc/novi/keys/novi-repo.pub"

echo ""
echo "Repository built: ${REPO_OUT}  ($(du -sh "${REPO_OUT}" | cut -f1))"
echo "Desktop file manifest: ${MANIFEST} ($(wc -l < "${MANIFEST}") files)"
echo ""
echo "  bash build/31-desktop-split.sh   # remove those files from the base image"
echo "  bash scripts/mkiso.sh            # the ISO carries this repo at /novi-repo"
