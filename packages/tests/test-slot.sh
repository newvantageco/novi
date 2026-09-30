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
check "rollback is in the usage text" \
    "$($SH_BIN "$TOOL" help 2>&1 | grep -c '^  novi-slot rollback ')" "1"
# And the help states the one way they differ, which is the trial.
check "and says how it differs" \
    "$($SH_BIN "$TOOL" help 2>&1 | grep -c 'a decision, not')" "1"

part "THE TRIAL BOOT -- a flag, because GRUB script has no arithmetic"
# `set n=$((n + 1))` is "error: Incorrect command." in GRUB, measured on
# a booted machine by a probe that failed on it before reaching the
# save_env it was written to test. Two states are all this needs.
AB="$WORK/ab2.cfg"
FN2="$WORK/fn2.sh"
awk '/^write_grub_cfg\(\) \{/{p=1} p{print} p&&/^GRUBCFG$/{g=1} g&&/^\}$/{exit}' \
    "$INSTALLER" > "$FN2"
cat > "$WORK/drv2.sh" <<DRV
set -u
ENCRYPT=0; AB=1; ROOT_LABEL=NOVI_ROOT_A; FIRMWARE=bios
SLOT_A_LABEL=NOVI_ROOT_A; SLOT_B_LABEL=NOVI_ROOT_B
BOOT_PART=/dev/vda1; LUKS_NAME=x; LUKS_UUID=y
separate_boot() { [ -n "\$BOOT_PART" ]; }
kernel_on_esp() { false; }
kernel_grub_prefix() { printf ""; }
. "$FN2"
write_grub_cfg "$AB" ""
DRV
$SH_BIN "$WORK/drv2.sh"
# Excluding comment lines: the generated file CARRIES a comment saying
# `set n=$((n + 1))` is an error in GRUB, which is the note this check
# exists to keep true. Grepping the whole file finds that note and
# reports the bug it warns about.
check "no arithmetic in the code"  "$(grep -v '^#' "$AB" | grep -c '\$((')" "0"
check "and the note explaining why is there" "$(grep -ci 'no arithmetic' "$AB")" "1"
# `sleep` is a MODULE. Without it in core.img the "going back" line is
# followed by "error: Incorrect command." instead of a pause somebody
# can read. Found by reading the generated menu, not by booting it.
check "sleep is baked into core.img" \
    "$(awk '/-o "\$\{NOVI_BOOT_DIR\}\/core.img"/{f=1} f&&/ sleep$/{print "yes"; exit} f&&/^$/{exit}' scripts/mkiso.sh)" "yes"
check "and into bootx64.efi" \
    "$(awk '/-o "\$\{NOVI_BOOT_DIR\}\/bootx64.efi"/{f=1} f&&/ sleep$/{print "yes"; exit} f&&/^$/{exit}' scripts/mkiso.sh)" "yes"
check "armed becomes taken"     "$(grep -c 'set novi_try=taken' "$AB")" "1"
check "and is saved at once"    "$(grep -A1 'set novi_try=taken' "$AB" | grep -c 'save_env novi_try')" "1"
check "taken flips the slot"    "$(grep -c 'elif \[ "\${novi_try}" = "taken" \]' "$AB")" "1"
# Both halves of the flip have to be persisted: the slot, or the next
# boot goes back to the bad one; and the flag, or it flips forever.
check "and saves both"          "$(grep -c 'save_env novi_slot novi_try' "$AB")" "1"
check "and says so on screen"   "$(grep -c 'did not complete' "$AB")" "1"
check "novi_try is loaded"      "$(grep -c 'load_env novi_slot novi_try' "$AB")" "1"
check "and defaulted first"     "$(grep -c '^set novi_try=$' "$AB")" "1"

