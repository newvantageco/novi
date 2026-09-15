#!/bin/sh
# ============================================================
# memcheck.sh — peak memory, one page at a time
#
# RFC 0031 roadmap 4's third instrument, and for a while its missing
# one: two attempts to produce a per-page table ended with the guest at
# 110% CPU and 4.9 GB of host RSS, an unresponsive console, and this
# script too starved to run the kill it was holding. The README said so
# rather than shipping numbers it could not measure.
#
# **The bound from roadmap 5 is what made the table possible.** With
# the browser capped at an address space it cannot exceed, the harness
# is no longer racing the thing it is measuring -- so the measurement
# the missing bound prevented is taken by the bound that replaced it.
#
# VmPeak, not just VmHWM. RLIMIT_AS bounds ADDRESS SPACE, so VmPeak is
# the number the ceiling is compared against; VmHWM is resident and on
# a process with mmap'd fonts and shm buffers the two differ. Both are
# printed: one says what the bound sees, the other what the machine
# pays.
#
#   sh memcheck.sh <page.html> [seconds] [bytes|off]
#
# One page per invocation, deliberately. A loop over all of them is
# what wedged the machine, and a measurement you cannot read is not a
# measurement. `off` removes the bound and is how the pre-roadmap-5
# behaviour is reproduced -- do not walk away from it.
# ============================================================
set -u
PAGE="${1:?usage: memcheck.sh <page.html> [seconds] [bytes|off]}"
SECS="${2:-45}"
LIMIT="${3:-1073741824}"
PORT=8089
DIR=/tmp/hostile

[ -f "$DIR/$PAGE" ] || { echo "ERROR: $DIR/$PAGE is not there (run generate.sh)." >&2; exit 1; }
[ -n "${WAYLAND_DISPLAY:-}" ] || { echo "ERROR: no WAYLAND_DISPLAY." >&2; exit 1; }
command -v netsurf-fb >/dev/null 2>&1 || {
    echo "ERROR: netsurf-fb is not installed (pkg install netsurf)." >&2; exit 1; }

# The limit reaches the browser through the shipped wrapper's own
# variable, so this measures the path a person gets rather than a
# second arrangement built for the test. On a build predating that
# wrapper the variable is simply ignored -- and then `off` is what you
# are measuring whatever you asked for.
NOVI_BROWSER_AS_LIMIT="$LIMIT"
export NOVI_BROWSER_AS_LIMIT

pgrep httpd >/dev/null 2>&1 || { busybox httpd -p "127.0.0.1:${PORT}" -h "$DIR"; sleep 1; }

total_kb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"

netsurf-fb "http://127.0.0.1:${PORT}/${PAGE}" >/dev/null 2>&1 &
p=$!

peak=0; hwm=0; t=0; gone=""
while [ "$t" -lt "$SECS" ]; do
    sleep 3; t=$((t + 3))
    if ! kill -0 "$p" 2>/dev/null; then gone="exited at ${t}s"; break; fi
    v="$(awk '/^VmPeak:/{print $2}' "/proc/$p/status" 2>/dev/null)"
    r="$(awk '/^VmHWM:/{print $2}'  "/proc/$p/status" 2>/dev/null)"
    [ -n "${v:-}" ] && peak="$v"
    [ -n "${r:-}" ] && hwm="$r"
done

kill "$p" 2>/dev/null; wait "$p" 2>/dev/null

note="${gone:-still running at ${SECS}s}"
case "$LIMIT" in
    off|none|0) ;;
    *) [ "$((peak * 1024))" -ge "$LIMIT" ] && note="$note, AT THE CEILING" ;;
esac

printf '%-22s VmPeak %7s kB  VmHWM %7s kB  (%s%% of %s kB)  %s\n' \
    "$PAGE" "$peak" "$hwm" "$(( hwm * 100 / total_kb ))" "$total_kb" "$note"
