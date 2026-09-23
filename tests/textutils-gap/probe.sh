#!/bin/bash
# RFC 0040 roadmap 4: is the busybox/GNU difference in sed, grep, awk and
# tar worth a package? Measured the way roadmap 1 was -- run each
# construct under BOTH and compare, rather than reading feature lists.
#
# Every case is something a script written elsewhere plausibly contains.
# AGREE cases are in the corpus on purpose: a harness that always
# reported "differs" would otherwise look like a finding.
#
#   bash probe.sh                 measure busybox against GNU
#   bash probe.sh --self-check    point BOTH sides at GNU; must be 52/52
#
# The self-check is not decoration. A harness that reported a
# difference for every case would produce exactly the alarming table
# this is meant to produce, and nothing in the output would say so.
BB="${BB:-/build/rootfs/bin/busybox}"

if [ "${1:-}" = "--self-check" ]; then
    D="$(mktemp -d)"; trap 'rm -rf "$D"' EXIT
    for t in sed grep awk tar; do
        case "$t" in awk) g="$(command -v gawk)" ;; *) g="$(command -v "$t")" ;; esac
        [ -n "$g" ] || { echo "self-check needs $t on PATH" >&2; exit 1; }
        printf '#!/bin/sh\nexec %s "$@"\n' "$g" > "$D/$t"; chmod +x "$D/$t"
    done
    # `#!/bin/bash`, not sh: the shim uses `shift`, and the first
    # version wrote `"${@:2}"` under dash, which expands to nothing --
    # so every case "differed" and the self-check looked like a
    # finding about busybox.
    printf '#!/bin/bash\nt="$1"; shift; exec "%s/$t" "$@"\n' "$D" > "$D/bbshim"
    chmod +x "$D/bbshim"
    BB="$D/bbshim"
    echo "== SELF-CHECK: both sides are GNU, so every case must agree"
fi

command -v gawk >/dev/null || {
    echo "ERROR: no gawk. Debian's \`awk\` is mawk, and comparing" >&2
    echo "       busybox against mawk answers a different question." >&2
    exit 1; }
[ -x "${BB}" ] || {
    echo "ERROR: no busybox at ${BB} -- build it, or set BB=." >&2; exit 1; }

W="$(mktemp -d)"; trap 'rm -rf "$W" ${D:-}' EXIT
same=0; diff=0; bbfail=0; seq=0; silent=0; silentlist=()
declare -A bytool_same bytool_diff

# THE HOST'S `awk` IS mawk ON DEBIAN, NOT gawk. The first run of this
# probe compared busybox against mawk and reported `gensub` as a
# busybox WIN -- inverting the one conclusion the awk rows exist to
# reach. Name the GNU program, do not take whatever is on PATH.
gnu_tool() { case "$1" in awk) echo gawk ;; *) echo "$1" ;; esac; }

run() {            # run <tool> <label> <shell-snippet using $T as the tool>
    local tool="$1" label="$2" snip="$3" g b grc brc
    # EACH RUN GETS A CLEAN DIRECTORY. The first version shared one,
    # so the tar hardlink case failed under busybox with "File exists"
    # -- left behind by the GNU run of the same case, and reported as
    # a busybox limitation it is not.
    local ga="$W/g.$((++seq))" ba="$W/b.$seq"
    mkdir -p "$ga" "$ba"; cp "$W/in.txt" "$W/kv.txt" "$ga/"; cp "$W/in.txt" "$W/kv.txt" "$ba/"
    # `set -o pipefail` IN THE SNIPPET SHELL, or a case written as a
    # pipeline reports the LAST command's status. `printf | $T -z | tr`
    # returned 0 with busybox's "unrecognized option: z" sitting in the
    # output, so two LOUD failures were counted as SILENT ones -- the
    # exact trap CLAUDE.md already records three times, hit by the
    # instrument measuring for a fourth.
    g="$(cd "$ga" && T="$(gnu_tool "$tool")" bash -o pipefail -c "$snip" 2>&1)"; grc=$?
    b="$(cd "$ba" && T="$BB $tool"           bash -o pipefail -c "$snip" 2>&1)"; brc=$?
    if [ "$g" = "$b" ] && [ "$grc" = "$brc" ]; then
        same=$((same+1)); bytool_same[$tool]=$(( ${bytool_same[$tool]:-0} + 1 ))
        printf '  agree   %-6s %s\n' "$tool" "$label"
    else
        diff=$((diff+1)); bytool_diff[$tool]=$(( ${bytool_diff[$tool]:-0} + 1 ))
        # LOUD vs SILENT is the distinction that decides this, not
        # agree vs differ. A busybox that errors is a bug report the
        # person reading the terminal gets for free; one that exits 0
        # with different text has corrupted the output of a script
        # that looked like it worked.
        local kind
        if [ "$brc" != 0 ] && [ "$grc" = 0 ]; then
            kind="LOUD "; bbfail=$((bbfail+1))
        elif [ "$brc" = 0 ] && [ "$grc" = 0 ]; then
            kind="SILENT"; silent=$((silent+1)); silentlist+=("$tool: $label")
        else
            kind="other "
        fi
        printf '  %s  %-6s %-42s gnu[%s]=%.55s | bb[%s]=%.55s\n' \
            "$kind" "$tool" "$label" "$grc" "${g//$'\n'/\\n}" "$brc" "${b//$'\n'/\\n}"
    fi
}

