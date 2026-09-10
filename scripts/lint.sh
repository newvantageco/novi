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
# them for real is disproportionately expensive: 40-repo.sh wipes
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
for t in packages/tests/test-lib-json.sh packages/tests/test-agent-verbs.sh \
         packages/tests/test-agent-secrets.sh; do
    echo ">>> ${t##*/}"
    if ! bash "$t"; then
        echo ">>> ${t} failed" >&2
        exit 1
    fi
done
exit 0
