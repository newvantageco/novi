#!/bin/sh
# ============================================================
# memcheck.sh — peak memory, one page at a time
#
# RFC 0031 roadmap 4, third instrument. run.sh measures survival and
# CPU; neither of those sees the axis that actually matters for a
# browser with no sandbox around it.
#
# THIS WAS FOUND THE HARD WAY. A first attempt to time how long the
# busy pages take to settle never returned: the guest sat at 110% CPU
# and 4.9 GB of host RSS with an unresponsive console, and no amount of
# waiting produced a result. That is not a hang to be waited out -- it
# is one of these pages driving the layout engine into the machine's
# entire memory, which on a system with no per-tab isolation takes the
# browser, the session and anything else that wanted to allocate.
#
# So: ONE PAGE PER INVOCATION, a hard deadline, and `VmHWM` -- the
# kernel's own high-water mark for resident memory, which survives the
# process being killed before it can be asked nicely.
#
#   sh memcheck.sh <page.html> [seconds]
#
# Run it one page at a time deliberately. A loop over all of them is
# what wedged the machine, and a measurement you cannot read is not a
# measurement.
# ============================================================
set -u
PAGE="${1:?usage: memcheck.sh <page.html> [seconds]}"
SECS="${2:-45}"
PORT=8089
DIR=/tmp/hostile

[ -f "$DIR/$PAGE" ] || { echo "ERROR: $DIR/$PAGE is not there (run generate.sh)." >&2; exit 1; }
[ -n "${WAYLAND_DISPLAY:-}" ] || { echo "ERROR: no WAYLAND_DISPLAY." >&2; exit 1; }

pgrep httpd >/dev/null 2>&1 || { busybox httpd -p "127.0.0.1:${PORT}" -h "$DIR"; sleep 1; }

total_kb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"

netsurf-fb "http://127.0.0.1:${PORT}/${PAGE}" >/dev/null 2>&1 &
p=$!

peak=0; t=0; gone=""
while [ "$t" -lt "$SECS" ]; do
    sleep 3; t=$((t + 3))
    if ! kill -0 "$p" 2>/dev/null; then gone="exited at ${t}s"; break; fi
    # VmHWM is the peak, so the last reading before death is the answer
    # -- no need to track a maximum across samples, but read it every
    # tick anyway so a process killed by the OOM killer still leaves
    # one behind here.
    hwm="$(awk '/^VmHWM:/{print $2}' "/proc/$p/status" 2>/dev/null)"
    [ -n "${hwm:-}" ] && peak="$hwm"
done

kill "$p" 2>/dev/null; wait "$p" 2>/dev/null

pct=$(( peak * 100 / total_kb ))
printf '%-22s peak RSS %6s kB  (%s%% of %s kB) %s\n' \
    "$PAGE" "$peak" "$pct" "$total_kb" "${gone:-still running at ${SECS}s}"