printf 'one two three\nalpha beta\nAAA bbb CCC\n' > "$W/in.txt"
printf 'x=1\ny=2\n' > "$W/kv.txt"

echo "== sed"
run sed "basic s///"               '$T "s/two/2/" in.txt'
run sed "s///g with backref"       '$T "s/\(a\)\(l\)/\2\1/g" in.txt'
run sed "address range"            '$T -n "2,3p" in.txt'
run sed "-i in place"              'cp in.txt t1; $T -i "s/one/1/" t1; cat t1'
run sed "-i.bak backup suffix"     'cp in.txt t2; $T -i.bak "s/one/1/" t2; ls t2.bak'
run sed "-E extended regex"        '$T -E "s/(one|two)/X/g" in.txt'
run sed "\\U case conversion"      '$T "s/one/\U&/" in.txt'
run sed "\\L case conversion"      '$T "s/AAA/\L&/" in.txt'
run sed "-z NUL separated"         'printf "a\0b\0" | $T -z "s/a/A/" | tr "\0" "|"'
run sed "-s separate files"        '$T -s -n "1p" in.txt kv.txt'
run sed "0,/re/ address"           '$T "0,/beta/s/a/A/" in.txt'
run sed "e command"                'echo x | $T "s/x/echo hi/e"'
run sed "F filename command"       '$T -n "1F" in.txt'

echo "== grep"
run grep "fixed string -F"         '$T -F "beta" in.txt'
run grep "-c count"                '$T -c "a" in.txt'
run grep "-o only matching"        '$T -o "[a-z]*a" in.txt'
run grep "-E alternation"          '$T -E "one|beta" in.txt'
run grep "-P perl regex"           '$T -P "\d+" kv.txt'
run grep "-P lookahead"            '$T -P "y(?=\=)" kv.txt'
run grep "-r --include"            'mkdir -p d && cp in.txt d/ && $T -r --include="*.txt" "beta" d'
run grep "-z NUL separated"        'printf "a\0beta\0" | $T -z "beta" | tr "\0" "|"'
run grep "--color=never"           '$T --color=never "beta" in.txt'
run grep "-A/-B context"           '$T -A1 -B1 "alpha" in.txt'
run grep "-w word boundary"        '$T -w "one" in.txt'
run grep "-m max count"            '$T -m1 "a" in.txt'

