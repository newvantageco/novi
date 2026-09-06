#!/bin/bash
# ============================================================
# restore-build-inputs.sh — put the desktop's libraries and headers
# back into the rootfs after 41-desktop-split.sh has removed them.
#
#   bash scripts/restore-build-inputs.sh
#
# Why this exists
# ---------------
# 41-desktop-split.sh deletes everything 40-repo.sh packaged, which
# includes every desktop library and (since RFC 0015) every header. So
# after a full build, the rootfs cannot compile a GUI client: change
# one line in novi-files/main.c and `bash build/20-novi-files.sh`
# stops at `wayland-util.h: No such file or directory`.
#
# The documented answer is "re-running stages 06..14 puts the files
# back", and that is correct and takes fifteen minutes. This does the
# same thing in a second, by unpacking the packages those stages
# already produced -- which is exactly what the split removed, so it
# restores precisely what was taken and nothing else.
#
# It exists because the ad-hoc version of it went badly. Extracting
# *every* package over the rootfs also restores the native toolchain
# (270 MB that belongs in packages, not the base image), and cleaning
# that up afterwards with a hand-written `rm` loop produced a tree
# nobody could reason about and an image that reached s6-linux-init and
# never started stage 2. The toolchain packages are excluded here by
# name, in one place, where the exclusion can be seen and checked.
#
# This is a DEVELOPMENT convenience. It is not part of `bash build.sh`
# and must not become one: a release build runs the stages in order,
# where the libraries are present because they were just built.
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../build/00-versions.sh"

REPO_OUT="${BUILD_DIR}/repo"
[ -d "${REPO_OUT}" ] || {
    echo "ERROR: no repository at ${REPO_OUT} -- run build/40-repo.sh first." >&2
    exit 1
}

# WHAT GETS RESTORED IS DERIVED, NOT LISTED.
#
# 40-repo.sh writes ${MANIFEST} -- every file pkgsplit moved out of the
# base image -- so "put back what the split took" is a question that
# already has a written answer. Restoring exactly those paths cannot go
# wrong as the repository grows.
#
# It used to be the other way round: unpack every package except a
# hand-maintained blocklist of toolchain names. That was right until
# the repository gained a package that was neither desktop nor
# toolchain. RFC 0019 added `git` and `openssh`, this script cheerfully
# installed them into the console base image, and the next 40-repo.sh
# failed with pkgsplit's straddle check -- "usr/lib/libz.so.1 stays,
# usr/lib/libz.so moves" -- because a base binary now linked zlib. The
# error was correct and named nothing that would lead you here. A
# blocklist has to be updated by whoever adds the next package, and
# nothing tells them.
MANIFEST="${BUILD_DIR}/repo-desktop-files.list"

[ -s "${MANIFEST}" ] || {
    echo "ERROR: no split manifest at ${MANIFEST}." >&2
    echo "       It is written by build/40-repo.sh; run that first." >&2
    exit 1
}

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Unpack everything, then copy back only what the manifest names. The
# unpack is cheap and the filter is the part that has to be right.
count=0
for f in "${REPO_OUT}"/*.pkg.tar.gz; do
    [ -e "${f}" ] || continue
    tar xzf "${f}" -C "${WORK}" 2>/dev/null || true
    count=$(( count + 1 ))
done

[ -d "${WORK}/files" ] || {
    echo "ERROR: no package contents unpacked -- is ${REPO_OUT} populated?" >&2
    exit 1
}

restored=0
missing=0
while IFS= read -r rel; do
    [ -n "${rel}" ] || continue
    src="${WORK}/files/${rel}"
    # -e follows symlinks and a soname link whose target has not been
    # unpacked yet would look absent, so test for the link too.
    if [ -e "${src}" ] || [ -L "${src}" ]; then
        mkdir -p "${ROOTFS}/$(dirname "${rel}")"
        cp -a "${src}" "${ROOTFS}/${rel}"
        restored=$(( restored + 1 ))
    else
        missing=$(( missing + 1 ))
    fi
done < "${MANIFEST}"

echo "Restored ${restored} file(s) into ${ROOTFS} from ${count} package(s)"
echo "  (the manifest 40-repo.sh wrote: $(wc -l < "${MANIFEST}") path(s))"
if [ "${missing}" -gt 0 ]; then
    echo "  WARNING: ${missing} manifest path(s) were in no package -- the" >&2
    echo "           manifest and the repository are out of step." >&2
fi
echo "  headers : $(find "${ROOTFS}/usr/include" -type f 2>/dev/null | wc -l) file(s)"
echo "  pkgconfig: $(find "${ROOTFS}/usr/lib/pkgconfig" -type f 2>/dev/null | wc -l) file(s)"
echo ""
echo "This is for rebuilding a client in place. Run build/40-repo.sh and"
echo "build/41-desktop-split.sh again before making an image."
