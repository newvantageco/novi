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
if shellcheck -S error -e "${EXCLUDE}" "${FILES[@]}"; then
    echo ">>> clean"
    exit 0
fi
echo ">>> shellcheck reported error-severity findings (above)" >&2
exit 1