echo "== awk"
run awk "field print"              '$T "{print \$2}" in.txt'
run awk "NR/NF"                    '$T "{print NR, NF}" in.txt'
run awk "-v assignment"            '$T -v k=9 "{print k, \$1; exit}" in.txt'
run awk "printf formatting"        '$T "{printf \"%-6s|%03d\n\", \$1, NR}" in.txt'
run awk "gsub"                     '$T "{n=gsub(/a/,\"A\"); print n, \$0}" in.txt'
run awk "gensub (GNU ext)"         '$T "{print gensub(/a/,\"A\",\"g\")}" in.txt'
run awk "length(array)"            '$T "BEGIN{a[1];a[2];print length(a)}"'
run awk "asort (GNU ext)"          '$T "BEGIN{a[1]=3;a[2]=1;n=asort(a);print n,a[1]}"'
run awk "match() RSTART/RLENGTH"   '$T "{if(match(\$0,/be/))print RSTART,RLENGTH}" in.txt'
run awk "split with regex"         '$T "BEGIN{n=split(\"a1b2c\",p,/[0-9]/);print n,p[3]}"'
run awk "substr/index/toupper"     '$T "{print toupper(substr(\$1,1,2)), index(\$0,\"b\")}" in.txt'
run awk "ENVIRON"                  'FOO=bar $T "BEGIN{print ENVIRON[\"FOO\"]}"'
run awk "multiple -f style prog"   '$T "BEGIN{OFS=\"-\"}{\$1=\$1;print}" in.txt'
run awk "strftime (GNU ext)"       '$T "BEGIN{print strftime(\"%Y\",0)}"'
run awk "RS as regex (GNU ext)"    'printf "a1b22c" | $T "BEGIN{RS=\"[0-9]+\"}{print NR\":\"\$0}"'

echo "== tar"
# EACH CASE BUILDS ITS OWN INPUTS. They used to chain off the first
# case's `td`, which worked only because every case shared one
# directory -- and the moment the runs were isolated, seven of ten
# "differed" because both sides were reporting the same missing file.
mk='mkdir -p td && echo hi > td/f'
run tar "create and list"          "$mk && \$T -cf a.tar td && \$T -tf a.tar | sort"
run tar "gzip -z"                  "$mk && \$T -czf b.tgz td && \$T -tzf b.tgz | sort"
run tar "extract to -C"            "$mk && \$T -cf a.tar td && mkdir -p ex && \$T -xf a.tar -C ex && cat ex/td/f"
run tar "--exclude"                "$mk && touch td/skip.tmp && \$T -cf c.tar --exclude='*.tmp' td && \$T -tf c.tar | sort"
run tar "--transform"              "$mk && \$T -cf d.tar --transform='s|td|ZZ|' td 2>&1 && \$T -tf d.tar | sort"
run tar "--strip-components"       "$mk && \$T -cf a.tar td && mkdir -p ex2 && \$T -xf a.tar -C ex2 --strip-components=1 && ls ex2"
run tar "-J xz"                    "$mk && \$T -cJf e.tar.xz td 2>&1 >/dev/null; \$T -tJf e.tar.xz 2>&1 | sort"
run tar "--owner/--group"          "$mk && \$T -cf f.tar --owner=0 --group=0 td 2>&1 && \$T -tf f.tar | sort"
run tar "hardlink preserved"       "mkdir -p hl && echo x > hl/a && ln hl/a hl/b && \$T -cf g.tar hl && mkdir -p exh && \$T -xf g.tar -C exh && stat -c %h exh/hl/a"
run tar "--no-recursion"           "$mk && \$T -cf h.tar --no-recursion td 2>&1 && \$T -tf h.tar | sort"
run tar "sparse file --sparse"     "dd if=/dev/zero of=sp bs=1 count=0 seek=1M 2>/dev/null && \$T -Scf i.tar sp 2>&1 && \$T -tf i.tar"
run tar "preserve mtime on extract" "$mk && touch -d '2020-01-02 03:04:05' td/f && \$T -cf j.tar td && mkdir -p exm && \$T -xf j.tar -C exm && date -r exm/td/f '+%Y-%m-%d %H:%M:%S'"

echo
echo "== RESULT"
echo "   $((same+diff)) cases:  agree $same   differ $diff"
echo "   of the differences: $bbfail LOUD (busybox errors), $silent SILENT (exits 0, different output)"
echo "   the silent ones -- the reason this is a package and not a footnote:"
for l in "${silentlist[@]}"; do echo "      $l"; done
for t in sed grep awk tar; do
    printf '   %-5s agree=%-3s differ=%s\n' "$t" "${bytool_same[$t]:-0}" "${bytool_diff[$t]:-0}"
done
