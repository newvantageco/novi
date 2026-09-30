#!/bin/bash
# §2's sandboxed-app tier: what does running a glibc binary here cost?
#
# PLATFORM-ROADMAP §2 proposes OCI/Flatpak-compatible bundles "so
# upstream glibc-built apps run without every app needing a musl port",
# and §11 calls that the actual unlock. Rows 6, 7, 9 and 12 of the
# status table all wait on it. Before writing that RFC, the question
# RFC 0040 roadmap 3 asked about util-linux and RFC 0031 should have
# asked about the browser: a number, not an opinion.
#
# THE SHARP QUESTION IS NARROWER THAN THE ITEM. An ELF names its own
# interpreter in PT_INTERP, so a glibc binary and a musl binary never
# share a loader -- they cannot, by construction. So "run an upstream
# glibc app" splits into two problems the roadmap states as one:
#
#   EXECUTION    -- can a glibc binary run on this machine at all?
#   DISTRIBUTION -- where does the bundle come from, who signed it,
#                   how is it updated, what is it allowed to touch?
#
# Only the first is measurable here, and it is the one the item's
# framing assumes is hard. This measures it.
#
#   bash probe.sh          run the measurement
#
# It builds a chroot out of THIS repo's shipped musl rootfs and the
# build host's glibc, so it needs a glibc build host and root. No VM:
# RFC 0018's rule about testing the shipped artifact rather than the
# idea, and the same chroot trick tests/busybox-man/probe.sh uses.
set -uo pipefail

ROOTFS="${ROOTFS:-/build/rootfs}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
note(){ printf '        %s\n' "$*"; }

