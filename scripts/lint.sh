#!/bin/bash
# ============================================================
# lint.sh — the repository's shell lint, one command.
#
#   bash scripts/lint.sh            report findings
#   bash scripts/lint.sh --list     just list the files that would be checked
#
# CI runs exactly this, so "it passes locally" and "it passes in CI"
# are the same claim. The previous arrangement had CI call a
# third-party action pinned to a commit that does not exist, so every
# run failed at "unable to resolve action" and no script was ever
# actually checked -- 124 consecutive red runs that told nobody
# anything about the code.
#
# What is checked: every *.sh, every s6 service `run` script, and every
# executable whose FIRST line is a shell shebang. Discovery rather than
# a hand-maintained list, for the same reason build.sh discovers its
# stages -- a list goes stale silently, and the previous CI list still
# named two service scripts from before six more existed.
#
# Severity is `error`, and three codes are excluded, each for a stated
# reason rather than to make the number go down:
#
#   SC2086  unquoted expansion. A repo-wide pre-existing style across
#           the whole build/ tree; CLAUDE.md documents it as a known
#           baseline, not a regression to chase.
#   SC2034  unused variable. Fires on the version constants in
#           00-versions.sh, which exist to be sourced by other scripts.
#   SC1091  cannot follow a sourced file. Every build stage sources
#           00-versions.sh by a path shellcheck will not resolve.
# ============================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

EXCLUDE="SC2086,SC2034,SC1091"

collect() {
    {
        find . -path ./.git -prune -o -type f -name '*.sh' -print
        find ./init -type f -name run -print 2>/dev/null
        # Executables whose first line is a shell shebang. Checking the
        # first line specifically matters: a plain `grep -l '#!.*sh'`
        # also matches a shebang inside a fenced code block in a
        # markdown file, which is how an earlier version of this
        # dragged packages/pkg-format.md in and reported 12 "errors" in
        # a specification document.
        find . -path ./.git -prune -o -type f -perm -u+x -print | while read -r f; do
            case "$f" in *.md|*.py|*.c|*.h|*.yml|*.yaml) continue ;; esac
            head -n1 "$f" 2>/dev/null | grep -qE '^#!.*[ /](sh|bash|dash|ash)$' && printf '%s\n' "$f"
        done
    } | sort -u
}

mapfile -t FILES < <(collect)

if [ "${1:-}" = "--list" ]; then
    printf '%s\n' "${FILES[@]}"
    exit 0
fi

if [ "${#FILES[@]}" -eq 0 ]; then
    echo "lint: found no shell scripts to check -- discovery is broken" >&2
    exit 1
fi

echo ">>> shellcheck: ${#FILES[@]} file(s), severity=error, excluding ${EXCLUDE}"
if ! shellcheck -S error -e "${EXCLUDE}" "${FILES[@]}"; then
    echo ">>> shellcheck reported error-severity findings (above)" >&2
    exit 1
fi
echo ">>> clean"

# novi-panel's icon geometry is pure math with no Wayland in it, so
# every state it can draw can be rendered and asserted right here --
# see novi-panel/icons-test.c for why the states a test VM can produce
# are not enough (hwsim reports one signal strength and nothing else).
# It builds with the HOST compiler and links only libm, so it belongs
# in the lint pass rather than in a build stage.
if command -v cc >/dev/null 2>&1; then
    echo ">>> novi-panel icon geometry"
    if ! make -s -C novi-panel check >/dev/null; then
        echo ">>> icon geometry checks failed -- run: make -C novi-panel check" >&2
        exit 1
    fi
    echo ">>> clean"
    # The shipped palettes, parsed by the REAL loader (common/theme.c)
    # and checked against §1's invariants. RFC 0030 found its two bugs
    # by shipping a light theme, screendumping it and looking; that
    # worked and does not scale, because the next palette mistake needs
    # somebody to boot an image and notice. This is the part that can
    # be checked without a VM: elevation ordering, text contrast on
    # every ground it is drawn on, and a pressed control that sinks
    # rather than pops.
    echo ">>> theme palettes"
    if ! make -s -C common check; then
        echo ">>> theme checks failed -- run: make -C common check" >&2
        exit 1
    fi
else
    echo ">>> no host cc -- skipping novi-panel icon geometry checks" >&2
    echo ">>> no host cc -- skipping theme palette checks" >&2
fi

