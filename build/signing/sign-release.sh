#!/usr/bin/env bash
# sign-release.sh — GPG sign an ISO image and generate verified checksums for Novi Linux
#
# Generates:
#   1. <image>.iso.asc    — Detached ASCII-armored GPG signature for the ISO
#   2. SHA256SUMS         — Standard SHA-256 checksum file
#   3. SHA256SUMS.gpg     — GPG clearsigned checksum file
#
# Usage:
#   ./sign-release.sh <path-to-iso> [gpg-key-id] [output-dir]
#
# Arguments:
#   <path-to-iso>   Path to the ISO file to sign (required)
#   [gpg-key-id]    GPG Key ID / Email to sign with (default: "release-signing@novilinux.org")
#   [output-dir]    Directory where checksums & signatures will be placed (default: ISO directory)
#
# Exit status:
#   0  Release signed, checksummed, and verified successfully
#   1  Error occurred during signing or verification

set -euo pipefail

# ─── Formatting Helpers ──────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    BOLD="\033[1m"
    GREEN="\033[32m"
    YELLOW="\033[33m"
    CYAN="\033[36m"
    RED="\033[31m"
    RESET="\033[0m"
else
    BOLD=""
    GREEN=""
    YELLOW=""
    CYAN=""
    RED=""
    RESET=""
fi

log_info()    { printf "${CYAN}==>${RESET} ${BOLD}%s${RESET}\n" "$*"; }
log_success() { printf "${GREEN}[✓]${RESET} %s\n" "$*"; }
log_warn()    { printf "${YELLOW}[!]${RESET} %s\n" "$*" >&2; }
log_error()   { printf "${RED}[✗] ERROR:${RESET} %s\n" "$*" >&2; }
die()         { log_error "$*"; exit 1; }

usage() {
    cat <<EOF
Usage: $(basename "$0") <path-to-iso> [gpg-key-id] [output-dir]

GPG-signs a Novi Linux ISO image, computes SHA-256 checksums, and creates a clearsigned manifest.

Arguments:
  path-to-iso   Path to the bootable ISO file (required)
  gpg-key-id    GPG Key ID, fingerprint, or email to sign with
                (default: \${NOVI_GPG_KEY_ID:-release-signing@novilinux.org})
  output-dir    Destination directory for signatures and checksums
                (default: directory containing the ISO)

Options:
  -h, --help    Display this help message and exit
EOF
    exit 1
}

