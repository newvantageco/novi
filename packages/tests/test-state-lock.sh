#!/bin/bash
# ============================================================
# test-state-lock.sh — two writers, and the change that used to vanish
#
# RFC 0002 roadmap 4. `state_set` is a read-modify-write of the whole
# document: awk reads it, the result goes to a temp file, the temp file
# is renamed over it. The rename is atomic, so the file is never
# half-written -- and that was the whole of the protection. Two writers
# that overlap therefore produced a well-formed document containing one
# of the two changes, with NO ERROR from either: the losing caller was
# told it succeeded and the value it declared was simply not there.
#
# That is the exact failure this engine exists to abolish, committed by
# the engine itself, and it is unobservable in any single run -- which
# is what makes it worth a test rather than a careful read.
#
# THE TEST HAS TO PROVE THE RACE IS REAL, or it proves nothing about
# the fix. So it runs the same scenario against a DOCTORED copy with
# the locking removed, and requires that copy to lose a write. If the
# unlocked copy ever stops losing one, this test says so rather than
# quietly passing on both -- a green test over a race that no longer
# reproduces is a test that has stopped watching.
#
# The window is widened deliberately (a `sleep` spliced between the
# read and the rename) rather than hoped for. A race you have to run a
# thousand times to see is a race a test cannot depend on, and the
# widening changes the timing, not the logic: the two orderings are the
# same two orderings.
# ============================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

BUSYBOX=/build/rootfs/bin/busybox
if [ -x "${BUSYBOX}" ]; then
    SH=("${BUSYBOX}" ash)
    echo ">>> novi-state locking, under the shipped busybox ash"
else
    SH=(bash)
    echo ">>> novi-state locking, under bash (no shipped busybox found)" >&2
fi