part "switch arms a trial; ROLLBACK MUST NOT"
# Arming on a rollback means a boot that fails to confirm sends you
# back to the slot you were escaping. A rollback is a decision, not an
# experiment.
check "switch passes 1"     "$(grep -c 'cmd_switch "switched" 1' "$TOOL")" "1"
check "rollback passes 0"   "$(grep -c 'cmd_switch "rolled back" 0' "$TOOL")" "1"
check "armed is written"    "$(grep -c '"novi_try=armed"' "$TOOL")" "1"
# And a rollback CLEARS any armed trial, or the bootloader would undo
# the decision on the next boot.
check "rollback clears it"  "$(awk '/^cmd_switch\(\) \{/,/^}/' "$TOOL" | grep -c '"novi_try="')" "1"

part "what clears a trial, and what deliberately does not"
check "confirm exists"      "$(grep -c '^cmd_confirm() {' "$TOOL")" "1"
check "and is dispatched"   "$(grep -c 'confirm)  cmd_confirm' "$TOOL")" "1"
# NOT novi-state health. A machine degraded for a reason unrelated to
# the update would roll it back, and the rollback would look like the
# update's fault. The file has to say so, because the next person will
# reach for health as the obvious signal.
check "health is not consulted" \
    "$(awk '/^cmd_confirm\(\) \{/,/^}/' "$TOOL" | grep -c 'novi-state health')" "0"
check "and the reason is written down" "$(grep -c 'novi-state health' "$TOOL")" "1"
# NO WRITE ON A NORMAL BOOT: this runs from rc.init every time, and
# rewriting the block the bootloader depends on at every start is churn.
check "returns early with no trial" \
    "$(awk '/^cmd_confirm\(\) \{/,/^}/' "$TOOL" | grep -c '\*) return 0 ;;')" "1"
RD="$(awk '/^cmd_confirm\(\) \{/,/^}/' "$TOOL" | grep -n 'novi-grubenv get' | head -1 | cut -d: -f1)"
WR="$(awk '/^cmd_confirm\(\) \{/,/^}/' "$TOOL" | grep -n 'novi-grubenv set' | head -1 | cut -d: -f1)"
check "and reads before it writes" "$([ "$RD" -lt "$WR" ] && echo yes)" "yes"
# rc.init is where it runs, because reaching that line means s6-rc
# brought the default bundle up and convergence ran.
check "rc.init calls it"    "$(grep -c 'novi-slot confirm' init/skel/rc.init)" "1"
check "and cannot fail a boot" "$(grep -c 'novi-slot confirm || true' init/skel/rc.init)" "1"
check "guarded by command -v"  "$(grep -B1 'novi-slot confirm || true' init/skel/rc.init | grep -c 'command -v novi-slot')" "1"

part "a confirmed trial claims a userland, not a good update"
# The bar is "this slot booted", which is what the mechanism can
# observe. Letting the word imply more would be the overclaim RFC 0025
# warns about with the word "Mesa".
check "the help says what it claims" \
    "$($SH_BIN "$TOOL" help 2>&1 | grep -c 'reached a working')" "1"
check "and what it does not"  \
    "$($SH_BIN "$TOOL" help 2>&1 | grep -c 'is a judgement')" "1"

