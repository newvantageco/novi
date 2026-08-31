#!/usr/bin/env bash
# generate-keys.sh — Generate cryptographic signing keys for Novi Linux
#
# Generates:
#   1. Ed25519 keypair for high-speed, secure package signing (used by sign-package.sh)
#   2. OpenPGP (GPG) keypair for official ISO / release signing (used by sign-release.sh)
#   3. SHA-256 verification digests for public keys
#   4. Detailed instructions for storing private keys in GitHub Secrets and CI/CD environments
#
# Usage:
#   ./generate-keys.sh [OPTIONS]
#
# Options:
#   --out-dir DIR       Output directory for generated keys (default: ./keys)
#   --name NAME         Real Name for GPG release key (default: "Novi Linux Release Signing Key")
#   --email EMAIL       Email for GPG release key (default: "release-signing@novilinux.org")
#   --comment COMMENT   Comment for GPG release key (default: "Official Release Signer")
#   --expire EXPIRY     Key expiration time for GPG key (default: "2y")
#   --force             Overwrite existing keys in output directory without prompt
#   -h, --help          Show this help message and exit

set -euo pipefail

# ─── Color & Formatting Helpers ──────────────────────────────────────────────
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

# ─── Defaults & CLI Parsing ──────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${SCRIPT_DIR}/keys"
KEY_NAME="Novi Linux Release Signing Key"
KEY_EMAIL="release-signing@novilinux.org"
KEY_COMMENT="Official Release Signer"
KEY_EXPIRE="2y"
FORCE_OVERWRITE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --out-dir)
            OUT_DIR="$2"
            shift 2
            ;;
        --name)
            KEY_NAME="$2"
            shift 2
            ;;
        --email)
            KEY_EMAIL="$2"
            shift 2
            ;;
        --comment)
            KEY_COMMENT="$2"
            shift 2
            ;;
        --expire)
            KEY_EXPIRE="$2"
            shift 2
            ;;
        --force)
            FORCE_OVERWRITE=true
            shift 1
            ;;
        -h|--help)
            sed -n '2,/^set -euo/p' "$0" | sed 's/^# \?//' | head -n -1
            exit 0
            ;;
        *)
            die "Unknown option: $1. Run with --help for usage."
            ;;
    esac
done

# ─── Dependency Checks ───────────────────────────────────────────────────────
check_cmd() {
    command -v "$1" &>/dev/null || die "Required command '$1' is not installed or not in PATH."
}

check_cmd openssl
check_cmd gpg
check_cmd sha256sum

# ─── Directory Setup & Overwrite Protection ───────────────────────────────────
mkdir -p "${OUT_DIR}"

ED25519_PRIV="${OUT_DIR}/novi-package-signing.key"
ED25519_PUB="${OUT_DIR}/novi-release.pub"
ED25519_PUB_ALIAS="${OUT_DIR}/novi-package-signing.pub"

GPG_PUB_ASCII="${OUT_DIR}/novi-release-signing-key.asc"
GPG_PUB_ALIAS="${OUT_DIR}/novi-release-gpg.pub"
GPG_SEC_ASCII="${OUT_DIR}/novi-release-signing-key.sec"
CHECKSUM_FILE="${OUT_DIR}/SHA256SUMS.keys"

if [[ "${FORCE_OVERWRITE}" != "true" ]]; then
    for existing_file in "${ED25519_PRIV}" "${ED25519_PUB}" "${GPG_PUB_ASCII}" "${GPG_SEC_ASCII}"; do
        if [[ -f "${existing_file}" ]]; then
            die "Existing key file detected at '${existing_file}'. Pass --force to overwrite."
        fi
    done
fi

