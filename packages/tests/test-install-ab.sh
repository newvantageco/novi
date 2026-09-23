#!/bin/sh
# RFC 0041 item 1: the A/B disk layout, as far as a host can check it.
#
# What a host CAN check is the part that is textual or that BusyBox can
# be made to do on a file: the partition arithmetic, the fstab the
# installer generates, the refusals, and the one invariant that decides
# whether the whole design is coherent.
#
# What it cannot check is an install. That needs a disk, a reboot and
# `mount` saying the binds took -- and a green run here is not that.
#
# THE INVARIANT WORTH MOST IS THE SHORTEST CHECK IN THE FILE:
# `var/lib/pkg` must never appear in STATE_SUBTREES. It is the slot's
# own package manifest, so sharing it would give the running system a
# database describing the OTHER slot -- a machine that lies about what
# it has, to pkg, to `novi-state diff` and to `novi-agent describe`.
# That is a one-word edit somebody could make in good faith, and
# nothing else in the tree would complain.
set -u
cd "$(dirname "$0")/../.." || exit 1
REPO_ROOT="$(pwd)"
INSTALL="${REPO_ROOT}/packages/novi-install"
BB="${BB:-/build/rootfs/bin/busybox}"

pass=0; fail=0
ok()   { pass=$((pass+1)); }
bad()  { fail=$((fail+1)); echo "  FAIL: $*"; }
check(){ if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
has()  { case "$2" in *"$3"*) ok ;; *) bad "$1: '$3' not found" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1: '$3' should not be there" ;; *) ok ;; esac; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

echo "== the shared-subtree list"
SUBS="$(sed -n 's/^STATE_SUBTREES="\(.*\)"$/\1/p' "$INSTALL")"
[ -n "$SUBS" ] && ok || bad "STATE_SUBTREES is not defined"
# The slot's own manifest stays in the slot. See the header.
hasnt "STATE_SUBTREES" " $SUBS " " var/lib/pkg "
for want in home var/log var/lib/novi-state var/cache/pkg; do
    has "STATE_SUBTREES" " $SUBS " " $want "
done

echo "== the refusals"
out="$(sh "$INSTALL" install --disk /dev/null --ab --encrypt -y 2>&1)"
has "--ab --encrypt" "$out" "cannot be combined"
out="$(sh "$INSTALL" install --disk /dev/null --ab --slot-mib 512 -y 2>&1)"
has "tiny --slot-mib" "$out" "too small"
out="$(sh "$INSTALL" install --disk /dev/null --ab --slot-mib banana -y 2>&1)"
has "non-numeric --slot-mib" "$out" "must be a number"

echo "== --ab is opt-in: the usage text says what it does not do"
out="$(sh "$INSTALL" --help 2>&1)"
has "usage names --ab" "$out" "--ab"
# The phrase wraps in the help text, so match a fragment that does not.
has "usage is honest" "$out" "NOTHING UPDATES OR ROLLS"

echo "== the four-partition arithmetic, against the shipped BusyBox"
# RFC 0018's rule: the shipped busybox is a static x86_64 binary, so
# this class of bug is reproducible on a sparse file in a second and
# does not need a VM. That is how the 63-sector default was found.
if [ -x "$BB" ]; then
    truncate -s 16G "$W/disk.img" 2>/dev/null || dd if=/dev/zero of="$W/disk.img" bs=1 count=0 seek=16G 2>/dev/null
    BOOT_MIB=512; SLOT_MIB=4096
    boot_end=$(( 2048 + BOOT_MIB * 2048 - 1 ))
    a_start=$(( boot_end + 1 )); a_end=$(( a_start + SLOT_MIB * 2048 - 1 ))
    b_start=$(( a_end + 1 ));    b_end=$(( b_start + SLOT_MIB * 2048 - 1 ))
    s_start=$(( b_end + 1 ))
    printf 'o\nn\np\n1\n2048\n%s\nn\np\n2\n%s\n%s\nn\np\n3\n%s\n%s\nn\np\n4\n%s\n\na\n1\nw\n' \
        "$boot_end" "$a_start" "$a_end" "$b_start" "$b_end" "$s_start" \
        | "$BB" fdisk -u "$W/disk.img" >/dev/null 2>&1
    tbl="$("$BB" fdisk -u -l "$W/disk.img" 2>/dev/null)"
    check "four partitions" "$(printf '%s\n' "$tbl" | grep -c 'disk\.img[1-4] ')" "4"
    # THE 63-SECTOR TRAP: BusyBox fdisk's default first sector for a new
    # partition is the start of the disk, not the first free sector.
    # Every sector is given explicitly for that reason, and this is the
    # check that would notice if somebody stopped doing it.
    hasnt "no partition starts at 63" "$tbl" "         63 "
    has "p1 is bootable"  "$tbl" "disk.img1 *"
    has "p2 starts after /boot" "$tbl" " $a_start "
    has "p3 starts after slot A" "$tbl" " $b_start "
    has "p4 starts after slot B" "$tbl" " $s_start "