part "a slot is a COPY, not the union of every sync into it"
# `tar -xf` OVERWRITES AND NEVER DELETES. Demonstrated on the host:
# remove a file from the source, re-sync, and it is still in the
# target. So without a wipe, `pkg remove` something and sync leaves
# the slot carrying that package's files while the install database
# copied beside them says it is gone -- a slot that lies to pkg, which
# is the hazard /var/lib/pkg is kept slot-local to avoid, arriving
# from the other direction.
check "there is a wipe"         "$(grep -c '^wipe_other() {' "$TOOL")" "1"
check "sync calls it"           "$(grep -c '^    wipe_other$' "$TOOL")" "1"
# BEFORE the tar, or it deletes the copy it just made.
WLINE="$(grep -n '^    wipe_other$' "$TOOL" | cut -d: -f1)"
TLINE="$(grep -n 'cd / && tar -cf -' "$TOOL" | cut -d: -f1)"
check "and before the copy"     "$([ "$WLINE" -lt "$TLINE" ] && echo yes || echo no)" "yes"
# It is an `rm -rf` as root, so it checks /proc/mounts rather than
# this program's own variables -- what would have gone wrong is those
# variables. Each refusal is driven for real against a loop mount
# elsewhere; these assert the guards are still present.
WFN="$(awk '/^wipe_other\(\) \{/,/^}/' "$TOOL" | grep -v '^[[:space:]]*#')"
check "it asks /proc/mounts"    "$(printf '%s' "$WFN" | grep -c '/proc/mounts')" "1"
check "it refuses a non-mount"  "$(printf '%s' "$WFN" | grep -c 'is not a mountpoint')" "1"
# Each refusal is named by its OWN message. Counting the shared
# "refusing to wipe it" tail matched all three at once, so any one of
# them could go and the count would still look plausible.
check "it refuses the wrong device" \
    "$(printf '%s' "$WFN" | grep -c 'not \${OTHER_DEV}')" "1"
check "it refuses the running root" \
    "$(printf '%s' "$WFN" | grep -c 'resolved to the running root')" "1"
check "it refuses /"            "$(printf '%s' "$WFN" | grep -c "MNT.*!=.*/")" "1"
# The CONTENTS go, never the directory -- $MNT is the mount point, and
# removing it would unmake the thing being written to.
check "mindepth 1 keeps the mount point" \
    "$(printf '%s' "$WFN" | grep -c 'mindepth 1')" "1"
check "no bare rm -rf of the mount" \
    "$(printf '%s' "$WFN" | grep -c 'rm -rf "\$MNT"')" "0"
# mke2fs made lost+found for e2fsck, and the tar excludes it, so
# removing it leaves the slot differing from a fresh filesystem with
# nothing here to put it back.
check "lost+found survives the wipe" \
    "$(printf '%s' "$WFN" | grep -c "name 'lost+found'")" "1"

part "a package name reaches a root sh -c, so it is checked by class"
# `in_other` runs `chroot "$MNT" /bin/sh -c "pkg install $*"`. The
# caller is already root at a shell so this is not a privilege
# boundary, but running `foo; rm -rf /` inside a chroot is a surprise
# nobody asked for.
check "there is a name check" "$(grep -c '^valid_pkg_name() {' "$TOOL")" "1"
# A DOCTORED COPY, because `cmd_pkg` calls `need_root` FIRST and these
# four checks RUN the program rather than grepping it. This container
# is root and a CI runner is not, so they passed here and failed there
# with `ERROR: This operation requires root.` -- which CLAUDE.md
# already records from test-state-packages.sh, and which the 96
# grep-based checks around them could never have hit. What is under
# test is the name class and the ordering, not the privilege check.
NOROOT="$WORK/slot-noroot"
sed 's/^    need_root$/    :/' "$TOOL" > "$NOROOT"
check "need_root really went"  "$(grep -c '^    need_root$' "$NOROOT")" "0"
OUT="$($SH_BIN "$NOROOT" install 'foo; rm -rf /' 2>&1)"
check "a metacharacter is refused" "$(printf '%s' "$OUT" | grep -c 'not a usable package name')" "1"
OUT="$($SH_BIN "$NOROOT" install -- 2>&1)"
check "a leading dash is refused"  "$(printf '%s' "$OUT" | grep -c 'not a usable package name')" "1"
# EVERY REFUSAL BEFORE ANY WORK. `install` with no arguments used to
# mount the slot, seed it (47 seconds, 760 MB) and bind three
# filesystems into it before printing a usage line -- the same lesson
# as the --ab --encrypt refusal that sat after the "is that a block
# device" test. These run on a host with no slots at all, so reaching
# the name check at all proves it comes first: resolve_slots would
# have died with "one root slot" otherwise.
OUT="$($SH_BIN "$NOROOT" install 2>&1)"
check "no arguments is refused"    "$(printf '%s' "$OUT" | grep -c 'install <package>\.\.\.')" "1"
check "and before resolve_slots"   "$(printf '%s' "$OUT" | grep -c 'one root slot')" "0"
# A name that is FINE must get past the check and reach the real
# refusal, or the guard is just rejecting everything (RFC 0031's dead
# `''` branch, and this file's own newline guard).
OUT="$($SH_BIN "$NOROOT" install sqlite 2>&1)"
check "a real name gets through"   "$(printf '%s' "$OUT" | grep -c 'not a usable package name')" "0"
check "and reaches the slot check" "$(printf '%s' "$OUT" | grep -c 'one root slot')" "1"

