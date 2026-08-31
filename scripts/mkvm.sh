#!/usr/bin/env bash
# mkvm.sh — Launch Novi Linux ISO in QEMU/KVM
# Usage:
#   ./mkvm.sh                     # boot ISO in live mode
#   ./mkvm.sh --disk              # create qcow2 + boot ISO for installation
#   ./mkvm.sh --disk --no-iso     # boot from existing disk only (post-install)
#
# Requires: qemu-system-x86_64, OVMF firmware

set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-${REPO_ROOT}/build}"

ISO_PATH="${ISO_PATH:-${BUILD_DIR}/novi.iso}"
DISK_IMAGE="${DISK_IMAGE:-${BUILD_DIR}/novi-disk.qcow2}"
DISK_SIZE="${DISK_SIZE:-32G}"

RAM_MB="${RAM_MB:-4096}"
VCPUS="${VCPUS:-4}"
DISPLAY="${DISPLAY_MODE:-sdl}"   # sdl | gtk | spice | none

# OVMF firmware search paths (Debian/Ubuntu/Arch/Fedora locations)
OVMF_FIRMWARE_PATHS=(
    "/usr/share/ovmf/OVMF.fd"
    "/usr/share/OVMF/OVMF_CODE.fd"
    "/usr/share/edk2/ovmf/OVMF_CODE.fd"
    "/usr/share/edk2-ovmf/OVMF_CODE.fd"
    "/usr/lib/qemu/ovmf-x86_64.bin"
    "/usr/share/qemu/OVMF.fd"
)
OVMF_VARS_PATHS=(
    "/usr/share/OVMF/OVMF_VARS.fd"
    "/usr/share/edk2/ovmf/OVMF_VARS.fd"
    "/usr/share/edk2-ovmf/OVMF_VARS.fd"
    "/usr/share/ovmf/OVMF_VARS.fd"
)

MODE_DISK=false
MODE_NO_ISO=false
EXTRA_QEMU_ARGS=()

# ─── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --disk)          MODE_DISK=true;  shift ;;
        --no-iso)        MODE_NO_ISO=true; shift ;;
        --iso)           ISO_PATH="$2";   shift 2 ;;
        --disk-image)    DISK_IMAGE="$2"; shift 2 ;;
        --disk-size)     DISK_SIZE="$2";  shift 2 ;;
        --ram)           RAM_MB="$2";     shift 2 ;;
        --cpus)          VCPUS="$2";      shift 2 ;;
        --display)       DISPLAY="$2";    shift 2 ;;
        --snapshot)      EXTRA_QEMU_ARGS+=(-snapshot); shift ;;
        -h|--help)
            cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --disk           Create (if missing) and attach a qcow2 disk image
  --no-iso         Don't attach the ISO (boot from disk only, post-install)
  --iso PATH       Path to the ISO image (default: ${ISO_PATH})
  --disk-image PATH  Path to the qcow2 image (default: ${DISK_IMAGE})
  --disk-size SIZE   Size of new disk (default: ${DISK_SIZE})
  --ram MB         RAM in megabytes (default: ${RAM_MB})
  --cpus N         Number of vCPUs (default: ${VCPUS})
  --display MODE   Display backend: sdl|gtk|spice|none (default: ${DISPLAY})
  --snapshot       Run in snapshot mode (discard writes on exit)
  -h, --help       Show this help

Examples:
  $0                        # Live boot ISO
  $0 --disk                 # Install from ISO to disk
  $0 --disk --no-iso        # Boot installed system from disk
  $0 --snapshot             # Live boot, discard all changes
EOF
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# ─── Prerequisite checks ──────────────────────────────────────────────────────
require() {
    if ! command -v "$1" &>/dev/null; then
        echo "ERROR: Required tool '$1' not found." >&2
        exit 1
    fi
}
require qemu-system-x86_64

# Check KVM availability
KVM_ARGS=()
if [[ -e /dev/kvm ]]; then
    if [[ -r /dev/kvm && -w /dev/kvm ]]; then
        KVM_ARGS=(-enable-kvm -cpu host)
        echo ">>> KVM acceleration enabled (host CPU passthrough)"
    else
        echo "WARNING: /dev/kvm exists but is not accessible. Running without KVM." >&2
        echo "  Fix: sudo usermod -aG kvm \$USER  (then re-login)" >&2
        KVM_ARGS=(-cpu qemu64)
    fi
else
    echo "WARNING: KVM not available (/dev/kvm missing). Performance will be poor." >&2
    KVM_ARGS=(-cpu qemu64)
fi

