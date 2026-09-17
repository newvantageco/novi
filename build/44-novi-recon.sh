#!/bin/bash
# ============================================================
# 44-novi-recon.sh — the recon tool, as a package
#
# RFC 0028. Nothing to compile: novi-recon is a Python script, which
# is the point of it. RFC 0026 and RFC 0027 put a working interpreter
# with working TLS on this machine and until now nothing on it was
# written in Python; a build stage that only copies a file is what
# "there is a scripting language here" is supposed to look like.
#
#   bash build/44-novi-recon.sh
#
# WHY IT EXISTS RATHER THAN A PORT. The obvious thing to reach for was
# the "God's Eye" information gathering tool on GitHub, and it cannot
# be shipped: its LICENCE is `Copyright 2022 PAVEL DAT. All rights
# reserved`, with no redistribution grant, and the other project of
# that name has no licence file at all (which means the same thing) and
# is 136 lines of skeleton. Putting either in a repository this project
# signs and hands to other people would be distributing code nobody
# gave us the right to distribute. The capability was worth having, so
# it is written here.
#
# It would also have cost six PyPI packages (requests, dnspython,
# python-nmap, folium, opencage, phonenumbers -- two of them wanting an
# API key) plus the nmap and httpie binaries, on a system with no pip.
# novi-recon uses the standard library and nothing else, so this stage
# has one dependency: `python`.
#
# Staged into ${BUILD_DIR}/stage-devtools, so 53-devtools-repo.sh
# publishes it with no change to that stage. The number is 39 because
# 50+ is packaging; it reads nothing out of ${ROOTFS} and installs
# nothing into it.
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/00-versions.sh"

STAGE_DIR="${BUILD_DIR}/stage-devtools"
SRC="${REPO_ROOT}/novi-recon/novi-recon"
VERSION="$(sed -n 's/^VERSION = "\(.*\)"$/\1/p' "${SRC}" | head -1)"
[ -n "${VERSION}" ] || { echo "ERROR: no VERSION in ${SRC}." >&2; exit 1; }

# Run the host test suite before packaging.
#
# scripts/lint.sh runs it too, and that is not a reason to skip it
# here: 50-repo.sh runs check-hardening.sh for the same reason, because
# the last moment before a thing is signed and published is the right
# place to check it, and nobody remembers whether lint was run on the
# tree that produced this artifact. It costs 200 ms.
echo ">>> novi-recon self-test ..."
python3 "${REPO_ROOT}/novi-recon/tests/test_recon.py"

# A syntax error in a Python script is a RUNTIME error, not a build
# error -- there is no compiler between here and the user. Without this
# the package builds, installs, signs and verifies perfectly and fails
# at the first invocation. Compile it with the same major.minor the
# target ships (RFC 0026 pins that to the build host's python3.11 for
# exactly this kind of reason).
echo ">>> syntax check against python${PYTHON_VERSION%.*} ..."
"python${PYTHON_VERSION%.*}" -c "import ast,sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])" "${SRC}"

D="${STAGE_DIR}/novi-recon"
rm -rf "${D}"; mkdir -p "${D}/files/usr/bin" "${D}/files/usr/libexec"
install -m 755 "${SRC}" "${D}/files/usr/libexec/novi-recon"

# The shebang says `#!/usr/bin/env python3` in the repository, which is
# right for running it out of a checkout on any machine. On the target
# there is exactly one interpreter and its path is known, so the
# installed copy names it directly: `env` costs a PATH search and an
# exec on every invocation, and a $PATH that finds a different python3
# first is a way for a system tool to behave differently for different
# users.
sed -i '1s|.*|#!/usr/bin/python3|' "${D}/files/usr/libexec/novi-recon"

# THE ALLOWLIST WRAPPER (RFC 0039 roadmap 3). The script moves to
# /usr/libexec and what goes on PATH is a wrapper -- the same shape RFC
# 0031 roadmap 5 gave the browser, and for the same reason: a bound
# somebody bypasses by typing the other name is not a bound.
#
# novi-recon is the case the denylist was not written for. It makes DNS
# queries and TLS connections, reads no file it was not given, and runs
# on an interpreter out of this same build -- so its syscall set is
# knowable, and 48 of them were measured (see
# novi-sandbox/profile-recon.syscalls). Everything is read-only: this
# tool writes nothing, which is worth saying because it means the bind
# list has no --rw at all.
#
# /usr/bin/python3 is bound as a FILE rather than /usr/bin as a
# directory. The shebang names it, and binding the directory would put
# every base binary on the machine inside a sandbox built to contain
# one script.
#
# NOT /etc/nsswitch.conf, which the browser's wrapper listed and which
# has never existed on this system -- 18-network.sh's own comment says
# musl does not read it. novi-sandbox skips an absent path by design
# (a caller names what a program MIGHT need), so the only symptom was
# one `skipping /etc/nsswitch.conf (not present)` line on stderr per
# run, which nobody sees for a GUI program and which was the first
# line of output for this one. A bind list is a claim about what a
# program needs; an entry nothing has ever provided is not one.
cat > "${D}/files/usr/bin/novi-recon" <<'WRAP'
#!/bin/sh
# novi-recon under an allowlist seccomp filter and a root filesystem
# holding nine paths (RFC 0039). NOVI_RECON_SANDBOX=off for somebody
# debugging the difference between the tool failing and a bind missing.
REAL=/usr/libexec/novi-recon
# NOVI_SANDBOX_DESCRIBE=1 prints the command this would have run and
# stops. Every exit goes through run(), so the answer is the argv that
# would really be exec'd -- runtime branches taken, optional binds
# resolved -- rather than a second description that can drift from it.
# `novi-agent describe` READS this file instead (RFC 0029 decision 1:
# describing must not run anything); this is the exact answer, for a
# person.
run() {
    if [ -n "${NOVI_SANDBOX_DESCRIBE:-}" ]; then
        printf '%s\n' "$*"
        exit 0
    fi
    exec "$@"
}

SANDBOX="${NOVI_RECON_SANDBOX:-on}"
case "${SANDBOX}" in
    off|none|0) run "${REAL}" "$@" ;;
    on|1) ;;
    *)
        echo "novi-recon: NOVI_RECON_SANDBOX must be 'on' or 'off'" >&2
        exit 2 ;;
esac
command -v novi-sandbox >/dev/null 2>&1 || run "${REAL}" "$@"
run novi-sandbox --profile recon \
    --ro /usr/lib --ro /usr/libexec --ro /lib \
    --ro /usr/bin/python3 \
    --ro /etc/ssl --ro /etc/resolv.conf --ro /etc/hosts \
    --ro /etc/services \
    -- "${REAL}" "$@"
WRAP
chmod 755 "${D}/files/usr/bin/novi-recon"

{
    echo "name=novi-recon"
    echo "version=${VERSION}"
    echo "arch=${TARGET_ARCH}"
    echo "depends=python"
    echo "description=Network reconnaissance -- DNS, WHOIS, TLS certificates, HTTP security headers, robots.txt, breached-password check and a TCP connect scan. Standard library only"
} > "${D}/MANIFEST"

echo ""
echo ">>> Staged under ${D}  ($(du -sh "${D}/files" | cut -f1))"
head -1 "${D}/files/usr/libexec/novi-recon"
echo ""
echo "Publish it with:  bash build/53-devtools-repo.sh"
