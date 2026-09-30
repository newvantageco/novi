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
# WHICH BROWSER IS MEASURED, and why that is a question at all. The
# shipped wrapper execs `novi-sandbox` (RFC 0039), which FORKS -- a new
# PID namespace takes effect for children, not for the process that
# asked for it -- and waits. So the pid the shell hands back is the
# supervisor's, and reading /proc/<that>/stat measures a process
# blocked in waitpid(2): 0% CPU and 848 kB of address space, measured,
# on a page burning 98% of a core three lines down in the same probe.
# Unchanged, this script would have reported the entire corpus as
# harmless the day the sandbox shipped, which is the strongest possible
# result and a false one. `browser_pid()` finds the process that is
# actually the browser, and a run that cannot find it says so instead
# of printing a number about something else.
#
# NOVI_BROWSER_SANDBOX=off in the environment takes the sandbox out,
# which is how the two columns of RFC 0039 roadmap 1's table were
# taken. The header says which one this run is.
#
# WHAT THIS DOES NOT ESTABLISH. It finds crashes and hangs on shapes
# somebody thought of. It says nothing about memory disclosure, and
# nothing about the shapes nobody thought of. The sandbox bounds what a
# page that fails can REACH; it does not stop it failing, and neither
# this script nor that boundary makes a green run mean "safe".
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

# A SERVER THIS SCRIPT LEFT BEHIND WILL NOT BE FOUND BY NAME. A
# busybox applet invoked as `busybox httpd` has `busybox` as its comm,
# so `pgrep httpd` and `pkill -x httpd` both miss it -- watched live,
# as `httpd: bind: Address in use` from a run whose first line had just
# tried to clear the port. Match the command line instead.
for d in /proc/[0-9]*; do
    p="${d#/proc/}"
    [ -r "$d/cmdline" ] || continue
    case "$(tr '\0' ' ' < "$d/cmdline")" in
        *httpd*127.0.0.1:${PORT}*) kill "$p" 2>/dev/null ;;
    esac
done

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

# Fields after the comm is cut away: 1 state, 2 ppid. Same cut as
# cpu_of, and for the same reason -- a process may name itself
# anything, parentheses included, so counting from the left is not a
# parse (common/procstat.c has the long version).
ppid_of() {
    [ -r "/proc/$1/stat" ] || return 1
    # shellcheck disable=SC2046  # splitting into positionals is the point
    set -- $(sed 's/.*) //' "/proc/$1/stat")
    printf '%s' "$2"
}

comm_of() { sed -e 's/^[0-9]* (//' -e 's/) .*//' "/proc/$1/stat" 2>/dev/null; }

# The browser is $1 itself (no sandbox) or a descendant of it (one
# fork, today). Walking UP from each netsurf-fb to $1 rather than down
# is what keeps a runaway left over from an earlier page out of this
# page's numbers: an unrelated browser is not below $1 whatever it is
# doing.
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

HZ=100        # CONFIG_HZ on this kernel; used only to name a percentage
pass=0; died=0; spun=0; blind=0
case "${NOVI_BROWSER_SANDBOX:-on}" in
    off|none|0) mode="NO SANDBOX" ;;
    *) mode="sandboxed (novi-sandbox)"
       command -v novi-sandbox >/dev/null 2>&1 ||
           mode="asked for a sandbox and novi-sandbox is not installed" ;;
esac
echo
echo "browser: ${mode}"
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
    # Resolve once, here: `bp` is the thing being measured from now on
    # and `pid` is only the job to reap.
    if ! bp="$(browser_pid "$pid")"; then
        printf '%-24s %-9s %8s  %s\n' "$b" "UNMEASURED" "-" \
            "no netsurf-fb under pid ${pid}"
        blind=$((blind + 1))
        kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
        continue
    fi
    before="$(cpu_of "$bp")"
    sleep "$SECS"

    if ! kill -0 "$pid" 2>/dev/null; then
        wait "$pid"; rc=$?
        note="exit ${rc}"
        [ "$rc" -gt 128 ] && note="KILLED BY SIGNAL $((rc - 128))"
        printf '%-24s %-9s %8s  %s\n' "$b" "DIED" "-" "$note"
        died=$((died + 1))
        continue
    fi

    after="$(cpu_of "$bp")"
    used=$((after - before))
    pct=$(( used * 100 / (SECS * HZ) ))
    # -9 on both, and on the browser FIRST. A sandboxed browser is pid
    # 1 of its own namespace, and the kernel discards a default-action
    # signal sent to such a process from outside it -- `kill` returns 0
    # and nothing happens. That is measured; novi-sandbox's own comment
    # has the rule. Leaving one of these behind is how this corpus took
    # the machine down twice.
    [ "$bp" = "$pid" ] || kill -9 "$bp" 2>/dev/null
    kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null

    if [ "$pct" -ge 90 ]; then
        printf '%-24s %-9s %7s%%  %s\n' "$b" "SPINNING" "$pct" "alive, but never settled"
        spun=$((spun + 1))
    else
        printf '%-24s %-9s %7s%%  %s\n' "$b" "survived" "$pct" ""
        pass=$((pass + 1))
    fi
done

echo
printf 'survived %d, spinning %d, died %d, unmeasured %d\n' \
    "$pass" "$spun" "$died" "$blind"

# A leftover is both a leak and a reason to distrust every row after
# it: the next page's CPU is measured on a machine already running one.
# Worth checking rather than assuming, because the way to leave one
# behind is not obvious -- see the kill above.
for d in /proc/[0-9]*; do
    p="${d#/proc/}"
    [ "$(comm_of "$p")" = netsurf-fb ] && echo "LEFTOVER: netsurf-fb pid ${p}"
done

echo 'A green run means "did not fall over". It does not mean safe.'
echo 'The sandbox (RFC 0039) bounds what a page that fails can reach;'
echo 'it does not stop the page failing, and nothing here tests for'
echo 'memory disclosure or for shapes nobody thought of.'
[ "$died" -eq 0 ] && [ "$blind" -eq 0 ]
