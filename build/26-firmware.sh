#!/bin/bash
# ============================================================
# 26-firmware.sh — the firmware real hardware needs to work at all
#
# RFC 0011. A driver is not enough. Most WiFi chips, every modern AMD
# GPU, and a good deal else will not initialise without a firmware blob
# the kernel loads from /lib/firmware at probe time. Novi shipped none,
# which is why the WiFi story (RFC 0009) ended with "on a large
# fraction of real laptops the driver loads and the radio does not come
# up".
#
# A CURATED SUBSET, not the whole tree: linux-firmware is about 4 GB
# extracted, most of it for hardware nobody reading this owns. The list
# below is the hardware in laptops and desktops built in the last
# decade or so.
#
# IN THE BASE IMAGE, not a package -- and that is a deliberate
# exception to RFC 0007's "everything else is a package". Firmware is
# hardware enablement, exactly like the kernel modules already in the
# base. Putting the driver for your WiFi card in a package you need
# working WiFi to fetch is a chicken-and-egg, and putting your GPU's
# firmware in a package you need a working display to install is worse.
#
# regulatory.db is in the list for a reason easy to miss: this kernel
# has CONFIG_CFG80211_REQUIRE_SIGNED_REGDB=y, so without it (and its
# .p7s signature) the wireless stack falls back to the most restrictive
# world-roaming rules -- fewer channels, less power, and a WiFi problem
# that looks like bad reception rather than a missing file.
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-versions.sh"

SRC="${SOURCES}/linux-firmware-${LINUX_FIRMWARE_VERSION}.tar.xz"
[ -f "${SRC}" ] || {
    echo "ERROR: ${SRC} not found -- run build/01-fetch.sh first." >&2
    exit 1
}

DEST="${ROOTFS}/lib/firmware"
PREFIX="linux-firmware-${LINUX_FIRMWARE_VERSION}"

# What gets extracted, and who needs it.
#
# Kept as a list of tar wildcards so it is one obvious place to add a
# vendor, and so a reader can tell at a glance what this image does and
# does not support.
PATTERNS=(
    # Intel WiFi -- the radio in most laptops.
    #
    # `intel/iwlwifi/`, NOT top-level `iwlwifi-*.ucode`: linux-firmware
    # reorganised into per-vendor directories, and the old pattern
    # matched nothing. It did so silently, because a tar wildcard that
    # matches nothing is not an error worth noticing among two hundred
    # others -- the first extraction produced 393 MB of firmware with
    # zero iwlwifi files in it and looked like a success.
    "${PREFIX}/intel/iwlwifi/*"

    # Qualcomm/Atheros WiFi
    "${PREFIX}/ath10k/*"
    "${PREFIX}/ath11k/*"
    "${PREFIX}/ath12k/*"
    "${PREFIX}/ath9k_htc/*"

    # MediaTek WiFi (mt7921/mt7922 are common in AMD laptops).
    #
    # mediatek/mt7* only, not the whole vendor directory: the rest is
    # firmware for MediaTek ARM SoCs -- phone and Chromebook silicon --
    # which this x86_64 image cannot run and which is most of the 71 MB.
    "${PREFIX}/mediatek/mt7*"

    # Realtek WiFi and Ethernet
    "${PREFIX}/rtw88/*"
    "${PREFIX}/rtw89/*"
    "${PREFIX}/rtl_nic/*"

    # Broadcom WiFi (Macs, older laptops, Raspberry Pi)
    "${PREFIX}/brcm/*"

    # Intel graphics: DMC for display power management, GuC/HuC for
    # everything from Tiger Lake on. Without these, newer Intel display
    # pipelines lose features and some refuse to come up.
    "${PREFIX}/i915/*"

    # AMD graphics. The big one, and not optional: amdgpu does not
    # initialise AT ALL without its microcode, so an AMD machine
    # without this has no DRM device and therefore no desktop.
    "${PREFIX}/amdgpu/*"

    # Intel's newer GPU driver (Xe, for Lunar Lake and on).
    "${PREFIX}/xe/*"

    # NOT nvidia/ (154 MB). nouveau is the only driver here that could
    # use it, and on a laptop with an NVIDIA chip the display is
    # almost always driven by the Intel or AMD integrated GPU anyway.
    # Paying 154 MB in every image for a driver most users will not
    # reach through is the wrong trade; it is a firmware package
    # waiting to happen (see the roadmap in RFC 0011).

    # Audio codecs and amplifiers. Cirrus parts are in a lot of recent
    # laptops and the speakers stay silent without them.
    "${PREFIX}/cirrus/*"

    # Qualcomm/Atheros WiFi and Bluetooth.
    #
    # NOT qcom/ (502 MB, the single largest directory in the tree):
    # that is Snapdragon SoC firmware -- modem, DSP, Adreno -- for ARM
    # hardware this x86_64 image cannot boot on at all. It becomes
    # relevant the day there is an aarch64 build, and not before.
    "${PREFIX}/qca/*"

    # AMD CPU microcode. Small, and it carries security fixes the CPU
    # applies at boot; there is no reason to ship a machine without it.
    # (Intel's equivalent is not in linux-firmware.)
    "${PREFIX}/amd-ucode/*"
)