# ─── Locate OVMF firmware ─────────────────────────────────────────────────────
OVMF_CODE=""
for p in "${OVMF_FIRMWARE_PATHS[@]}"; do
    if [[ -f "${p}" ]]; then
        OVMF_CODE="${p}"
        break
    fi
done
if [[ -z "${OVMF_CODE}" ]]; then
    echo "ERROR: OVMF UEFI firmware not found." >&2
    echo "  Install with: sudo apt install ovmf   OR   sudo pacman -S edk2-ovmf" >&2
    exit 1
fi
echo ">>> Using OVMF firmware: ${OVMF_CODE}"

# Try to find writable OVMF_VARS (for EFI variable persistence)
OVMF_VARS=""
OVMF_VARS_RUNTIME="${BUILD_DIR}/OVMF_VARS_runtime.fd"
for p in "${OVMF_VARS_PATHS[@]}"; do
    if [[ -f "${p}" ]]; then
        OVMF_VARS="${p}"
        break
    fi
done

DRIVE_FIRMWARE_ARGS=()
if [[ -n "${OVMF_VARS}" ]]; then
    # Copy VARS to a writable runtime copy so EFI settings persist between runs
    if [[ ! -f "${OVMF_VARS_RUNTIME}" ]]; then
        echo ">>> Copying OVMF_VARS to runtime location for persistence ..."
        mkdir -p "${BUILD_DIR}"
        cp "${OVMF_VARS}" "${OVMF_VARS_RUNTIME}"
    fi
    DRIVE_FIRMWARE_ARGS=(
        -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}"
        -drive "if=pflash,format=raw,file=${OVMF_VARS_RUNTIME}"
    )
    echo ">>> EFI vars: ${OVMF_VARS_RUNTIME} (persistent)"
else
    # Single-file OVMF (no separate VARS)
    DRIVE_FIRMWARE_ARGS=(
        -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}"
    )
    echo ">>> Single-file OVMF (no persistent EFI vars)"
fi

# ─── Disk image setup ─────────────────────────────────────────────────────────
DISK_ARGS=()
if "${MODE_DISK}"; then
    if [[ ! -f "${DISK_IMAGE}" ]]; then
        echo ">>> Creating qcow2 disk image: ${DISK_IMAGE} (${DISK_SIZE}) ..."
        mkdir -p "$(dirname "${DISK_IMAGE}")"
        qemu-img create -f qcow2 "${DISK_IMAGE}" "${DISK_SIZE}"
        echo ">>> Disk created."
    else
        echo ">>> Using existing disk image: ${DISK_IMAGE}"
    fi
    DISK_ARGS=(
        -drive "file=${DISK_IMAGE},if=none,id=hd0,format=qcow2,cache=writeback"
        -device virtio-blk-pci,drive=hd0,bootindex=1
    )
fi

# ─── ISO / CDROM ──────────────────────────────────────────────────────────────
# Attached as a plain virtio-blk device, not virtio-scsi+scsi-cd: our kernel
# config builds CONFIG_VIRTIO_BLK=m but has no CONFIG_VIRTIO_SCSI at all (not
# even as a module), so a scsi-cd-on-virtio-scsi-pci device would be
# undetectable at boot. virtio-blk needs no ATAPI/CD-ROM semantics to read an
# ISO9660 filesystem -- mounting it directly (as init already does) works the
# same as any other block device.
ISO_ARGS=()
if ! "${MODE_NO_ISO}"; then
    [[ -f "${ISO_PATH}" ]] || { echo "ERROR: ISO not found at ${ISO_PATH}"; exit 1; }
    ISO_ARGS=(
        -drive "file=${ISO_PATH},if=none,id=cd0,readonly=on"
        -device virtio-blk-pci,drive=cd0,bootindex=2
    )
    echo ">>> ISO: ${ISO_PATH}"
fi

# ─── Network ──────────────────────────────────────────────────────────────────
# virtio-net with user networking; add TAP via tap,ifname=tap0,script=... for bridged
NET_ARGS=(
    -netdev "user,id=net0,hostfwd=tcp::2222-:22,hostfwd=tcp::8080-:80"
    -device "virtio-net-pci,netdev=net0,mac=52:54:00:de:ad:01"
)

