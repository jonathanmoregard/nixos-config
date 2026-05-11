#!/usr/bin/env bash
# scripts/check-fork-guards.sh — assert every job in .github/workflows/
# that runs on `pull_request` or `pull_request_target` either:
#   (a) has a job-level `if:` guard checking head.repo == base.repo, OR
#   (b) is a metadata-only fork-handling job (close-fork-prs.yml's
#       close-fork job is the canonical exception and is identified
#       by an inverted predicate `head.repo != base.repo`).
#
# Run locally before opening a PR; also runs as a CI job under
# .github/workflows/ci.yml. With CI now on GitHub-hosted runners,
# this is a regression guard rather than a security gate — but a
# missing guard would still let fork PRs eat free CI minutes and
# noise up the actions log.
#
# Exit 0 if all jobs are properly guarded. Exit 1 otherwise.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
WF_DIR="$REPO_ROOT/.github/workflows"

if [ ! -d "$WF_DIR" ]; then
  echo "no .github/workflows/ directory; nothing to check"
  exit 0
fi

GUARD_PATTERN='head\.repo\.full_name *==.*base\.repo\.full_name|head\.repo\.full_name *==.*github\.repository|head\.repo\.full_name *!=.*github\.repository'
# Match only actual PR-event triggers. The earlier `^on:|` alternation
# matched every workflow's top-level `on:` key and incorrectly flagged
# schedule / workflow_dispatch workflows that have no PR exposure.
PR_TRIGGER_PATTERN='pull_request:|pull_request_target:'

errors=0

for wf in "$WF_DIR"/*.yml; do
  name=$(basename "$wf")

  # Skip files that don't trigger on PR events at all.
  if ! grep -qE "$PR_TRIGGER_PATTERN" "$wf"; then
    continue
  fi

  # Every workflow that triggers on a PR event must have at least one
  # guard. Count occurrences; zero = missing guard.
  guard_hits=$(grep -cE "$GUARD_PATTERN" "$wf" || true)
  if [ "$guard_hits" -eq 0 ]; then
    echo "✗ $name: triggers on a PR event but has no fork-guard predicate"
    errors=$((errors + 1))
  fi
done

if [ "$errors" -gt 0 ]; then
  echo
  echo "$errors workflow(s) missing fork-guard. Add a job-level"
  echo "  if: github.event_name == 'push' || github.event.pull_request.head.repo.full_name == github.repository"
  echo "or, for fork-handling jobs, an inverted predicate."
  exit 1
fi

echo "✓ all PR-triggered workflows have a fork-guard"
