#!/bin/bash
# ============================================================
# test-grubenv.sh — novi-grubenv, against GRUB's own tools.
#
# WHAT THIS IS ABOUT. RFC 0041 needs a boot that can be steered from
# userland, which means writing GRUB's environment block. The tool
# every other distribution uses for that is `grub-editenv`, part of a
# GRUB userland this system does not have -- so `packages/novi-grubenv`
# writes the format itself, and the format is fixed bytes: a 1024-byte
# file beginning with a byte-exact signature, `name=value` lines, and
# `#` padding.
#
# EVERY WAY TO GET IT WRONG IS SILENT. GRUB does not report a malformed
# block; `load_env` reads what it can and boots with whatever it got.
# A missing trailing newline on the last line makes GRUB discard that
# variable -- 1024 bytes, correct signature, right-looking content, one
# variable quietly absent -- which is exactly the bug this found in its
# own subject before it found anything else.
#
# SO THE ORACLE IS GRUB'S OWN READER, not a reimplementation of
# envblk.c in this file. Two implementations agreeing about a format is
# worth something; one implementation agreeing with itself is not.
# `grub-editenv` writes and novi-grubenv reads, then the reverse. CI
# installs grub-common for this, on the argument the keys test already
# won: a check that skips itself where its tool is missing skips itself
# in the one place it needs to run.
#
# And the shell is the SHIPPED busybox ash where there is one. This
# script runs on the target, and `/bin/sh` on a CI runner is dash.
# ============================================================
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

TOOL="packages/novi-grubenv"
SH_BIN="bash"
for c in build/rootfs/bin/busybox /build/rootfs/bin/busybox; do
    [ -x "$c" ] && { SH_BIN="$c ash"; break; }
done

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL: $*"; }
check(){ if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$3], got [$2]"; fi; }
part() { echo "== $*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
D="$WORK/grub"; mkdir -p "$D"; : > "$D/grub.cfg"
export NOVI_GRUBENV_DIR="$D"

# EVERY WRITE HERE NEEDS ROOT AND A CI RUNNER IS NOT. `need_root` guards
# a file the bootloader reads, which is root's by rights -- and what is
# under test is the FORMAT, not the privilege check. Locally this ran as
# root and passed; on the runner all 22 write checks failed at once with
# "This operation requires root." CLAUDE.md already recorded that shape
# from the packages test.
#
# A SHIM ON PATH RATHER THAN A DOCTORED COPY, so the file that runs is
# the file that ships. (The doctored copy was tried first and was worse
# in the way these things usually are: `sed` rewrote the first line of
# need_root and left its old body behind as top-level code.) The one
# fact being lied about is the caller's uid, which is irrelevant to
# every claim below.
mkdir -p "$WORK/bin"
printf '#!/bin/sh\ncase "$*" in -u) echo 0 ;; *) exec /usr/bin/id "$@" ;; esac\n' \
    > "$WORK/bin/id"
chmod 755 "$WORK/bin/id"
PATH="$WORK/bin:$PATH"; export PATH
G() { $SH_BIN "$TOOL" "$@"; }

SIG="# GRUB Environment Block"

part "the block is exactly 1024 bytes, with the signature GRUB demands"
G create >/dev/null 2>&1
check "size" "$(wc -c < "$D/grubenv" | tr -d ' ')" "1024"
check "signature" "$(head -c ${#SIG} "$D/grubenv")" "$SIG"
# The byte after the signature must be a newline: GRUB compares the
# signature INCLUDING it, so a block that merely starts with the right
# text is one GRUB rejects outright.
check "signature newline" \
    "$(dd if="$D/grubenv" bs=1 skip=${#SIG} count=1 2>/dev/null | od -An -c | tr -d ' ')" '\n'
# The rest is padding, and padding is `#` because GRUB skips a line
# that begins with one. Any other filler would parse as a variable.
check "padding is #" \
    "$(tail -c 100 "$D/grubenv" | tr -d '#' | wc -c | tr -d ' ')" "0"

part "a value survives a round trip, and the file stays 1024 bytes"
G set novi_slot=a >/dev/null 2>&1
check "get"   "$(G get novi_slot)" "a"
check "size"  "$(wc -c < "$D/grubenv" | tr -d ' ')" "1024"
G set novi_slot=b boot_try=2 >/dev/null 2>&1
check "overwritten"  "$(G get novi_slot)" "b"
check "second key"   "$(G get boot_try)" "2"
check "size again"   "$(wc -c < "$D/grubenv" | tr -d ' ')" "1024"
G unset boot_try >/dev/null 2>&1
check "unset"        "$(G get boot_try; echo "rc=$?")" "rc=1"
check "survivor"     "$(G get novi_slot)" "b"

part "EVERY LINE IS TERMINATED -- the bug that looks like nothing"
# The last variable used to run straight into the padding
# (`boot_try=2####...`), which GRUB reads as a record with no
# terminator and DISCARDS. The file was 1024 bytes and looked right.
# What proves it is a newline between the value and the first `#`.
G set only_one=zz >/dev/null 2>&1
check "value then newline then padding" \
    "$(tr -d '\0' < "$D/grubenv" | grep -c '^only_one=zz$')" "1"

part "refusals leave the file exactly as it was"
G create >/dev/null 2>&1; G set keep=yes >/dev/null 2>&1
BEFORE="$(md5sum < "$D/grubenv")"
check "space in name"  "$(G set 'bad name=x' 2>&1 | grep -c 'not a usable variable name')" "1"
check "leading digit"  "$(G set '9x=1'       2>&1 | grep -c 'not a usable variable name')" "1"
check "no equals"      "$(G set 'noequals'   2>&1 | grep -c 'not a name=value pair')" "1"
# A newline in a value would end the record and make every byte after
# it somebody else's variable. Nothing in this format escapes.
check "newline in value" \
    "$(G set "x=$(printf 'a\nb=evil')" 2>&1 | grep -c 'may not contain a newline')" "1"
# THE FIRST VERSION OF THAT GUARD COULD NOT FIRE. `case "$value" in
# *"$(printf '\n')"*)` -- a command substitution strips trailing
# newlines, so the pattern was `**` and it refused every value. This
# is the other half of the check: a plain value must still go through.
G set plain=ok >/dev/null 2>&1
check "a plain value is still accepted" "$(G get plain)" "ok"
G unset plain >/dev/null 2>&1
check "file unchanged by the refusals" "$(md5sum < "$D/grubenv")" "$BEFORE"

part "the size limit refuses rather than truncating"
# 1024 - (24 signature + 1 newline) - len("k=") - 1 newline = 996.
G create >/dev/null 2>&1
BIG996="$(head -c 996 /dev/zero | tr '\0' 'y')"
G set "k=$BIG996" >/dev/null 2>&1
check "996 fits exactly"  "$(wc -c < "$D/grubenv" | tr -d ' ')" "1024"
check "and reads back"    "$(G get k | wc -c | tr -d ' ')" "997"
G create >/dev/null 2>&1
BEFORE="$(md5sum < "$D/grubenv")"
OUT="$(G set "k=${BIG996}y" 2>&1)"
check "997 is refused"    "$(printf '%s' "$OUT" | grep -c 'do not fit')" "1"
check "and nothing is written" "$(md5sum < "$D/grubenv")" "$BEFORE"
# A REFUSED WRITE MUST NOT REPORT SUCCESS. write_block used to be fed
# through a pipe, which put it in a subshell -- so its `die` ended only
# the subshell and the caller went on to print "wrote". The pipeline
# trap this repository keeps meeting.
check "and does not say it wrote" "$(printf '%s' "$OUT" | grep -c 'wrote')" "0"

part "the path is found from grub.cfg, not from /sys/firmware/efi"
unset NOVI_GRUBENV_DIR
OUT="$(env -u NOVI_GRUBENV_DIR $SH_BIN "$TOOL" path 2>&1)"
case "$OUT" in
    /boot/efi/EFI/BOOT/grubenv|/boot/grub/grubenv) ok ;;
    *"no grub.cfg found"*) ok ;;   # a build host, which has neither
    *) bad "path on a host with no grub.cfg: [$OUT]" ;;
