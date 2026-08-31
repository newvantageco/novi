#!/bin/bash
# ============================================================
# setup-github.sh — Initialize the Novi Linux GitHub repo
#
# Run this ONCE after cloning an empty GitHub repo.
# Assumes you've already created github.com/novilinux/novi
# ============================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[1;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[info]${NC}  $*"; }
success() { echo -e "${GREEN}[ok]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[warn]${NC}  $*"; }
die()     { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }

# ── Preflight ─────────────────────────────────────────────
command -v git  &>/dev/null || die "git not found"
command -v gh   &>/dev/null || warn "GitHub CLI (gh) not found — some steps will be manual"

info "Setting up Novi Linux repository..."

# ── Git identity ──────────────────────────────────────────
if ! git config user.email &>/dev/null; then
    die "Git user.email not set. Run: git config --global user.email 'you@example.com'"
fi

# ── Initialize repo if needed ─────────────────────────────
if [ ! -d ".git" ]; then
    info "Initializing git repository..."
    git init -b main
fi

# ── Set remote ────────────────────────────────────────────
if ! git remote get-url origin &>/dev/null; then
    read -rp "GitHub remote URL (e.g. git@github.com:novilinux/novi.git): " REMOTE_URL
    git remote add origin "${REMOTE_URL}"
    success "Remote added: ${REMOTE_URL}"
fi

# ── GPG commit signing ────────────────────────────────────
info "Checking GPG signing setup..."
if command -v gpg &>/dev/null; then
    EXISTING_KEY=$(git config --global user.signingkey 2>/dev/null || true)
    if [ -z "${EXISTING_KEY}" ]; then
        warn "No GPG signing key configured."
        echo "  To generate one: gpg --full-generate-key (choose Ed25519)"
        echo "  Then: git config --global user.signingkey <KEY_ID>"
        echo "  Then: git config --global commit.gpgsign true"
    else
        success "GPG signing key configured: ${EXISTING_KEY}"
        git config --global commit.gpgsign true
    fi
fi

# ── SSH key for GitHub ────────────────────────────────────
info "Checking SSH key for GitHub..."
if [ ! -f "${HOME}/.ssh/id_ed25519.pub" ]; then
    warn "No Ed25519 SSH key found at ~/.ssh/id_ed25519.pub"
    read -rp "Generate one now? [y/N] " GENERATE_SSH
    if [[ "${GENERATE_SSH}" =~ ^[Yy]$ ]]; then
        read -rp "Email for SSH key: " SSH_EMAIL
        ssh-keygen -t ed25519 -C "${SSH_EMAIL}" -f "${HOME}/.ssh/id_ed25519"
        success "SSH key generated: ~/.ssh/id_ed25519.pub"
        echo ""
        echo "Add this to github.com/settings/keys:"
        cat "${HOME}/.ssh/id_ed25519.pub"
        echo ""
        read -rp "Press Enter after adding it to GitHub..."
    fi
else
    success "SSH key found: ~/.ssh/id_ed25519.pub"
fi

# ── GitHub CLI setup ──────────────────────────────────────
if command -v gh &>/dev/null; then
    info "Authenticating GitHub CLI..."
    if ! gh auth status &>/dev/null; then
        gh auth login --git-protocol ssh --web
    else
        success "GitHub CLI authenticated"
    fi

    # ── Branch protection rules ───────────────────────────
    info "Applying branch protection rules to main..."
    REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "novilinux/novi")

    gh api "repos/${REPO}/branches/main/protection" \
        --method PUT \
        --field required_status_checks='{"strict":true,"contexts":["shellcheck","build-test"]}' \
        --field enforce_admins=false \
        --field required_pull_request_reviews='{"required_approving_review_count":1,"dismiss_stale_reviews":true,"require_code_owner_reviews":true}' \
        --field restrictions=null \
        --field allow_force_pushes=false \
        --field allow_deletions=false \
        2>/dev/null && success "Branch protection applied to main" || warn "Branch protection failed — apply manually in GitHub settings"

    # ── Repo settings ──────────────────────────────────────
    info "Configuring repository settings..."
    gh api "repos/${REPO}" --method PATCH \
        --field has_issues=true \
        --field has_projects=true \
        --field has_wiki=false \
        --field allow_squash_merge=true \
        --field allow_merge_commit=false \
        --field allow_rebase_merge=false \
        --field delete_branch_on_merge=true \
        --field allow_auto_merge=false \
        2>/dev/null && success "Repo settings configured" || warn "Repo settings failed — configure manually"

    # ── Labels ────────────────────────────────────────────
    info "Creating issue labels..."
    create_label() {
        gh label create "$1" --color "$2" --description "$3" --force 2>/dev/null || true
    }
    create_label "security"        "d93f0b" "Security vulnerability or hardening"
    create_label "kernel"          "0075ca" "Kernel configuration or patches"
    create_label "packages"        "e4e669" "Package manager or package definitions"
    create_label "desktop"         "7057ff" "Desktop environment / Wayland compositor"
    create_label "gaming"          "008672" "Gaming layer / Proton / GPU"
    create_label "build-system"    "e99695" "Build scripts or toolchain"
    create_label "documentation"   "0075ca" "Documentation improvements"
    create_label "good first issue" "7057ff" "Good for newcomers"
    create_label "pinned"          "000000" "Never goes stale"
    create_label "roadmap"         "bfd4f2" "On the roadmap"
    create_label "breaking-change" "b60205" "Breaking change"
    success "Labels created"
fi

# ── Initial commit ────────────────────────────────────────
info "Creating initial commit..."
git add -A
git diff --cached --quiet && { info "Nothing to commit"; } || {
    git commit -m "chore: initial Novi Linux repository setup

Novi Linux — Linux, reimagined.
Version: 0.1.0 (Axiom)
Org: github.com/novilinux

- Build system: LFS + musl + s6
- Kernel: Linux 6.10.3-novi (280+ config options)
- Package manager: custom pkg/mkpkg
- ISO builder + QEMU test launcher
- GitHub Actions: shellcheck, build-test, security-scan
- Security: package signing, SECURITY.md, disclosure policy
- Docs: CONTRIBUTING, CODE_OF_CONDUCT, PR templates"

    success "Initial commit created"
}

# ── Push ──────────────────────────────────────────────────
info "Pushing to GitHub..."
git push -u origin main && success "Pushed to origin/main" || {
    warn "Push failed. Make sure the remote exists and you have access."
    echo "  Run manually: git push -u origin main"
}

echo ""
echo "╔════════════════════════════════════════════════╗"
echo "║  Novi Linux — Repository Setup Complete        ║"
echo "╠════════════════════════════════════════════════╣"
echo "║  Next steps:                                   ║"
echo "║  1. Visit github.com/novilinux/novi            ║"
echo "║  2. Enable GitHub Sponsors in repo settings    ║"
echo "║  3. Add Open Collective link to README         ║"
echo "║  4. Set up security@novilinux.org email        ║"
echo "║  5. Add NOVI_SIGNING_KEY to GitHub Secrets     ║"
echo "╚════════════════════════════════════════════════╝"
