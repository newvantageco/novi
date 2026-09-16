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

echo ""
echo "novi-sandbox installed:"
ls -la "${ROOTFS}/usr/bin/novi-sandbox"
