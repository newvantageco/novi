#!/bin/bash
# RFC 0037 roadmap 3, the half a host test cannot reach: the SESSION.
#
# Three claims, each currently reasoned-from-mechanism in the RFC:
#   1. novi-shell's service exports HOME, so the compositor and the
#      clients it spawns resolve the same per-user file.
#   2. ~/.config/novi/keys.conf is applied after /etc and therefore
#      wins, per action, with the machine's other lines inherited.
#   3. the Keys panel writes the USER file, leaving /etc untouched.
set -u
cd "$(dirname "$0")"
. ./lib.sh

ISO="${1:-/home/user/novi/build/novi.iso}"
[ -f "$ISO" ] || die "no ISO at $ISO"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
check() { if [ "$1" = 0 ]; then ok "$2"; else bad "$2"; fi; }

trap vm_stop EXIT
vm_start "$ISO"

log "waiting for the login prompt"
wait_for "login:" 300 0 || die "never reached a login prompt"
OFF="$(mark)"
send "root"
# Wait for the SHELL PROMPT, not a timer: sending on a timer races the
# prompt and produces a column of 'Password:'.
wait_for "~#" 60 "$OFF" || die "never got a shell prompt"
log "logged in"

echo
# THE SUPPORTED BRING-UP, not a hand-rolled one. The first version of
# this harness ran `novi-state set services.novi-shell on` + `apply`
# and watched the machine oscillate -- novi-shell off->on, seatd
# on->off, three passes, never settling. novi-live-desktop declares
# services.seatd on AS WELL, so leaving it out made every pass raise
# the graphical bundle and then take seatd down to match a document
# that still said off. A harness that invents its own version of a
# sequence the image ships is measuring the invention.
echo "== the desktop, via the script the Live Desktop entry runs"
run "novi-live-desktop" 900 >/dev/null || die "novi-live-desktop did not return"
# Never trust its own last line: every step of it ends in `|| true`,
# so it prints "desktop ready" whatever happened (CLAUDE.md records
# exactly that costing five boots). Ask the process table.
OFF="$(mark)"
# The marker is split across printf's format and argument, or it lands
# in the line the console echoes back and the test answers about its
# own command rather than about the machine.
out="$(run "pgrep -x novi-shell || printf 'NO%s\\n' SHELL" 60)"
case "$out" in *NOSHELL*) die "novi-shell is not running" ;; esac
log "compositor up"

echo
echo "== 1. the session's environment"
out="$(run "tr '\\0' '\\n' < /proc/\$(pgrep -x novi-shell)/environ | grep -E '^(HOME|XDG_RUNTIME_DIR)=' | sort")"
printf '%s\n' "$out" | grep -q 'HOME=/root'; check $? "novi-shell has HOME=/root"
printf '%s\n' "$out" | grep -q 'XDG_RUNTIME_DIR=/run/user/0'; check $? "and still has XDG_RUNTIME_DIR"

echo
echo "== 2a. CONTROL: a keystroke reaches the compositor at all"
# Counting with `pgrep -x foot | wc -l`, never `pgrep -c`: busybox
# pgrep takes [-flanovx] and has no -c, so `pgrep -c -x foot` printed
# its usage and exited non-zero -- and the `|| 0` fallback reported
# zero terminals on a machine whose compositor log showed foot mapping
# a window two lines earlier. The probe was broken, not the product.
# Without this the two checks below cannot tell "the user's line moved
# the binding" from "no key arrived": a guest with no keyboard fails
# the first and PASSES the second, which is what run 2 reported.
sleep 3
qmp '{"execute":"send-key","arguments":{"keys":[{"type":"qcode","data":"meta_l"},{"type":"qcode","data":"ret"}]}}' >/dev/null
sleep 6
out="$(run "pgrep -x foot | wc -l")"
n_ctrl="$(printf '%s\n' "$out" | grep -oE '^[0-9]+$' | head -1)"
[ "${n_ctrl:-0}" -ge 1 ]; check $? "Super+Return opens a terminal with the SHIPPED bindings"
[ "${n_ctrl:-0}" -ge 1 ] || die "no keystroke reaches the guest -- every binding check below would be meaningless"
run "pkill -x foot || true" >/dev/null; sleep 2

echo
echo "== 2. two files, and which one wins"
# The machine's file sets two actions; the user's file overrides ONE of
# them. So the run proves precedence AND per-action layering at once --
# if it replaced wholesale, find.themes would fall back to its default.
run "printf 'window.terminal = Super+Shift+Y\nfind.themes = Super+Y\n' >> /etc/novi/keys.conf" >/dev/null
run "mkdir -p /root/.config/novi && printf 'window.terminal = Super+Shift+T\n' > /root/.config/novi/keys.conf" >/dev/null
OFF="$(mark)"
run "s6-rc -d change graphical && s6-rc -u change graphical" 120 >/dev/null
wait_for "keys:" 60 "$OFF" || log "no keys: line on the console; looking in the logs"
# A supervised longrun's stderr goes to the catch-all logger, not to
# syslog's file -- look in both rather than guess which.
out="$(run "cat /run/uncaught-logs/current /var/log/messages 2>/dev/null | grep -o 'keys:.*' | tail -1")"
printf '%s\n' "$out" | grep -q '/etc/novi/keys.conf then /root/.config/novi/keys.conf'
check $? "the compositor names both files, in order"