[ -x "$ROOTFS/bin/busybox" ] || { echo "no shipped rootfs at $ROOTFS -- build first"; exit 2; }
[ "$(id -u)" = 0 ] || { echo "needs root (it chroots)"; exit 2; }
command -v gcc >/dev/null || { echo "needs a glibc gcc on the build host"; exit 2; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
R="$W/root"

# ---------------------------------------------------------------------------
# The two interpreter paths, read rather than written down
# ---------------------------------------------------------------------------
interp() { readelf -l "$1" 2>/dev/null | sed -n 's/.*program interpreter: \(.*\)\]/\1/p'; }

cat > "$W/hello.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <gnu/libc-version.h>
int main(void){ char *s=strdup("ran"); printf("%s %s\n",s,gnu_get_libc_version()); free(s); return 0; }
EOF
gcc -O2 -o "$W/hello" "$W/hello.c" || { echo "host gcc failed"; exit 2; }

GLIBC_INTERP="$(interp "$W/hello")"
MUSL_BIN=""
for b in "$ROOTFS"/usr/sbin/* "$ROOTFS"/usr/bin/*; do
    [ -f "$b" ] || continue
    [ -n "$(interp "$b")" ] && { MUSL_BIN="$b"; break; }
done
[ -n "$MUSL_BIN" ] || { echo "no dynamic musl binary in $ROOTFS"; exit 2; }
MUSL_INTERP="$(interp "$MUSL_BIN")"

echo "== the two interpreters, read from the binaries"
note "glibc: $GLIBC_INTERP"
note "musl : $MUSL_INTERP"
[ "$GLIBC_INTERP" != "$MUSL_INTERP" ] \
    && ok "the two loaders are different paths, so they never meet" \
    || bad "the two loaders claim the SAME path -- everything below is void"
# The whole argument rests on the glibc path being free on a Novi machine.
if [ -e "$ROOTFS$GLIBC_INTERP" ]; then
    bad "$GLIBC_INTERP already exists in the shipped rootfs"
else
    ok "$GLIBC_INTERP does not exist in the shipped rootfs -- the path is free"
fi

# ---------------------------------------------------------------------------
# A root that is Novi's musl world, plus glibc at its own paths
# ---------------------------------------------------------------------------
mkdir -p "$R"/{bin,lib,usr/lib,usr/sbin,etc,proc,dev}
cp "$ROOTFS/bin/busybox" "$R/bin/"
cp -a "$ROOTFS"/lib/ld-musl-*.so.* "$ROOTFS"/lib/libc.musl-*.so.* "$R/lib/"
cp "$MUSL_BIN" "$R/usr/sbin/"

# Transitive closure, not direct NEEDED -- the first version of this
# copied one level and the musl binary died on its grandchild.
need() { readelf -d "$1" 2>/dev/null | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p'; }
todo="$(need "$MUSL_BIN")"; seen=""
while [ -n "$todo" ]; do
    nx=""
    for l in $todo; do
        case " $seen " in *" $l "*) continue ;; esac
        seen="$seen $l"
        for d in "$ROOTFS/usr/lib" "$ROOTFS/lib"; do
            [ -e "$d/$l" ] || continue
            cp -a "$d/$l"* "$R/usr/lib/" 2>/dev/null
            nx="$nx $(need "$d/$l")"; break
        done
    done
    todo="$nx"
done

stage_glibc() {   # $1 = binary; copy its loader and its whole resolved set
    local b="$1" ip; ip="$(interp "$b")"
    mkdir -p "$R$(dirname "$ip")"
    # cp -L, NOT cp -a: on a Debian host $GLIBC_INTERP is a symlink into
    # a directory the chroot does not have, and `cp -a` copies the
    # dangling link. The failure is `chroot: No such file or directory`
    # about a binary that is right there -- it is the INTERPRETER that
    # is missing, and nothing says so.
    cp -L "$ip" "$R$ip" 2>/dev/null
    ldd "$b" 2>/dev/null | sed -n 's|.*=> \(/[^ ]*\).*|\1|p' | while read -r f; do
        mkdir -p "$R$(dirname "$f")"; cp -L "$f" "$R$f" 2>/dev/null
    done
}

echo
echo "== a control first: the glibc binary with NO glibc runtime present"
cp "$W/hello" "$R/bin/hello"
if chroot "$R" /bin/hello >/dev/null 2>&1; then
    bad "it ran without a glibc runtime -- this probe cannot prove anything"
else
    ok "refused, as it must be -- so a pass below is the runtime doing the work"
fi

stage_glibc "$W/hello"

echo
echo "== one root, two libcs"
chroot "$R" /bin/busybox true 2>/dev/null \
    && ok "static musl busybox runs" || bad "static musl busybox does not run"
chroot "$R" "/usr/sbin/$(basename "$MUSL_BIN")" --version >/dev/null 2>&1 \
    && ok "DYNAMIC musl binary runs ($(basename "$MUSL_BIN"))" \
    || bad "dynamic musl binary does not run"
out="$(chroot "$R" /bin/hello 2>&1)"
case "$out" in
    ran\ *) ok "DYNAMIC GLIBC binary runs -- no container, no shim (glibc ${out#ran })" ;;
    *)      bad "glibc binary: $out" ;;
esac

# ---------------------------------------------------------------------------
# The obstacles people actually hit
# ---------------------------------------------------------------------------
echo
echo "== the obstacles, rather than the easy case"

cat > "$W/nss.c" <<'EOF'
#include <stdio.h>
#include <pwd.h>
#include <netdb.h>
int main(void){
    struct passwd *p=getpwnam("root");
    printf("pw=%s\n", p?p->pw_dir:"NULL");
    struct addrinfo *ai=NULL,h={0}; h.ai_family=AF_INET;
    printf("hosts=%d\n", getaddrinfo("localhost",NULL,&h,&ai));
    return 0;
}
EOF
gcc -O2 -o "$W/nss" "$W/nss.c" && cp "$W/nss" "$R/bin/nss" && stage_glibc "$W/nss"
printf 'root:x:0:0:root:/root:/bin/sh\n' > "$R/etc/passwd"
printf '127.0.0.1 localhost\n' > "$R/etc/hosts"
# No nsswitch.conf and no libnss_*.so on purpose: that is what a Novi
# /etc looks like, and it is the classic reason this is said to be hard.
n="$(chroot "$R" /bin/nss 2>&1)"
case "$n" in
  *"pw=/root"*) ok "glibc getpwnam works with NO nsswitch.conf and NO libnss_*.so" ;;
  *)            bad "getpwnam: $n" ;;
esac
case "$n" in
  *"hosts=0"*)  ok "glibc hosts-file resolution works the same way" ;;
  *)            bad "getaddrinfo(localhost): $n" ;;
esac
c=$(nm -D "$(ldd "$W/nss" | sed -n 's|.*libc\.so\.6 => \([^ ]*\).*|\1|p')" 2>/dev/null \
    | grep -c '_nss_files_\|_nss_dns_')
note "because libc.so.6 exports $c _nss_files_/_nss_dns_ symbols: glibc"
note "merged those backends INTO libc, so the version-matched"
note "libnss_*.so this is supposed to need is not needed."

cat > "$W/cxx.cc" <<'EOF'
#include <cstdio>
#include <string>
#include <thread>
#include <vector>
int main(){ std::vector<std::thread> t; int n=0;
  for(int i=0;i<3;i++) t.emplace_back([&,i]{n+=i;});
  for(auto&x:t) x.join();
  std::string s="ok"; printf("cxx=%s sum=%d\n",s.c_str(),n); return 0; }
EOF
if g++ -O2 -o "$W/cxx" "$W/cxx.cc" 2>/dev/null; then
    cp "$W/cxx" "$R/bin/cxx"; stage_glibc "$W/cxx"
    chroot "$R" /bin/cxx 2>&1 | grep -q 'cxx=ok sum=3' \
        && ok "C++ and threads run (libstdc++, libgcc_s, libm all glibc)" \
        || bad "C++/threads: $(chroot "$R" /bin/cxx 2>&1)"
else
    note "no g++ on this host -- C++ case skipped"
fi

cat > "$W/loc.c" <<'EOF'
#include <stdio.h>
#include <locale.h>
int main(void){
  printf("C=%s\n", setlocale(LC_ALL,"C"));
  const char *u=setlocale(LC_ALL,"en_US.UTF-8");
  printf("utf8=%s\n", u?u:"NULL");
  return 0; }
EOF
gcc -O2 -o "$W/loc" "$W/loc.c" && cp "$W/loc" "$R/bin/loc" && stage_glibc "$W/loc"
l="$(chroot "$R" /bin/loc 2>&1)"
case "$l" in *"C=C"*) ok "the C locale works" ;; *) bad "C locale: $l" ;; esac
case "$l" in
  *"utf8=NULL"*) ok "a real locale does NOT (no locale-archive) -- a bounded, known cost" ;;
  *)             note "a real locale resolved too: ${l#*utf8=}" ;;
esac

echo
echo "== what that runtime costs"
sz=$(du -sk "$R/lib" "$R/usr/lib" 2>/dev/null | awk '{s+=$1} END{print s}')
gl=$(find "$R" -name 'libc.so.6' -o -name 'libstdc++.so.6' -o -name 'libm.so.6' \
        -o -name 'libgcc_s.so.1' -o -name 'ld-linux-*.so.*' 2>/dev/null \
     | xargs -r du -ck 2>/dev/null | tail -1 | cut -f1)
note "glibc C and C++ runtime: ${gl} KB"
# %s is the size; %d is the DEPTH, and the first version of this line
# printed "3 KB" for a 2 MB library with nothing to say it was wrong.
find "$R" \( -name 'libc.so.6' -o -name 'libstdc++.so.6' -o -name 'libm.so.6' \
     -o -name 'libgcc_s.so.1' -o -name 'ld-linux-*.so.*' \) \
     -printf '%f %s\n' 2>/dev/null | sort -u \
     | awk '{printf "        %-26s %8.1f KB\n", $1, $2/1024}'

echo
echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
