#!/usr/bin/env bash
# Re-enable GitHub branch protection on `main` after the repo is made public.
#
# GitHub branch protection on private repos requires GitHub Pro. When this
# repo flipped public, protection was dropped — this script restores a
# baseline matching CLAUDE.md's PR-only workflow:
#
#   - PR required before merge (no direct pushes to main)
#   - Force-push and branch deletion disabled
#   - Stale review approvals dismissed when new commits land
#   - Conversation resolution required before merge
#   - Required status checks: the CI jobs that gate every PR today
#
# Reviews are NOT required (solo-developer project). If a co-maintainer
# joins, set required_approving_review_count to 1 below.
#
# Usage:
#   gh auth login   # if not already authenticated
#   scripts/enable-branch-protection.sh [owner/repo]
#
# Defaults to the `origin` remote of the current checkout.

set -euo pipefail

REPO="${1:-}"
if [[ -z "$REPO" ]]; then
  REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
fi
echo "Applying branch protection to $REPO:main"

# Required CI check names. Must match the `jobs.<name>` keys in the workflows
# under .github/workflows/. Matrix builds expand to one check per cell, which
# is too fragile to pin here — start with the non-matrix gates and extend by
# hand if you want a specific matrix cell to be required.
REQUIRED_CHECKS=(
  "verilator-lint"
  "verilator-tb"
  "python-lint"
  "itch-decoder-codegen"
  "itch-decoder"
)

CHECKS_JSON=$(printf '%s\n' "${REQUIRED_CHECKS[@]}" \
  | jq -R . | jq -s 'map({context: ., app_id: -1})')

gh api -X PUT "repos/$REPO/branches/main/protection" \
  --input - <<EOF
{
  "required_status_checks": {
    "strict": true,
    "checks": $CHECKS_JSON
  },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": false,
    "required_approving_review_count": 0,
    "require_last_push_approval": false
  },
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": true,
  "lock_branch": false,
  "allow_fork_syncing": false
}
EOF

echo "Done. Verify at: https://github.com/$REPO/settings/branches"
