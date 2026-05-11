#!/usr/bin/env bash
# scripts/bootstrap-branch-protection.sh — set up legacy Branch Protection
# on origin/main. Free on private repos (Rulesets are paid-only).
#
# Design (solo-author + agents):
# - enforce_admins=false: jonathan (admin) opens most PRs himself.
#   "Failed checks" should always mean "something is broken", never
#   "happy path waiting on a gate".
# - No required_pull_request_reviews: solo-author workflow. The merge
#   gate is the required status checks (build/vm-minimal/etc.), not a
#   human review. Agent-authored PRs still get a human eyeball via the
#   GitHub web UI before the merge button is clicked.
# - All `gh pr merge` invocations are denied at the safe-bash MCP layer
#   to keep merges a deliberate UI gesture (audit-friendly, no CLI
#   autopilot path past the required checks).
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
    "contexts": [
      "verify fork-guards",
      "flake check (eval)",
      "build dellan toplevel",
      "vm-minimal",
      "label-gate"
    ]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
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
