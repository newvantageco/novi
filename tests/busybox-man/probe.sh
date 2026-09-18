#!/bin/bash
# RFC 0040 roadmap 2: the base image has shipped a `man` that cannot
# display a page for the life of the project. This proves it with the
# SHIPPED busybox binary and no VM -- the same argument RFC 0018 makes
# about BusyBox fdisk: the binary is static x86-64, so the failure
# reproduces on the build host in a second.
#
# It is not "run it and see it fail". busybox man exits 0 either way,
# which is the whole point, so the probe instruments the pipeline.
set -u
BB="${BB:-/build/rootfs/bin/busybox}"
[ -x "$BB" ] || { echo "no busybox at $BB -- build it, or set BB=." >&2; exit 1; }

R="$(mktemp -d)"; trap 'rm -rf "$R"' EXIT
mkdir -p "$R"/{bin,etc,dev,usr/share/man/man1}
cp "$BB" "$R/bin/busybox"
for a in man sh cat gzip less echo; do ln -sf busybox "$R/bin/$a"; done
mknod "$R/dev/null" c 1 3 2>/dev/null; chmod 666 "$R/dev/null"
echo "MANDATORY_MANPATH /usr/share/man" > "$R/etc/man.conf"

# A REAL PAGE HAS TO BE THERE. With no pages installed busybox man
# says "no manual entry" and never reaches its formatter at all, so a
# probe run against the bare base image proves nothing.
cat > "$R/p.1" <<'PAGE'
.TH LS 1 "2026" "test" "User Commands"
.SH NAME
ls \- list directory contents
PAGE
gzip -c "$R/p.1" > "$R/usr/share/man/man1/ls.1.gz"

fail=0
chk() { if eval "$2"; then echo "  ok    $1"; else echo "  FAIL  $1"; fail=$((fail+1)); fi; }

echo "== which of the helpers does this busybox provide as applets?"
have="$("$BB" --list | grep -xE 'tbl|nroff|col|groff' | tr '\n' ' ')"
echo "     tbl/nroff/col/groff: ${have:-(none)}"
chk "busybox provides none of tbl, nroff, col" '[ -z "$have" ]'

echo "== what the applet runs, with shims standing in for the helpers"
for c in tbl nroff col; do
    printf '#!/bin/sh\necho "INVOKED: %s $*" >&2\nexec /bin/cat\n' "$c" > "$R/bin/$c"
    chmod +x "$R/bin/$c"
done
# The nroff stage carries `2>&1` INTO THE PIPE, so its diagnostics land
# where the page text should be rather than on stderr. Capturing only
# stderr hides it -- which is how a first reading of this concluded
# nroff was never invoked at all.
out="$(chroot "$R" /bin/sh -c 'PATH=/bin; export PATH; man ls' 2>&1)"
echo "$out" | grep '^INVOKED' | sed 's/^/     /'
chk "runs tbl"                  'echo "$out" | grep -q "INVOKED: tbl"'
chk "runs nroff -mandoc"        'echo "$out" | grep -q "INVOKED: nroff -mandoc"'
chk "runs col -b -p -x"         'echo "$out" | grep -q "INVOKED: col -b -p -x"'

echo "== and with the helpers absent, as on a real Novi base image"
rm -f "$R"/bin/{tbl,nroff,col}
out="$(chroot "$R" /bin/sh -c 'PATH=/bin; export PATH; man ls' 2>&1)"; rc=$?
echo "$out" | sed 's/^/     /'
chk "says tbl not found"        'echo "$out" | grep -q "tbl: not found"'
chk "says col not found"        'echo "$out" | grep -q "col: not found"'
chk "renders NONE of the page"  '! echo "$out" | grep -q "list directory contents"'
# THE FINDING THAT MATTERS. It does not fail -- it succeeds, having
# printed its own diagnostics where the page should be.
chk "EXITS 0 ANYWAY"            '[ "$rc" = 0 ]'

echo
[ "$fail" = 0 ] && echo ">>> busybox man: all checks passed (it cannot display a page, and says so by exiting 0)" \
                || echo ">>> busybox man: $fail check(s) FAILED"
exit "$fail"
