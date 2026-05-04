#!/usr/bin/env bash
# scripts/bootstrap-branch-protection.sh — set up legacy Branch Protection
# on origin/main. Free on private repos (Rulesets are paid-only).
#
# Tradeoff vs Rulesets: enforce_admins is all-or-nothing — if true,
# admin (jonathanmoregard) cannot direct-push to main AND cannot
# override required status checks via PR merge UI. We accept the
# tradeoff; emergencies → toggle this off via UI.
#
# Required env: GH_TOKEN (classic PAT with `repo` scope)
# Required arg: enforcement mode = "evaluate" or "active"
#   - evaluate: prints the desired config but doesn't apply (no
#     equivalent of Rulesets dry-run mode in branch protection;
#     we just print what we would do).
#   - active: PUTs the config to the branch.

set -euo pipefail

REPO="${REPO:-jonathanmoregard/nixos-config}"
BRANCH="${BRANCH:-main}"
MODE="${1:-evaluate}"

if [ "$MODE" != "evaluate" ] && [ "$MODE" != "active" ]; then
  echo "usage: $0 evaluate|active" >&2
  exit 2
fi

: "${GH_TOKEN:?GH_TOKEN must be set (classic PAT with 'repo' scope)}"

# Required status checks. Match the names emitted by ci.yml + gate.yml.
# `strict: false` means PRs don't have to be up-to-date with main
# before merge — keeps auto-merge fast.
read -r -d '' BODY <<'JSON' || true
{
  "required_status_checks": {
    "strict": false,
    "contexts": ["eval", "build", "vm-minimal", "classify", "label-gate"]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "required_approving_review_count": 0,
    "dismiss_stale_reviews": false,
    "require_code_owner_reviews": false,
    "require_last_push_approval": true
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_linear_history": false,
  "required_conversation_resolution": false,
  "block_creations": false,
  "lock_branch": false,
  "allow_fork_syncing": false
}
JSON

if [ "$MODE" = "evaluate" ]; then
  echo "Would PUT to /repos/$REPO/branches/$BRANCH/protection:"
  echo "$BODY" | jq .
  echo ""
  echo "Run with 'active' to apply."
  exit 0
fi

echo "PUT /repos/$REPO/branches/$BRANCH/protection"
response=$(curl -fsS -X PUT \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $GH_TOKEN" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/$REPO/branches/$BRANCH/protection" \
  -d "$BODY")

echo "$response" | jq '{url, required_status_checks, enforce_admins, required_pull_request_reviews, allow_force_pushes, allow_deletions}'
echo ""
echo "Branch protection applied. To inspect:"
echo "  curl -H 'Authorization: Bearer \$GH_TOKEN' https://api.github.com/repos/$REPO/branches/$BRANCH/protection | jq ."
echo "To remove (emergency):"
echo "  curl -X DELETE -H 'Authorization: Bearer \$GH_TOKEN' https://api.github.com/repos/$REPO/branches/$BRANCH/protection"