part "novi-agent describes the slots, and READS to do it"
AGENT="packages/novi-agent"
check "there is a slots section"   "$(grep -c '^describe_slots() {' "$AGENT")" "1"
check "it is in the text document" "$(grep -c '^        describe_slots$' "$AGENT")" "1"
check "and in the JSON one"        "$(grep -c '"slots": %s' "$AGENT")" "1"
# RFC 0029 decision 1: describing is free because it is a view of files
# any user can already read. `novi-slot status` MOUNTS the other slot,
# so describe must not call it -- and the sandbox section made exactly
# this call for the same reason (RFC 0039 item 5).
# MATCH THE INVOCATION, NOT THE MENTION -- for the second time in this
# repository, and caught the same way. The function's own comments name
# novi-grubenv (to say it is deliberately NOT shelled out to), so a
# grep over the body reported the tool as being run by the code that
# explains why it is not. Comment lines are dropped first.
SLOTFN="$(awk '/^describe_slots\(\) \{/,/^}/' "$AGENT" | grep -v '^[[:space:]]*#')"
check "it does not run novi-slot"   "$(printf '%s' "$SLOTFN" | grep -c 'novi-slot')" "0"
check "nor novi-grubenv"            "$(printf '%s' "$SLOTFN" | grep -c 'novi-grubenv')" "0"
check "nor blkid, which needs root" "$(printf '%s' "$SLOTFN" | grep -c 'blkid')" "0"
check "nor mount"                   "$(printf '%s' "$SLOTFN" | grep -c 'mount ')" "0"
# It reads the two files it can: the kernel command line and the
# environment block. Getting from /dev/vda2 to a LABEL means opening
# the block device, which is root's -- a description that only works
# for root is not the free read decision 1 describes.
check "it reads /proc/cmdline"      "$(printf '%s' "$SLOTFN" | grep -c '/proc/cmdline')" "1"
check "and the environment block"   "$(printf '%s' "$SLOTFN" | grep -c '/boot/grub/grubenv')" "1"
# A machine with one slot says so rather than reporting zeros, which is
# describe_idle's rule about an instrument that is not there.
check "absent is its own answer"    "$(printf '%s' "$SLOTFN" | grep -c '"present": false')" "1"
# And the two readers disagree about their source ON PURPOSE, so the
# file has to say why or somebody will "fix" one of them.
# The two readers disagree about their SOURCE on purpose -- novi-slot
# reads the mount, this reads the command line -- so the reason has to
# be written down beside the function or somebody will "fix" one of
# them into agreement with the other.
check "the disagreement is written down" \
    "$(grep -B30 '^describe_slots() {' "$AGENT" | grep -c 'RFC 0014')" "1"

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

part "/etc is the slot's own, and switch says what that costs"
# RFC 0041 item 1 left `/etc` open. The answer is slot-local and the
# ARGUMENT IS IN THE TREE rather than in anybody's taste:
# /etc/s6-linux-init/scripts/rc.init is the stage-2 boot script and
# /etc/s6-rc/compiled is the generated service database beside it. A
# shared /etc means the old slot boots the NEW slot's rc.init -- so the
# one boot the rollback exists to rescue would run the failed update's
# own boot script, and the net would share its single point of failure
# with the thing it catches (item 5).
for RFS in build/rootfs /build/rootfs; do
    [ -d "$RFS/etc" ] || continue
    check "the boot script is in /etc"   "$([ -f "$RFS/etc/s6-linux-init/scripts/rc.init" ] && echo yes)" "yes"
    check "so is the compiled s6-rc db"  "$([ -d "$RFS/etc/s6-rc/compiled" ] && echo yes)" "yes"
    break
