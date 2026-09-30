#!/bin/bash
# Every command Novi ships should have a manual page.
#
# The base image carries a manual reader (mandoc, RFC 0040 roadmap 2)
# and 56 pages, and for a long time not one of them documented
# anything Novi wrote: a person who booted the ISO could learn the
# system only by reading its shell scripts. This is the check that
# keeps that from coming back.
#
#   bash probe.sh          report coverage and lint every page
#
# DERIVED FROM WHAT SHIPS, not from a list. The set of commands comes
# from the built rootfs, so a new command arrives in this check by
# being installed -- there is no second place to remember. Same
# argument as pkgsplit deriving the base/desktop split and
# novi-sandbox having no list of sandboxed programs.
set -uo pipefail

ROOTFS="${ROOTFS:-/build/rootfs}"
MANDOC="${MANDOC:-/build/stage-devtools/man/files/usr/bin/mandoc}"
SRC="${SRC:-rootfs/usr/share/man}"
MISSING=0; LINTED=0; DIRTY=0

[ -d "$ROOTFS" ] || { echo "no rootfs at $ROOTFS -- build first"; exit 2; }

echo "== commands the image ships, and whether they are documented"
for d in bin sbin usr/bin usr/sbin; do
    for f in "$ROOTFS/$d"/novi-* "$ROOTFS/$d"/pkg "$ROOTFS/$d"/mkpkg; do
        [ -f "$f" ] || continue
        n="$(basename "$f")"
        case "$d" in *sbin) sec=8 ;; *) sec=1 ;; esac
        if [ -f "$ROOTFS/usr/share/man/man$sec/$n.$sec" ]; then
            printf '  ok       %s(%s)\n' "$n" "$sec"
        else
            printf '  MISSING  %s(%s)\n' "$n" "$sec"; MISSING=$((MISSING+1))
        fi
    done
done

# Config formats a person has to edit by hand. These are section 5 and
# have no binary to derive them from, so this list is the one place
# they are named -- and each entry is a file the image actually ships,
# checked below, so it cannot name something imaginary.
echo
echo "== configuration files, and whether their format is documented"
for pair in \
    "etc/novi/system.conf:system.conf" \
    "etc/novi/keys.conf:keys.conf" \
    "etc/novi/pkg.conf:pkg.conf" \
    "etc/novi/firewall.nft:firewall.nft"; do
    file="${pair%%:*}"; page="${pair##*:}"
    [ -e "$ROOTFS/$file" ] || { printf '  --       %s is not in the image\n' "$file"; continue; }
    if [ -f "$ROOTFS/usr/share/man/man5/$page.5" ]; then
        printf '  ok       %s(5)\n' "$page"
    else
        printf '  MISSING  %s(5)  (%s ships and has no page)\n' "$page" "$file"
        MISSING=$((MISSING+1))
    fi
done

# ---------------------------------------------------------------------------
# Every page must also be clean mdoc, checked with the mandoc THIS
# REPO BUILDS rather than the host's -- the shipped reader is the one
# whose opinion matters, and it is the one configured with
# OSNAME="Novi Linux", which is why a page writes a bare `.Os`.
# ---------------------------------------------------------------------------
echo
echo "== mandoc -Tlint, with the mandoc this repo builds"
if [ ! -x "$MANDOC" ]; then
    echo "  -- no built mandoc at $MANDOC; skipping the lint"
else
    W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
    mkdir -p "$W"/{bin,lib,usr/bin,usr/lib}
    cp "$ROOTFS/bin/busybox" "$W/bin/" 2>/dev/null
    cp -a "$ROOTFS"/lib/ld-musl-*.so.* "$ROOTFS"/lib/libc.musl-*.so.* "$W/lib/" 2>/dev/null
    cp "$MANDOC" "$W/usr/bin/"
    # mandoc links libz, which the desktop split moves into a package.
    for z in "$ROOTFS"/usr/lib/libz.so.1* /build/repo/zlib-*.pkg.tar.gz; do
        case "$z" in
            *.pkg.tar.gz) [ -f "$z" ] && tar -xzf "$z" -C "$W" --strip-components=1 \
                              --wildcards 'files/usr/lib/libz.so*' 2>/dev/null ;;
            *)            [ -e "$z" ] && cp -a "$z" "$W/usr/lib/" ;;
        esac
    done
    mkdir -p "$W/usr/share/man"
    cp -a "$SRC"/* "$W/usr/share/man/" 2>/dev/null
    for page in $(cd "$W/usr/share/man" && find . -type f -name '*.[0-9]' | sort); do
        rel="/usr/share/man/${page#./}"
        out="$(chroot "$W" /usr/bin/mandoc -T lint "$rel" 2>&1 \
               | grep -v 'outdated mandoc.db')"
        LINTED=$((LINTED+1))
        if [ -n "$out" ]; then
            DIRTY=$((DIRTY+1))
            printf '  DIRTY    %s\n' "${page#./}"
            printf '%s\n' "$out" | sed 's/^/           /'
        fi
    done
    printf '  %d page(s) linted, %d with warnings\n' "$LINTED" "$DIRTY"
fi

echo
printf '  %d undocumented, %d page(s) with mandoc warnings\n' "$MISSING" "$DIRTY"
[ "$MISSING" -eq 0 ] && [ "$DIRTY" -eq 0 ]
