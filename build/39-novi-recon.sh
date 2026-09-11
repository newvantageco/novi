#!/bin/bash
# ============================================================
# 39-novi-recon.sh — the recon tool, as a package
#
# RFC 0028. Nothing to compile: novi-recon is a Python script, which
# is the point of it. RFC 0026 and RFC 0027 put a working interpreter
# with working TLS on this machine and until now nothing on it was
# written in Python; a build stage that only copies a file is what
# "there is a scripting language here" is supposed to look like.
#
#   bash build/39-novi-recon.sh
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
rm -rf "${D}"; mkdir -p "${D}/files/usr/bin"
install -m 755 "${SRC}" "${D}/files/usr/bin/novi-recon"

# The shebang says `#!/usr/bin/env python3` in the repository, which is
# right for running it out of a checkout on any machine. On the target
# there is exactly one interpreter and its path is known, so the
# installed copy names it directly: `env` costs a PATH search and an
# exec on every invocation, and a $PATH that finds a different python3
# first is a way for a system tool to behave differently for different
# users.
sed -i '1s|.*|#!/usr/bin/python3|' "${D}/files/usr/bin/novi-recon"

{
    echo "name=novi-recon"
    echo "version=${VERSION}"
    echo "arch=${TARGET_ARCH}"
    echo "depends=python"
    echo "description=Network reconnaissance -- DNS, WHOIS, TLS certificates, HTTP security headers, robots.txt, breached-password check and a TCP connect scan. Standard library only"
} > "${D}/MANIFEST"

echo ""
echo ">>> Staged under ${D}  ($(du -sh "${D}/files" | cut -f1))"
head -1 "${D}/files/usr/bin/novi-recon"
echo ""
echo "Publish it with:  bash build/53-devtools-repo.sh"
