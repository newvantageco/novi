#!/bin/sh
# ============================================================
# run.sh — serve the JavaScript probe pages to NetSurf
#
# RFC 0031 roadmap 2. These pages exist to answer "what would
# JavaScript actually buy this browser", and the answer they gave was
# "not enough" -- see the README and the RFC. They are kept so the
# next person can re-run the measurement rather than re-argue it.
#
#   sh run.sh            serve on 127.0.0.1:8090 and print the URL
#
# TWO THINGS HAVE TO BE TRUE before any of it means anything, and both
# are silent when they are not:
#
#   1. The browser must be built with NETSURF_USE_DUKTAPE=YES. The
#      shipped one is NOT (that is the decision), so against a stock
#      Novi every page here reports the no-script answer -- which is a
#      valid result and not a broken harness.
#   2. `enable_javascript:1` must be in **~/.netsurf/Choices**. The
#      option defaults to FALSE upstream, and the framebuffer frontend
#      reads Choices off its RESOURCE path -- not ~/.config/netsurf,
#      which is where it was first put, and where it did nothing at
#      all.
# ============================================================
set -u
PORT=8090
DIR="$(cd "$(dirname "$0")" && pwd)"

command -v netsurf-fb >/dev/null 2>&1 || {
    echo "ERROR: netsurf-fb is not installed (pkg install netsurf)." >&2; exit 1; }
[ -n "${WAYLAND_DISPLAY:-}" ] || {
    echo "WARNING: no WAYLAND_DISPLAY -- the browser needs the desktop up." >&2; }

if [ ! -f "${HOME}/.netsurf/Choices" ] ||
   ! grep -q '^enable_javascript:1' "${HOME}/.netsurf/Choices" 2>/dev/null; then
    echo "NOTE: ~/.netsurf/Choices does not enable javascript. Every page"
    echo "      here will report the no-script answer. To change that:"
    echo "        mkdir -p ~/.netsurf && echo enable_javascript:1 > ~/.netsurf/Choices"
fi

busybox httpd -f -p "127.0.0.1:${PORT}" -h "${DIR}" &
H=$!
trap 'kill $H 2>/dev/null' EXIT INT TERM
sleep 1
echo "serving ${DIR} at http://127.0.0.1:${PORT}/"
echo "  netsurf-fb http://127.0.0.1:${PORT}/index.html"
wait "$H"
