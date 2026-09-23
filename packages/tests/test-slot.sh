#!/bin/bash
# ============================================================
# test-slot.sh — novi-slot, on the parts a host can answer.
#
# WHAT A HOST CAN AND CANNOT CHECK. `novi-slot` mounts a partition,
# chroots into it and reboots a machine, so most of it needs a disk and
# is verified by an install and three boots (RFC 0041 item 4). What is
# checkable here is everything TEXTUAL, and textual is where the two
# worst bugs in this feature live:
#
#   - THE COPIED fstab NAMES THE OTHER SLOT AS ROOT. `/init` mounts the
#     root from the kernel command line, so a wrong `/` line does not
#     stop the machine booting. It sits there being wrong until
#     something reads it.
#   - THE EXCLUSION LIST. A `tar` of `/` on an A/B machine runs through
#     live bind mounts: excluding /state alone still copies /home
#     THROUGH its bind, and excluding the binds alone still copies the
#     whole of /state under /state. Either mistake produces a slot that
#     boots perfectly and is quietly two copies of everything.
#
# Both are silent, and neither shows up in a diff. The shortest check
# here is still the one worth most: `var/lib/pkg` must never join
# STATE_SUBTREES and must never be bound into the chroot, because it is
# the slot's own package manifest -- share it and an install into the
# inactive slot registers in the running one's database.
# ============================================================
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

TOOL="packages/novi-slot"
INSTALLER="packages/novi-install"
SH_BIN="bash"
for c in build/rootfs/bin/busybox /build/rootfs/bin/busybox; do
    [ -x "$c" ] && { SH_BIN="$c ash"; break; }
