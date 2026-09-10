#!/bin/bash
# ============================================================
# 40-repo.sh — Build and sign the first-party package repository
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

# ── Refuse to package a binary that lost its hardening ────────────────────
#
# Here rather than in scripts/lint.sh because this needs a built rootfs
# and CI compiles nothing -- and here rather than at the end of the
# build because this is the last moment every first-party binary is
# still in the rootfs, before 41-desktop-split.sh moves them into
# packages. Shipping an unhardened binary is not something to notice
# afterwards.

# REFUSE TO RUN ON AN ALREADY-SPLIT ROOTFS.
#
# pkgsplit computes the desktop from what is IN the rootfs. Run this
# after 41-desktop-split.sh has already taken the desktop out and the
# answer is "nothing leaves the base": an empty manifest, a repository
# holding only the novi-desktop meta-package, and an ISO with no
# desktop anywhere -- no error, because an empty answer is a valid
# answer to the question that was asked.
#
# That is the same failure CLAUDE.md already records from the other
# direction (chaining this stage after a client build that failed).
# The guard is here rather than in a comment because the comment did
# not stop it happening a second time. `bash build.sh` never trips it;
# re-running stages by hand does.
if [ ! -x "${ROOTFS}/usr/bin/novi-shell" ]; then
    echo "ERROR: ${ROOTFS} has no desktop in it -- ${ROOTFS}/usr/bin/novi-shell" >&2
    echo "       is missing, so 41-desktop-split.sh has already run here." >&2
    echo "" >&2
    echo "  Computing the split now would find nothing to move, write an" >&2
    echo "  empty manifest, and produce an ISO with no desktop at all." >&2
    echo "" >&2
    echo "  Put the desktop back first:" >&2
    echo "      bash build.sh --from 06 --to 39" >&2
    echo "  then:" >&2
    echo "      bash build.sh --from 40" >&2
    echo "" >&2
    echo "  --to 39, NOT --to 29: content stages run to 39 now" >&2
    echo "  (novi-notifyd and novi-bg are 36, novi-glinfo is 37)." >&2
    echo "  This message said 29 and shipped a repository of 51" >&2
    echo "  packages instead of 54, with those three missing from" >&2
    echo "  novi-desktop and no error anywhere." >&2
    exit 1
fi

bash "${REPO_ROOT}/scripts/check-hardening.sh"

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
echo "  bash build/41-desktop-split.sh   # remove those files from the base image"
echo "  bash build/42-toolchain-repo.sh  # this stage WIPED the toolchain packages"
echo "  bash scripts/mkiso.sh            # the ISO carries this repo at /novi-repo"

# Said out loud because the failure is silent. This stage removes
# ${REPO_OUT} and rebuilds it from the rootfs, which drops anything
# another stage published into it -- today that is the native
# toolchain (28/42), 95 MB of it. build.sh runs the stages in order and
# is fine; running this one by hand and stopping produces an ISO that
# is simply smaller, with no error and nothing to say which packages a
# repository was supposed to hold.
if [ -d "${BUILD_DIR}/stage-toolchain" ] &&
   ! ls "${REPO_OUT}"/novi-devel-*.pkg.tar.gz >/dev/null 2>&1; then
    echo ""
    echo "NOTE: /build/stage-toolchain exists but novi-devel is not in the"
    echo "      repository -- this stage wiped it. Run build/42-toolchain-repo.sh"
    echo "      before mkiso.sh, or the image ships without a compiler."
fi
