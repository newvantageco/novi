#!/bin/bash
# The other half of the util-linux question: the 43 program names
# busybox does NOT provide, where there is nothing to compare against.
#
# So the test is not behaviour but REACHABILITY -- could this program
# do anything on this machine? Answered from the GENERATED kernel
# config and from what the image already ships, never from the curated
# config: `kernel/config-x86_64` is a ~280-option SUBSET, so a symbol
# it does not mention is not thereby off. Checked the hard way --
# CONFIG_SWAP and CONFIG_HOTPLUG_CPU are both unmentioned there and
# both `y` in the generated config, and swap really works on a booted
# machine.
set -uo pipefail
BB="${BB:-/build/rootfs/bin/busybox}"
GEN="${GEN:-$(echo /build/sources/linux-*/.config)}"
[ -x "$BB" ]   || { echo "no busybox at $BB" >&2; exit 1; }
[ -f "$GEN" ]  || { echo "no generated kernel config at $GEN" >&2; exit 1; }

ul="$(mktemp)"; bb="$(mktemp)"; trap 'rm -f "$ul" "$bb"' EXIT
for p in util-linux bsdutils util-linux-extra mount; do dpkg -L "$p" 2>/dev/null; done \
  | grep -E '^/(bin|sbin|usr/bin|usr/sbin)/[^/]+$' | sed 's|.*/||' | sort -u > "$ul"
[ -s "$ul" ] || { echo "no util-linux on this host to enumerate" >&2; exit 1; }
"$BB" --list | sort > "$bb"

sym() { grep -qE "^$1=(y|m)" "$GEN"; }
echo "util-linux programs: $(wc -l < "$ul")   busybox applets: $(wc -l < "$bb")"
echo "  provided by busybox: $(comm -12 "$ul" "$bb" | wc -l)"
echo "  not provided:        $(comm -23 "$ul" "$bb" | wc -l)"
echo
printf '%-14s %-8s %s\n' program verdict reason
printf -- '-%.0s' $(seq 74); echo
gap=0; cov=0; imp=0
while read -r m; do
    v=GAP; r=""
    case "$m" in
      ipcmk|lsipc)            sym CONFIG_SYSVIPC || { v=CANNOT; r="CONFIG_SYSVIPC=n -- no /proc/sysvipc on a booted machine"; } ;;
      mkfs.cramfs|fsck.cramfs) sym CONFIG_CRAMFS || { v=CANNOT; r="CONFIG_CRAMFS=n"; } ;;
      mkfs.bfs)               sym CONFIG_BFS_FS || { v=CANNOT; r="CONFIG_BFS_FS=n"; } ;;
      agetty)      v=COVERED; r="busybox getty, which this init already runs" ;;
      i386|x86_64) v=COVERED; r="busybox setarch" ;;
      runuser)     v=COVERED; r="busybox su" ;;
      ctrlaltdel)  v=COVERED; r="s6-linux-init owns the reboot path" ;;
      mkfs)        v=COVERED; r="a dispatcher over mkfs.* busybox provides directly" ;;
      lastb|utmpdump|lslogins) v=COVERED; r="reads utmp/wtmp/btmp, which nothing in this image writes" ;;
      mcookie)     v=COVERED; r="X authority cookies, and there is no X" ;;
      scriptlive)  v=COVERED; r="busybox has script and scriptreplay" ;;
      rename.ul)   v=COVERED; r="a Debian rename, not util-linux core" ;;
    esac
    case "$v" in GAP) gap=$((gap+1));; COVERED) cov=$((cov+1));; CANNOT) imp=$((imp+1));; esac
    printf '%-14s %-8s %s\n' "$m" "$v" "$r"
done < <(comm -23 "$ul" "$bb")
echo
echo "  GAP $gap    COVERED $cov    CANNOT $imp"
echo
echo "A GAP here is a program with nothing standing in for it. It is NOT"
echo "automatically a reason to port util-linux: read the list and ask"
echo "which ones somebody on this machine would reach for."