checks=0
fail=0
note() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }
did() { checks=$((checks + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# Two copies of the tool. `slow` has a pause spliced between the awk
# that reads the document and the mv that replaces it, which is the
# window the race lives in; `unlocked` has that pause AND no lock,
# which is what this code was before today.
#
# need_root goes in both: this container is root and CI is not, and the
# thing under test is the write path, not the privilege check. Same
# call test-state-packages.sh makes.
make_copy() {
    sed -e 's|^    need_root$|    :|' \
        -e "s|^    mv \"\$tmp\" \"\$STATE_FILE\"\$|    sleep 1\n    mv \"\$tmp\" \"\$STATE_FILE\"|" \
        packages/novi-state > "$1"
}
make_copy "${TMP}/slow"
make_copy "${TMP}/unlocked"
# A fourth copy with need_root removed and NO pause: the lock-lifecycle
# checks below want a plain, fast write.
#
# THEY USED THE SHIPPED SCRIPT AT FIRST, AND CI CAUGHT IT. This
# container is root, so `novi-state set` ran; a CI runner is not, so
# need_root refused, the write never happened and the stale lock was
# never cleared -- two checks failing for a reason that has nothing to
# do with locking. Worse, the "a live holder is obeyed" check PASSED
# there for the wrong reason: it expects the command to fail, and
# need_root failed it. A check that cannot tell why it passed is the
# thing this repository keeps finding in its own tests. Same doctoring
# test-state-packages.sh already does, and for the same reason: what is
# under test is the write path, not the privilege check.
sed 's|^    need_root$|    :|' packages/novi-state > "${TMP}/plain"
chmod +x "${TMP}/plain"
# Remove the lock from the second copy: state_lock becomes a no-op.
sed -i 's|^state_lock() {$|state_lock() { return 0; }\nunused_state_lock() {|' "${TMP}/unlocked"

did
grep -q 'sleep 1' "${TMP}/slow" || note "the widening sed did not apply -- the race window is not open"
did
"${SH[@]}" -n "${TMP}/slow" || note "the doctored copy does not parse"
did
"${SH[@]}" -n "${TMP}/unlocked" || note "the unlocked copy does not parse"

# Two writers touching DIFFERENT keys, which is the case that matters:
# a lost write to the same key is at least visible as "my value is not
# the one on screen", while a lost write to another key is a setting
# that is simply absent from a document somebody is reading as truth.
race() {
    local tool="$1" conf="${TMP}/conf"
    printf '# a document\nhostname = start\n' > "$conf"
    NOVI_STATE_FILE="$conf" "${SH[@]}" "$tool" set hostname one >/dev/null 2>&1 &
    local a=$!
    # Half the widened window, so the second writer's read lands inside
    # the first writer's read-modify-write rather than after it.
    sleep 0.4
    NOVI_STATE_FILE="$conf" "${SH[@]}" "$tool" set network.dhcp on >/dev/null 2>&1 &
    local b=$!
    wait "$a" "$b" 2>/dev/null
    cat "$conf"
}

# ── 1. the race is real ──────────────────────────────────────────────
did
out="$(race "${TMP}/unlocked")"
if printf '%s' "$out" | grep -q 'hostname = one' \
   && printf '%s' "$out" | grep -q 'network.dhcp = on'; then
    note "the unlocked copy kept BOTH writes -- the race no longer reproduces, so nothing below proves anything"
fi

# ── 2. the lock fixes it ─────────────────────────────────────────────
out="$(race "${TMP}/slow")"
did
printf '%s' "$out" | grep -q 'hostname = one' \
    || note "the first writer's change was lost with the lock in place"
did
printf '%s' "$out" | grep -q 'network.dhcp = on' \
    || note "the second writer's change was lost with the lock in place"
did
# The document's own text, not just the two values: serialising writes
# must not cost the comment preservation that makes this file editable.
printf '%s' "$out" | grep -q '^# a document' \
    || note "the comment header did not survive two concurrent writes"

# ── 3. the lock is released ──────────────────────────────────────────
did
[ ! -d "${TMP}/conf.lock" ] || note "the lock directory outlived the writers"

# ── 4. a stale lock from an earlier boot is cleared, not obeyed ───────
# The pid recorded belongs to this very process, so a pid check ALONE
# would call this lock live and wait out the timeout. It is the boot
# time that makes it stale -- which is the case a reboot after a crash
# produces, and the one a pid check cannot see.
printf '# doc\n' > "${TMP}/conf"
mkdir -p "${TMP}/conf.lock"
printf '1 %s\n' "$$" > "${TMP}/conf.lock/owner"
did
NOVI_STATE_LOCK_TIMEOUT=3 NOVI_STATE_FILE="${TMP}/conf" \
    "${SH[@]}" "${TMP}/plain" set hostname after-stale >/dev/null 2>&1 \
    || note "a lock from an earlier boot blocked a write"
did
grep -q 'hostname = after-stale' "${TMP}/conf" \
    || note "the write did not happen after the stale lock was cleared"

# ── 5. a lock whose holder died is cleared too ───────────────────────
# Same boot, a pid that cannot exist. 4194304 is above the default
# pid_max on every 64-bit Linux, so it is a pid no process can have --
# a pid picked at random might be in use and the test would then be
# asserting a timeout.
printf '# doc\n' > "${TMP}/conf"
mkdir -p "${TMP}/conf.lock"
printf '%s 4194304\n' "$(sed -n 's/^btime //p' /proc/stat | head -1)" \
    > "${TMP}/conf.lock/owner"
did
NOVI_STATE_LOCK_TIMEOUT=3 NOVI_STATE_FILE="${TMP}/conf" \
    "${SH[@]}" "${TMP}/plain" set hostname after-dead >/dev/null 2>&1 \
    || note "a lock held by a dead process blocked a write"
did
grep -q 'hostname = after-dead' "${TMP}/conf" \
    || note "the write did not happen after the dead holder's lock was cleared"

# ── 6. a lock held by a LIVE process of this boot is obeyed ──────────
# The other half, and the one that would make every check above
# meaningless if it failed: a fix that clears every lock it meets is
# not a lock. `sleep` is the holder because it is a real live pid that
# will still be there when the timeout expires.
printf '# doc\n' > "${TMP}/conf"
sleep 30 & holder=$!
mkdir -p "${TMP}/conf.lock"
printf '%s %s\n' "$(sed -n 's/^btime //p' /proc/stat | head -1)" "$holder" \
    > "${TMP}/conf.lock/owner"
did
if NOVI_STATE_LOCK_TIMEOUT=2 NOVI_STATE_FILE="${TMP}/conf" \
       "${SH[@]}" "${TMP}/plain" set hostname stolen >/dev/null 2>&1; then
    note "a live holder's lock was taken anyway"
fi
did
grep -q 'hostname = stolen' "${TMP}/conf" \
    && note "the document was written while another process held the lock"
kill "$holder" 2>/dev/null
rm -rf "${TMP}/conf.lock"

# ── 7. reentrant within one process ──────────────────────────────────
# rollback takes the lock and then calls apply, which takes it again,
# and every converger's `set` takes it a third time. Without
# reentrancy that is a program that hangs on its own correctness, and
# the symptom would be a boot that never finishes.
printf '# doc\nhostname = nested\n' > "${TMP}/conf"
# The tool's own dispatch runs on source, so reentrancy is exercised
# the way the program actually does it: rollback -> apply -> set, each
# taking the lock, driven here by a script that sources the functions
# with the dispatch cut off at the `case`.
sed '/^case "\${1:-}" in$/,$d' "${TMP}/slow" > "${TMP}/lib"
did
NOVI_STATE_LOCK_TIMEOUT=5 "${SH[@]}" -c '
    NOVI_STATE_FILE="'"${TMP}"'/conf"
    . "'"${TMP}"'/lib"
    state_lock
    state_set hostname nested-once
    state_set network.dhcp on
    [ "$STATE_LOCK_HELD" -eq 1 ] || { echo "the outer lock was released by an inner set" >&2; exit 1; }
    state_lock_release
' >/dev/null 2>&1 || note "a set inside a held lock deadlocked or released the outer lock"
did
grep -q 'hostname = nested-once' "${TMP}/conf" \
    || note "a write made while the lock was already held did not land"
did
grep -q 'network.dhcp = on' "${TMP}/conf" \
    || note "the second nested write did not land"

# The other side of reentrancy, and the only check that can see the
# explicit release in state_set at all: the EXIT trap frees the lock
# whatever happens, so a process that exits after a `set` proves
# nothing about whether the function released it. This one does not
# exit -- it looks at the flag and the directory while still running.
# Without that, removing the release from state_set is a change no
# test here would notice.
printf '# doc\n' > "${TMP}/conf"
did
"${SH[@]}" -c '
    NOVI_STATE_FILE="'"${TMP}"'/conf"
    . "'"${TMP}"'/lib"
    state_set hostname unheld
    [ "$STATE_LOCK_HELD" -eq 0 ] || { echo "set kept the lock it took" >&2; exit 1; }
    [ ! -d "$STATE_FILE.lock" ] || { echo "set left the lock directory" >&2; exit 1; }
' >/dev/null 2>&1 || note "a set that TOOK the lock did not give it back before returning"
did
[ ! -d "${TMP}/conf.lock" ] || note "the lock outlived the process that took it"

echo ">>> novi-state locking: ${checks} check(s), ${fail} failure(s)"
[ "${fail}" -eq 0 ] || exit 1
exit 0