TMP_DIR="$(mktemp -d)"
cleanup() {
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT INT TERM

log_info "Generating Novi Linux Cryptographic Keys in: ${OUT_DIR}"

# ─── 1. Generate Ed25519 Package Signing Keypair ─────────────────────────────
log_info "1/3 Generating Ed25519 Package Signing Keypair (OpenSSL)..."

# Generate Ed25519 private key in PKCS#8 PEM format
openssl genpkey -algorithm ed25519 -out "${ED25519_PRIV}"
chmod 0600 "${ED25519_PRIV}"

# Extract public key in standard SubjectPublicKeyInfo PEM format
openssl pkey -in "${ED25519_PRIV}" -pubout -out "${ED25519_PUB}"
chmod 0644 "${ED25519_PUB}"
cp -f "${ED25519_PUB}" "${ED25519_PUB_ALIAS}"

log_success "Created Ed25519 Private Key : ${ED25519_PRIV} (mode 0600)"
log_success "Created Ed25519 Public Key  : ${ED25519_PUB} (mode 0644)"

# Self-test Ed25519 keypair
TEST_MSG="${TMP_DIR}/test_msg.txt"
TEST_SIG="${TMP_DIR}/test_msg.sig"
echo "Novi Linux Ed25519 Keypair Integrity Verification $(date -u)" > "${TEST_MSG}"

openssl pkeyutl -sign -rawin -inkey "${ED25519_PRIV}" -in "${TEST_MSG}" -out "${TEST_SIG}"
if openssl pkeyutl -verify -rawin -pubin -inkey "${ED25519_PUB}" -in "${TEST_MSG}" -sigfile "${TEST_SIG}" >/dev/null 2>&1; then
    log_success "Ed25519 key self-verification test passed successfully."
else
    die "Ed25519 signature self-test failed! Keys may be corrupt."
fi

# ─── 2. Generate GPG Key for Release & ISO Signing ───────────────────────────
log_info "2/3 Generating OpenPGP (GPG) Release Signing Key..."

# Use isolated GNUPGHOME to avoid interfering with host keyring
export GNUPGHOME="${TMP_DIR}/gnupg"
mkdir -p -m 0700 "${GNUPGHOME}"

GPG_BATCH_FILE="${TMP_DIR}/gpg_batch.txt"
cat > "${GPG_BATCH_FILE}" <<EOF
%echo Generating Novi Linux GPG Release Key
Key-Type: EDDSA
Key-Curve: ed25519
Key-Usage: sign
Subkey-Type: ECDH
Subkey-Curve: cv25519
Subkey-Usage: encrypt
Name-Real: ${KEY_NAME}
Name-Email: ${KEY_EMAIL}
Name-Comment: ${KEY_COMMENT}
Expire-Date: ${KEY_EXPIRE}
%no-protection
%commit
%echo Release Key Generation Complete
EOF

gpg --batch --generate-key "${GPG_BATCH_FILE}" >/dev/null 2>&1 || {
    # Fallback to RSA 4096 if EDDSA batch generation is unsupported on host GPG version
    log_warn "Ed25519 GPG key generation failed, falling back to RSA 4096..."
    cat > "${GPG_BATCH_FILE}" <<EOF
Key-Type: RSA
Key-Length: 4096
Key-Usage: sign
Subkey-Type: RSA
Subkey-Length: 4096
Subkey-Usage: encrypt
Name-Real: ${KEY_NAME}
Name-Email: ${KEY_EMAIL}
Name-Comment: ${KEY_COMMENT}
Expire-Date: ${KEY_EXPIRE}
%no-protection
%commit
EOF
    gpg --batch --generate-key "${GPG_BATCH_FILE}" >/dev/null 2>&1 || die "Failed to generate GPG key."
}

# Retrieve Key ID and Fingerprint
GPG_FPR="$(gpg --with-colons --fingerprint "${KEY_EMAIL}" | awk -F: '$1=="fpr"{print $10; exit}')"
GPG_KEYID="${GPG_FPR: -16}"

# Export Public and Secret Keys
gpg --armor --export "${KEY_EMAIL}" > "${GPG_PUB_ASCII}"
chmod 0644 "${GPG_PUB_ASCII}"
cp -f "${GPG_PUB_ASCII}" "${GPG_PUB_ALIAS}"

gpg --armor --export-secret-keys "${KEY_EMAIL}" > "${GPG_SEC_ASCII}"
chmod 0600 "${GPG_SEC_ASCII}"

log_success "Created GPG Public Key   : ${GPG_PUB_ASCII} (Key ID: 0x${GPG_KEYID})"
log_success "Created GPG Private Key  : ${GPG_SEC_ASCII} (mode 0600)"
log_success "GPG Fingerprint          : ${GPG_FPR}"

# Self-test GPG keypair
TEST_GPG_SIG="${TMP_DIR}/test_gpg.asc"
gpg --batch --yes --armor --detach-sign --local-user "${KEY_EMAIL}" --output "${TEST_GPG_SIG}" "${TEST_MSG}" >/dev/null 2>&1
if gpg --batch --verify "${TEST_GPG_SIG}" "${TEST_MSG}" >/dev/null 2>&1; then
    log_success "GPG release signing self-verification test passed successfully."
else
    die "GPG signature self-test failed! Keys may be corrupt."
fi

# ─── 3. Compute SHA256 Checksums ─────────────────────────────────────────────
log_info "3/3 Calculating SHA-256 Verification Checksums..."

(
    cd "${OUT_DIR}"
    sha256sum "$(basename "${ED25519_PUB}")" \
              "$(basename "${GPG_PUB_ASCII}")" \
              > "$(basename "${CHECKSUM_FILE}")"
)

log_success "SHA-256 checksums recorded in: ${CHECKSUM_FILE}"

# ─── Summary Output ──────────────────────────────────────────────────────────
echo ""
printf "${BOLD}======================================================================${RESET}\n"
printf "${BOLD}                 NOVI LINUX KEY GENERATION SUMMARY                    ${RESET}\n"
printf "${BOLD}======================================================================${RESET}\n"
printf "Output Directory       : %s\n" "${OUT_DIR}"
printf "Package Signing Public : %s\n" "${ED25519_PUB}"
printf "Package Public SHA256  : %s\n" "$(sha256sum "${ED25519_PUB}" | awk '{print $1}')"
printf "GPG Release Key ID     : 0x%s\n" "${GPG_KEYID}"
printf "GPG Fingerprint        : %s\n" "${GPG_FPR}"
printf "GPG Public SHA256      : %s\n" "$(sha256sum "${GPG_PUB_ASCII}" | awk '{print $1}')"
printf "${BOLD}======================================================================${RESET}\n"
echo ""

# ─── GitHub Secrets Instructions ─────────────────────────────────────────────
cat <<EOF
${BOLD}======================================================================${RESET}
${BOLD}           HOW TO CONFIGURE GITHUB SECRETS / CI PIPELINES             ${RESET}
${BOLD}======================================================================${RESET}

Store your private keys in GitHub Repository Secrets so CI/CD can sign
packages and official releases automatically.

${BOLD}Option 1: Using GitHub CLI (Recommended)${RESET}
  Run the following commands from your repository root:

  ${CYAN}gh secret set NOVI_PACKAGE_SIGNING_KEY < "${ED25519_PRIV}"${RESET}
  ${CYAN}gh secret set NOVI_RELEASE_GPG_KEY < "${GPG_SEC_ASCII}"${RESET}
  ${CYAN}gh secret set NOVI_RELEASE_GPG_PASSPHRASE --body ""${RESET}

${BOLD}Option 2: Using GitHub Web UI${RESET}
  1. Open your repository on GitHub.
  2. Go to: ${BOLD}Settings${RESET} -> ${BOLD}Secrets and variables${RESET} -> ${BOLD}Actions${RESET}.
  3. Click ${BOLD}"New repository secret"${RESET}.
  4. Create the following secrets:

     - Name  : ${BOLD}NOVI_PACKAGE_SIGNING_KEY${RESET}
       Value : Copy the entire contents of ${BOLD}${ED25519_PRIV}${RESET}

     - Name  : ${BOLD}NOVI_RELEASE_GPG_KEY${RESET}
       Value : Copy the entire contents of ${BOLD}${GPG_SEC_ASCII}${RESET}

${BOLD}Distribution of Public Keys:${RESET}
  - Package Public Key: Embed ${BOLD}${ED25519_PUB}${RESET} into the rootfs at ${BOLD}/etc/pkg/keys/novi-release.pub${RESET}.
  - Release Public Key: Publish ${BOLD}${GPG_PUB_ASCII}${RESET} to https://novilinux.org/security/novi-release-signing-key.asc
    and keyservers (e.g. keys.openpgp.org).

${RED}${BOLD}CRITICAL SECURITY WARNING:${RESET}
Never commit private key files (*.key, *.sec) to Git. Ensure '${OUT_DIR}/*.key'
and '${OUT_DIR}/*.sec' are listed in your .gitignore file.
${BOLD}======================================================================${RESET}
EOF
