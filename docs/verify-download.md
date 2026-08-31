# How to Verify Your Novi Linux Download

Before writing Novi Linux to a USB drive or booting it in a virtual machine, you should always **verify its cryptographic integrity and authenticity**.

Verifying your download guarantees that:
1. **The image is authentic**: It was built and signed by the official Novi Linux release team.
2. **The image is intact**: The ISO file was not corrupted during download or disk transfer.
3. **The image is untampered**: No mirror, network proxy, or third-party intermediary has injected malicious code.

---

## 1. Release Files Overview

For every official release of Novi Linux, we provide the following files in our release directory:

| Filename | Description |
|---|---|
| `novi-<version>-x86_64.iso` | The bootable hybrid installation ISO image |
| `novi-<version>-x86_64.iso.asc` | Detached ASCII-armored GPG signature for the ISO image |
| `SHA256SUMS` | Plaintext list of SHA-256 cryptographic checksums |
| `SHA256SUMS.gpg` | Cryptographic GPG clearsigned signature of `SHA256SUMS` |
| `novi-release-signing-key.asc` | Novi Linux official release signing public GPG key |

---

## 2. Official Novi Linux Signing Key

All official releases are signed using the dedicated **Novi Linux Release Signing Key**:

- **User ID**: `Novi Linux Release Signing Key <release-signing@novilinux.org>`
- **Key ID**: `0x9E5A87BC4D6F0123`
- **Key Type**: `EDDSA / Ed25519 (sign) + cv25519 (encrypt)`
- **Key Fingerprint**:
  ```text
  E4B2 91A7 F3C8 2D10 9E5A  87BC 4D6F 0123 9876 ABCD
  ```
