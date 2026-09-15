#!/bin/sh
# ============================================================
# run.sh — point NetSurf at the hostile corpus, ON THE TARGET
#
# RFC 0031 roadmap 4.
#
#   sh run.sh [seconds-per-page]
#
# Runs on a booted Novi with the desktop up. Serves the corpus from the
# machine itself with busybox httpd on 127.0.0.1, so nothing here
# depends on the outside world -- which also means a failure is the
# browser's and not a network's.
#
# WHAT IS MEASURED, and why it is two things:
#
#   * SURVIVAL. The process is alive when the clock runs out, or it is
#     not. A layout engine that dies on a document takes the window
#     with it, and on a machine with no per-tab isolation that is the
#     whole browser.
#   * CPU. A hang is not a crash and the liveness test cannot see one:
#     a quadratic table algorithm on 200k cells leaves a process that
#     is perfectly alive and will never finish. So the jiffies burned
#     over the window are recorded too, and a page that spends the
#     entire window at 100% is reported as SPINNING rather than as
#     passing.
#
# WHAT THIS DOES NOT ESTABLISH. It finds crashes and hangs on shapes
# somebody thought of. It says nothing about memory disclosure, nothing
# about the shapes nobody thought of, and NOTHING about the absence of
# a sandbox -- which is the standing finding and stays true whatever
# this prints. A green run means "did not fall over", never "safe".
# ============================================================
set -u

SECS="${1:-12}"
PORT=8089
DIR=/tmp/hostile
HERE="$(cd "$(dirname "$0")" && pwd)"

command -v netsurf-fb >/dev/null 2>&1 || {
    echo "ERROR: netsurf-fb is not installed (pkg install netsurf)." >&2; exit 1; }
[ -n "${WAYLAND_DISPLAY:-}" ] || {
    echo "ERROR: no WAYLAND_DISPLAY -- the desktop has to be up." >&2; exit 1; }

rm -rf "$DIR"; mkdir -p "$DIR"
sh "$HERE/generate.sh" "$DIR" || exit 1

# -f so the supervisor here is this script, not a daemon we then have
# to find again.
busybox httpd -f -p "127.0.0.1:${PORT}" -h "$DIR" &
HTTPD=$!
sleep 1
kill -0 "$HTTPD" 2>/dev/null || { echo "ERROR: httpd did not start." >&2; exit 1; }
trap 'kill "$HTTPD" 2>/dev/null' EXIT INT TERM

# Jiffies of user+system time for a pid. `$14`/`$15` cannot be written
# that way in POSIX sh -- `$14` is `$1` followed by `4`, which CLAUDE.md
# records costing a benchmark its entire meaning. `${14}` it is.
cpu_of() {
    [ -r "/proc/$1/stat" ] || { printf '0'; return; }
    # comm may contain spaces and parentheses; cut at the last ')'.
    # shellcheck disable=SC2046  # splitting into positionals is the point
    set -- $(sed 's/.*) //' "/proc/$1/stat")
    # after that cut, field 1 is `state`, so utime is 12 and stime 13.
    printf '%s' "$((${12} + ${13}))"
}

HZ=100        # CONFIG_HZ on this kernel; used only to name a percentage
pass=0; died=0; spun=0
echo
printf '%-24s %-9s %8s  %s\n' PAGE RESULT CPU% NOTE
printf '%s\n' '-------------------------------------------------------------'

for f in "$DIR"/*.html; do
    b="${f##*/}"
    [ "$b" = "index.html" ] && continue

    netsurf-fb "http://127.0.0.1:${PORT}/${b}" >/dev/null 2>&1 &
    pid=$!
    sleep 2
    if ! kill -0 "$pid" 2>/dev/null; then
        wait "$pid"; rc=$?
        printf '%-24s %-9s %8s  %s\n' "$b" "DIED" "-" "exit ${rc} within 2s"
        died=$((died + 1))
        continue
    fi
    before="$(cpu_of "$pid")"
    sleep "$SECS"

    if ! kill -0 "$pid" 2>/dev/null; then
        wait "$pid"; rc=$?
        note="exit ${rc}"
        [ "$rc" -gt 128 ] && note="KILLED BY SIGNAL $((rc - 128))"
        printf '%-24s %-9s %8s  %s\n' "$b" "DIED" "-" "$note"
        died=$((died + 1))
        continue
    fi

    after="$(cpu_of "$pid")"
    used=$((after - before))
    pct=$(( used * 100 / (SECS * HZ) ))
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null

    if [ "$pct" -ge 90 ]; then
        printf '%-24s %-9s %7s%%  %s\n' "$b" "SPINNING" "$pct" "alive, but never settled"
        spun=$((spun + 1))
    else
        printf '%-24s %-9s %7s%%  %s\n' "$b" "survived" "$pct" ""
        pass=$((pass + 1))
    fi
done

echo
printf 'survived %d, spinning %d, died %d\n' "$pass" "$spun" "$died"
echo 'A green run means "did not fall over". It does not mean safe:'
echo 'there is no sandbox around this process (RFC 0031 roadmap 4).'
[ "$died" -eq 0 ]
