#!/usr/bin/env bash
# verify-package.sh — Verify an Ed25519 signature on a Novi Linux package
#
# Usage:
#   ./verify-package.sh <package.pkg.tar.gz> <public-key-file> [signature-file]
#
# Arguments:
#   <package.pkg.tar.gz>  Target package archive to verify
#   <public-key-file>     Path to Ed25519 PEM public key (e.g. novi-release.pub)
#   [signature-file]      Optional signature path (default: <package.pkg.tar.gz>.sig)
#
# Exit status:
#   0  Signature is valid (package is authentic and unmodified)
#   1  Signature verification failed (package is tampered, corrupt, or signature invalid)

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
Usage: $(basename "$0") <package.pkg.tar.gz> <public-key-file> [signature-file]

Verifies the cryptographic Ed25519 signature of a Novi Linux package archive.

Arguments:
  package.pkg.tar.gz  Package archive file to verify (required)
  public-key-file     Ed25519 PEM public key file (e.g. novi-release.pub) (required)
  signature-file      Optional signature file (default: <package.pkg.tar.gz>.sig)

Options:
  -h, --help          Display this help message and exit

Exit Status:
  0  Signature VERIFIED (authentic and intact)
  1  Signature TAMPERED / INVALID / File not found
EOF
    exit 1
}

# ─── Argument & Flag Handling ────────────────────────────────────────────────
if [[ $# -eq 0 ]] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
    usage
fi

[[ $# -ge 2 ]] || die "Missing required arguments. See --help for usage."

PKG_FILE="$1"
PUBKEY_FILE="$2"
SIG_FILE="${3:-${PKG_FILE}.sig}"

# ─── Dependency Checks ───────────────────────────────────────────────────────
command -v openssl >/dev/null 2>&1 || die "openssl is required but not installed or not in PATH."
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required but not installed or not in PATH."

# ─── File Existence & Readability Checks ─────────────────────────────────────
if [[ ! -f "${PKG_FILE}" ]]; then
    log_error "Package file does not exist: ${PKG_FILE}"
    exit 1
fi

if [[ ! -r "${PKG_FILE}" ]]; then
    log_error "Package file is unreadable (permission denied): ${PKG_FILE}"
    exit 1
fi

if [[ ! -f "${PUBKEY_FILE}" ]]; then
    log_error "Public key file does not exist: ${PUBKEY_FILE}"
    exit 1
fi

if [[ ! -r "${PUBKEY_FILE}" ]]; then
    log_error "Public key file is unreadable: ${PUBKEY_FILE}"
    exit 1
fi

if [[ ! -f "${SIG_FILE}" ]]; then
    echo ""
    printf "${RED}${BOLD}======================================================================${RESET}\n"
    printf "${RED}${BOLD}             [TAMPERED / UNVERIFIED] MISSING SIGNATURE                ${RESET}\n"
    printf "${RED}${BOLD}======================================================================${RESET}\n"
    printf "Package File    : %s\n" "${PKG_FILE}"
    printf "Expected Sig    : %s\n" "${SIG_FILE}"
    printf "Error           : Signature file was not found.\n"
    printf "${RED}${BOLD}======================================================================${RESET}\n"
    exit 1
fi

if [[ ! -r "${SIG_FILE}" ]]; then
    log_error "Signature file is unreadable: ${SIG_FILE}"
    exit 1
fi

# Validate public key format
if ! openssl pkey -pubin -in "${PUBKEY_FILE}" -noout 2>/dev/null; then
    log_error "Invalid public key format in: ${PUBKEY_FILE}"
    exit 1
fi

# ─── Verification Execution ──────────────────────────────────────────────────
log_info "Verifying signature for package: $(basename "${PKG_FILE}")"

VERIFY_OUTPUT=""
VERIFY_STATUS=0
VERIFY_OUTPUT="$(openssl pkeyutl -verify -rawin -pubin -inkey "${PUBKEY_FILE}" -in "${PKG_FILE}" -sigfile "${SIG_FILE}" 2>&1)" || VERIFY_STATUS=$?

PKG_SIZE="$(wc -c < "${PKG_FILE}" | tr -d ' ')"
PKG_SHA256="$(sha256sum "${PKG_FILE}" | awk '{print $1}')"
SIG_SIZE="$(wc -c < "${SIG_FILE}" | tr -d ' ')"
SIG_SHA256="$(sha256sum "${SIG_FILE}" | awk '{print $1}')"
KEY_SHA256="$(sha256sum "${PUBKEY_FILE}" | awk '{print $1}')"

echo ""
if [[ ${VERIFY_STATUS} -eq 0 ]]; then
    # Signature is valid
    printf "${BOLD}======================================================================${RESET}\n"
    printf "${GREEN}${BOLD}                 [VERIFIED] PACKAGE IS AUTHENTIC                      ${RESET}\n"
    printf "${BOLD}======================================================================${RESET}\n"
    printf "Status          : ${GREEN}${BOLD}VERIFIED (Signature matches public key)${RESET}\n"
    printf "Package File    : %s\n" "${PKG_FILE}"
    printf "Package Size    : %s bytes (%s KB)\n" "${PKG_SIZE}" "$(( (PKG_SIZE + 1023) / 1024 ))"
    printf "Package SHA256  : %s\n" "${PKG_SHA256}"
    printf "Public Key      : %s\n" "${PUBKEY_FILE}"
    printf "Key SHA256      : %s\n" "${KEY_SHA256}"
    printf "Signature File  : %s\n" "${SIG_FILE}"
    printf "Signature SHA256: %s\n" "${SIG_SHA256}"
    printf "${BOLD}======================================================================${RESET}\n"
    exit 0
else
    # Signature is invalid / tampered
    printf "${RED}${BOLD}======================================================================${RESET}\n"
    printf "${RED}${BOLD}             [TAMPERED / INVALID] SIGNATURE MISMATCH!                 ${RESET}\n"
    printf "${RED}${BOLD}======================================================================${RESET}\n"
    printf "Status          : ${RED}${BOLD}REJECTED — Package has been modified, corrupted, or signed by an untrusted key!${RESET}\n"
    printf "Package File    : %s\n" "${PKG_FILE}"
    printf "Package SHA256  : %s\n" "${PKG_SHA256}"
    printf "Public Key      : %s\n" "${PUBKEY_FILE}"
    printf "Signature File  : %s\n" "${SIG_FILE}"
    if [[ -n "${VERIFY_OUTPUT}" ]]; then
        printf "OpenSSL Output  : %s\n" "${VERIFY_OUTPUT}"
    fi
    printf "${RED}${BOLD}======================================================================${RESET}\n"
    exit 1
fi