done

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL: $*"; }
check(){ if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$3], got [$2]"; fi; }
part() { echo "== $*"; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

part "the shared subtrees are the installer's list, character for character"
# Two files naming the same set is how they stop naming the same set.
A="$(sed -n 's/^STATE_SUBTREES="\(.*\)"$/\1/p' "$INSTALLER" | head -1)"
B="$(sed -n 's/^STATE_SUBTREES="\(.*\)"$/\1/p' "$TOOL" | head -1)"
check "novi-install has a list" "$([ -n "$A" ] && echo yes)" "yes"
check "novi-slot agrees"        "$B" "$A"
# var/lib/pkg is the slot's OWN manifest. Sharing it would give the
# running system a database describing the other slot.
check "var/lib/pkg is not shared" \
    "$(printf '%s\n' $B | grep -cx 'var/lib/pkg')" "0"
check "var/cache/pkg IS shared"  "$(printf '%s\n' $B | grep -cx 'var/cache/pkg')" "1"

part "the copy excludes the shared partitions AND the binds over them"
for d in ./proc ./sys ./dev ./run ./tmp ./mnt ./state ./boot; do
    check "excludes $d" "$(grep -c -- "--exclude=$d\b" "$TOOL")" "1"
done
# The bind targets are excluded by the loop over STATE_SUBTREES, which
# is what keeps the two halves from drifting apart.
check "the binds are excluded from the list, not by hand" \
    "$(grep -c 'for sub in \$STATE_SUBTREES; do ex=' "$TOOL")" "1"
# /var/lib/pkg must NOT be excluded: the new slot needs its own.
check "var/lib/pkg is copied" "$(grep -c -- '--exclude=./var/lib/pkg' "$TOOL")" "0"

part "the chroot binds are the ones it can justify, and no more"
check "binds /dev /proc /sys"   "$(grep -c 'for d in /dev /proc /sys' "$TOOL")" "1"
check "binds the shared cache"  "$(grep -c 'mount --bind /state/var/cache/pkg' "$TOOL")" "1"
# Binding /var/lib/pkg would make an install into the inactive slot
# register in the RUNNING one's database -- a machine that lies to pkg,
# to novi-state diff and to novi-agent describe.
check "never binds the install database" \
    "$(grep -c 'bind /var/lib/pkg\|/var/lib/pkg" ' "$TOOL")" "0"
# The whole of /run is the running system's private runtime state. One
# file, not the directory.
check "binds one resolver file, not /run" \
    "$(grep -c 'mount --bind /run ' "$TOOL")" "0"
check "the resolver source is the one file" \
    "$(grep -c '^    src=/run/novi/resolv.conf$' "$TOOL")" "1"
check "and it is bound"            "$(grep -c 'mount --bind "\$src"' "$TOOL")" "1"

part "THE fstab REWRITE -- the bug that boots perfectly"
FN="$WORK/fn.sh"
awk '/^rewrite_fstab\(\) \{/{p=1} p{print} p&&/^\}$/{exit}' "$TOOL" > "$FN"
check "extracted" "$(grep -c '^rewrite_fstab() {' "$FN")" "1"
mkdir -p "$WORK/slot/etc"
cat > "$WORK/slot/etc/fstab" <<'FSTAB'
# a comment that must survive
LABEL=NOVI_ROOT_A   /       ext4    rw,noatime      0 1
LABEL=NOVI_ESP    /boot/efi vfat  rw,noatime,nofail  0 2
LABEL=NOVI_STATE  /state  ext4  rw,noatime,nofail  0 2
/state/home                   /home                   none  bind,nofail  0 0
proc                  /proc   proc    defaults        0 0
FSTAB
cat > "$WORK/drv.sh" <<DRV
set -u
MNT="$WORK/slot"; OTHER_LABEL="NOVI_ROOT_B"
info() { :; }
warn() { echo "WARN: \$*"; }
die()  { echo "DIE: \$*"; exit 1; }
. "$FN"
rewrite_fstab
DRV
$SH_BIN "$WORK/drv.sh" >/dev/null 2>&1
check "the root line now names the other slot" \
    "$(awk '$2 == "/" { print $1 }' "$WORK/slot/etc/fstab")" "LABEL=NOVI_ROOT_B"
# Only the root line. /boot/efi and /state are SHARED and must keep
# pointing at the same partitions from both slots -- rewriting them
# would give slot B its own idea of where the shared state is.
check "the ESP line is untouched" \
    "$(grep -c '^LABEL=NOVI_ESP    /boot/efi vfat  rw,noatime,nofail  0 2$' "$WORK/slot/etc/fstab")" "1"
check "the state line is untouched" \
    "$(grep -c '^LABEL=NOVI_STATE  /state  ext4  rw,noatime,nofail  0 2$' "$WORK/slot/etc/fstab")" "1"
check "the bind line is untouched" \
    "$(grep -c '^/state/home  ' "$WORK/slot/etc/fstab")" "1"
check "comments survive" "$(grep -c '^# a comment that must survive$' "$WORK/slot/etc/fstab")" "1"
check "no line was lost" "$(grep -c . "$WORK/slot/etc/fstab")" "6"
# Running it twice must be a no-op, because `sync` is a thing somebody
# does repeatedly.
$SH_BIN "$WORK/drv.sh" >/dev/null 2>&1
check "idempotent" "$(grep -c '^LABEL=NOVI_ROOT_B' "$WORK/slot/etc/fstab")" "1"

part "a slot whose fstab has no LABEL root line is refused, not guessed"
printf 'UUID=deadbeef  /  ext4  rw  0 1\n' > "$WORK/slot/etc/fstab"
OUT="$($SH_BIN "$WORK/drv.sh" 2>&1)"
check "refused" "$(printf '%s' "$OUT" | grep -c 'DIE:')" "1"
check "and the file is untouched" "$(grep -c '^UUID=deadbeef' "$WORK/slot/etc/fstab")" "1"
check "and no temp file is left" "$(ls "$WORK/slot/etc" | grep -c 'fstab.new')" "0"

part "A HALF-COPIED SLOT MUST NOT LOOK LIKE A WHOLE ONE"
# `tar` writes in directory order, so an interrupted copy has a
# /bin/busybox and an /etc long before it has everything -- and the
# machine that produces one is not hypothetical. Watched live: a
# harness killed its own sync at 311 MB of 762, and `switch` then
# pointed the next boot at the result, which reached s6-linux-init and
# stopped. "Is it populated" cannot be answered by looking; it has to
# be answered by a marker the copy writes when it is finished.
check "sync writes the marker" \
    "$(awk '/^sync_other\(\) \{/,/^}/' "$TOOL" | grep -c '> "\$MNT/\$SYNC_MARK"')" "1"
check "and removes it first" \
    "$(awk '/^sync_other\(\) \{/,/^}/' "$TOOL" | grep -c 'rm -f "\$MNT/\$SYNC_MARK"')" "1"
# Removed FIRST matters as much as written last: a re-sync that is
# itself interrupted must not leave the mark from the copy before it.
FIRST="$(awk '/^sync_other\(\) \{/,/^}/' "$TOOL" | grep -n 'SYNC_MARK' | head -1 | cut -d: -f1)"
LAST="$(awk '/^sync_other\(\) \{/,/^}/' "$TOOL" | grep -n 'SYNC_MARK' | tail -1 | cut -d: -f1)"
TARL="$(awk '/^sync_other\(\) \{/,/^}/' "$TOOL" | grep -n 'tar -cf -' | head -1 | cut -d: -f1)"
check "the removal is before the copy" "$([ "$FIRST" -lt "$TARL" ] && echo yes)" "yes"
check "the write is after it"          "$([ "$LAST"  -gt "$TARL" ] && echo yes)" "yes"
check "populated means the marker"     "$(awk '/^slot_is_populated\(\) \{/,/^}/' "$TOOL" | grep -c 'SYNC_MARK')" "1"
# AND THE INSTALLER HAS TO MAKE THE SAME CLAIM ABOUT ITS OWN WORK.
# Without it the machine cannot roll back to the slot it was installed
# into -- the one a rollback most wants -- because that slot is a
# complete copy whose completion nothing recorded. Watched live: the
# rollback answered "slot a is not ready: no completed copy" about the
# slot the machine had booted from twenty minutes earlier.
MARK_SLOT="$(sed -n 's/^SYNC_MARK="\(.*\)"$/\1/p' "$TOOL" | head -1)"
MARK_INST="$(sed -n 's/^SLOT_SYNC_MARK="\(.*\)"$/\1/p' "$INSTALLER" | head -1)"
check "novi-slot names a marker"  "$([ -n "$MARK_SLOT" ] && echo yes)" "yes"
check "the installer agrees"      "$MARK_INST" "$MARK_SLOT"
check "and writes it"             "$(grep -c '> "\$MNT/\$SLOT_SYNC_MARK"' "$INSTALLER")" "1"
# Only on an --ab install: a machine with one root slot has nothing to
# switch to, and a marker there would be a claim nobody reads.
check "only when --ab"            "$(grep -B4 '> "\$MNT/\$SLOT_SYNC_MARK"' "$INSTALLER" | grep -c 'if \[ "\$AB" -eq 1 \]')" "1"
# And status distinguishes the three states, because "empty" and
# "half written" need different things done about them.
check "status names UNFINISHED"        "$(grep -c 'UNFINISHED' "$TOOL")" "1"
check "status still names EMPTY"       "$(grep -c 'EMPTY --' "$TOOL")" "1"
check "switch refuses an unready slot" \
    "$(awk '/^cmd_switch\(\) \{/,/^}/' "$TOOL" | grep -c 'not ready')" "1"

part "a machine with one root slot is told so, not crashed into"
# resolve_slots reads /proc/mounts, so on this host / is labelled
# something that is neither slot -- which is the single-slot case.
OUT="$($SH_BIN "$TOOL" status 2>&1)"
check "status refuses"      "$(printf '%s' "$OUT" | grep -c 'one root slot')" "1"
check "and names the flag"  "$(printf '%s' "$OUT" | grep -c 'novi-install --ab')" "1"
# THE REASON MATTERS: a partition table is written once, so this is not
# something a person can turn on later.
check "and says it cannot be added later" \
    "$(printf '%s' "$OUT" | grep -c 'written[[:space:]]*$\|written once')" "1"

part "switch and rollback are ONE implementation with two names"
check "both dispatch to cmd_switch" "$(grep -c 'cmd_switch "' "$TOOL")" "2"
check "there is one cmd_switch"     "$(grep -c '^cmd_switch() {' "$TOOL")" "1"
# Somebody whose machine has just booted a bad update types `rollback`.
# A verb that is absent because it would be a synonym is a verb
# somebody gives up looking for.
check "rollback is in the usage text" "$($SH_BIN "$TOOL" help 2>&1 | grep -c 'rollback')" "1"
check "and says it is the same operation" \
    "$($SH_BIN "$TOOL" help 2>&1 | grep -c 'same operation')" "1"

part "it does not claim to know whether the update worked"
# RFC 0041 item 5. A tool that implied it had a trial-boot rule when it
# has none would be the overclaim RFC 0025 warns about with "Mesa".
check "the help says so" "$($SH_BIN "$TOOL" help 2>&1 | grep -c 'not built yet')" "1"

part "the kernel goes on the ESP when the root is not the boot area"
# RFC 0041 item 1 had this wrong for UEFI A/B: the test was `$ENCRYPT`,
# so the kernel went into SLOT A's /boot while grub.cfg searched for
# slot A's label -- both slots booting slot A's kernel out of slot A's
# filesystem. A slot switch that cannot change the kernel is not an A/B
# system. Same correction as `separate_boot()`, one layer up: ask what
# is true, not why.
check "there is one predicate"  "$(grep -c '^kernel_on_esp() {' "$INSTALLER")" "1"
check "it covers A/B"           "$(grep -c 'AB.*-eq 1' <(sed -n '/^kernel_on_esp() {/,/^}/p' "$INSTALLER"))" "1"
check "it covers encrypted"     "$(grep -c 'ENCRYPT.*-eq 1' <(sed -n '/^kernel_on_esp() {/,/^}/p' "$INSTALLER"))" "1"
check "and it is UEFI-only"     "$(grep -c 'FIRMWARE. = .uefi' <(sed -n '/^kernel_on_esp() {/,/^}/p' "$INSTALLER"))" "1"
check "no ENCRYPT test decides the kernel's home" \
    "$(grep -c 'ENCRYPT. -eq 1 \] && \[ ."\$FIRMWARE" = .uefi' "$INSTALLER")" "0"
# The grub.cfg search has to follow it, or GRUB looks for the kernel on
# a filesystem that does not have it.
check "the search follows the same predicate" \
    "$(grep -c 'if kernel_on_esp; then' "$INSTALLER")" "2"

echo
echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