echo "== 2b. and the bindings that actually fire"
sleep 2
qmp '{"execute":"send-key","arguments":{"keys":[{"type":"qcode","data":"meta_l"},{"type":"qcode","data":"shift"},{"type":"qcode","data":"t"}]}}'
sleep 4
out="$(run "pgrep -x foot | wc -l")"
n_shift_t="$(printf '%s\n' "$out" | grep -oE '^[0-9]+$' | head -1)"
[ "${n_shift_t:-0}" -ge 1 ]; check $? "Super+Shift+T (the USER's line) opens a terminal"

qmp '{"execute":"send-key","arguments":{"keys":[{"type":"qcode","data":"meta_l"},{"type":"qcode","data":"ret"}]}}'
sleep 4
out="$(run "pgrep -x foot | wc -l")"
n_after="$(printf '%s\n' "$out" | grep -oE '^[0-9]+$' | head -1)"
[ "${n_after:-0}" -eq "${n_shift_t:-0}" ]; check $? "Super+Return (the default it replaced) opens nothing"

echo
echo "== 3. which file the Keys panel writes"
run "md5sum /etc/novi/keys.conf > /tmp/etc.before" >/dev/null
# Clear the desktop first: an "after" screenshot means nothing if the
# window it shows could have been the one already there.
run "pkill -x foot || true" >/dev/null; sleep 3
# A GUI client started from the SERIAL shell has no WAYLAND_DISPLAY --
# the first attempt exited instantly and `[1]+ Done` was the only
# trace. novi-shell publishes /run/novi/display for exactly this, and
# novi-power already reads it this way; assuming `wayland-0` instead
# is the split-brain that file exists to prevent.
run "WD=\$(awk '\$1==\"WAYLAND_DISPLAY\"{print \$2}' /run/novi/display); \
     XRD=\$(awk '\$1==\"XDG_RUNTIME_DIR\"{print \$2}' /run/novi/display); \
     WAYLAND_DISPLAY=\$WD XDG_RUNTIME_DIR=\${XRD:-/run/user/0} \
     setsid novi-settings --panel keys >/tmp/settings.log 2>&1 &" 30 >/dev/null
sleep 8
out="$(run "pgrep -x novi-settings | wc -l")"
n_set="$(printf '%s\n' "$out" | grep -oE '^[0-9]+$' | head -1)"
[ "${n_set:-0}" -ge 1 ]; check $? "the Keys panel is actually on screen"
[ "${n_set:-0}" -ge 1 ] || run "cat /tmp/settings.log"
qmp "{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"${SP}/keys-panel.ppm\"}}"
# e opens the inline editor -- PRE-FILLED with what the row reads now
# ("Alt + Tab"), so typing straight into it appends and produces
# "Alt + Taboff", which the panel correctly refuses. The first run of
# this check did exactly that and the screendump showed the refusal in
# the footer: right product, wrong keystrokes. Clear the field first.
qmp '{"execute":"send-key","arguments":{"keys":[{"type":"qcode","data":"e"}]}}' >/dev/null
sleep 1
i=0; while [ "$i" -lt 16 ]; do
    qmp '{"execute":"send-key","arguments":{"keys":[{"type":"qcode","data":"backspace"}]}}' >/dev/null
    i=$((i + 1))
done
sleep 1
for k in o f f ret; do
    qmp "{\"execute\":\"send-key\",\"arguments\":{\"keys\":[{\"type\":\"qcode\",\"data\":\"${k}\"}]}}"
    sleep 1
done
sleep 2
qmp "{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"${SP}/keys-saved.ppm\"}}"
out="$(run "md5sum -c /tmp/etc.before >/dev/null 2>&1 && printf 'ETC_%s\\n' UNCHANGED || printf 'ETC_%s\\n' CHANGED; cat /root/.config/novi/keys.conf")"
printf '%s\n' "$out" | grep -q ETC_UNCHANGED; check $? "the machine's file is byte-identical after the edit"
# The action is `window.cycle-next`: [a-z.] has no HYPHEN, so the
# first version of this pattern could not match the line the panel
# had correctly written, and reported a working save as a failure.
printf '%s\n' "$out" | grep -qE '^[a-z.-]+ = off'; check $? "and the user's file gained the line the panel wrote"
printf '%s\n' "$out" | grep -q 'window.terminal = Super+Shift+T'; check $? "without disturbing the line already in it"

echo
printf '%s\n' "----- $PASS passed, $FAIL failed -----"
[ "$FAIL" -eq 0 ]
