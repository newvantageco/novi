#!/bin/bash
# ============================================================
# 16-s6-rc-db.sh — Regenerate the init trees from init/
#
# build/04-s6.sh already does both of these, but only as part of
# building the entire skarnet stack from source (skalibs -> execline ->
# s6 -> s6-rc -> s6-linux-init), which is minutes of compilation to
# pick up a one-line change under init/.
#
# This stage is just the two generation steps, so editing a service or
# a boot script is a seconds-long operation:
#
#   init/services/  -> /etc/s6-rc/compiled       (s6-rc-compile)
#   init/skel/      -> /etc/s6-linux-init/       (s6-linux-init-maker)
#
# Run it after ANY change under init/. Both targets are *generated* --
# the running system reads the compiled database and the generated
# scripts, never the source directories -- so an unregenerated change
# simply does not exist as far as boot is concerned.
#
# Deliberately numbered last: later build stages may add services of
# their own, and these have to be generated after all of them.
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/00-versions.sh"

[ -x "${ROOTFS}/usr/bin/s6-rc-compile" ] || {
    echo "ERROR: ${ROOTFS}/usr/bin/s6-rc-compile not found -- run build/04-s6.sh first." >&2
    exit 1
}

# Same musl-loader trick build/04-s6.sh documents: s6-rc-compile is a
# TARGET binary, but the target arch matches this build host, so musl's
# own dynamic linker can load it directly rather than needing a second
# host-native build of the whole skarnet stack.
MUSL_LOADER="${ROOTFS}/lib/ld-musl-x86_64.so.1"
run_target() {
    LD_LIBRARY_PATH="${ROOTFS}/usr/lib" "${MUSL_LOADER}" "$@"
}

echo "==> Compiling s6-rc service database"
# Compile to a temporary path and swap it in only on success: a failed
# compile that had already deleted the old database would leave the
# rootfs with no service database at all, which is an unbootable image.
rm -rf "${ROOTFS}/etc/s6-rc/compiled.new"
mkdir -p "${ROOTFS}/etc/s6-rc"
run_target "${ROOTFS}/usr/bin/s6-rc-compile" \
    "${ROOTFS}/etc/s6-rc/compiled.new" "${REPO_ROOT}/init/services"
rm -rf "${ROOTFS}/etc/s6-rc/compiled"
mv "${ROOTFS}/etc/s6-rc/compiled.new" "${ROOTFS}/etc/s6-rc/compiled"

echo "==> Regenerating the s6-linux-init runtime tree"
# Same flags build/04-s6.sh uses -- see its own comments for why -f and
# -p have to be given explicitly (the compiled-in defaults are host
# paths baked in at configure time, and the default PATH omits /sbin).
rm -rf "${BUILD_DIR}/s6-linux-init-gen"
run_target "${ROOTFS}/usr/bin/s6-linux-init-maker" \
    -c /etc/s6-linux-init \
    -f "${REPO_ROOT}/init/skel" \
    -p "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    -N "${BUILD_DIR}/s6-linux-init-gen"

# Only the generated subtrees are replaced. /sbin/init and friends are
# left alone: they are the same binaries 04-s6.sh already installed,
# and reinstalling PID 1 is not something a "re-read init/" stage
# should be doing.
rm -rf "${ROOTFS}/etc/s6-linux-init"
mkdir -p "${ROOTFS}/etc/s6-linux-init"
cp -a "${BUILD_DIR}/s6-linux-init-gen/env" \
      "${BUILD_DIR}/s6-linux-init-gen/run-image" \
      "${BUILD_DIR}/s6-linux-init-gen/scripts" \
      "${ROOTFS}/etc/s6-linux-init/"
rm -rf "${BUILD_DIR}/s6-linux-init-gen"

echo ""
echo "Services in the compiled database:"
ls "${REPO_ROOT}/init/services"
