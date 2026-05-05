#!/usr/bin/env bash
# tests/install.test.sh — end-to-end test for scripts/install.sh.
#
# Runs install.sh against a fake CONFIG_PATH with throwaway SSH keys
# we own (so we can decrypt + verify content). Stubs sudo via DRY_RUN,
# injects token values via TEST_PAT (no prompts).
#
# Asserts:
#   - All 3 .age files materialize at $FAKE/secrets/
#   - Each ciphertext is > 350 bytes (above empty-plaintext baseline)
#   - Each decrypts to the expected plaintext
#   - Phase 3 git commit lands in the fake repo
#   - Idempotent: second run skips everything
#
# Run via:
#   nix shell nixpkgs#rage nixpkgs#openssl nixpkgs#jq nixpkgs#gh \
#     nixpkgs#openssh nixpkgs#coreutils \
#     --command bash tests/install.test.sh

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
TESTDIR=$(mktemp -d)
trap 'rm -rf "$TESTDIR"' EXIT

PASSED=0
FAILED=0

ok()   { echo "  ✓ $*"; PASSED=$((PASSED+1)); }
nope() { echo "  ✗ $*"; FAILED=$((FAILED+1)); }
heading() { echo; echo "▸ $*"; }

# -------------------------------------------------------------------------
# Setup: throwaway SSH keys + fake CONFIG_PATH
# -------------------------------------------------------------------------

heading "Setup"

ssh-keygen -t ed25519 -f "$TESTDIR/k1" -N '' -C testk1 -q
ssh-keygen -t ed25519 -f "$TESTDIR/k2" -N '' -C testk2 -q
PUB1=$(cat "$TESTDIR/k1.pub")
PUB2=$(cat "$TESTDIR/k2.pub")
ok "Generated 2 throwaway ed25519 keypairs"

FAKE="$TESTDIR/etc-nixos"
mkdir -p "$FAKE/secrets" "$FAKE/hosts/dellan"

cat > "$FAKE/secrets/secrets.nix" <<EOF
let
  k1 = "$PUB1";
  k2 = "$PUB2";
in {
  "deploy-ssh-key.age".publicKeys        = [ k1 k2 ];
  "github-webhook-secret.age".publicKeys = [ k1 k2 ];
  "gh-janitor-token.age".publicKeys      = [ k1 k2 ];
}
EOF

# Minimal hosts/dellan/default.nix that satisfies install.sh's pre-flight
# (services.nixosDeploy reference must be present).
cat > "$FAKE/hosts/dellan/default.nix" <<'EOF'
{ config, ... }:
{
  imports = [];

  age.secrets.deploy-ssh-key.file        = ../../secrets/deploy-ssh-key.age;
  age.secrets.github-webhook-secret.file = ../../secrets/github-webhook-secret.age;
  age.secrets.gh-janitor-token.file      = ../../secrets/gh-janitor-token.age;

  services.githubWebhook = {
    enable = true;
    secretFile = config.age.secrets.github-webhook-secret.path;
  };

  services.nixosDeploy = {
    enable = true;
    sshKeyFile = config.age.secrets.deploy-ssh-key.path;
  };
}
EOF

# Initialize as a git repo so install.sh's branch check passes.
git -C "$FAKE" init -q -b main
git -C "$FAKE" -c user.name=test -c user.email=test@test add -A
git -C "$FAKE" -c user.name=test -c user.email=test@test commit -qm "init"
ok "Fake CONFIG_PATH at $FAKE (branch: main)"

# -------------------------------------------------------------------------
# Run install.sh with DRY_RUN + injected PAT
# -------------------------------------------------------------------------

heading "Run install.sh with DRY_RUN=1"

EXPECTED_PAT="ghp_DUMMY_TEST_PAT_VALUE_FOR_TESTING"

if CONFIG_PATH="$FAKE" \
   DRY_RUN=1 \
   INSTALL_SH_BOOTSTRAPPED=1 \
   TEST_PAT="$EXPECTED_PAT" \
   "$REPO_ROOT/scripts/install.sh" >"$TESTDIR/install.log" 2>&1; then
  ok "install.sh exited 0"
else
  nope "install.sh exited non-zero. Tail of log:"
  tail -30 "$TESTDIR/install.log" | sed 's/^/    /'
  exit 1
