#!/bin/bash
# 42-tzdata.sh — the IANA time zone database (RFC 0042).
#
# Before this the image shipped NO zoneinfo at all and no
# /etc/localtime, so every Novi machine was permanently UTC: `date`,
# `ls -l`, every log line and the panel clock, with no way to say
# otherwise. The panel already called localtime_r(3); the data it
# resolves through was simply absent.
#
# BASE CONTENT, not a package, and the number is why. Measured on the
# compiled output rather than guessed:
#
#     slim   203,282 bytes over 341 inodes (598 names)
#     fat    400,141 bytes over 341 inodes
#     slim gzipped        78,898 bytes
#
# against a 790 MB base OS. The whole database is 0.03% of the image
# compressed, so a curated subset buys nothing and a timezone database
# that lacks YOUR zone is useless. And a package would mean a machine
# that has not installed it reads UTC, which is the state this stage
# exists to end.
#
# SLIM, NOT FAT, and that was checked rather than assumed. Slim leans
# on the POSIX TZ footer string for transitions past the last explicit
# one, which an old TZif reader cannot follow -- so the question is
# what MUSL does, not what the format allows. Driven through the
# shipped static-musl busybox over 8 zones x 7 instants (two
# hemispheres' DST, Pacific/Chatham's quarter-hour offset, Asia/Tehran,
# a 1966 date and a 2038 one): slim and fat agree on all 56, and both
# agree with the HOST's glibc reading the same 2025b data. Two readers
# and two formats, one answer.
#
# zic IS BUILT HERE, from the pinned tzcode, and never taken from the
# build host. foot's terminfo rule (CLAUDE.md): a generator's output
# has to be a property of the pinned source, or the image quietly
# depends on which distribution built it. It is a build-host tool and
# is never installed -- the hostapd bargain.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-versions.sh
source "${SCRIPT_DIR}/00-versions.sh"

SRC="${SOURCES}/tzdata-${TZDATA_VERSION}"
TOOLDIR="${BUILD_DIR}/tz-tools"
ZONEDIR="${ROOTFS}/usr/share/zoneinfo"

# The zone files to compile. `backward` carries the historical names
# (US/Eastern, Asia/Calcutta) that real configuration files and real
# people still use, so leaving it out would make a correct-looking
# `time.timezone = US/Eastern` fail to resolve. `factory` is one zone
# whose abbreviation tells anyone who sees it that nobody configured
# this machine, which is a better default than a plausible wrong one.
ZONE_FILES="africa antarctica asia australasia europe northamerica \
southamerica etcetera backward factory"

echo "=== Stage 42: IANA time zone database ${TZDATA_VERSION} ==="

# ---------------------------------------------------------------------------
# Extract. Both tarballs unpack into ONE directory -- that is how IANA
# ships them, and zic's makefile expects its data beside it.
# ---------------------------------------------------------------------------
rm -rf "${SRC}"
mkdir -p "${SRC}"
for t in tzdata tzcode; do
    tarball="${SOURCES}/${t}${TZDATA_VERSION}.tar.gz"
    [ -f "${tarball}" ] || {
        echo "ERROR: ${tarball} missing -- run build/01-fetch.sh" >&2
        exit 1
    }
    tar -xzf "${tarball}" -C "${SRC}"
done

# ---------------------------------------------------------------------------
# zic, for the BUILD host. Not cross-compiled: it runs here, reads the
# text rules and writes the target's binary files.
# ---------------------------------------------------------------------------
echo "--- building zic (build host tool, never installed)"
mkdir -p "${TOOLDIR}"
(
    cd "${SRC}"
    # Its own CFLAGS, not harden_flags(): this binary never reaches the
    # image, and the build host's compiler is not the cross compiler.
    make CFLAGS='-O2 -DHAVE_GETTEXT=0' zic >/dev/null
    cp zic "${TOOLDIR}/zic"
)
"${TOOLDIR}/zic" --version | head -1

# ---------------------------------------------------------------------------
# Compile the zones.
# ---------------------------------------------------------------------------
echo "--- compiling zones (-b slim)"
STAGE="${BUILD_DIR}/tz-stage"
rm -rf "${STAGE}"
mkdir -p "${STAGE}"
(
    cd "${SRC}"
    # shellcheck disable=SC2086
    "${TOOLDIR}/zic" -b slim -d "${STAGE}" ${ZONE_FILES}
)

