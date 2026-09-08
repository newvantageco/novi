#!/bin/bash
# ============================================================
# build.sh — Master build orchestrator
# Run this to build everything in order.
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_SCRIPTS="${SCRIPT_DIR}/build"

log() { echo -e "\n\033[1;32m>>> $*\033[0m\n"; }
err() { echo -e "\n\033[1;31m!!! $*\033[0m\n" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Usage: bash build.sh [--base-only] [--from NN] [--to NN] [--list]

  --base-only   stop after the kernel (stages 01-05): a bootable console
                system, no desktop, no package tooling, no installer
  --from NN     start at stage NN (e.g. --from 06)
  --to NN       stop after stage NN
  --list        print the stage list and exit

With no arguments every stage runs, in numeric order. Stages are not
independent -- each builds on /build/{sources,tools,sysroot,rootfs} left
by the ones before it -- so --from is for resuming a build you have
already got past that point, not for picking and choosing.
USAGE
}

FROM="01"
TO="99"
LIST_ONLY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base-only) TO="05"; shift ;;
        --from) FROM="$2"; shift 2 ;;
        --to)   TO="$2";   shift 2 ;;
        --list) LIST_ONLY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) err "unknown argument: $1" ;;
    esac
done

# Stages are discovered rather than listed, so a new build/NN-*.sh is
# part of `bash build.sh` the moment it exists. The alternative -- a
# hardcoded list here -- is how this script ended up running only stages
# 01 through 05 while stages 06 through 17 (the entire desktop, the
# package tooling, novi-state and the installer) existed but were never
# reached by the one command the README tells people to run.
mapfile -t STAGES < <(find "${BUILD_SCRIPTS}" -maxdepth 1 -name '[0-9][0-9]-*.sh' -printf '%f\n' | sort)
[[ ${#STAGES[@]} -gt 0 ]] || err "no build stages found in ${BUILD_SCRIPTS}"

# 00-versions.sh is sourced by every stage, not run as one.
FILTERED=()
for s in "${STAGES[@]}"; do
    [[ "${s}" == 00-* ]] && continue
    FILTERED+=("${s}")
done
STAGES=("${FILTERED[@]}")

# A stage number is an identity, not a sort key: it is what --from and
# --to name, and what a failed stage tells you to resume from. Two
# stages sharing one still *runs* -- `sort` breaks the tie by filename
# and both execute in a sensible order -- which is exactly why a
# duplicate can sit there unnoticed. It did: 22-novi-view.sh was added
# next to 22-live-desktop.sh and nothing said a word, leaving
# "resume with: bash build.sh --from 22" pointing at two different
# stages.
declare -A SEEN_STAGE_NUM=()
DUPES=""
for s in "${STAGES[@]}"; do
    n="${s%%-*}"
    if [[ -n "${SEEN_STAGE_NUM[${n}]:-}" ]]; then
        DUPES+="  ${n}: ${SEEN_STAGE_NUM[${n}]} and ${s}"$'\n'
    fi
    SEEN_STAGE_NUM[${n}]="${s}"
done
[[ -z "${DUPES}" ]] || err "two build stages share a number -- --from/--to
cannot tell them apart:
${DUPES}Renumber one of them."

if (( LIST_ONLY )); then
    printf '%s\n' "${STAGES[@]}"
    exit 0
fi

# Require Linux
[[ "$(uname)" == "Linux" ]] || err "Must run on Linux (use WSL2 or a VM)"

# Require build tools
for tool in gcc make curl tar; do
    command -v "$tool" &>/dev/null || err "Missing required tool: ${tool}"
done

TOTAL=0
for s in "${STAGES[@]}"; do
    n="${s%%-*}"
    # 10# so a leading-zero stage number ("08") is decimal, not octal.
    (( 10#${n} < 10#${FROM} )) && continue
    (( 10#${n} > 10#${TO}   )) && continue
    TOTAL=$(( TOTAL + 1 ))
done

i=0
for s in "${STAGES[@]}"; do
    n="${s%%-*}"
    # 10# so a leading-zero stage number ("08") is decimal, not octal.
    (( 10#${n} < 10#${FROM} )) && continue
    (( 10#${n} > 10#${TO}   )) && continue
    i=$(( i + 1 ))
    log "Stage ${n} (${i}/${TOTAL}): ${s}"
    bash "${BUILD_SCRIPTS}/${s}" || err "stage ${s} failed -- resume with: bash build.sh --from ${n}"
done

log "Build complete!"
source "${BUILD_SCRIPTS}/00-versions.sh"
echo "Rootfs size: $(du -sh "${ROOTFS}" | cut -f1)"
echo "Kernel: ${ROOTFS}/boot/vmlinuz-${LINUX_VERSION}"
echo ""
echo "Next: bash scripts/mkiso.sh   # bootable ISO with the installer on it"
echo "      bash scripts/mkvm.sh    # boot it"