# ─── Argument & Flag Handling ────────────────────────────────────────────────
if [[ $# -eq 0 ]] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
    usage
fi

ISO_FILE="$(realpath "$1")"
GPG_KEY_ID="${2:-${NOVI_GPG_KEY_ID:-release-signing@novilinux.org}}"
OUT_DIR="${3:-$(dirname "${ISO_FILE}")}"

# ─── Dependency Checks ───────────────────────────────────────────────────────
command -v gpg >/dev/null 2>&1 || die "gpg is required but not installed or not in PATH."
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required but not installed or not in PATH."

# ─── Validation ──────────────────────────────────────────────────────────────
[[ -f "${ISO_FILE}" ]] || die "ISO file not found: ${ISO_FILE}"
[[ -r "${ISO_FILE}" ]] || die "ISO file is not readable: ${ISO_FILE}"
[[ -s "${ISO_FILE}" ]] || die "ISO file is empty (0 bytes): ${ISO_FILE}"

mkdir -p "${OUT_DIR}"

ISO_NAME="$(basename "${ISO_FILE}")"
ISO_ASC="${OUT_DIR}/${ISO_NAME}.asc"
SHA256SUMS_FILE="${OUT_DIR}/SHA256SUMS"
SHA256SUMS_GPG="${OUT_DIR}/SHA256SUMS.gpg"

# Verify secret key is available in GPG keyring
if ! gpg --list-secret-keys "${GPG_KEY_ID}" >/dev/null 2>&1; then
    die "Private key for '${GPG_KEY_ID}' was not found in the active GPG keyring."
fi

log_info "Signing Novi Linux Release ISO: ${ISO_NAME}"
log_info "Signing Key : ${GPG_KEY_ID}"
log_info "Output Dir  : ${OUT_DIR}"

# ─── 1. Generate Detached ISO Signature ──────────────────────────────────────
log_info "1/3 Creating detached ASCII-armored GPG signature for ISO..."
gpg --batch --yes --armor \
    --local-user "${GPG_KEY_ID}" \
    --detach-sign \
    --output "${ISO_ASC}" \
    "${ISO_FILE}"

chmod 0644 "${ISO_ASC}"
log_success "Created ISO detached signature: ${ISO_ASC}"

# ─── 2. Generate SHA256SUMS File ─────────────────────────────────────────────
log_info "2/3 Calculating SHA-256 checksums..."

# Copy or calculate hash relative to output directory for portable verification
(
    cd "$(dirname "${ISO_FILE}")"
    sha256sum "${ISO_NAME}" > "${SHA256SUMS_FILE}"
)

chmod 0644 "${SHA256SUMS_FILE}"
log_success "Created SHA256SUMS: ${SHA256SUMS_FILE}"

# ─── 3. Generate Clearsigned SHA256SUMS.gpg ──────────────────────────────────
log_info "3/3 Creating GPG clearsigned checksum file (SHA256SUMS.gpg)..."

gpg --batch --yes --armor \
    --local-user "${GPG_KEY_ID}" \
    --clearsign \
    --output "${SHA256SUMS_GPG}" \
    "${SHA256SUMS_FILE}"

chmod 0644 "${SHA256SUMS_GPG}"
log_success "Created clearsigned checksum file: ${SHA256SUMS_GPG}"

# ─── 4. Immediate Self-Verification ──────────────────────────────────────────
log_info "Performing cryptographic self-verification test..."

if ! gpg --batch --verify "${ISO_ASC}" "${ISO_FILE}" >/dev/null 2>&1; then
    die "ISO detached signature self-verification failed!"
fi

if ! gpg --batch --verify "${SHA256SUMS_GPG}" >/dev/null 2>&1; then
    die "SHA256SUMS.gpg clearsign self-verification failed!"
fi

log_success "All release signatures verified successfully."

# ─── 5. Summary & User Verification Guide ────────────────────────────────────
ISO_SIZE="$(wc -c < "${ISO_FILE}" | tr -d ' ')"
ISO_SHA256="$(sha256sum "${ISO_FILE}" | awk '{print $1}')"

echo ""
printf "${BOLD}======================================================================${RESET}\n"
printf "${GREEN}${BOLD}             NOVI LINUX RELEASE SIGNED SUCCESSFULLY                   ${RESET}\n"
printf "${BOLD}======================================================================${RESET}\n"
printf "Release ISO       : %s\n" "${ISO_FILE}"
printf "ISO Size          : %s bytes (%s MB)\n" "${ISO_SIZE}" "$(( ISO_SIZE / 1048576 ))"
printf "ISO SHA-256       : %s\n" "${ISO_SHA256}"
printf "Detached Sig      : %s\n" "${ISO_ASC}"
printf "Checksum Manifest : %s\n" "${SHA256SUMS_FILE}"
printf "Clearsigned Sums  : %s\n" "${SHA256SUMS_GPG}"
printf "${BOLD}======================================================================${RESET}\n"
echo ""

cat <<EOF
${BOLD}======================================================================${RESET}
${BOLD}               END-USER VERIFICATION INSTRUCTIONS                    ${RESET}
${BOLD}======================================================================${RESET}

Provide the following instructions to users downloading Novi Linux:

${BOLD}1. Import Novi Linux Release Public Key:${RESET}
   ${CYAN}curl -sO https://novilinux.org/security/novi-release-signing-key.asc${RESET}
   ${CYAN}gpg --import novi-release-signing-key.asc${RESET}

${BOLD}2. Verify Checksum Manifest Signature:${RESET}
   ${CYAN}gpg --verify SHA256SUMS.gpg${RESET}

${BOLD}3. Verify ISO Checksum:${RESET}
   ${CYAN}sha256sum -c SHA256SUMS.gpg${RESET}
   ${GREEN}Expected output: ${ISO_NAME}: OK${RESET}

${BOLD}4. (Alternative) Directly Verify ISO Signature:${RESET}
   ${CYAN}gpg --verify ${ISO_NAME}.asc ${ISO_NAME}${RESET}
${BOLD}======================================================================${RESET}
EOF

exit 0