# ─── Display & Sound ──────────────────────────────────────────────────────────
DISPLAY_ARGS=()
AUDIO_ARGS=()
case "${DISPLAY}" in
    sdl)
        DISPLAY_ARGS=(-display sdl,gl=on)
        AUDIO_ARGS=(-audiodev sdl,id=audio0 -device ich9-intel-hda -device hda-output,audiodev=audio0)
        ;;
    gtk)
        DISPLAY_ARGS=(-display gtk,gl=on)
        AUDIO_ARGS=(-audiodev sdl,id=audio0 -device ich9-intel-hda -device hda-output,audiodev=audio0)
        ;;
    spice)
        SPICE_PORT=5930
        DISPLAY_ARGS=(
            -display spice-app
            -spice "port=${SPICE_PORT},disable-ticketing=on"
            -device virtio-serial-pci
            -chardev "spicevmc,id=vdagent,debug=0,name=vdagent"
            -device "virtserialport,chardev=vdagent,name=com.redhat.spice.0"
        )
        AUDIO_ARGS=(-audiodev spice,id=audio0 -device ich9-intel-hda -device hda-output,audiodev=audio0)
        echo ">>> SPICE display on port ${SPICE_PORT}"
        ;;
    none)
        DISPLAY_ARGS=(-display none -nographic)
        ;;
    *)
        echo "ERROR: Unknown display mode '${DISPLAY}'" >&2
        exit 1
        ;;
esac

# ─── USB devices ──────────────────────────────────────────────────────────────
USB_ARGS=(
    -device qemu-xhci,id=xhci0
    -device usb-tablet,bus=xhci0.0
    -device usb-kbd,bus=xhci0.0
)

# ─── RNG ──────────────────────────────────────────────────────────────────────
RNG_ARGS=(-object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-pci,rng=rng0)

# ─── Build full QEMU command ──────────────────────────────────────────────────
QEMU_CMD=(
    qemu-system-x86_64

    # Machine & firmware
    -machine type=q35,accel=kvm:tcg,smm=on
    "${DRIVE_FIRMWARE_ARGS[@]}"

    # CPU & RAM
    "${KVM_ARGS[@]}"
    -smp "cpus=${VCPUS},sockets=1,cores=${VCPUS},threads=1"
    -m "${RAM_MB}M"
    -mem-prealloc

    # NUMA (single node, matches -m)
    -object "memory-backend-ram,id=ram-node0,size=${RAM_MB}M"
    -numa "node,memdev=ram-node0"

    # Disks
    "${DISK_ARGS[@]}"
    "${ISO_ARGS[@]}"

    # Network
    "${NET_ARGS[@]}"

    # Display & Audio
    "${DISPLAY_ARGS[@]}"
    "${AUDIO_ARGS[@]}"

    # USB & Input
    "${USB_ARGS[@]}"

    # VirtIO GPU (Wayland/DRM capable inside VM)
    -device "virtio-gpu-pci,xres=1920,yres=1080"

    # RNG
    "${RNG_ARGS[@]}"

    # Serial console (useful for debugging)
    -serial mon:stdio

    # QEMU monitor over Unix socket
    -monitor "unix:${BUILD_DIR}/qemu-monitor.sock,server,nowait"

    # QMP (machine-readable monitor)
    -qmp "unix:${BUILD_DIR}/qemu-qmp.sock,server,nowait"

    # Misc
    -name "ScamShield Linux"
    -rtc base=utc,clock=host
    -boot order=dc,menu=on,reboot-timeout=5000
    -no-user-config
    -nodefaults

    # Extra args (e.g. --snapshot)
    "${EXTRA_QEMU_ARGS[@]}"
)

# ─── Launch ───────────────────────────────────────────────────────────────────
echo ""
echo "╔════════════════════════════════════════════════════╗"
echo "║  Launching ScamShield Linux in QEMU/KVM            ║"
echo "╠════════════════════════════════════════════════════╣"
printf "║  RAM   : %-41s║\n" "${RAM_MB} MB"
printf "║  vCPUs : %-41s║\n" "${VCPUS}"
printf "║  KVM   : %-41s║\n" "$( [[ ${#KVM_ARGS[@]} -gt 0 ]] && echo enabled || echo disabled )"
printf "║  Disk  : %-41s║\n" "$( "${MODE_DISK}" && echo "${DISK_IMAGE}" || echo "(none)" )"
printf "║  ISO   : %-41s║\n" "$( "${MODE_NO_ISO}" && echo "(none)" || echo "${ISO_PATH}" )"
printf "║  Net   : %-41s║\n" "virtio-net (SSH→:2222, HTTP→:8080)"
printf "║  UEFI  : %-41s║\n" "${OVMF_CODE}"
echo "╚════════════════════════════════════════════════════╝"
echo ""
echo ">>> SSH into VM: ssh -p 2222 root@127.0.0.1"
echo ">>> QEMU monitor: socat - UNIX-CONNECT:${BUILD_DIR}/qemu-monitor.sock"
echo ""

exec "${QEMU_CMD[@]}"
