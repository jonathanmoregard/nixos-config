#!/usr/bin/env bash
# scripts/risk-rules.test.sh — unit tests for the risk classifier.
#
# Tests run against mocked inputs (stub the build step and inject canned
# diff-closures / etc-paths / git-diff output). Verifies the bucket
# selection logic across the boundary cases from the spec.
#
# Run: scripts/risk-rules.test.sh

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_TESTS=()

# -------------------------------------------------------------------------
# Test harness — runs the classifier with stubbed inputs and asserts risk
# -------------------------------------------------------------------------

run_case() {
  local name="$1" pkg_input="$2" etc_input="$3" src_input="$4" expected="$5"
  local churn_input="${6:-}"
  local work; work=$(mktemp -d)
  trap 'rm -rf "$work"' RETURN

  printf '%b' "$pkg_input"   > "$work/pkg-delta.txt"
  printf '%b' "$etc_input"   > "$work/etc-paths.diff"
  printf '%b' "$src_input"   > "$work/source-paths.txt"
  printf '%b' "$churn_input" > "$work/churn.txt"

  # Re-run the bucket logic directly by sourcing a stripped-down version.
  local risk
  export WORK="$work" REPO_ROOT
  risk=$("$REPO_ROOT/scripts/risk-rules-classify-only.sh" 2>/dev/null | tail -1)

  if [ "$risk" = "$expected" ]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "  ✓ $name"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAILED_TESTS+=("$name (got: $risk, expected: $expected)")
    echo "  ✗ $name (got: $risk, expected: $expected)"
  fi
}

# -------------------------------------------------------------------------
# Test cases (from spec D.2 unit-test list)
# -------------------------------------------------------------------------

echo "Risk classifier tests:"

run_case \
  "linux-firmware bump → CRITICAL (exact match)" \
  "linux-firmware: 20240101 → 20240601, +12 MiB\n" \
  "" "" \
  "CRITICAL"

run_case \
  "util-linux bump → MEDIUM (no rule match → default)" \
  "util-linux: 2.39 → 2.40\n" \
  "" "" \
  "MEDIUM"

run_case \
  "openssh bump → HIGH" \
  "openssh: 9.0 → 9.1\n" \
  "" "" \
  "HIGH"

run_case \
  "unit-podman.service add → MEDIUM (default)" \
  "unit-podman.service: ε → ∅\n" \
  "" "" \
  "MEDIUM"

run_case \
  "etc/pam.d/sshd → HIGH (etc prefix match)" \
  "" \
  "> ./pam.d/sshd\n" \
  "" \
  "HIGH"

run_case \
  "etc/dbus-1/systemd/system/foo → MEDIUM (NOT prefix-matched by systemd/system/)" \
  "" \
  "> ./dbus-1/systemd/system/foo\n" \
  "" \
  "MEDIUM"

run_case \
  "all-empty diffs → TRIVIAL (no-op short-circuit)" \
  "" "" "" \
  "TRIVIAL"

run_case \
  "docs-only change with empty closure → TRIVIAL" \
  "" "" "docs/README.md\n" \
  "TRIVIAL"

run_case \
  "secret rotation (.age suffix) → HIGH" \
  "anthropic-api-key.age: ε → ∅\n" \
  "" "" \
  "HIGH"

run_case \
  "kernel bump → CRITICAL (exact match on 'linux')" \
  "linux: 6.1.0 → 6.2.0\n" \
  "" "" \
  "CRITICAL"

run_case \
  "multi-source (linux CRITICAL + pam HIGH) → CRITICAL (max wins)" \
  "linux: 6.1 → 6.2\nopenssh: 9.0 → 9.1\n" \
  "> ./pam.d/login\n" \
  "" \
  "CRITICAL"

# -------------------------------------------------------------------------
# Source 1b: derivation churn (same name+version, different store hash =
# patches / build env vars / kernel config flip without version bump).
# Closes the 3 nix-diff blind spots without nix-diff's parse cost.
# Format: one package name per line in churn.txt.
# -------------------------------------------------------------------------

run_case \
  "kernel config flip → CRITICAL via churn (linux exact match)" \
  "" "" "" \
  "CRITICAL" \
  "linux\n"

run_case \
  "openssh patch (no version bump) → HIGH via churn" \
  "" "" "" \
  "HIGH" \
  "openssh\n"

run_case \
  "bash unrelated patch → MEDIUM via churn (no rule match → default)" \
  "" "" "" \
  "MEDIUM" \
  "bash\n"

run_case \
  "linux-firmware churn → CRITICAL (exact match, NOT substring 'linux')" \
  "" "" "" \
  "CRITICAL" \
  "linux-firmware\n"

run_case \
  "churn + closure-bump (linux churn AND openssh version bump) → CRITICAL" \
  "openssh: 9.0 → 9.1\n" "" "" \
  "CRITICAL" \
  "linux\n"

run_case \
  "empty churn + empty other diffs → TRIVIAL (no-op short-circuit holds)" \
  "" "" "" \
  "TRIVIAL" \
  ""

# -------------------------------------------------------------------------
# Source 3: source-tree HIGH upgrades (CI/policy files with no closure
# impact). These are the blind-spot paths Sources 1+2 cannot see.
# -------------------------------------------------------------------------

run_case \
  ".github/workflows/ci.yml change → HIGH (gate workflow)" \
  "" "" ".github/workflows/ci.yml\n" \
  "HIGH"

run_case \
  ".github/workflows/gate.yml change → HIGH (trusted gate)" \
  "" "" ".github/workflows/gate.yml\n" \
  "HIGH"

run_case \
  "scripts/bootstrap-branch-protection.sh change → HIGH (merge-gate policy)" \
  "" "" "scripts/bootstrap-branch-protection.sh\n" \
  "HIGH"

run_case \
  "scripts/classify-pr.sh change → HIGH (classifier itself)" \
  "" "" "scripts/classify-pr.sh\n" \
  "HIGH"

run_case \
  "scripts/risk-rules.nix change → HIGH (rule table)" \
  "" "" "scripts/risk-rules.nix\n" \
  "HIGH"

run_case \
  "scripts/install.sh change → HIGH (security-sensitive bootstrap)" \
  "" "" "scripts/install.sh\n" \
  "HIGH"

run_case \
  "scripts/mint-drift-agent.sh change → TRIVIAL (no rule, no closure delta)" \
  "" "" "scripts/mint-drift-agent.sh\n" \
  "TRIVIAL"

run_case \
  "home/foo.nix touched but no closure delta → TRIVIAL (fall-through)" \
  "" "" "home/foo.nix\n" \
  "TRIVIAL"

run_case \
  ".github/workflows/x.yml + openssh bump → HIGH (HIGH max wins, both are HIGH)" \
  "openssh: 9.0 → 9.1\n" "" ".github/workflows/x.yml\n" \
  "HIGH"

run_case \
  ".github/workflows/x.yml + linux bump → CRITICAL (linux outranks HIGH)" \
  "linux: 6.1 → 6.2\n" "" ".github/workflows/x.yml\n" \
  "CRITICAL"

run_case \
  "docs-only with sourceTree HIGH path absent → TRIVIAL" \
  "" "" "docs/foo.md\n" \
  "TRIVIAL"

# -------------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------------

echo ""
echo "Passed: $TESTS_PASSED"
echo "Failed: $TESTS_FAILED"
if [ "$TESTS_FAILED" -gt 0 ]; then
  echo ""
  echo "Failures:"
  for f in "${FAILED_TESTS[@]}"; do echo "  - $f"; done
  exit 1
fi
