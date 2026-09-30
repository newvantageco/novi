#!/bin/bash
# shellcheck shell=bash
# lib.sh -- drive a Novi guest over the serial console.
#
# Every rule here is one this repository already paid for:
#   * a fifo feeding `-serial mon:stdio` needs a PERMANENT writer, or the
#     fifo hits EOF and qemu's stdio monitor QUITS -- which in the log
#     looks exactly like a boot that hung;
#   * every wait takes a BYTE OFFSET, because a search from byte zero
#     matches output from an earlier phase and answers a question about
#     the past;
#   * a completion marker is COMPOSED AT RUNTIME, or it appears in the
#     line the console echoes back and every wait matches instantly;
#   * check the qemu process is alive before believing a frozen log;
#   * -nodefaults means NO KEYBOARD unless one is attached, and QMP
#     send-key then returns {"return": {}} -- success -- having
#     delivered the keystroke to nothing at all. The first run of this
#     harness read that as two failing bindings;
#   * the console speaks CRLF, so anchored patterns need the \r gone.

SP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIFO="${SP}/in.fifo"
LOG="${SP}/serial.log"
QMP="${SP}/qmp.sock"
QPID=""
HOLDER=""

log() { printf '[harness] %s\n' "$*"; }
die() { printf '[harness] FATAL: %s\n' "$*" >&2; vm_stop; exit 1; }

vm_start() {
    local iso="$1"; shift
    rm -f "$FIFO" "$LOG" "$QMP"
    mkfifo "$FIFO"
    : > "$LOG"
    # The permanent writer. Without it the first `send` closes the write
    # end, the fifo EOFs and qemu exits.
    setsid sh -c "sleep 100000 > '$FIFO'" >/dev/null 2>&1 &
    HOLDER=$!
    setsid qemu-system-x86_64 \
        -machine q35,accel=tcg -cpu max -smp 4 -m 4096 \
        -drive "file=${iso},if=none,id=cd0,media=cdrom,readonly=on" \
        -device ide-cd,drive=cd0,bus=ide.0 \
        -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
        -device virtio-gpu-pci,xres=1280,yres=800 \
        -device virtio-rng-pci \
        -device qemu-xhci,id=xhci0 \
        -device usb-kbd,bus=xhci0.0 \
        -device usb-tablet,bus=xhci0.0 \
        -vga none -display none \
        -serial mon:stdio \
        -qmp "unix:${QMP},server,nowait" \
        -rtc base=utc -boot order=dc -no-user-config -nodefaults \
        "$@" < "$FIFO" > "$LOG" 2>&1 &
    QPID=$!
    log "qemu pid ${QPID}, log ${LOG}"
}

vm_stop() {
    [ -n "$QPID" ] && kill "$QPID" 2>/dev/null
    [ -n "$HOLDER" ] && kill "$HOLDER" 2>/dev/null
    return 0
}

vm_alive() { [ -n "$QPID" ] && kill -0 "$QPID" 2>/dev/null; }

# Current size of the log, to be passed back as a search offset.
mark() { stat -c %s "$LOG" 2>/dev/null || echo 0; }

# wait_for <pattern> <timeout_s> <offset>  -- searches only what was
# written AFTER <offset>, and fails loudly if qemu died.
wait_for() {
    local pat="$1" timeout="$2" off="${3:-0}" waited=0
    while [ "$waited" -lt "$timeout" ]; do
        if tail -c "+$((off + 1))" "$LOG" 2>/dev/null | grep -qF -- "$pat"; then
            return 0
        fi
        if ! vm_alive; then
            log "qemu exited while waiting for: $pat"
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
    log "TIMEOUT after ${timeout}s waiting for: $pat"
    return 1
}

send() { printf '%s\n' "$*" > "$FIFO"; }

# run <shell command> -- send it, wait for a marker this invocation
# composes at runtime so the console's echo of the command cannot match.
RUN_N=0
run() {
    RUN_N=$((RUN_N + 1))
    local tag="RUNDONE${RUN_N}" off; off="$(mark)"
    send "$1"
    send "printf 'RUN%s%s\\n' DONE ${RUN_N}"
    wait_for "$tag" "${2:-60}" "$off" || return 1
    # STRIP THE CARRIAGE RETURNS. A serial console ends every line
    # \r\n, so a count of 1 arrives as "1\r" and an anchored pattern
    # like ^[0-9]+$ never matches it -- which read as "no terminal
    # opened" on a machine whose compositor had just mapped one.
    # Substring greps (the ones that happened to pass) hid this.
    tail -c "+$((off + 1))" "$LOG" | tr -d '\r'
}

qmp() {
    python3 - "$QMP" "$1" <<'PY'
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
f = s.makefile('rw')
f.readline()
f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n"); f.flush(); f.readline()
f.write(sys.argv[2] + "\n"); f.flush()
print(f.readline().strip())
PY
}