echo ">>> Extracting firmware from $(basename "${SRC}") ..."
mkdir -p "${DEST}"
rm -rf "${DEST:?}"/*

# --wildcards for the globs, --no-wildcards-match-slash off so `*`
# crosses directories inside a vendor dir (amdgpu has none, brcm does).
# --warning=no-... because patterns that match nothing in a given
# release are normal, not an error: hardware comes and goes.
# A pattern matching nothing makes GNU tar exit non-zero, and that is
# NOT a failure here: hardware comes and goes between releases, and the
# list above is deliberately broader than any one release. But a real
# error -- a truncated download, a full disk -- must still stop the
# build. So: keep tar's stderr, and fail only if it says something
# other than "not found in archive".
#
# The first version of this just discarded stderr and trusted the exit
# code, which meant it reported failure on a perfectly good 393 MB
# extraction and would have reported the same on a broken one.
tar_err="${BUILD_DIR}/firmware-extract.err"
if ! tar -xf "${SRC}" -C "${DEST}" --strip-components=1 \
        --wildcards --wildcards-match-slash \
        "${PATTERNS[@]}" 2>"${tar_err}"; then
    if grep -qvE 'Not found in archive|Exiting with failure status' "${tar_err}"; then
        echo "ERROR: extracting firmware failed:" >&2
        head -20 "${tar_err}" >&2
        exit 1
    fi
    missed="$(grep -c 'Not found in archive' "${tar_err}" || true)"
    echo "    ${missed} pattern(s) matched nothing in this release (expected)"
fi
rm -f "${tar_err}"

# ── The two that are not in linux-firmware ────────────────────────────────
#
# Both are separately versioned projects, and both are the difference
# between hardware that works and hardware that half-works in a way
# that looks like something else.

# The wireless regulatory database. This kernel has
# CONFIG_CFG80211_REQUIRE_SIGNED_REGDB=y, so without regulatory.db AND
# its detached .p7s signature the wireless stack falls back to the most
# restrictive world-roaming rules -- fewer channels, less power, and a
# problem that presents as bad reception rather than a missing file.
REGDB_SRC="${SOURCES}/wireless-regdb-${WIRELESS_REGDB_VERSION}.tar.xz"
if [ -f "${REGDB_SRC}" ]; then
    echo ">>> Installing the wireless regulatory database ..."
    tmp="${BUILD_DIR}/regdb-tmp"; rm -rf "${tmp}"; mkdir -p "${tmp}"
    tar -xf "${REGDB_SRC}" -C "${tmp}" --strip-components=1
    install -m 644 "${tmp}/regulatory.db" "${DEST}/regulatory.db"
    # The kernel refuses an unsigned db when REQUIRE_SIGNED_REGDB is
    # set, so the signature is not optional.
    install -m 644 "${tmp}/regulatory.db.p7s" "${DEST}/regulatory.db.p7s"
    rm -rf "${tmp}"
else
    echo ">>> WARNING: no wireless-regdb tarball -- WiFi will be limited to" >&2
    echo ">>>          world-roaming channels and power." >&2
fi

# Intel SOF audio. Intel laptops from roughly 2019 on drive their audio
# through SOF rather than legacy HDA; without this they have no sound
# at all, while an older machine on snd_hda_intel is unaffected.
SOF_SRC="${SOURCES}/sof-bin-${SOF_BIN_VERSION}.tar.gz"
if [ -f "${SOF_SRC}" ]; then
    echo ">>> Installing Intel SOF audio firmware ..."
    tmp="${BUILD_DIR}/sof-tmp"; rm -rf "${tmp}"; mkdir -p "${tmp}"
    tar -xf "${SOF_SRC}" -C "${tmp}" --strip-components=1
    # sof-bin ships versioned directories plus the symlink names the
    # driver actually asks for; copy the tree as-is so both survive.
    for d in sof sof-tplg sof-ipc4 sof-ipc4-tplg; do
        [ -d "${tmp}/${d}" ] && cp -a "${tmp}/${d}" "${DEST}/intel/" 2>/dev/null || true
    done
    rm -rf "${tmp}"
else
    echo ">>> WARNING: no sof-bin tarball -- Intel laptops newer than about" >&2
    echo ">>>          2019 will have no audio." >&2
fi

# linux-firmware ships many files as symlinks into other directories
# that the patterns above may not have pulled in. A dangling firmware
# symlink is worse than a missing file: the driver finds a name,
# follows it, and fails in a way that looks like corruption.
echo ">>> Pruning dangling symlinks ..."
dangling=0
while IFS= read -r l; do
    [ -e "$l" ] || { rm -f "$l"; dangling=$(( dangling + 1 )); }
done < <(find "${DEST}" -type l)
[ "${dangling}" -gt 0 ] && echo "    removed ${dangling} dangling link(s)"

echo ""
echo "Firmware installed: $(du -sh "${DEST}" | cut -f1), $(find "${DEST}" -type f | wc -l) file(s)"
for d in iwlwifi ath10k ath11k mediatek rtw88 rtw89 brcm i915 amdgpu rtl_nic; do
    if [ -d "${DEST}/${d}" ]; then
        printf '  %-12s %s\n' "${d}" "$(du -sh "${DEST}/${d}" | cut -f1)"
    fi
done
[ -f "${DEST}/regulatory.db" ] && echo "  regulatory.db present (wireless channel/power rules)"
[ -d "${DEST}/intel/iwlwifi" ] && printf '  %-12s %s\n' "iwlwifi" "$(du -sh "${DEST}/intel/iwlwifi" | cut -f1)"
[ -d "${DEST}/intel/sof" ]     && printf '  %-12s %s\n' "sof (audio)" "$(du -csh "${DEST}"/intel/sof* | tail -1 | cut -f1)"
exit 0
