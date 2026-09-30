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
#
# AND IT IS NOT NECESSARILY THE JOB PID THAT HOLDS THE NUMBER. Under
# the sandbox (RFC 0039) the shipped wrapper ends at `novi-sandbox`,
# which forks and waits; its VmPeak is 848 kB whatever the page does.
# run.sh has the long version of this. NOVI_BROWSER_SANDBOX=off in the
# environment takes the sandbox out.
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

# `pgrep httpd` cannot find one of these: a busybox applet run as
# `busybox httpd` reports `busybox` as its comm. run.sh has the long
# version. So the test is the command line, and a server already
# serving this corpus is left alone rather than duplicated.
serving=""
for d in /proc/[0-9]*; do
    [ -r "$d/cmdline" ] || continue
    case "$(tr '\0' ' ' < "$d/cmdline")" in
        *httpd*127.0.0.1:${PORT}*) serving=yes ;;
    esac
done
[ -n "$serving" ] || { busybox httpd -p "127.0.0.1:${PORT}" -h "$DIR"; sleep 1; }

total_kb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"

ppid_of() {
    [ -r "/proc/$1/stat" ] || return 1
    # shellcheck disable=SC2046  # splitting into positionals is the point
    set -- $(sed 's/.*) //' "/proc/$1/stat")
    printf '%s' "$2"
}
comm_of() { sed -e 's/^[0-9]* (//' -e 's/) .*//' "/proc/$1/stat" 2>/dev/null; }
browser_pid() {
    _root="$1"
    for _d in /proc/[0-9]*; do
        _p="${_d#/proc/}"
        [ "$(comm_of "$_p")" = netsurf-fb ] || continue
        _q="$_p"; _n=0
        while [ "$_n" -lt 8 ]; do
            [ "$_q" = "$_root" ] && { printf '%s' "$_p"; return 0; }
            _q="$(ppid_of "$_q")" || break
            [ -n "$_q" ] || break
            [ "$_q" -gt 1 ] 2>/dev/null || break
            _n=$((_n + 1))
        done
    done
    return 1
}

netsurf-fb "http://127.0.0.1:${PORT}/${PAGE}" >/dev/null 2>&1 &
p=$!
sleep 2
if ! b="$(browser_pid "$p")"; then
    kill -9 "$p" 2>/dev/null; wait "$p" 2>/dev/null
    echo "ERROR: no netsurf-fb under pid ${p} -- nothing to measure." >&2
    exit 1
fi

peak=0; hwm=0; t=2; gone=""
while [ "$t" -lt "$SECS" ]; do
    sleep 3; t=$((t + 3))
    if ! kill -0 "$p" 2>/dev/null; then gone="exited at ${t}s"; break; fi
    v="$(awk '/^VmPeak:/{print $2}' "/proc/$b/status" 2>/dev/null)"
    r="$(awk '/^VmHWM:/{print $2}'  "/proc/$b/status" 2>/dev/null)"
    [ -n "${v:-}" ] && peak="$v"
    [ -n "${r:-}" ] && hwm="$r"
done

# -9, and the browser first: a sandboxed browser is pid 1 of its own
# namespace, where a default-action SIGTERM from outside is discarded
# and kill(2) still returns 0.
[ "$b" = "$p" ] || kill -9 "$b" 2>/dev/null
kill -9 "$p" 2>/dev/null; wait "$p" 2>/dev/null

note="${gone:-still running at ${SECS}s}"
case "$LIMIT" in
    off|none|0) ;;
    *) [ "$((peak * 1024))" -ge "$LIMIT" ] && note="$note, AT THE CEILING" ;;
esac

printf '%-22s VmPeak %7s kB  VmHWM %7s kB  (%s%% of %s kB)  %s\n' \
    "$PAGE" "$peak" "$hwm" "$(( hwm * 100 / total_kb ))" "$total_kb" "$note"
