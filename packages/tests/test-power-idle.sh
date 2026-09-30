#!/bin/bash
# ============================================================
# test-power-idle.sh — `novi-power idle` reads a file it does not own
#
# RFC 0035. novi-shell publishes /run/novi/idle; this command is the
# only thing that reads it. Two properties are worth a test rather than
# a look:
#
#   1. The reader must not fall over on a file it did not expect. A
#      novi-shell newer than this script will write keys this script
#      has never heard of, and an installed base is never one version.
#      "Ignore what you do not know" is easy to write and easy to lose
#      to a `case` that grew an `*)` branch.
#
#   2. `awake` and `inhibit` are TWO CLAIMS, not one. Somebody pressing
#      Super+A and a program asking to stay awake are different events
#      with different remedies, and the whole reason this command
#      exists is that a machine which will not sleep cannot otherwise
#      say which of them is happening.
#
# Run against the shipped busybox ash where there is one: the target's
# shell is not this host's, and the difference has bitten this repo
# before (`pipefail`, process substitution, `/dev/fd`).
# ============================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

BUSYBOX=/build/rootfs/bin/busybox
if [ -x "${BUSYBOX}" ]; then
    SH=("${BUSYBOX}" ash)
    echo ">>> novi-power idle, under the shipped busybox ash"
else
    SH=(sh)
    echo ">>> novi-power idle, under host sh (no shipped busybox found)" >&2
fi

checks=0
fail=0
note() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }
did() { checks=$((checks + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# The script reads one hardcoded path, which is right for the tool and
# unhelpful for a test. Point that one line somewhere writable rather
# than adding an environment override to production code purely so a
# test can reach it.
sed "s|local file=/run/novi/idle|local file=${TMP}/idle|" packages/novi-power \
    > "${TMP}/novi-power"

idle() { "${SH[@]}" "${TMP}/novi-power" idle 2>&1; }

# ── 1. a quiet machine ───────────────────────────────────────────────
cat > "${TMP}/idle" <<'F'
blanked 0
locked 0
idle 35
blank 600
suspend 0
awake 0
inhibit 0
F
out="$(idle)"
did; case "${out}" in *"awake      no"*) ;; *) note "a quiet machine should report awake: no" ;; esac
did; case "${out}" in *"inhibit    no"*) ;; *) note "a quiet machine should report inhibit: no" ;; esac
# 0 seconds is how novi-shell spells "never"; the document spells it `off`.
did; case "${out}" in *"suspend    off"*) ;; *) note "suspend 0 should print as 'off', the word the document uses" ;; esac
did; case "${out}" in *"blank      600s"*) ;; *) note "a real timeout should print in seconds" ;; esac

# ── 2. THE TWO CLAIMS ARE SEPARATE ───────────────────────────────────
#
# A person pressed a key; no program asked for anything. Reporting
# "something is holding this machine awake" without saying which kind
# is the failure this command exists to prevent, so the two are
# asserted independently in both directions.
cat > "${TMP}/idle" <<'F'
blanked 0
locked 0
idle 5
blank 600
suspend 1800
awake 1
inhibit 0
F
out="$(idle)"
did; case "${out}" in *"awake      yes"*) ;; *) note "awake 1 must be reported" ;; esac
did; case "${out}" in *"Super+A"*) ;; *) note "the report should name the key that set it" ;; esac
did; case "${out}" in *"inhibit    no"*) ;; *) note "a keypress is not a client inhibitor" ;; esac

cat > "${TMP}/idle" <<'F'
blanked 0
locked 0
idle 5
blank 600
suspend 1800
awake 0
inhibit 2
inhibitor foot
inhibitor netsurf-fb
F
out="$(idle)"
did; case "${out}" in *"awake      no"*) ;; *) note "a client inhibitor is not somebody pressing a key" ;; esac
did; case "${out}" in *foot*) ;; *) note "each inhibiting client must be named" ;; esac
did; case "${out}" in *netsurf-fb*) ;; *) note "the SECOND inhibitor must be named too, not just the first" ;; esac

# ── 3. a file from a newer novi-shell ────────────────────────────────
cat > "${TMP}/idle" <<'F'
blanked 0
locked 0
idle 5
blank 600
suspend 0
awake 0
inhibit 0
somethingnew 42
another line with several words
F
out="$(idle)"
did; case "${out}" in *"blank      600s"*) ;; *) note "unknown keys must not stop the keys that are known being read" ;; esac
did; case "${out}" in *somethingnew*) note "an unknown key should be ignored, not echoed" ;; *) ;; esac

# ── 4. nothing published it ──────────────────────────────────────────
#
# The desktop is not running, or this machine has none. Distinguishing
# that from "running and idle" is the same absent-vs-unreachable
# distinction `novi-agent send` had to learn.
rm -f "${TMP}/idle"
out="$(idle)"
did; case "${out}" in *"nothing is publishing"*) ;; *) note "a missing file should say nothing published it" ;; esac
did; case "${out}" in *"novi-shell"*) ;; *) note "it should name what writes the file" ;; esac

# ── 5. a value that is not a number ──────────────────────────────────
#
# Nothing should ever write this, and `[ x -gt 0 ]` in ash is an ERROR
# rather than a false -- so the arithmetic test has to be the kind that
# survives one.
cat > "${TMP}/idle" <<'F'
blanked 0
locked 0
idle 5
blank 600
suspend 0
awake 0
inhibit banana
F
out="$(idle)"
rc=$?
did; [ "${rc}" -eq 0 ] || note "a garbage count must not make the command fail"
did; case "${out}" in *"inhibit    no"*) ;; *) note "a garbage count should read as none, not as a crash" ;; esac

if [ "${fail}" -ne 0 ]; then
    echo "novi-power idle: ${fail} check(s) FAILED of ${checks}" >&2
    exit 1
fi
echo "novi-power idle: ${checks} checks passed"