done
# And the file must no longer claim item 5 is absent -- it is here.
check "no stale 'not here yet' about the trial rule" \
    "$(grep -c 'item 5 and is deliberately not here yet' "$TOOL")" "0"

FN="$WORK/etcfn.sh"
{
    grep '^info() {' "$TOOL"
    grep '^warn() {' "$TOOL"
    sed -n 's/^\(ETC_EXPECTED=.*\)$/\1/p' "$TOOL" | head -1
    sed -n 's/^\(ETC_REPORT_MAX=.*\)$/\1/p' "$TOOL" | head -1
    for f in etc_list etc_same etc_diff_list etc_accounts_only_in etc_report; do
        sed -n "/^${f}() {/,/^}/p" "$TOOL"
    done
} > "$FN"
# SYNC_MARK is what ETC_EXPECTED is built from, so take the real one.
sed -n 's/^\(SYNC_MARK=.*\)$/\1/p' "$TOOL" | head -1 | cat - "$FN" > "$FN.x" && mv "$FN.x" "$FN"
check "extracted" "$(grep -c '^etc_report() {' "$FN")" "1"
# shellcheck disable=SC1090
. "$FN"

mketc() {  # $1 root
    mkdir -p "$1/etc/novi"
    printf 'root:x:0:0:root:/root:/bin/sh\n'      > "$1/etc/passwd"
    printf '127.0.0.1 localhost\n'                > "$1/etc/hosts"
    printf 'hostname = axiom\n'                   > "$1/etc/novi/system.conf"
    printf 'LABEL=NOVI_ROOT_A / ext4 defaults 0 1\n' > "$1/etc/fstab"
    : > "$1/etc/novi/slot-synced"
    ln -sf /run/novi/resolv.conf "$1/etc/resolv.conf"
}
A="$WORK/etc-a"; B="$WORK/etc-b"; rm -rf "$A" "$B"; mketc "$A"; mketc "$B"

# An absent answer and a negative answer are different things.
OUT="$(etc_report "$A" "$B" b 2>&1)"
check "identical trees say so"  "$(printf '%s' "$OUT" | grep -c "/etc matches slot b's copy")" "1"
check "and name no file"        "$(printf '%s' "$OUT" | grep -c 'differ from slot')" "0"

# The two paths `sync` makes different on purpose are not news.
printf 'LABEL=NOVI_ROOT_B / ext4 defaults 0 1\n' > "$B/etc/fstab"
printf '2026-01-01\n' > "$B/etc/novi/slot-synced"
check "the rewritten fstab is not reported" \
    "$(etc_diff_list "$A" "$B" | grep -cx 'etc/fstab')" "0"
check "nor is the sync marker" \
    "$(etc_diff_list "$A" "$B" | grep -cx 'etc/novi/slot-synced')" "0"
# ...and the exclusion is doing something, rather than the two files
# happening to match. Provoked, because a filter that filters nothing
# reads exactly like one that works.
check "without the exclusion, both would be" \
    "$(ETC_EXPECTED="" etc_diff_list "$A" "$B" | grep -cx 'etc/fstab\|etc/novi/slot-synced')" "2"

printf 'hostname = other\n' > "$B/etc/novi/system.conf"
printf 'secret\n'           > "$A/etc/novi/wifi.conf"
LIST="$(etc_diff_list "$A" "$B")"
check "a changed file is named"        "$(printf '%s\n' "$LIST" | grep -cx 'etc/novi/system.conf')" "1"
check "a file only one side has, too"  "$(printf '%s\n' "$LIST" | grep -cx 'etc/novi/wifi.conf')" "1"
check "and nothing else is"            "$(printf '%s\n' "$LIST" | grep -c .)" "2"

