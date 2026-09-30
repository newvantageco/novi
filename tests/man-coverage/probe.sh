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

# Two halves, and they need different things.
#
# The COMMAND coverage needs a built rootfs, because the set of
# commands is derived from what is installed rather than from a list
# -- and a CI runner has no rootfs and no way to get one in the time
# it has. That half is skipped there, loudly, the same way
# `novi-state diff` cannot run in CI: making it run would mean faking
# the machine, and a check against a fake machine checks the fake.
#
# The LINT needs only a mandoc, and mandoc is a package on every
# runner, so that half runs everywhere. It prefers the one this repo
# builds -- that is the reader whose opinion matters, and the one
# configured with OSNAME="Novi Linux" -- and falls back to the host's
# with the same -I os, because a check that skips itself where a
# header is missing skips itself exactly where it would have caught
# something.
HAVE_ROOTFS=1
[ -d "$ROOTFS" ] || HAVE_ROOTFS=0

if [ "$HAVE_ROOTFS" = 0 ]; then
    echo "== commands the image ships: SKIPPED, no rootfs at $ROOTFS"
    echo "   (the command set is derived from what is installed; build first)"
else
echo "== commands the image ships, and whether they are documented"
for d in bin sbin usr/bin usr/sbin; do
    for f in "$ROOTFS/$d"/novi-* "$ROOTFS/$d"/pkg "$ROOTFS/$d"/mkpkg; do
        [ -f "$f" ] || continue
        n="$(basename "$f")"
        case "$d" in *sbin) sec=8 ;; *) sec=1 ;; esac
        if [ -f "$SRC/man$sec/$n.$sec" ]; then
            printf '  ok       %s(%s)\n' "$n" "$sec"
        else
            printf '  MISSING  %s(%s)\n' "$n" "$sec"; MISSING=$((MISSING+1))
        fi
    done
done

fi

# Config formats a person has to edit by hand. These are section 5 and
# have no binary to derive them from, so this list is the one place
# they are named -- and each entry is a file the image actually ships,
# checked below, so it cannot name something imaginary.
echo
echo "== configuration files, and whether their format is documented"
if [ "$HAVE_ROOTFS" = 0 ]; then
    echo "  -- skipped with the rootfs"
fi
[ "$HAVE_ROOTFS" = 1 ] && for pair in \
    "etc/novi/system.conf:system.conf" \
    "etc/novi/keys.conf:keys.conf" \
    "etc/novi/pkg.conf:pkg.conf" \
    "etc/novi/firewall.nft:firewall.nft"; do
    file="${pair%%:*}"; page="${pair##*:}"
    [ -e "$ROOTFS/$file" ] || { printf '  --       %s is not in the image\n' "$file"; continue; }
    if [ -f "$SRC/man5/$page.5" ]; then
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
NATIVE=""
if [ ! -x "$MANDOC" ]; then
    NATIVE="$(command -v mandoc || true)"
fi
if [ ! -x "$MANDOC" ] && [ -z "$NATIVE" ]; then
    echo "  -- no mandoc, built or host; skipping the lint"
elif [ -n "$NATIVE" ]; then
    # The host mandoc resolves `.Xr` against ITS OWN manpath, not a
    # staged tree, and neither -C nor a built mandoc.db beside the
    # pages changes that -- tried both. So on this path the
    # cross-reference check DID NOT RUN, and its finding is dropped
    # rather than reported: 25 pages each "referencing a manual not
    # found" is an instrument answering a different question, which
    # is the failure this file's own comments keep naming. Everything
    # else mandoc checks -- structure, section order, macro use,
    # delimiters -- is unaffected and still runs.
    echo "  (host mandoc: the built one is not here;"
    echo "   cross-references are NOT checked on this path)"
    W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
    mkdir -p "$W/usr/share/man"
    [ "$HAVE_ROOTFS" = 1 ] &&
        cp -a "$ROOTFS/usr/share/man"/* "$W/usr/share/man/" 2>/dev/null
    cp -a "$SRC"/* "$W/usr/share/man/" 2>/dev/null
    makewhatis "$W/usr/share/man" >/dev/null 2>&1 || true
    for page in $(cd "$W/usr/share/man" && find . -type f -name '*.[0-9]' | sort); do
        [ -f "$SRC/${page#./}" ] || continue
        out="$("$NATIVE" -I os="Novi Linux" -T lint \
               "$W/usr/share/man/${page#./}" 2>&1 |
               grep -v 'referenced manual not found' || true)"
        LINTED=$((LINTED+1))
        if [ -n "$out" ]; then
            DIRTY=$((DIRTY+1))
            printf '  DIRTY    %s\n' "${page#./}"
            printf '%s\n' "$out" | sed "s|$W/usr/share/man/||" | sed 's/^/           /'
        fi
    done
    printf '  %d page(s) linted, %d with warnings\n' "$LINTED" "$DIRTY"
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
    # The lint tree is the WHOLE shipped tree -- the base image's own
    # pages (alsa-utils ships 79) as well as ours -- because mandoc
    # resolves every `.Xr` against it. Staging only our pages makes a
    # reference to a page the image really has report "referenced
    # manual not found", which reads exactly like a reference to one
    # nobody has written: the finding this check exists for, drowned in
    # false ones. The index is built for the same reason -- without it
    # every page reports an outdated mandoc.db and the real staleness
    # is indistinguishable from the noise.
    mkdir -p "$W/usr/share/man"
    cp -a "$ROOTFS/usr/share/man"/* "$W/usr/share/man/" 2>/dev/null
    cp -a "$SRC"/* "$W/usr/share/man/" 2>/dev/null
    ln -sf mandoc "$W/usr/bin/makewhatis"
    chroot "$W" /usr/bin/makewhatis /usr/share/man >/dev/null 2>&1 ||
        echo "  -- makewhatis failed; cross-references will report as missing"
    for page in $(cd "$W/usr/share/man" && find . -type f -name '*.[0-9]' | sort); do
        rel="/usr/share/man/${page#./}"
        # Ours only: linting alsa-utils' pages would report upstream's
        # style against a check nobody here can act on.
        [ -f "$SRC/${page#./}" ] || continue
        out="$(chroot "$W" /usr/bin/mandoc -T lint "$rel" 2>&1)"
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
