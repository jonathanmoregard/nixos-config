#!/usr/bin/env bash
# scripts/bootstrap-rulesets.sh — idempotent setup for GitHub Rulesets
# protecting `main`. Two-phase:
#   Phase 1: PUT rulesets in `enforcement: "evaluate"` mode (dry-run).
#   Phase 2: PUT in `enforcement: "active"` once verified.
#
# Idempotency: ruleset IDs stored in scripts/rulesets-state.json
# (committed). On bootstrap: if state file lists IDs, PUT to update; if
# missing, POST to create and write back.
#
# Required env: GH_TOKEN (PAT with repo:admin scope; not the runner token)
# Required arg: enforcement mode = "evaluate" or "active"

set -euo pipefail

REPO="${REPO:-jonathanmoregard/nixos-config}"
STATE="$(git rev-parse --show-toplevel)/scripts/rulesets-state.json"
MODE="${1:-evaluate}"

if [ "$MODE" != "evaluate" ] && [ "$MODE" != "active" ]; then
  echo "usage: $0 evaluate|active" >&2
  exit 2
fi

: "${GH_TOKEN:?GH_TOKEN must be set (PAT with repo:admin scope)}"

# Each ruleset = a JSON spec generated inline. The set of rules:
#   require-pr        - PR required for main
#   required-checks   - status checks: eval, build, vm-minimal, classify, label-gate
#   block-force       - no force pushes
#   block-deletion    - no branch deletion
#
# Rule 5 (label-gate) is implicitly satisfied by adding `label-gate` to
# required-checks; the workflow encodes the label semantics. See spec D.4.

ruleset_json() {
  local name="$1"
  local rules_json="$2"
  cat <<EOF
{
  "name": "$name",
  "target": "branch",
  "enforcement": "$MODE",
  "conditions": {
    "ref_name": {
      "include": ["refs/heads/main"],
      "exclude": []
    }
  },
  "rules": $rules_json,
  "bypass_actors": []
}
EOF
}

# Rule definitions. bypass_actors per-rule is what justifies using
# Rulesets over legacy branch protection.

PR_RULE='[{
  "type": "pull_request",
  "parameters": {
    "required_approving_review_count": 0,
    "dismiss_stale_reviews_on_push": false,
    "require_code_owner_review": false,
    "require_last_push_approval": false,
    "required_review_thread_resolution": false
  }
}]'

# Required status checks. Each check matches a job name from ci.yml/gate.yml.
CHECKS_RULE='[{
  "type": "required_status_checks",
  "parameters": {
    "strict_required_status_checks_policy": false,
    "required_status_checks": [
      {"context": "eval"},
      {"context": "build"},
      {"context": "vm-minimal"},
      {"context": "classify"},
      {"context": "label-gate"}
    ]
  }
}]'

FORCE_PUSH_RULE='[{"type":"non_fast_forward"}]'
DELETE_RULE='[{"type":"deletion"}]'

declare -A SPECS=(
  [require-pr]="$(ruleset_json 'nixos-config-require-pr' "$PR_RULE")"
  [required-checks]="$(ruleset_json 'nixos-config-required-checks' "$CHECKS_RULE")"
  [block-force]="$(ruleset_json 'nixos-config-block-force-push' "$FORCE_PUSH_RULE")"
  [block-deletion]="$(ruleset_json 'nixos-config-block-deletion' "$DELETE_RULE")"
)

# Load existing state
declare -A IDS=()
if [ -f "$STATE" ]; then
  while IFS=$'\t' read -r key id; do
    [ -n "$key" ] && IDS["$key"]="$id"
  done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' "$STATE")
fi

apply_ruleset() {
  local key="$1"
  local body="$2"
  local id="${IDS[$key]:-}"
  local response
  if [ -n "$id" ]; then
    echo "PUT $key (id=$id, mode=$MODE)"
    response=$(curl -fsS -X PUT \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer $GH_TOKEN" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com/repos/$REPO/rulesets/$id" \
      -d "$body")
  else
    echo "POST $key (mode=$MODE)"
    response=$(curl -fsS -X POST \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer $GH_TOKEN" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com/repos/$REPO/rulesets" \
      -d "$body")
    IDS[$key]=$(echo "$response" | jq -r '.id')
  fi
  echo "$response" | jq '{id, name, enforcement}'
}

for key in "${!SPECS[@]}"; do
  apply_ruleset "$key" "${SPECS[$key]}"
done

# Save IDs back to state file
{
  echo "{"
  first=1
  for key in "${!IDS[@]}"; do
    [ "$first" = 1 ] && first=0 || echo ","
    printf '  "%s": %s' "$key" "${IDS[$key]}"
  done
  echo
  echo "}"
} > "$STATE"

echo ""
echo "Rulesets applied in mode=$MODE."
echo "State saved to $STATE — commit this file to make the bootstrap idempotent."
