#!/bin/bash
# ============================================================
# 43-devtools-repo.sh — publish git and the ssh client into the repo
#
# 35-devtools.sh builds them; this packages them and re-signs the
# index. Two stages for the same reason 28 and 42 are two stages:
# 40-repo.sh wipes and recreates ${BUILD_DIR}/repo, so anything that
# adds to it must run afterwards, and the build must not wait that
# long. Build early, publish late.
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${SCRIPT_DIR}/35-devtools.sh" repo
