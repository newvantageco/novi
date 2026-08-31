# Contributing to Novi Linux

Thank you for your interest in contributing to **Novi Linux** (*Linux, reimagined.*)! Novi Linux is built from scratch with musl libc, s6 supervision, and zero unnecessary bloat.

To ensure consistency, security, and high reliability across all parts of the operating system, please review this guide before submitting issues, proposals, or pull requests.

---

## Table of Contents

1. [Code of Conduct](#code-of-conduct)
2. [Setting Up Your Build Environment](#setting-up-your-build-environment)
3. [Coding Standards](#coding-standards)
4. [Commit Message Guidelines](#commit-message-guidelines)
5. [Pull Request Process](#pull-request-process)
6. [RFC Process for Major Changes](#rfc-process-for-major-changes)
7. [Issue Labels Guide](#issue-labels-guide)
8. [Testing & Verification Requirements](#testing--verification-requirements)

---

## Code of Conduct

All contributors and maintainers are expected to adhere to our [Code of Conduct](CODE_OF_CONDUCT.md). Please report any unacceptable behavior to [conduct@novilinux.org](mailto:conduct@novilinux.org).

---

## Setting Up Your Build Environment

Novi Linux requires a standard Linux host or WSL2 environment (x86_64) with modern GNU build utilities to compile the cross-toolchain and rootfs.

### 1. Prerequisites (Ubuntu / Debian / WSL2)

```bash
sudo apt update
sudo apt install -y \
    build-essential gcc g++ make \
    curl tar xz-utils bzip2 \
    bison flex texinfo libelf-dev \
    bc libssl-dev python3 \
    libmpc-dev libmpfr-dev libgmp-dev \
    rsync cpio file mksquashfs xorriso grub-common grub-pc-bin grub-efi-amd64-bin kmod \
    shellcheck qemu-system-x86
```

### 2. Prerequisites (Arch Linux)

```bash
sudo pacman -Syu --needed \
    base-devel gcc make curl tar xz bzip2 \
    bison flex texinfo libelf bc openssl python \
    libmpc mpfr gmp rsync cpio file \
    squashfs-tools libisoburn grub kmod shellcheck qemu-system-x86
```

### 3. Cloning the Repository

```bash
git clone https://github.com/novilinux/novi.git
cd novi
```

### 4. Running a Test Build

```bash
# Build the complete toolchain, base userland, s6 init, and kernel
bash build.sh

# Generate the hybrid bootable ISO image
bash scripts/mkiso.sh

# Test the generated image in QEMU
bash scripts/mkvm.sh
```

---

## Coding Standards

Because Novi Linux is a lightweight, high-performance distribution, all code and scripts must adhere to strict quality rules.

### 1. Shell Scripting Guidelines

- **POSIX Portability**: Target standard POSIX shell semantics where possible. If `bash` features are required for build orchestration, explicitly use `#!/usr/bin/env bash`.
- **Strict Error Handling**: Every shell script must start with strict error trapping:
  ```bash
  #!/usr/bin/env bash
  set -euo pipefail
  ```
- **ShellCheck Cleanliness**: Every script must pass ShellCheck without warnings or errors:
  ```bash
  shellcheck build/*.sh scripts/*.sh packages/pkg packages/mkpkg
  ```
- **Quoting Variables**: Always double-quote variable expansions (e.g., `"${VAR}"`, `"$@"`) to prevent word splitting and globbing hazards.
- **Functions & Modularity**: Use lowercase snake_case for function names (`build_kernel()`, `fetch_source()`) and uppercase for environment/constant variables (`OUTPUT_DIR`, `TARGET_ARCH`).
- **Meaningful Comments**: Explain *why* an operation is performed, especially compiler flags, kernel configuration options, or patch workarounds.

### 2. C / musl Standards

- Code must compile cleanly against **musl libc 1.2.5+** and **GCC 14.2+** with `-Wall -Wextra -Wpedantic -Werror`.
- Avoid GNU-specific glibc extensions unless guarded by feature test macros.
- Use explicit integer types (`uint32_t`, `int64_t`, `size_t`) from `<stdint.h>` and `<stddef.h>`.

### 3. s6 & Service Definitions

- Service scripts in `init/services/` should remain minimal and supervise single processes directly in the foreground.
- Use `s6-log` for structured logging. Avoid spawning unmonitored background daemons.

### 4. Package Definitions

- Package recipes must conform to [`packages/pkg-format.md`](packages/pkg-format.md).
- Keep dependencies explicit, minimal, and musl-compatible.

---

## Commit Message Guidelines

We follow the [Conventional Commits](https://www.conventionalcommits.org/) specification (v1.0.0). Consistent commit history allows automated changelog generation and clear auditability.

### Commit Format

```text
<type>(<scope>): <short summary in imperative mood>

[optional body providing technical context and motivation]

[optional footer(s) for breaking changes and issue references]
```

### Allowed Types

| Type | Purpose | Example |
|---|---|---|
| `feat` | A new feature or capability | `feat(init): support dynamic tty allocation` |
| `fix` | A bug fix | `fix(pkg): handle empty checksum verification` |
| `docs` | Documentation only changes | `docs(contributing): add RFC workflow details` |
| `build` | Changes to build system, toolchain, or dependencies | `build(kernel): bump kernel to 6.10.3-novi` |
| `ci` | Changes to CI workflows and automation | `ci(github): add automated shellcheck validation` |
| `refactor` | Code restructuring without feature or fix changes | `refactor(stage1): simplify virtual filesystem mounts` |
| `perf` | Performance optimizations | `perf(iso): enable zstd compression for squashfs` |
| `test` | Adding or updating tests | `test(mkvm): add headless boot timeout check` |
| `chore` | Miscellaneous repository maintenance | `chore(gitignore): ignore temporary qcow2 drives` |

### Scope Conventions

Common scopes include: `toolchain`, `kernel`, `init`, `s6`, `pkg`, `iso`, `rootfs`, `scripts`, `docs`, `security`.

### Rules

1. Use the **imperative, present tense** in the summary: "add" not "added", "fix" not "fixed".
2. Keep the first line under **72 characters**.
3. Do not end the subject line with a period.
4. Reference issues in the footer: `Fixes #42` or `Closes #108`.
5. For breaking changes, include `BREAKING CHANGE:` in the footer or append `!` after the type/scope (e.g., `feat(pkg)!: change binary package format signature`).

---

## Pull Request Process

1. **Fork & Branch**: Fork the repo and create a focused feature branch from `main`:
   ```bash
   git checkout -b feat/kernel-virtio-gpu
   ```
2. **Local Validation**: Ensure your changes build cleanly, pass linting, and boot in QEMU:
   ```bash
   shellcheck $(git ls-files '*.sh')
   bash build.sh
   bash scripts/mkiso.sh
   bash scripts/mkvm.sh
   ```
3. **Write Clear Descriptions**: Use the provided [PR Template](.github/PULL_REQUEST_TEMPLATE.md) and detail what was changed, why, and how it was tested.
4. **Rebase, Don't Merge**: Keep your branch up to date by rebasing on top of `upstream/main`:
   ```bash
   git fetch upstream
   git rebase upstream/main
   ```
5. **Code Review**: At least one maintainer approval is required before merging. Address review feedback constructively and update commits.

---

## RFC Process for Major Changes

For major architectural shifts, new core subsystems, breaking package manager alterations, or init redesigns, an **RFC (Request for Comments)** is required prior to submitting PRs.

### When is an RFC Required?

- Replacing or adding core init subsystems or process supervisors.
- Modifying the package format specification (`.pkg.tar.gz`).
- Altering default kernel architectures or compiler toolchain baselines.
- Introducing a desktop / GUI stack or Wayland compositor layer.

### RFC Workflow

1. Open a new issue with the label `rfc` or start a GitHub Discussion under the **Architecture & RFCs** category.
2. Outline:
   - **Motivation & Problem Statement**
   - **Proposed Technical Design & Architecture**
   - **Impact on Footprint & Dependencies**
   - **Alternatives Considered & Drawbacks**
   - **Migration / Compatibility Plan**
3. The community and maintainers will discuss the proposal for a minimum of 7 days.
4. Once consensus is reached, the RFC will be approved by the core team and implementation may begin.

---

## Issue Labels Guide

We categorize issues and PRs using standardized labels:

| Label | Scope | Description |
|---|---|---|
| `bug` | Issue | Something isn't working as intended |
| `enhancement` | Issue / PR | Feature proposal or general improvement |
| `kernel` | Component | Linux kernel config, drivers, or modules |
| `init` | Component | s6-linux-init, s6-rc, stage1/stage2 scripts, or service defs |
| `packaging` | Component | `pkg` manager, `mkpkg`, or package recipes |
| `build-system` | Component | Toolchain, cross-compiler, or rootfs builder scripts |
| `documentation` | Component | Markdown documentation, specs, or guides |
| `good first issue` | Onboarding | Great for newcomers looking to get involved |
| `help wanted` | Collaboration | Extra attention or domain expertise needed |
| `security` | Security | Vulnerability or security mitigation |
| `rfc` | Planning | Architectural proposal requiring consensus |
| `breaking-change` | Impact | Incompatible API, ABI, or behavioral change |

---

## Testing & Verification Requirements

Every pull request must pass the following verification checks:

1. **Linting Check**:
   ```bash
   shellcheck build/*.sh scripts/*.sh packages/pkg packages/mkpkg
   ```
2. **Clean Build Check**:
   ```bash
   rm -rf build/rootfs build/isoroot
   bash build.sh
   ```
3. **ISO & Boot Verification**:
   ```bash
   bash scripts/mkiso.sh
   # Verify QEMU boots to login prompt without kernel panic or service failure
   bash scripts/mkvm.sh
   ```
4. **Musl Compliance**:
   Ensure binaries do not link against glibc symbols or external shared library dependencies unexpectedly (`readelf -d <binary>` or `ldd`).

---

Thank you for helping make Novi Linux the cleanest, fastest, and most reliable Linux distribution!
