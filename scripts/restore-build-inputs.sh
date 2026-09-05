#!/bin/bash
# ============================================================
# restore-build-inputs.sh — put the desktop's libraries and headers
# back into the rootfs after 31-desktop-split.sh has removed them.
#
#   bash scripts/restore-build-inputs.sh
#
# Why this exists
# ---------------
# 31-desktop-split.sh deletes everything 30-repo.sh packaged, which
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
    echo "ERROR: no repository at ${REPO_OUT} -- run build/30-repo.sh first." >&2
    exit 1
}

# Packages that are toolchain, not desktop. These install to the same
# prefixes but belong only in the repository; restoring them would put
# ~270 MB of compiler into a console base image that is meant to be
# 788 MB in total, and the next 30-repo.sh run would not remove them
# because pkgsplit does not claim them.
#
# novi-headers is deliberately NOT in this list, though it looks like it
# belongs: it holds the headers and .pc files for the shipped libraries,
# which is precisely what a GUI client needs to compile. musl-dev is the
# one that is excluded, because those are the musl and kernel headers
# the cross-compiler already has in its own sysroot. Getting this
# backwards restores 26 packages and zero headers, and the build fails
# in exactly the same way it did before you ran this.
SKIP='gcc|binutils|make|pkgconf|musl-dev|novi-devel'

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

count=0
for f in "${REPO_OUT}"/*.pkg.tar.gz; do
    [ -e "${f}" ] || continue
    base="$(basename "${f}")"
    name="${base%%-[0-9]*}"
    if [[ "${name}" =~ ^(${SKIP})$ ]]; then
        continue
    fi
    tar xzf "${f}" -C "${WORK}" 2>/dev/null || true
    count=$(( count + 1 ))
done

[ -d "${WORK}/files" ] || {
    echo "ERROR: no package contents unpacked -- is ${REPO_OUT} populated?" >&2
    exit 1
}

cp -a "${WORK}/files/." "${ROOTFS}/"

echo "Restored build inputs from ${count} package(s) into ${ROOTFS}"
echo "  headers : $(find "${ROOTFS}/usr/include" -type f 2>/dev/null | wc -l) file(s)"
echo "  pkgconfig: $(find "${ROOTFS}/usr/lib/pkgconfig" -type f 2>/dev/null | wc -l) file(s)"
echo ""
echo "This is for rebuilding a client in place. Run build/30-repo.sh and"
echo "build/31-desktop-split.sh again before making an image."
