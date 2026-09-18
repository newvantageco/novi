#!/bin/sh
# ============================================================
# settle.sh — do the busy pages FINISH?
#
# RFC 0031 roadmap 4, second half. run.sh reports a page that spent its
# whole window at 100% CPU as SPINNING, and on this target that verdict
# alone means very little: the guest is TCG-emulated with a software
# renderer, and several of these documents are genuinely enormous (4 MB
# of unbreakable text, 200k elements). Ten seconds of hard work is what
# a big document looks like here.
#
# SLOW AND UNBOUNDED ARE DIFFERENT FINDINGS and only the second is a
# denial of service, so this samples CPU over two minutes and reports
# when each page goes quiet — or that it never did. Reporting the
# stronger claim off run.sh's ten-second window would be exactly the
# mistake this repository keeps recording.
#
#   sh settle.sh        (after run.sh has generated /tmp/hostile)
# ============================================================
set -u
PORT=8089; DIR=/tmp/hostile
busybox httpd -f -p "127.0.0.1:${PORT}" -h "$DIR" & H=$!
sleep 1; trap 'kill $H 2>/dev/null' EXIT

cpu_of() { [ -r "/proc/$1/stat" ] || { printf 0; return; }
  # shellcheck disable=SC2046  # splitting into positionals is the point
  set -- $(sed 's/.*) //' "/proc/$1/stat"); printf '%s' "$((${12} + ${13}))"; }

for b in deep-nesting.html huge-table.html long-line.html many-siblings.html unclosed-tags.html; do
    netsurf-fb "http://127.0.0.1:${PORT}/${b}" >/dev/null 2>&1 & p=$!
    sleep 2
    prev=0; settled=""; t=0
    while [ "$t" -lt 120 ]; do
        a="$(cpu_of "$p")"; sleep 5; t=$((t + 5))
        b2="$(cpu_of "$p")"
        kill -0 "$p" 2>/dev/null || { settled="DIED at ${t}s"; break; }
        d=$((b2 - a))
        # under 10% of a 5s window (500 jiffies) counts as quiet
        if [ "$d" -lt 50 ]; then settled="settled by ${t}s (${d} jiffies in last 5s)"; break; fi
        prev=$d
    done
    [ -n "$settled" ] || settled="STILL BUSY at 120s (${prev} jiffies in last 5s)"
    printf '%-22s %s\n' "$b" "$settled"
    kill "$p" 2>/dev/null; wait "$p" 2>/dev/null
done
