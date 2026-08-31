#!/usr/bin/env bash
# sign-package.sh — Sign a Novi Linux package (.pkg.tar.gz) using Ed25519
#
# Usage:
#   ./sign-package.sh <package.pkg.tar.gz> <private-key-file> [output-sig-file]
#
# Arguments:
#   <package.pkg.tar.gz>  Target package archive to sign
#   <private-key-file>    Path to Ed25519 private key in PEM format
#   [output-sig-file]     Optional custom path for output signature
#                         (default: <package.pkg.tar.gz>.sig)
#
# Exit status:
#   0  Package signed and verified successfully
#   1  Error occurred (bad args, missing file, signing failure, verification failure)

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
Usage: $(basename "$0") <package.pkg.tar.gz> <private-key-file> [output-sig-file]

Signs a Novi Linux package archive with Ed25519 and verifies the signature.

Arguments:
  package.pkg.tar.gz  Package archive file to sign (required)
  private-key-file    Ed25519 PEM private key file (required)
  output-sig-file     Optional destination for signature file
                      (default: <package.pkg.tar.gz>.sig)

Options:
  -h, --help          Display this help message and exit
EOF
    exit 1
}

# ─── Argument & Flag Handling ────────────────────────────────────────────────
if [[ $# -eq 0 ]] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
    usage
fi

[[ $# -ge 2 ]] || die "Missing required arguments. See --help for usage."

PKG_FILE="$1"
KEY_FILE="$2"
SIG_FILE="${3:-${PKG_FILE}.sig}"

# ─── Dependency Checks ───────────────────────────────────────────────────────
command -v openssl >/dev/null 2>&1 || die "openssl is required but not installed or not in PATH."
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required but not installed or not in PATH."

# ─── Input Validation ────────────────────────────────────────────────────────
[[ -f "${PKG_FILE}" ]] || die "Package file not found: ${PKG_FILE}"
[[ -r "${PKG_FILE}" ]] || die "Package file is not readable: ${PKG_FILE}"
[[ -s "${PKG_FILE}" ]] || die "Package file is empty (0 bytes): ${PKG_FILE}"

[[ -f "${KEY_FILE}" ]] || die "Private key file not found: ${KEY_FILE}"
[[ -r "${KEY_FILE}" ]] || die "Private key file is not readable: ${KEY_FILE}"

# Validate key format
if ! openssl pkey -in "${KEY_FILE}" -noout 2>/dev/null; then
    die "Invalid private key file: ${KEY_FILE}. Ensure it is a valid OpenSSL PEM private key."
fi

# ─── Temporary Resources ─────────────────────────────────────────────────────
TMP_DIR="$(mktemp -d)"
TMP_PUBKEY="${TMP_DIR}/extracted_pubkey.pem"

cleanup() {
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT INT TERM

# ─── Signing Operation ───────────────────────────────────────────────────────
log_info "Signing package: $(basename "${PKG_FILE}")"

# Create destination directory for signature if needed
SIG_DIR="$(dirname "${SIG_FILE}")"
[[ -d "${SIG_DIR}" ]] || mkdir -p "${SIG_DIR}"

# Perform Ed25519 signing using raw bytes mode (PureEdDSA)
if ! openssl pkeyutl -sign -rawin -inkey "${KEY_FILE}" -in "${PKG_FILE}" -out "${SIG_FILE}" 2>/dev/null; then
    die "Failed to sign package '${PKG_FILE}' with key '${KEY_FILE}'."
fi

chmod 0644 "${SIG_FILE}"

# ─── Immediate Verification ──────────────────────────────────────────────────
# Extract the public key component from the private key
if ! openssl pkey -in "${KEY_FILE}" -pubout -out "${TMP_PUBKEY}" 2>/dev/null; then
    rm -f "${SIG_FILE}"
    die "Failed to extract public key from private key for self-verification."
fi

# Verify signature against the package
if ! openssl pkeyutl -verify -rawin -pubin -inkey "${TMP_PUBKEY}" -in "${PKG_FILE}" -sigfile "${SIG_FILE}" >/dev/null 2>&1; then
    rm -f "${SIG_FILE}"
    die "Immediate signature verification FAILED! Signature file removed."
fi

# ─── Output Signing Info ─────────────────────────────────────────────────────
PKG_SIZE="$(wc -c < "${PKG_FILE}" | tr -d ' ')"
PKG_SHA256="$(sha256sum "${PKG_FILE}" | awk '{print $1}')"
SIG_SIZE="$(wc -c < "${SIG_FILE}" | tr -d ' ')"
SIG_SHA256="$(sha256sum "${SIG_FILE}" | awk '{print $1}')"
SIGN_TIME="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

echo ""
printf "${BOLD}======================================================================${RESET}\n"
printf "${GREEN}${BOLD}              PACKAGE SIGNED & VERIFIED SUCCESSFULLY                  ${RESET}\n"
printf "${BOLD}======================================================================${RESET}\n"
printf "Package File     : %s\n" "${PKG_FILE}"
printf "Package Size     : %s bytes (%s KB)\n" "${PKG_SIZE}" "$(( (PKG_SIZE + 1023) / 1024 ))"
printf "Package SHA256   : %s\n" "${PKG_SHA256}"
printf "Algorithm        : Ed25519 (PureEdDSA)\n"
printf "Signature File   : %s\n" "${SIG_FILE}"
printf "Signature Size   : %s bytes\n" "${SIG_SIZE}"
printf "Signature SHA256 : %s\n" "${SIG_SHA256}"
printf "Timestamp (UTC)  : %s\n" "${SIGN_TIME}"
printf "${BOLD}======================================================================${RESET}\n"

log_success "Package signature verified and written to: ${SIG_FILE}"
exit 0