# UTC has to exist under every name people reach for. zic's own
# `backward` supplies most of them; this is the one the POSIX name
# resolves to and the fallback a machine with no declared zone uses.
[ -f "${STAGE}/UTC" ] || {
    echo "ERROR: no UTC zone compiled -- the etcetera file did not load" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# A ZONE FILE MUST ACTUALLY PARSE, and only a musl reader can say so.
# The build host's date(1) is glibc: it would accept a file this
# system cannot read and the failure would first appear on a booted
# machine as a clock that is silently UTC.
# ---------------------------------------------------------------------------
echo "--- checking the shipped musl can read them"
BB="${ROOTFS}/bin/busybox"
if [ -x "${BB}" ]; then
    probe="${BUILD_DIR}/tz-probe"
    rm -rf "${probe}"
    mkdir -p "${probe}/bin" "${probe}/usr/share"
    cp "${BB}" "${probe}/bin/busybox"
    cp -a "${STAGE}" "${probe}/usr/share/zoneinfo"
    # An instant whose answer differs per zone, so a zone file that
    # failed to load (musl falls back to UTC, silently) is visible.
    want_ny="2024-07-03 08:00:00 -0400"
    got_ny="$(chroot "${probe}" /bin/busybox env TZ=America/New_York \
        /bin/busybox date -d @1720008000 '+%Y-%m-%d %H:%M:%S %z')"
    if [ "${got_ny}" != "${want_ny}" ]; then
        echo "ERROR: musl read America/New_York as '${got_ny}'," >&2
        echo "       expected '${want_ny}'. A silent UTC fallback looks" >&2
        echo "       exactly like this." >&2
        exit 1
    fi
    echo "    America/New_York @1720008000 -> ${got_ny}"
    rm -rf "${probe}"
else
    echo "    (no busybox in the rootfs yet -- skipping, stage 03 builds it)"
fi

# ---------------------------------------------------------------------------
# Install. ONE `cp -a`, and the reason is mandoc's (CLAUDE.md, RFC
# 0040 roadmap 2): zic emits every Link entry as a HARDLINK, so 598
# names share 341 inodes -- and `cp -a` preserves a hardlink only
# among the sources of a SINGLE invocation. A per-file loop would
# silently produce 598 full copies, doubling the cost of the thing
# this stage measured so carefully.
# ---------------------------------------------------------------------------
echo "--- installing to ${ZONEDIR}"
rm -rf "${ZONEDIR}"
mkdir -p "$(dirname "${ZONEDIR}")"
cp -a "${STAGE}" "${ZONEDIR}"

names="$(find "${ZONEDIR}" -type f | wc -l)"
inodes="$(find "${ZONEDIR}" -type f -printf '%i\n' | sort -u | wc -l)"
bytes="$(find "${ZONEDIR}" -type f -printf '%i %s\n' | sort -u -k1,1 |
         awk '{s+=$2} END {print s+0}')"
printf '    %s names, %s inodes, %s bytes\n' "${names}" "${inodes}" "${bytes}"

# DERIVED FROM THE SOURCE, not a number written down here: whatever
# zic linked together in the staging tree must still be linked in the
# image. A count would rot the next time IANA adds a zone; this
# cannot.
stage_inodes="$(find "${STAGE}" -type f -printf '%i\n' | sort -u | wc -l)"
stage_names="$(find "${STAGE}" -type f | wc -l)"
if [ "${names}" != "${stage_names}" ] || [ "${inodes}" != "${stage_inodes}" ]; then
    echo "ERROR: staging had ${stage_names} names over ${stage_inodes} inodes," >&2
    echo "       the image has ${names} over ${inodes}. The hardlinks zic" >&2
    echo "       made were not preserved -- see the one-cp rule above." >&2
    exit 1
fi
[ "${names}" -gt "${inodes}" ] || {
    echo "ERROR: no hardlinks at all in the compiled output. zic always" >&2
    echo "       emits Link entries as hardlinks, so this means the" >&2
    echo "       zone list lost its 'backward' file." >&2
    exit 1
}

# ---------------------------------------------------------------------------
# /etc/localtime. A RELATIVE symlink, because RFC 0041's A/B installer
# mounts a slot's root somewhere other than / and an absolute link
# would resolve against the RUNNING system rather than the slot being
# written -- the same reason `novi-sandbox` resolves the xkb symlink
# rather than writing its target down.
#
# UTC by default: a machine nobody has configured should say so
# plainly rather than guess, and `time.timezone` is what changes it.
# ---------------------------------------------------------------------------
ln -sfn ../usr/share/zoneinfo/UTC "${ROOTFS}/etc/localtime"
echo "    /etc/localtime -> $(readlink "${ROOTFS}/etc/localtime")"

echo "=== Stage 42 complete ==="