else
    echo "  (no shipped busybox at $BB -- skipping the partition-table checks)"
fi

echo "== the fstab the installer would write"
# Driven through the REAL generator, extracted from the installer: a
# test that holds its own copy of the format stops checking the one
# that ships. Sourcing the whole program would run its argument parser,
# so the one function is cut out -- the same doctoring the other tests
# here do to reach inside a program with a main().
{
    echo 'msg() { :; }'
    sed -n '/^write_fstab() {/,/^}/p' "$INSTALL"
    echo 'write_fstab'
} > "$W/gen.sh"

mkdir -p "$W/t/etc"
(
    MNT="$W/t" ROOT_LABEL=NOVI_ROOT_A ROOT_FSTYPE=ext4 \
    STATE_LABEL=NOVI_STATE STATE_PART=/dev/vda4 BOOT_PART=/dev/vda1 \
    ESP_PART="" BOOT_LABEL=NOVI_BOOT STATE_SUBTREES="$SUBS" \
    sh "$W/gen.sh"
) >/dev/null 2>&1
fstab="$(cat "$W/t/etc/fstab" 2>/dev/null || true)"
if [ -n "$fstab" ]; then
    has "root by label"     "$fstab" "LABEL=NOVI_ROOT_A"
    has "state by label"    "$fstab" "LABEL=NOVI_STATE"
    has "state mount point" "$fstab" "/state"
    has "boot still there"  "$fstab" "LABEL=NOVI_BOOT"
    for sub in $SUBS; do
        has "bind for /$sub" "$fstab" "/state/$sub"
    done
    hasnt "no bind for the slot's own manifest" "$fstab" "/state/var/lib/pkg"
    # /state has to be mounted before anything is bound out of it, and
    # `mount -a` processes fstab IN ORDER.
    sl="$(printf '%s\n' "$fstab" | grep -n 'LABEL=NOVI_STATE' | head -1 | cut -d: -f1)"
    bl="$(printf '%s\n' "$fstab" | grep -n '^/state/' | head -1 | cut -d: -f1)"
    if [ -n "$sl" ] && [ -n "$bl" ] && [ "$sl" -lt "$bl" ]; then ok
    else bad "the /state mount must come before the binds (got '$sl' vs '$bl')"; fi
else
    bad "write_fstab produced nothing"
fi

echo "== and no state partition means no state lines at all"
# Every machine installed before --ab existed, and every live boot.
rm -f "$W/t/etc/fstab"
(
    MNT="$W/t" ROOT_LABEL=NOVI_ROOT ROOT_FSTYPE=ext4 \
    STATE_LABEL=NOVI_STATE STATE_PART="" BOOT_PART="" ESP_PART="" \
    BOOT_LABEL=NOVI_BOOT STATE_SUBTREES="$SUBS" \
    sh "$W/gen.sh"
) >/dev/null 2>&1
plain="$(cat "$W/t/etc/fstab" 2>/dev/null || true)"
has   "plain fstab has a root" "$plain" "LABEL=NOVI_ROOT"
hasnt "plain fstab has no /state" "$plain" "/state"

