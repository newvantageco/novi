#!/bin/bash
# ============================================================
# test-agent-verbs.sh — the verb list exists twice, so check it
#
# `novi-agent` carries VERBS because it dispatches on them.
# `novi-state` carries AGENT_VERBS because that is where a typo in
# `agent.allow` is CAUGHT -- a list living only in the tool being
# configured cannot be validated by the thing that validates the
# document.
#
# Two copies of a list is how a policy file ends up permitting a verb
# nothing implements, or refusing one that exists. This repository's
# usual answer is one table both readers share
# (`common/keybindings.h`), and that is not available across two
# standalone shell scripts installed at different paths. So the answer
# is the other one: derive nothing, and check the two against each
# other on every lint run.
#
# It also checks that every verb in the list is actually DISPATCHED by
# novi-agent's case statement. A verb that passes the policy check and
# then falls through to no branch reports success having done nothing,
# which is the worst failure this interface could have.
# ============================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

AGENT=packages/novi-agent
STATE=packages/novi-state

fail=0
note() { echo "   ! $*"; fail=1; }

agent_verbs=$(sed -n 's/^VERBS="\(.*\)"$/\1/p' "${AGENT}")
state_verbs=$(sed -n 's/^AGENT_VERBS="\(.*\)"$/\1/p' "${STATE}")

[ -n "${agent_verbs}" ] || note "no VERBS= line in ${AGENT}"
[ -n "${state_verbs}" ] || note "no AGENT_VERBS= line in ${STATE}"

sorted() { printf '%s\n' $1 | sort; }

if [ "$(sorted "${agent_verbs}")" != "$(sorted "${state_verbs}")" ]; then
    note "the two verb lists disagree:"
    note "  ${AGENT}: ${agent_verbs}"
    note "  ${STATE}: ${state_verbs}"
fi

# Every verb must have a branch in cmd_do's case statement.
for v in ${agent_verbs}; do
    grep -qE "^[[:space:]]*${v//./\\.}\)" "${AGENT}" \
        || note "verb '${v}' is in VERBS but has no branch in ${AGENT}"
done

# THE USAGE TEXT IS A THIRD LIST, and it had already drifted: wifi.join
# was dispatched, permitted by novi-state and absent from `novi-agent`
# with no arguments -- so the one place a person looks to find out what
# this interface can do did not mention the newest thing it could do.
# A capability nobody can discover is not one.
usage_text=$(sed -n "/<<'USAGE'/,/^USAGE\$/p" "${AGENT}")
for v in ${agent_verbs}; do
    case "${usage_text}" in
        *"${v}"*) ;;
        *) note "verb '${v}' is dispatched but never named in novi-agent's usage" ;;
    esac
done

# And nothing may claim to be a verb without being in the list -- a
# branch for `exec)` would be exactly the hole this interface's whole
# argument depends on not existing.
if grep -qE '^[[:space:]]*(exec|shell|run)\)' "${AGENT}"; then
    note "${AGENT} has an exec/shell/run branch; RFC 0029 says there is none"
fi

if [ "${fail}" -ne 0 ]; then
    echo "novi-agent verbs: FAILED"
    exit 1
fi
echo "novi-agent verbs: $(printf '%s\n' ${agent_verbs} | wc -l) verbs, both lists agree, all dispatched"
