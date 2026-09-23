#!/bin/bash
# RFC 0040 roadmap 3: what would a util-linux package actually buy?
#
# The roadmap names util-linux beside coreutils and bash, and RFC 0040
# scoped it out as "its own RFC". Before writing that RFC, the same
# question roadmap 4 asked about sed/grep/awk/tar: a number, not an
# opinion.
#
# TWO POPULATIONS, and only one of them can be measured this way.
# busybox provides 48 of util-linux's 91 program names and lacks 43.
# For the 43 there is nothing to compare against, so `inventory.sh`
# classifies those against what THIS kernel and image actually have.
# This file measures the 48 -- where busybox answers DIFFERENTLY is
# where somebody gets bitten, and that is the only part a package
# would fix silently.
#
#   bash probe.sh                 measure busybox against util-linux
#   bash probe.sh --self-check    point BOTH sides at util-linux; must agree
#
# Cases needing root, a block device or a real console are OUT: a probe
# that cannot run is not evidence, and guessing at those would be the
# feature-list reading this exists to replace.
set -uo pipefail
BB="${BB:-/build/rootfs/bin/busybox}"

if [ "${1:-}" = "--self-check" ]; then
    D="$(mktemp -d)"; trap 'rm -rf "$D"' EXIT
    printf '#!/bin/bash\nt="$1"; shift; exec "$t" "$@"\n' > "$D/bbshim"
    chmod +x "$D/bbshim"; BB="$D/bbshim"
    echo "== SELF-CHECK: both sides are util-linux, so every case must agree"
fi
[ -x "${BB}" ] || { echo "ERROR: no busybox at ${BB} -- build it, or set BB=." >&2; exit 1; }

same=0; diff=0; loud=0; silent=0; seq=0; silentlist=(); skipped=0
declare -A bytool_same bytool_diff

W="$(mktemp -d)"; trap 'rm -rf "$W" ${D:-}' EXIT

run() {                       # run <tool> <label> <snippet using $T>
    local tool="$1" label="$2" snip="$3" g b grc brc
    if ! command -v "$tool" >/dev/null 2>&1; then
        skipped=$((skipped+1)); printf '  skip    %-10s %s (no %s on this host)\n' "$tool" "$label" "$tool"; return
    fi
    local ga="$W/g.$((++seq))" ba="$W/b.$seq"
    mkdir -p "$ga" "$ba"
    # `set -o pipefail` in the snippet shell: a case written as a
    # pipeline otherwise reports its LAST command's status, which is
    # how RFC 0040 roadmap 4 miscounted two loud failures as silent.
    g="$(cd "$ga" && T="$tool"        bash -o pipefail -c "$snip" 2>&1)"; grc=$?
    b="$(cd "$ba" && T="$BB $tool"    bash -o pipefail -c "$snip" 2>&1)"; brc=$?
    # NORMALISE THE NOISE THE TWO RUNS CANNOT SHARE, AND NOTHING ELSE.
    # The two sides are separate processes, so anything carrying a pid
    # differs for a reason that has nothing to do with the tools:
    # `chrt -p $$` was reported as a SILENT divergence purely because
    # the two runs had different pids.
    #
    # The first version of this line was `s/\b[0-9]{2,7}'?s?\b/<pid>/g`
    # -- any two-to-seven-digit number -- and it ATE AN EXIT STATUS:
    # mountpoint's `rc=32` became `rc=<pid>`, which is the one field
    # the comparison turns on. It happened to still report a
    # difference because busybox's `rc=1` is a single digit and
    # survived; a busybox exiting 33 would have compared EQUAL to a
    # util-linux exiting 32. It also blanked blkid's BLOCK_SIZE value.
    # A normaliser wide enough to hide the noise is wide enough to
    # hide the finding: match the SHAPE the noise comes in -- these
    # tools print `pid <n>'s ...` -- not "a number".
    # Sixth time in this project that the instrument, not the thing
    # measured, was the broken part.
    g="$(printf '%s' "$g" | sed -E "s/\bpid [0-9]+'s\b/pid <pid>'s/g")"
    b="$(printf '%s' "$b" | sed -E "s/\bpid [0-9]+'s\b/pid <pid>'s/g")"
    if [ "$g" = "$b" ] && [ "$grc" = "$brc" ]; then
        same=$((same+1)); bytool_same[$tool]=$(( ${bytool_same[$tool]:-0} + 1 ))
        printf '  agree   %-10s %s\n' "$tool" "$label"
    else
        diff=$((diff+1)); bytool_diff[$tool]=$(( ${bytool_diff[$tool]:-0} + 1 ))
        local kind
        if [ "$brc" != 0 ] && [ "$grc" = 0 ]; then kind="LOUD  "; loud=$((loud+1))
        elif [ "$brc" = 0 ] && [ "$grc" = 0 ]; then kind="SILENT"; silent=$((silent+1)); silentlist+=("$tool: $label")
        else kind="other "; fi
        printf '  %s  %-10s %-34s ul[%s]=%.44s | bb[%s]=%.44s\n' \
            "$kind" "$tool" "$label" "$grc" "${g//$'\n'/\\n}" "$brc" "${b//$'\n'/\\n}"
    fi
}