# A SYMLINK IS COMPARED BY ITS TARGET. /etc/resolv.conf is one, so a
# comparison that followed links would be reading the running system's
# runtime state twice and calling it agreement -- and a package that
# replaced a link with a real file would go unreported.
rm -f "$B/etc/resolv.conf"; printf 'nameserver 1.1.1.1\n' > "$B/etc/resolv.conf"
check "a link replaced by a file differs" \
    "$(etc_diff_list "$A" "$B" | grep -cx 'etc/resolv.conf')" "1"
rm -f "$B/etc/resolv.conf"; ln -s /run/novi/other "$B/etc/resolv.conf"
check "two links to different targets differ" \
    "$(etc_diff_list "$A" "$B" | grep -cx 'etc/resolv.conf')" "1"
rm -f "$B/etc/resolv.conf"; ln -s /run/novi/resolv.conf "$B/etc/resolv.conf"
check "two links to the same target do not" \
    "$(etc_diff_list "$A" "$B" | grep -cx 'etc/resolv.conf')" "0"

# A list that shows a subset must say so.
for i in 1 2 3 4 5 6 7 8 9 10; do printf 'x\n' > "$A/etc/f${i}"; done
OUT="$(etc_report "$A" "$B" b 2>&1)"
check "twelve differences are counted"  "$(printf '%s' "$OUT" | grep -c '12 file(s) differ')" "1"
check "eight are shown"                 "$(printf '%s' "$OUT" | grep -c '^       etc/')" "8"
check "and the rest are admitted"       "$(printf '%s' "$OUT" | grep -c '\.\.\. and 4 more')" "1"
for i in 1 2 3 4 5 6 7 8 9 10; do rm -f "$A/etc/f${i}"; done

# ACCOUNTS GET THEIR OWN SENTENCE, because /home is on the shared
# partition and /etc/passwd is not: a name on one side only is a home
# directory the other slot can see with nothing behind it.
printf 'root:x:0:0:root:/root:/bin/sh\nalice:x:1000:1000::/home/alice:/bin/sh\n' > "$A/etc/passwd"
check "an account only here is named" "$(etc_accounts_only_in "$A" "$B")" "alice"
check "the other direction is not"    "$(etc_accounts_only_in "$B" "$A")" ""
OUT="$(etc_report "$A" "$B" b 2>&1)"
check "the report says so"            "$(printf '%s' "$OUT" | grep -c 'slot b has no account for: alice')" "1"
check "and says what it costs"        "$(printf '%s' "$OUT" | grep -c 'shared partition')" "1"
# A QUERY THAT FAILED IS NOT AN EMPTY ANSWER: with no passwd to read on
# the far side, claiming every account is about to be orphaned would be
# the loudest possible wrong answer.
mv "$B/etc/passwd" "$WORK/passwd.away"
check "an unreadable far passwd claims nothing" "$(etc_accounts_only_in "$A" "$B")" ""
mv "$WORK/passwd.away" "$B/etc/passwd"

# A slot that cannot be listed at all is a failed query, not a clean one.
check "a missing far /etc is a failure" \
    "$(etc_diff_list "$A" "$WORK/nowhere" >/dev/null 2>&1; echo $?)" "1"
OUT="$(etc_report "$A" "$WORK/nowhere" b 2>&1)"
check "and the report says so rather than 'matches'" \
    "$(printf '%s' "$OUT" | grep -c 'could not compare')" "1"

