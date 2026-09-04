#!/bin/bash
# ============================================================
# 21-desktop-split.sh — Remove the desktop from the base image
#
# RFC 0007. §2 of the platform roadmap wants a small native base with
# everything else delivered as packages. Until now the desktop was in
# the base image AND in the repository, which is the architecture
# described rather than the one shipped.
#
# This stage deletes exactly the files build/20-repo.sh packaged, using
# the manifest that stage wrote. It does not have its own idea of what
# the desktop is -- one source of truth for the split, computed from
# the ELF dependency graph, or the two drift apart and the image ends
# up either broken or still fat.
#
# DESTRUCTIVE, and re-running 06..14 puts the files back. That is the
# intended workflow: build everything, package the desktop, then shrink
# the base. `bash build.sh` runs the stages in that order.
#
# The s6 service definitions for seatd/novi-shell and the `graphical`
# bundle deliberately STAY in the base. They are text in a compiled
# database, they cost nothing, and a machine that installs
# novi-desktop should be able to `novi-state set services.novi-shell on`
# without also needing a new service database. s6-rc does not check
# that a run script's binary exists, so a declared-off service pointing
# at a not-yet-installed binary is inert, not broken.
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-versions.sh"

MANIFEST="${BUILD_DIR}/repo-desktop-files.list"
[ -f "${MANIFEST}" ] || {
    echo "ERROR: ${MANIFEST} not found -- run build/20-repo.sh first." >&2
    exit 1
}

BEFORE="$(du -sh "${ROOTFS}" | cut -f1)"

removed=0
missing=0
while IFS= read -r rel; do
    [ -n "${rel}" ] || continue
    target="${ROOTFS}/${rel}"
    # -e is false for a dangling symlink; -L catches those. A library's
    # soname link can outlive its target if the order here ever changes.
    if [ -e "${target}" ] || [ -L "${target}" ]; then
        rm -f "${target}"
        removed=$(( removed + 1 ))
    else
        missing=$(( missing + 1 ))
    fi
done < "${MANIFEST}"

# Prune directories the removal emptied. -depth so children go first;
# rmdir rather than rm -rf so a directory that still holds something
# survives untouched.
find "${ROOTFS}/usr/share" "${ROOTFS}/usr/lib" "${ROOTFS}/etc/fonts" \
     -depth -type d -empty -exec rmdir {} + 2>/dev/null || true

AFTER="$(du -sh "${ROOTFS}" | cut -f1)"

echo ""
echo "Desktop removed from the base image:"
echo "  files removed : ${removed}"
echo "  already gone  : ${missing}"
echo "  rootfs        : ${BEFORE} -> ${AFTER}"
echo ""
echo "The desktop now lives only in the repository (${BUILD_DIR}/repo)."
echo "Install it on a running system with:  pkg install novi-desktop"