# novi-recon is pure Python and most of what can be wrong in it cannot
# be shown by running it: a real resolver never sends a compression
# pointer loop, a mismatched transaction ID, or a TXT record split
# across chunks, and a live site exercises one row of the clickjacking
# truth table. So the wire format is tested by building messages and
# parsing them back. No network, no downloaded fixtures -- same
# argument as the icon geometry test above.
if command -v python3 >/dev/null 2>&1; then
    echo ">>> novi-recon"
    if ! python3 novi-recon/tests/test_recon.py; then
        echo ">>> novi-recon checks failed -- run: python3 novi-recon/tests/test_recon.py" >&2
        exit 1
    fi
else
    echo ">>> no host python3 -- skipping novi-recon checks" >&2
fi

# pkgsplit's meta-package checks. These are here because provoking
# them for real is disproportionately expensive: 50-repo.sh wipes
# /build/repo before pkgsplit runs and refuses outright on a rootfs
# 41 has already split, so watching the check fire costs a full
# content rebuild. A meta-package that silently drops a member is
# exactly the failure that shipped once already -- a repository of 51
# packages instead of 54, novi-desktop naming three fewer clients, and
# `pkg install novi-desktop` reporting success.
if command -v python3 >/dev/null 2>&1; then
    echo ">>> pkgsplit"
    if ! python3 tools/pkgsplit/test_pkgsplit.py; then
        echo ">>> pkgsplit checks failed -- run: python3 tools/pkgsplit/test_pkgsplit.py" >&2
        exit 1
    fi
fi

