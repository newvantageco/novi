#!/bin/bash
# ============================================================
# 31-desktop-split.sh — Remove the desktop from the base image
#
# RFC 0007. §2 of the platform roadmap wants a small native base with
# everything else delivered as packages. Until now the desktop was in
# the base image AND in the repository, which is the architecture
# described rather than the one shipped.
#
# This stage deletes exactly the files build/30-repo.sh packaged, using
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
    echo "ERROR: ${MANIFEST} not found -- run build/30-repo.sh first." >&2
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

# Prune directories the removal emptied. rmdir rather than rm -rf, so a
# directory that still holds something survives untouched.
#
# usr/include is in this list because RFC 0015 made the headers a
# package too: without it the base kept empty directories named after
# libraries it no longer contains, which reads like a broken install
# rather than a deliberate one.
#
# The loop is not belt-and-braces. `find -depth -type d -empty -exec
# rmdir {} +` looks like it handles nesting and does not: -empty is
# evaluated during the traversal, so a parent that still contains an
# about-to-be-deleted empty child is not empty *at the moment it is
# tested*. One pass removes only the deepest level. That left
# usr/include/alsa/sound behind as a three-deep chain of empty
# directories, and would have quietly done the same under usr/share for
# as long as this script has existed. Repeat until a pass changes
# nothing; bounded so a bug here cannot spin forever.
prune_pass() {
    find "${ROOTFS}/usr/share" "${ROOTFS}/usr/lib" "${ROOTFS}/etc/fonts" \
         "${ROOTFS}/usr/include" \
         -depth -type d -empty -print -exec rmdir {} + 2>/dev/null | wc -l
}
for _ in 1 2 3 4 5 6 7 8; do
    [ "$(prune_pass)" -eq 0 ] && break
done

AFTER="$(du -sh "${ROOTFS}" | cut -f1)"

echo ""
echo "Desktop removed from the base image:"
echo "  files removed : ${removed}"
echo "  already gone  : ${missing}"
echo "  rootfs        : ${BEFORE} -> ${AFTER}"
echo ""
echo "The desktop now lives only in the repository (${BUILD_DIR}/repo)."
echo "Install it on a running system with:  pkg install novi-desktop"