esac
# A UEFI machine whose ESP did not mount still has /sys/firmware/efi
# and has nowhere GRUB will read. The refusal has to be the answer.
check "the refusal names the reason" \
    "$(printf '%s' "$OUT" | grep -c 'grub.cfg\|grubenv')" "1"
export NOVI_GRUBENV_DIR="$D"

part "GRUB'S OWN READER agrees, in both directions"
if command -v grub-editenv >/dev/null 2>&1; then
    G create >/dev/null 2>&1
    G set novi_slot=b boot_try=3 >/dev/null 2>&1
    check "grub-editenv reads novi_slot" \
        "$(grub-editenv "$D/grubenv" list | sed -n 's/^novi_slot=//p')" "b"
    check "grub-editenv reads boot_try" \
        "$(grub-editenv "$D/grubenv" list | sed -n 's/^boot_try=//p')" "3"
    check "and sees NOTHING else" \
        "$(grub-editenv "$D/grubenv" list | wc -l | tr -d ' ')" "2"
    # The reverse: GRUB writes, we read. A value with spaces, because
    # the format does not quote and a reader that split on whitespace
    # would lose everything after the first word.
    grub-editenv "$D/grubenv" set "from_grub=a b c"
    check "we read what grub-editenv wrote" "$(G get from_grub)" "a b c"
    check "and still see ours"              "$(G get novi_slot)" "b"
    # An empty block written by grub-editenv must read as empty here,
    # not as one variable called "WARNING" -- grub-editenv's own header
    # has a second comment line, and a reader that only skipped the
    # signature would pick it up.
    grub-editenv "$D/grubenv" create
    check "an empty grub-editenv block reads empty" "$(G list | wc -l | tr -d ' ')" "0"
else
    echo "  !! grub-editenv is not installed -- the cross-check did not run."
    echo "  !! CI installs grub-common so that it does. Install it locally with:"
    echo "  !!   sudo apt-get install grub-common"
    FAIL=$((FAIL+1))
fi