# The shell JSON escaper (RFC 0029) is checked under the SHIPPED
# busybox ash, not the host's bash, and against a real JSON parser
# rather than a string comparison. Every JSON document this system
# emits is assembled by a shell script out of strings the shell did
# not choose. The verb-list check catches the other thing two files
# can do to each other: novi-agent dispatches on a list novi-state
# also carries, because that is where a typo in agent.allow is caught.
# The secrets check is the third: wifi.join is the first agent verb
# that handles one, and its refusal path is the part that is easy to
# get wrong -- cmd_do captures args="$*" before dispatch, so refusing
# `wifi.join <ssid> <passphrase>` with "$args" would write that
# passphrase into a 0600 log permanently, by the very refusal meant to
# protect it.
# test-state-document.sh is the last, and it is RFC 0002 roadmap 3's
# half that CI can actually do. That item asked for "`novi-state diff`
# in CI, and a --json projection for tooling", and the --json half
# ALREADY EXISTED when it was written -- built for RFC 0029's agent
# interface, which composes its document out of exactly those modes.
# Fourth roadmap item in this repository found to be wrong about what
# is already built. The real `diff` observes a RUNNING machine, which a
# runner is not; what a runner CAN do is drive the observer over the
# SHIPPED system.conf and check no key comes back `unmanaged`, because
# an unrecognised key is deliberately not an error -- so a typo in that
# document ships as a line that reads declarative and converges
# nothing, the same class as the `power.governor` line that got
# accidentally uncommented. It checks three lists against each other:
# the document, the dispatcher, and the help text that is the only
# place a person learns what a key is called. Its first run found
# `power.lid`, `power.button` and `agent.enabled` live in the shipped
# document and absent from that reference.
#
# test-install-ab.sh is the tenth, and it checks what a HOST can check
# about a disk layout: the partition arithmetic (driven through the
# shipped static BusyBox on a sparse file, RFC 0018's rule), the fstab
# the installer generates, and the refusals. It cannot check an
# install -- that needs a disk and a reboot -- and says so. The
# shortest check in it is the one worth most: `var/lib/pkg` must never
# join STATE_SUBTREES, because it is the slot's own package manifest
# and sharing it would give the running system a database describing
# the OTHER slot. That is a one-word edit somebody could make in good
# faith with nothing else in the tree complaining.
#
# test-slot.sh is the twelfth, and it checks the TEXTUAL half of a tool
# whose other half needs a disk and three boots. Textual is where this
# feature's two worst bugs live, and both are silent: the fstab copied
# into the inactive slot names the OTHER slot as root -- which does not
# stop the machine booting, because /init mounts root from the kernel
# command line, so it just sits there being wrong until something reads
# it -- and the copy's exclusion list runs through live bind mounts, so
# excluding /state alone still copies /home THROUGH its bind while
# excluding the binds alone still copies the whole of /state under
# /state. Either produces a slot that boots perfectly and is quietly
# two copies of everything. The shortest check is still worth the most:
# `var/lib/pkg` must never be shared and never be bound into the
# chroot, because it is the slot's own manifest.
#
# test-grubenv.sh is the eleventh, and its oracle is GRUB's own
# tools. RFC 0041 needs a boot that can be steered from userland, which
# means writing GRUB's environment block -- a fixed 1024 bytes with a
# byte-exact signature and `#` padding, normally written by
# `grub-editenv`, which belongs to a GRUB userland this system does not
# have. So `packages/novi-grubenv` writes the format itself, and every
# way to get it wrong is SILENT: GRUB reports nothing and boots with
# whatever it managed to parse. A missing newline on the last line made
# GRUB discard that variable from a file that was 1024 bytes and looked
# perfectly right -- found by this test, in its own subject, before it
# found anything else. The check is therefore grub-editenv reading what
# we wrote and us reading what grub-editenv wrote, plus
# grub-script-check on the generated menu; `grub-common` is installed in
# CI for the same reason libxkbcommon-dev is, because a test that skips
# itself where its tool is missing skips itself where it is needed.
#
# test-dead-applets.sh is the ninth, and its subject is a table of
# CLAIMS about a kernel. `kernel/dead-applets` says which busybox
# applets need which CONFIG_ symbol, and the removal is derived from
# the GENERATED config so that turning a symbol on restores the
# command -- which means a typo'd applet name sits there forever doing
# nothing, and a broken "the symbol is set" branch deletes a working
# command on every build. Neither shows up in a diff. Its first run
# found four rows naming MTD tools this busybox config does not
# compile at all, and its own fixture left every symlink dangling, so
# `[ -e ]` read "gone" whether or not the script had run.
#
# test-pkg-conflicts.sh is the eighth, and it guards the other half of
# what `pkg install` does as root: not "is this archive what the index
# says", but "is this path somebody else's". It extracted over the root
# filesystem with no owner check at all, and the live case was one
# package deep -- binutils ships usr/bin/strings where the base has a
# busybox symlink, so removing binutils deleted a command the base
# image had. The test provokes all four branches (own file, another
# package's, unowned, declared) because the interesting one is the
# third, and confirmed by removing the check (15 of 28 fail) and by
# removing only the restore-on-remove half (3 fail).
#
# test-state-lock.sh is the seventh, and it is the only one here that
# has to PROVE ITS OWN BUG before it can prove the fix: it runs the
# same two-writer race against a copy with the locking removed and
# fails if that copy stops losing a write. A green test over a race
# that no longer reproduces is a test that has stopped watching.
# test-agent-text.sh is the sixth, and it guards a kind of drift the
# others do not: `describe` emits the same facts twice, as JSON and as
# a table, and a field added to one branch and forgotten in the other
# is invisible in a diff and looks like nothing when you run it. The
# check needs no list of its own -- every string value in the document
# must appear in the table.
# test-services.sh is the fifth, and the only one whose subject is a
# DATA file: /etc/services is parsed by musl rather than by anything
# in this repository, and every way to get it wrong -- a line past
# musl's 128-byte fgets buffer, a name past the 32 bytes
# reverse_services() will copy, a duplicated port -- is skipped
# silently and comes back as a bare number, which is exactly what a
# port with no name looks like. A typo in it is indistinguishable from
# the feature working.
# test-network-static.sh is the fourth of this shape: `network.address`
# is the first value in system.conf that becomes an argument to `ip
# addr add`, and every interesting way to get it wrong is textual --
# an octet of 256, a leading zero, a leading dot whose empty field
# field-splitting silently drops. None of those need a machine, and
# none of them would ever be produced by one.
for t in packages/tests/test-lib-json.sh packages/tests/test-agent-verbs.sh \
         packages/tests/test-agent-secrets.sh packages/tests/test-agent-rate.sh \
         packages/tests/test-agent-socket.sh packages/tests/test-network-static.sh \
         packages/tests/test-power-idle.sh \
         packages/tests/test-agent-idle.sh \
         packages/tests/test-state-packages.sh \
         packages/tests/test-services.sh \
         packages/tests/test-agent-text.sh \
         packages/tests/test-state-lock.sh \
         packages/tests/test-state-document.sh \
         packages/tests/test-agent-sandbox.sh \
         packages/tests/test-pkg-conflicts.sh \
         packages/tests/test-dead-applets.sh \
         packages/tests/test-install-ab.sh \
         packages/tests/test-grubenv.sh \
         packages/tests/test-slot.sh \
         packages/tests/test-pkg-lifecycle.sh \
         packages/tests/test-pkg-cache-hash.sh; do
    echo ">>> ${t##*/}"
    if ! bash "$t"; then
        echo ">>> ${t} failed" >&2
        exit 1
    fi
done
exit 0