- **Public Keyserver**: [`keys.openpgp.org`](https://keys.openpgp.org)
- **HTTPS Public Key URL**: `https://novilinux.org/security/novi-release-signing-key.asc`

> [!IMPORTANT]
> Always verify that the key fingerprint matches `E4B2 91A7 F3C8 2D10 9E5A 87BC 4D6F 0123 9876 ABCD` across independent sources (our website, GitHub repository, and public keyservers).

---

## 3. Quick Verification Steps (Linux & macOS)

### Step 1: Download Release Files

Download the ISO and verification files into the same directory:

```bash
# Set version variable
export NOVI_VERSION="0.1.0"

# Download the ISO image
curl -LO "https://releases.novilinux.org/${NOVI_VERSION}/novi-${NOVI_VERSION}-x86_64.iso"

# Download the checksums and detached signatures
curl -LO "https://releases.novilinux.org/${NOVI_VERSION}/novi-${NOVI_VERSION}-x86_64.iso.asc"
curl -LO "https://releases.novilinux.org/${NOVI_VERSION}/SHA256SUMS"
curl -LO "https://releases.novilinux.org/${NOVI_VERSION}/SHA256SUMS.gpg"

# Download the official signing public key
curl -LO "https://novilinux.org/security/novi-release-signing-key.asc"
```

---

### Step 2: Import & Verify the Signing Key

Import the public key into your GPG keyring and inspect its fingerprint:

```bash
# Import the public key
gpg --import novi-release-signing-key.asc

# Alternatively, fetch from the OpenPGP keyserver:
# gpg --keyserver keys.openpgp.org --recv-keys "E4B291A7F3C82D109E5A87BC4D6F01239876ABCD"

# Verify the fingerprint
gpg --fingerprint release-signing@novilinux.org
```

**Expected output:**
```text
pub   ed25519 2026-08-31 [SC] [expires: 2028-08-31]
      E4B2 91A7 F3C8 2D10 9E5A  87BC 4D6F 0123 9876 ABCD
uid           [ unknown] Novi Linux Release Signing Key <release-signing@novilinux.org>
sub   cv25519 2026-08-31 [E]
```

Confirm that the output fingerprint matches `E4B2 91A7 F3C8 2D10 9E5A 87BC 4D6F 0123 9876 ABCD`.

---

### Step 3: Verify the Checksum File Signature

Verify that `SHA256SUMS.gpg` was signed by the official Novi Linux release key:

```bash
gpg --verify SHA256SUMS.gpg
```

**Expected output:**
```text
gpg: Signature made Mon Aug 31 2026 ... using EDDSA key E4B291A7F3C82D109E5A87BC4D6F01239876ABCD
gpg: Good signature from "Novi Linux Release Signing Key <release-signing@novilinux.org>" [unknown]
```

> [!NOTE]
> The `[unknown]` trust level warning indicates that you have not assigned a personal Web-of-Trust trust level to the key in your local keyring. As long as the **fingerprint** matches the official fingerprint and the message says **"Good signature"**, the signature is valid.

---

### Step 4: Verify the ISO Checksum

Run `sha256sum` (Linux) or `shasum` (macOS) against the clearsigned file:

**On Linux:**
```bash
sha256sum --check --ignore-missing SHA256SUMS.gpg
```

**On macOS:**
```bash
shasum -a 256 -c SHA256SUMS.gpg
```

**Expected output:**
```text
novi-0.1.0-x86_64.iso: OK
```

---

### Step 5: (Alternative) Verify the ISO Image Directly

You can also directly verify the detached signature (`.iso.asc`) against the `.iso` file:

```bash
gpg --verify novi-0.1.0-x86_64.iso.asc novi-0.1.0-x86_64.iso
```

**Expected output:**
```text
gpg: Signature made ... using EDDSA key E4B291A7F3C82D109E5A87BC4D6F01239876ABCD
gpg: Good signature from "Novi Linux Release Signing Key <release-signing@novilinux.org>"
```

---

## 4. Verification on Windows

### Method A: PowerShell (Built-in SHA-256 Checksum)

You can compute the SHA-256 hash using native Windows PowerShell:

1. Open **PowerShell** in the directory where your ISO was downloaded.
2. Run the `Get-FileHash` cmdlet:

```powershell
Get-FileHash -Algorithm SHA256 .\novi-0.1.0-x86_64.iso | Format-List
```

**Expected output:**
```text
Algorithm : SHA256
Hash      : A1B2C3D4E5F6... (64-character hexadecimal hash)
Path      : C:\Users\Username\Downloads\novi-0.1.0-x86_64.iso
```

3. Compare the computed hash with the entry in `SHA256SUMS`. You can automate this check in PowerShell:

```powershell
$expectedHash = (Get-Content .\SHA256SUMS | Select-String "novi-0.1.0-x86_64.iso").Line.Split(" ")[0].Trim()
$actualHash   = (Get-FileHash -Algorithm SHA256 .\novi-0.1.0-x86_64.iso).Hash.ToLower()

if ($expectedHash.ToLower() -eq $actualHash) {
    Write-Host "SUCCESS: SHA-256 checksum matches!" -ForegroundColor Green
} else {
    Write-Host "ERROR: Checksum mismatch! Do NOT use this ISO." -ForegroundColor Red
}
```

---

### Method B: Command Prompt (CertUtil)

On standard Windows Command Prompt (`cmd.exe`):

```cmd
certutil -hashfile novi-0.1.0-x86_64.iso SHA256
```

Compare the printed hash with the hash inside `SHA256SUMS`.

---

### Method C: GPG Signature Verification on Windows (Gpg4win / Kleopatra)

To verify the GPG signature on Windows:

1. Download and install [Gpg4win](https://www.gpg4win.org/) (or use `winget install GnuPG.Gpg4win`).
2. Open PowerShell or Command Prompt:

```powershell
# Import the public key
gpg.exe --import .\novi-release-signing-key.asc

# Verify the release checksums signature
gpg.exe --verify .\SHA256SUMS.gpg

# Verify the ISO detached signature directly
gpg.exe --verify .\novi-0.1.0-x86_64.iso.asc .\novi-0.1.0-x86_64.iso
```

---

## 5. Troubleshooting & FAQ

### What does `BAD signature` mean?
If `gpg --verify` outputs:
```text
gpg: BAD signature from "Novi Linux Release Signing Key <release-signing@novilinux.org>"
```
> [!CAUTION]
> **DO NOT BOOT OR INSTALL THIS ISO.**
> A bad signature indicates that the file has been tampered with or corrupted during transit. Delete the file immediately and report the incident to [`security@novilinux.org`](mailto:security@novilinux.org).

---

### What does `FAILED` checksum mean?
If `sha256sum -c` outputs:
```text
novi-0.1.0-x86_64.iso: FAILED
sha256sum: WARNING: 1 computed checksum did NOT match
```
The download was incomplete or corrupted. Delete the incomplete ISO file and re-download it over a stable connection.

---

### Why does GPG show "WARNING: This key is not certified with a trusted signature"?
This is standard GnuPG behavior when a key has not been signed by your personal web of trust. As long as you have verified that the **Fingerprint** (`E4B2 91A7 F3C8 2D10 9E5A 87BC 4D6F 0123 9876 ABCD`) matches our official published fingerprint, the key and signature are completely authentic.

To mark the key as trusted in your local keyring and suppress the warning:
```bash
gpg --edit-key release-signing@novilinux.org
# Type: trust
# Select: 5 (I trust ultimately)
# Type: save
```

---

*For further assistance, visit our documentation portal at [https://novilinux.org/docs](https://novilinux.org/docs) or email [security@novilinux.org](mailto:security@novilinux.org).*