echo "== getopt  (argument parsing -- a script that mis-parses its own flags)"
run getopt "short options"        '$T abc: -a -b -c val 2>&1'
run getopt "-o long form"         '$T -o ab: -- -a -b val'
run getopt "--longoptions"        '$T -o a -l verbose -- --verbose'
run getopt "quoting a space"      '$T -o a: -- -a "two words"'
run getopt "unknown option"       '$T -o a -- -z; echo "rc=$?"'
run getopt "-u unquoted"          '$T -u -o a: -- -a x'

echo "== flock  (the lock a shell script uses so two copies do not race)"
run flock "exclusive, runs cmd"   'touch L; $T L true; echo "rc=$?"'
run flock "-n on a free lock"     'touch L; $T -n L echo got'
run flock "-n on a HELD lock"     'touch L; ( $T L sleep 2 & ) ; sleep 0.3; $T -n L echo got; echo "rc=$?"'
run flock "-s shared"             'touch L; $T -s L echo shared'
run flock "-w timeout"            'touch L; $T -w 1 L echo waited'
run flock "-c command string"     'touch L; $T L -c "echo viacmd"'

echo "== rev / mountpoint / setsid / isosize"
run rev "reverses"                'printf "abc\ndef\n" | $T'
run rev "empty line"              'printf "\n" | $T | od -c | head -1'
run mountpoint "a plain dir"      'mkdir -p d; $T d; echo "rc=$?"'
run mountpoint "-q"               'mkdir -p d; $T -q d; echo "rc=$?"'
run setsid "runs a command"       '$T true; echo "rc=$?"'

echo "== taskset / chrt / ionice  (scheduling, all readable unprivileged)"
run taskset "-p on self"          '$T -p $$ >/dev/null; echo "rc=$?"'
run taskset "-c 0 true"           '$T -c 0 true; echo "rc=$?"'
run chrt "-p on self"             '$T -p $$ 2>&1 | head -2'
run ionice "-p on self"           '$T -p $$ 2>&1 | head -1'

echo "== fallocate / logger / script"
run fallocate "-l makes a file"   '$T -l 4096 f && stat -c %s f'
run fallocate "-l 0 refused"      '$T -l 0 g 2>&1 | head -1; echo "rc=$?"'
run script "-c with -q"           '$T -q -c "echo hi" /dev/null'

echo "== setpriv / unshare / nsenter  (what novi-sandbox is built from)"
run setpriv "--help exists"       '$T --help >/dev/null 2>&1; echo "rc=$?"'
run setpriv "--no-new-privs"      '$T --no-new-privs true 2>&1; echo "rc=$?"'
run unshare "user namespace"      '$T -Ur true 2>&1; echo "rc=$?"'
run unshare "-Urm mounts"         '$T -Urm true 2>&1; echo "rc=$?"'
run unshare "--map-root-user"     '$T --user --map-root-user id -u 2>&1'

echo "== blkid / findfs / mkfs.minix  (on a FILE image, so no device needed)"
run mkfs.minix "makes a filesystem" 'dd if=/dev/zero of=fs bs=1k count=512 2>/dev/null; $T fs >/dev/null 2>&1; echo "rc=$?"'
run blkid "reads a minix image"   'dd if=/dev/zero of=fs bs=1k count=512 2>/dev/null; mkfs.minix fs >/dev/null 2>&1; $T fs 2>&1 | sed "s|^[^:]*:||" | head -1'

echo
echo "== RESULT"
echo "   $((same+diff)) comparable cases:  agree $same   differ $diff   (skipped $skipped)"
echo "   of the differences: $loud LOUD (busybox errors), $silent SILENT (exits 0, different answer)"
if [ "${#silentlist[@]}" -gt 0 ]; then
    echo "   the silent ones -- a script that looked like it worked:"
    for l in "${silentlist[@]}"; do echo "      $l"; done
fi
for t in getopt flock rev mountpoint setsid taskset chrt ionice fallocate script setpriv unshare blkid mkfs.minix; do
    [ -n "${bytool_same[$t]:-}${bytool_diff[$t]:-}" ] || continue
    printf '   %-11s agree=%-3s differ=%s\n' "$t" "${bytool_same[$t]:-0}" "${bytool_diff[$t]:-0}"
done