echo "== a separate /boot is a FACT, not a reason"
# Three places used to test $ENCRYPT where they meant "is partition 1
# the boot partition". RFC 0018's encrypted layout was the only reason
# there had ever been; --ab is the second. With the old test an --ab
# install would have written core.img, whose prefix is
# (hd0,msdos1)/boot/grub, onto a disk whose partition 1 IS /boot -- so
# GRUB would have looked for /boot/boot/grub and the machine would not
# have booted.
{
    sed -n '/^separate_boot() /p' "$INSTALL"
    sed -n '/^kernel_grub_prefix() {/,/^}/p' "$INSTALL"
    echo 'printf "prefix=[%s]\n" "$(kernel_grub_prefix)"'
} > "$W/pfx.sh"
out="$(ENCRYPT=0 BOOT_PART=/dev/vda1 sh "$W/pfx.sh" 2>&1)"
check "unencrypted, separate /boot" "$out" "prefix=[]"
out="$(ENCRYPT=1 BOOT_PART=/dev/vda1 sh "$W/pfx.sh" 2>&1)"
check "encrypted, separate /boot"   "$out" "prefix=[]"
out="$(ENCRYPT=0 BOOT_PART="" sh "$W/pfx.sh" 2>&1)"
check "plain single-root install"   "$out" "prefix=[/boot]"
# And the bootloader picks its core.img from the same predicate.
has "core-boot.img keyed on the fact" \
    "$(sed -n '/^install_bootloader_bios() {/,/^}/p' "$INSTALL")" \
    "if separate_boot; then"

echo "== novi-gpt writes four entries for --slot-mib, and still two without"
# Built for the HOST and run against a sparse file, then read back with
# util-linux -- a tool that did not write it, which is how RFC 0008
# verified the original layout and the only check worth much about a
# structure this rigid.
if command -v gcc >/dev/null 2>&1 && command -v partx >/dev/null 2>&1; then
    if gcc -O2 -o "$W/novi-gpt" "${REPO_ROOT}/novi-gpt/main.c" 2>"$W/cc.log"; then
        truncate -s 20G "$W/g.img" 2>/dev/null
        "$W/novi-gpt" "$W/g.img" --slot-mib 4096 >/dev/null 2>&1
        tbl="$(partx -s "$W/g.img" 2>/dev/null)"
        check "four partitions" "$(printf '%s\n' "$tbl" | grep -c '^ *[0-9]')" "4"
        for want in NOVI_ESP NOVI_ROOT_A NOVI_ROOT_B NOVI_STATE; do
            has "gpt has $want" "$tbl" "$want"
        done
        hasnt "no plain NOVI_ROOT in the A/B layout" "$tbl" "NOVI_ROOT "
        # 1 MiB alignment on every partition: a start that is not a
        # multiple of 2048 sectors straddles an erase block on flash,
        # which is invisible until somebody measures write latency.
        #
        # Provoking this found the PROVOCATION was wrong rather than
        # the check: deleting novi-gpt's round-up left every partition
        # aligned anyway, because --slot-mib is whole MiB so the slot
        # length is already a multiple of 2048. It takes a real
        # misalignment to make it fire, and then it does.
        badalign=0
        for st in $(printf '%s\n' "$tbl" | awk '/^ *[0-9]/{print $2}'); do
            [ $(( st % 2048 )) -eq 0 ] || badalign=$((badalign+1))
        done
        check "every partition is 1 MiB aligned" "$badalign" "0"
        # The two-partition layout is untouched.
        truncate -s 20G "$W/g2.img" 2>/dev/null
        "$W/novi-gpt" "$W/g2.img" >/dev/null 2>&1
        tbl2="$(partx -s "$W/g2.img" 2>/dev/null)"
        check "still two without --slot-mib" "$(printf '%s\n' "$tbl2" | grep -c '^ *[0-9]')" "2"
        has "and the plain root label" "$tbl2" "NOVI_ROOT"
        # A slot size the disk cannot hold is refused, not truncated.
        truncate -s 3G "$W/g3.img" 2>/dev/null
        out="$("$W/novi-gpt" "$W/g3.img" --slot-mib 4096 2>&1)"
        has "too-small disk refused" "$out" "too small"
    else
        bad "novi-gpt did not compile: $(head -1 "$W/cc.log")"
    fi
else
    echo "  (no gcc or no partx -- skipping the novi-gpt checks)"
fi

echo ""
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