fi

# -------------------------------------------------------------------------
# Assertion: all 3 .age files exist
# -------------------------------------------------------------------------

heading "All 3 .age files present"

for name in deploy-ssh-key github-webhook-secret gh-janitor-token; do
  f="$FAKE/secrets/${name}.age"
  if [ -f "$f" ]; then
    ok "$name.age exists"
  else
    nope "$name.age MISSING"
  fi
done

# -------------------------------------------------------------------------
# Assertion: each ciphertext > 350 bytes
# -------------------------------------------------------------------------

heading "Ciphertext sizes above empty-baseline (>350)"

for name in deploy-ssh-key github-webhook-secret gh-janitor-token; do
  f="$FAKE/secrets/${name}.age"
  size=$(wc -c < "$f")
  if [ "$size" -gt 350 ]; then
    ok "$name.age ciphertext: $size bytes"
  else
    nope "$name.age too small: $size bytes (<= 350; encryption produced empty plaintext)"
  fi
done

# -------------------------------------------------------------------------
# Assertion: decrypt and verify plaintext content
# -------------------------------------------------------------------------

heading "Decrypted plaintext matches expectations"

decrypt() {
  rage -d -i "$TESTDIR/k1" "$1"
}

actual_pat=$(decrypt "$FAKE/secrets/gh-janitor-token.age")
expected_pat_line="GH_TOKEN=$EXPECTED_PAT"
if [ "$actual_pat" = "$expected_pat_line" ]; then
  ok "gh-janitor-token decrypts to GH_TOKEN=<pat> (env-format)"
else
  nope "gh-janitor-token mismatch. Expected: $expected_pat_line  Got: $actual_pat"
fi

actual_webhook=$(decrypt "$FAKE/secrets/github-webhook-secret.age")
if [[ "$actual_webhook" =~ ^WEBHOOK_SECRET=[a-f0-9]{64}$ ]]; then
  ok "github-webhook-secret has env-format with 32-byte hex"
else
  nope "webhook-secret format wrong: $actual_webhook"
fi

actual_sshkey=$(decrypt "$FAKE/secrets/deploy-ssh-key.age")
if [[ "$actual_sshkey" =~ "OPENSSH PRIVATE KEY" ]]; then
  ok "deploy-ssh-key contains an OpenSSH private key"
else
  nope "deploy-ssh-key isn't a recognizable SSH key: ${actual_sshkey:0:60}..."
fi

# -------------------------------------------------------------------------
# Assertion: Phase 3 commit landed
# -------------------------------------------------------------------------

heading "Phase 3 git commit"

last_commit_msg=$(git -C "$FAKE" log -1 --format=%s)
if [[ "$last_commit_msg" =~ "encrypt CI/CD secrets" ]]; then
  ok "Latest commit: $last_commit_msg"
else
  nope "Expected install commit not found. Last commit: $last_commit_msg"
fi

# -------------------------------------------------------------------------
# Idempotence: re-run should be a no-op (skip all secret phases)
# -------------------------------------------------------------------------

heading "Idempotence: second run is a no-op"

if CONFIG_PATH="$FAKE" \
   DRY_RUN=1 \
   INSTALL_SH_BOOTSTRAPPED=1 \
   "$REPO_ROOT/scripts/install.sh" >"$TESTDIR/install2.log" 2>&1; then
  ok "Second install.sh run exited 0"
else
  nope "Second run failed:"
  tail -20 "$TESTDIR/install2.log" | sed 's/^/    /'
fi

# All three "already exists; skipping" should appear
skip_count=$(grep -c "already exists; skipping" "$TESTDIR/install2.log")
if [ "$skip_count" -ge 3 ]; then
  ok "All 3 secret phases skipped as expected (skip count: $skip_count)"
else
  nope "Expected >=3 skip messages, got $skip_count"
fi

# -------------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------------

echo
echo "Passed: $PASSED"
echo "Failed: $FAILED"

if [ "$FAILED" -gt 0 ]; then
  echo
  echo "Last 30 lines of first install.sh run log:"
  tail -30 "$TESTDIR/install.log" | sed 's/^/    /'
  exit 1
fi