# THE WIRING, not the mention: the report is only worth anything if the
# real command calls it, with the running system on one side and the
# mounted slot on the other.
CS="$(sed -n '/^cmd_switch() {/,/^}/p' "$TOOL")"
check "cmd_switch calls it"       "$(printf '%s\n' "$CS" | grep -c 'etc_report "" "\$MNT" "\$want"')" "1"
check "before it unmounts"        "$([ "$(printf '%s\n' "$CS" | grep -n 'etc_report' | cut -d: -f1)" \
                                      -lt "$(printf '%s\n' "$CS" | grep -n 'cleanup' | head -1 | cut -d: -f1)" ] && echo yes)" "yes"
# switch and rollback are one implementation, so one call site serves
# both -- and the dispatcher is what says so.
check "rollback reaches the same function" \
    "$(grep -c 'rollback) cmd_switch' "$TOOL")" "1"
# IT REFUSES NOTHING. Somebody rolling back is escaping something.
check "the report cannot end the program" \
    "$(sed -n '/^etc_report() {/,/^}/p' "$TOOL" | grep -c 'die ')" "0"
check "nor can the comparison" \
    "$(sed -n '/^etc_diff_list() {/,/^}/p' "$TOOL" | grep -c 'die ')" "0"

# THE SHELL THAT WILL ACTUALLY RUN IT. Everything above is bash on the
# build host; `novi-slot` is `#!/bin/sh` and runs under busybox ash
# against busybox's OWN cmp, readlink, mktemp, find and grep. This repo
# has been caught testing the shell instead of the image before -- the
# /dev/fd bug in `pkg`, verified against the right binary in the wrong
# environment. A busybox-only PATH is the cheap half of that answer.
BB=""
for c in build/rootfs/bin/busybox /build/rootfs/bin/busybox; do
    [ -x "$c" ] && { BB="$(cd "$(dirname "$c")" && pwd)/busybox"; break; }
done
if [ -n "$BB" ]; then
    part "the same comparison under busybox ash, with busybox's applets"
    mkdir -p "$WORK/bb"
    for a in cmp readlink mktemp grep cut sort find wc head sed tr rm mkdir cat printf; do
        check "busybox has ${a}" "$("$BB" --list | grep -cx "$a")" "1"
        ln -sf "$BB" "$WORK/bb/$a"
    done
    # One deterministic fixture, rendered by both shells.
    rm -rf "$A" "$B"; mketc "$A"; mketc "$B"
    printf 'hostname = other\n' > "$B/etc/novi/system.conf"
    printf 'secret\n'           > "$A/etc/novi/wifi.conf"
    printf 'LABEL=NOVI_ROOT_B / ext4 defaults 0 1\n' > "$B/etc/fstab"
    printf 'root:x:0:0:root:/root:/bin/sh\nalice:x:1000:1000::/home/alice:/bin/sh\n' > "$A/etc/passwd"
    BASH_OUT="$(etc_report "$A" "$B" b 2>&1)"
    cat > "$WORK/bb-drive.sh" <<EOF
. "$FN"
etc_report "$A" "$B" b 2>&1
EOF
    ASH_OUT="$(PATH="$WORK/bb" "$BB" ash "$WORK/bb-drive.sh" 2>&1)"
    # THREE: system.conf changed, wifi.conf only here, passwd gained an
    # account. The first version of this line said two and the failure
    # read as busybox behaving differently -- it was the expectation.
    check "ash counts all three"       "$(printf '%s' "$ASH_OUT" | grep -c "3 file(s) differ")" "1"
    check "ash names the account"      "$(printf '%s' "$ASH_OUT" | grep -c 'no account for: alice')" "1"
    check "ash excludes the fstab"     "$(printf '%s' "$ASH_OUT" | grep -c 'etc/fstab')" "0"
    # Byte for byte: an applet that behaves differently is the thing
    # this block exists to find, and a substring check would miss it.
    check "and the two shells agree exactly" "$([ "$ASH_OUT" = "$BASH_OUT" ] && echo yes || printf 'ASH[%s] BASH[%s]' "$ASH_OUT" "$BASH_OUT")" "yes"
fi

echo
echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
