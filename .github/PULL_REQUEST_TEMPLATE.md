## Description

<!-- Provide a brief description of the changes introduced by this pull request. -->

## Motivation & Context

<!-- Why is this change required? What problem does it solve? -->

## Related Issue(s)

<!-- Link related issues below using GitHub auto-closing keywords (e.g. Fixes #123, Closes #456) -->
Fixes #

## Type of Change

<!-- Please check the options that apply. -->

- [ ] `bug` (non-breaking bug fix)
- [ ] `feat` (non-breaking new feature or enhancement)
- [ ] `build` / `ci` (build system, cross-toolchain, kernel config, or CI automation)
- [ ] `refactor` (code refactoring without functional changes)
- [ ] `perf` (performance optimization)
- [ ] `docs` (documentation updates or fixes)
- [ ] `breaking` (breaking change that requires existing configurations to change)

## Checklist

<!-- Before submitting, please verify the following requirements: -->

- [ ] My code adheres to the coding and style standards of Novi Linux (`set -euo pipefail`, POSIX shell, comments).
- [ ] **ShellCheck passes**: I have run `shellcheck` on all modified shell scripts with zero warnings or errors.
- [ ] **Tested clean build**: Full build succeeds locally without errors (`bash build.sh`).
- [ ] **Tested in QEMU**: Tested the bootable image in QEMU (`scripts/mkvm.sh`) and verified successful boot to shell.
- [ ] **Documentation updated**: Updated relevant documentation, README, or specifications (`packages/pkg-format.md`, etc.).
- [ ] **Breaking changes noted**: If this is a breaking change, it is clearly noted above and in commit footers.
- [ ] **Related issue linked**: The corresponding issue or RFC is linked above.
- [ ] Commits follow the [Conventional Commits](https://www.conventionalcommits.org/) format (e.g. `feat(scope): message`).

## Verification & Testing Output

<!-- Paste relevant terminal output or describe steps taken to test this PR: -->

```text
# Output from shellcheck, build.sh, or QEMU boot test:

```
