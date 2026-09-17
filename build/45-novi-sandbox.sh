#!/bin/bash
# ============================================================
# 45-novi-sandbox.sh — Build /usr/bin/novi-sandbox
#
# RFC 0039. Namespaces and a seccomp filter, so a program that parses
# somebody else's document does it without the machine's filesystem or
# process table in reach.
#
# Base content, not a package, and the argument is RFC 0031 roadmap 5's
# verbatim: `s6-softlimit` is base because s6 is how this system boots,
# so the browser's memory bound costs no new dependency. This costs
# none either -- it is libc and the kernel headers that were already
# in the sysroot -- and a confinement tool that arrives only with the
# browser is one that nothing else can be put behind.
#
# NOT static, unlike novi-umh and novi-verify. Those two run in the
# kernel's exec path and on the trust path respectively, where a
# loader is a dependency worth refusing. This one is an ordinary
# userland program that execs another, so it takes harden_flags()
# like every other first-party binary -- which check-hardening.sh
# then enforces at 50-repo.sh.
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/00-versions.sh"

CC="${TOOLS}/bin/${TARGET_TRIPLE}-gcc"
[ -x "${CC}" ] || {
    echo "ERROR: ${CC} not found -- run build/02-toolchain.sh first." >&2
    exit 1
}

# The kernel has to be able to do this, and a kernel that cannot would
# produce a binary that builds perfectly and refuses at every run --
# the failure shape this repository keeps getting caught by. So the
# config is checked here rather than discovered on a booted machine.
KCONFIG="${REPO_ROOT}/kernel/config-x86_64"
# CONFIG_IPC_NS is NOT in this list, and that is the finding rather
# than an omission: it depends on CONFIG_SYSVIPC, which this kernel
# deliberately does not set, so olddefconfig drops it and the symbol
# does not appear in the built .config at all. Asking for an IPC
# namespace on such a kernel is `unshare()` returning EINVAL and no
# sandbox at all -- which is what the first booted run did. main.c
# reads /proc/self/ns to ask for what exists.
for sym in CONFIG_USER_NS CONFIG_PID_NS CONFIG_UTS_NS \
           CONFIG_SECCOMP CONFIG_SECCOMP_FILTER; do
    grep -q "^${sym}=y$" "${KCONFIG}" || {
        echo "ERROR: ${sym} is not set in ${KCONFIG}." >&2
        echo "       novi-sandbox would build and then fail at every run." >&2
        exit 1
    }
done
# --no-net needs one more, and it is optional rather than fatal: the
# browser does not use it and a kernel without it should still get the
# filesystem and process-table half.
grep -q "^CONFIG_NET_NS=y$" "${KCONFIG}" || {
    echo ">>> note: CONFIG_NET_NS is not set -- --no-net will fail."
}

harden_flags

WORK="${BUILD_DIR}/novi-sandbox-build"
rm -rf "${WORK}"
mkdir -p "${WORK}"

echo ">>> Building novi-sandbox ..."
(
    cd "${WORK}"
    # shellcheck disable=SC2086
    "${CC}" ${CFLAGS} ${LDFLAGS} -std=gnu11 -Wall -Wextra -Werror \
        -o novi-sandbox "${REPO_ROOT}/novi-sandbox/main.c"
    "${TOOLS}/bin/${TARGET_TRIPLE}-strip" novi-sandbox
)

install -D -m 755 "${WORK}/novi-sandbox" "${ROOTFS}/usr/bin/novi-sandbox"

# The tracer, into /build/sandbox-test and DELIBERATELY NOT into the
# image -- the hostapd bargain from RFC 0009 and the sshd one from RFC
# 0019. It exists to DERIVE an allowlist (RFC 0039 roadmap 3) from a
# program rather than from somebody's reading of it, and the derived
# list is then committed as C. A ptrace tool on the target would be a
# second way to inspect a process on a system whose whole argument is
# that there is one way.
echo ">>> Building novi-syscalls (test only, not installed) ..."
(
    cd "${WORK}"
    # shellcheck disable=SC2086
    "${CC}" ${CFLAGS} ${LDFLAGS} -std=gnu11 -Wall -Wextra -Werror \
        -o novi-syscalls "${REPO_ROOT}/novi-sandbox/syscall-trace.c"
    "${TOOLS}/bin/${TARGET_TRIPLE}-strip" novi-syscalls
)
install -D -m 755 "${WORK}/novi-syscalls" \
    "${BUILD_DIR}/sandbox-test/novi-syscalls"

# THE PROFILE IS DIFFED AGAINST WHAT WAS MEASURED (RFC 0039 roadmap 3).
# main.c writes the allowlist as `SYS_recvfrom` and friends, because a
# reviewer can read that and cannot read `45`; the derivation lives in
# profile-recon.syscalls as numbers, because that is what the tracer
# produced. Neither is a copy of the other and a transcription mistake
# between them is silent in both directions -- a missing entry is a
# tool that fails on one subcommand, an extra one is a hole. So the
# table is EXTRACTED from main.c and run.
#
# Host cc, deliberately: these are kernel ABI numbers from
# <asm/unistd_64.h>, identical whichever libc's headers include it, and
# a target binary would have to be run to print anything.
echo ">>> Checking the recon profile against the measured list ..."
PROF_SRC="${WORK}/profile-check.c"
{
    echo '#include <stdio.h>'
    echo '#include <stddef.h>'
    echo '#include <sys/syscall.h>'
    sed -n '/^static const int profile_recon\[\] = {/,/^};/p' \
        "${REPO_ROOT}/novi-sandbox/main.c"
    echo 'int main(void) {'
    echo '    size_t n = sizeof(profile_recon) / sizeof(profile_recon[0]);'
    echo '    for (size_t i = 0; i < n; i++) printf("%d\n", profile_recon[i]);'
    echo '    return 0;'
    echo '}'
} > "${PROF_SRC}"
grep -q 'profile_recon\[\]' "${PROF_SRC}" || {
    echo "ERROR: could not extract profile_recon[] from novi-sandbox/main.c." >&2
    echo "       The sed range above no longer matches the source." >&2
    exit 1
}
cc -O0 -w -o "${WORK}/profile-check" "${PROF_SRC}"
"${WORK}/profile-check" | sort -n -u > "${WORK}/profile-from-c.txt"
grep -v '^#' "${REPO_ROOT}/novi-sandbox/profile-recon.syscalls" |
    grep -v '^$' | sort -n -u > "${WORK}/profile-measured.txt"
if ! diff -u "${WORK}/profile-measured.txt" "${WORK}/profile-from-c.txt" \
        > "${WORK}/profile.diff"; then
    echo "ERROR: novi-sandbox's recon profile does not match the measured" >&2
    echo "       list in novi-sandbox/profile-recon.syscalls." >&2
    echo "       -- is measured and absent from main.c;" >&2
    echo "       ++ is in main.c and was never measured." >&2
    sed -n '3,$p' "${WORK}/profile.diff" >&2
    exit 1
fi
echo "    recon profile: $(wc -l < "${WORK}/profile-from-c.txt") syscalls, matching the measured list"

echo ""
echo "novi-sandbox installed:"
ls -la "${ROOTFS}/usr/bin/novi-sandbox"
echo "novi-syscalls (not installed):"
ls -la "${BUILD_DIR}/sandbox-test/novi-syscalls"