part "the installed menu is valid GRUB script, in both shapes"
# write_grub_cfg is pulled out of novi-install rather than copied: a
# test holding its own copy of a generator tests the copy. The range
# ends at the first `}` AFTER the heredoc terminator, because the
# menuentries inside the heredoc close with a `}` in column 0.
FN="$WORK/fn.sh"
awk '/^write_grub_cfg\(\) \{/{p=1} p{print} p&&/^GRUBCFG$/{g=1} g&&/^\}$/{exit}' \
    packages/novi-install > "$FN"
check "the function was extracted" "$(grep -c '^write_grub_cfg() {' "$FN")" "1"
render() {
    cat > "$WORK/drv.sh" <<DRV
set -u
ENCRYPT=0; AB=$1; ROOT_LABEL=NOVI_ROOT_A
SLOT_A_LABEL=NOVI_ROOT_A; SLOT_B_LABEL=NOVI_ROOT_B
BOOT_PART=""; LUKS_NAME=x; LUKS_UUID=y
separate_boot() { [ -n "\$BOOT_PART" ]; }
kernel_grub_prefix() { if [ "\$ENCRYPT" -eq 1 ] || separate_boot; then printf ""; else printf "/boot"; fi; }
. "$FN"
write_grub_cfg "$WORK/$2" ""
DRV
    $SH_BIN "$WORK/drv.sh"
}
render 0 plain.cfg; render 1 ab.cfg

# A MACHINE WITH ONE SLOT MUST BE UNCHANGED. `--ab` is opt-in, and a
# load_env on a machine with no grubenv and no second slot would be
# wiring with nothing on the other end.
check "no env logic without --ab" \
    "$(grep -c 'load_env\|novi_slot' "$WORK/plain.cfg")" "0"
check "and a plain title"        "$(grep -c '^menuentry "Novi Linux" ' "$WORK/plain.cfg")" "1"
check "and three entries"        "$(grep -c '^menuentry ' "$WORK/plain.cfg")" "3"

check "--ab loads the env"       "$(grep -c '^    load_env novi_slot$' "$WORK/ab.cfg")" "1"
# load_env NAMES the variables it accepts. Bare, it imports everything
# in the file into GRUB's environment -- `prefix` and `root` included
# -- so a block somebody appended to could redirect the bootloader.
check "and names them"           "$(grep -c '^ *load_env$' "$WORK/ab.cfg")" "0"
# load_env on a missing or truncated file prints an error and leaves
# novi_slot unset, which reads as slot A. Booting slot A is the right
# answer to "I cannot tell"; the guard is so nobody sees an error
# about a machine that is fine.
check "guarded by -s"            "$(grep -c 'if \[ -s ${prefix}/grubenv \]' "$WORK/ab.cfg")" "1"
check "defaulted before loading" "$(grep -c '^set novi_slot=a$' "$WORK/ab.cfg")" "1"
check "b selects slot B"         "$(grep -c 'set novi_root=LABEL=NOVI_ROOT_B' "$WORK/ab.cfg")" "1"
check "otherwise slot A"         "$(grep -c 'set novi_root=LABEL=NOVI_ROOT_A' "$WORK/ab.cfg")" "1"
# THE OTHER SLOT NEEDS A MENU ENTRY, not just a variable: if the slot
# grubenv names will not boot there is no userland to run novi-grubenv
# in, and without this the recovery path for a failed update is a
# rescue medium.
check "the other slot is on the menu" \
    "$(grep -c 'root=${novi_other}' "$WORK/ab.cfg")" "1"
check "four entries"             "$(grep -c '^menuentry ' "$WORK/ab.cfg")" "4"
check "every boot entry is by variable" \
    "$(grep -c 'root=LABEL=NOVI_ROOT_A rw' "$WORK/ab.cfg")" "0"

if command -v grub-script-check >/dev/null 2>&1; then
    grub-script-check "$WORK/plain.cfg" 2>/dev/null
    check "GRUB parses the one-slot menu" "$?" "0"
    grub-script-check "$WORK/ab.cfg" 2>/dev/null
    check "GRUB parses the A/B menu"      "$?" "0"
else
    echo "  !! grub-script-check is not installed (grub-common)."
    FAIL=$((FAIL+1))
fi

part "loadenv is baked into every image, or none of this runs"
# A module GRUB does not have is a command the menu cannot run, and
# the failure is at boot on somebody's disk. Three images, because
# a machine gets exactly one of them.
for img in "core.img" "core-boot.img" "bootx64.efi"; do
    case "$img" in
        core.img)      pat="-o \"\${NOVI_BOOT_DIR}/core.img\"" ;;
        core-boot.img) pat="-o \"\${NOVI_BOOT_DIR}/core-boot.img\"" ;;
        *)             pat="-o \"\${NOVI_BOOT_DIR}/bootx64.efi\"" ;;
    esac
    n="$(awk -v p="$pat" 'index($0,p){f=1} f&&/loadenv/{print "yes"; exit} f&&/^$/{exit}' scripts/mkiso.sh)"
    check "loadenv in $img" "$n" "yes"
done

echo
echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
