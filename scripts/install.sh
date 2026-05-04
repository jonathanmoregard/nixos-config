#!/usr/bin/env bash
# scripts/install.sh — guided, single-command installer for the CI/CD
# workflow on dellan. Walks through:
#   1. Generate runner SSH keypair → pause for user to add to GH Deploy Keys
#   2. Prompt for runner registration token
#   3. Generate webhook secret + prompt for Rulesets PAT + generate Attic RS256
#   4. Uncomment age.secrets + service blocks; commit + push
#   5. VM gate + nixos-rebuild switch
#   6. Bare-repo + deploy-target bootstraps
#   7. Tailscale Funnel + GitHub Webhook UI
#   8. Branch protection bootstrap (evaluate then active)
#   9. Smoke test (no-op PR)
#
# Run as your normal user; the script will sudo for the privileged steps.
# Idempotent-ish: each phase checks if it's already done and skips.
#
# Test/debug knobs (env vars):
#   CONFIG_PATH=/path        Override /etc/nixos target (default: /etc/nixos)
#   DRY_RUN=1                Skip sudo, push, rebuild, bootstraps, funnel, rulesets
#   SKIP_VM_GATE=1           Skip the VM gate before nixos-rebuild switch
#   TEST_RUNNER_TOKEN=...    Skip Phase 2 prompt; use this value
#   TEST_PAT=...             Skip Phase 3 PAT prompt; use this value
#   INSTALL_SH_BOOTSTRAPPED  Internal: prevents nix-shell re-exec loop

set -euo pipefail

# ------------------------------------------------------------------------
# Self-bootstrap: if any required tool is missing, re-exec inside nix shell.
# ------------------------------------------------------------------------
if [ -z "${INSTALL_SH_BOOTSTRAPPED:-}" ]; then
  REQUIRED=(openssl jq gh ssh-keygen shred)
  MISSING=()
  for cmd in "${REQUIRED[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || MISSING+=("$cmd")
  done
  if [ ${#MISSING[@]} -gt 0 ]; then
    echo "Missing tools: ${MISSING[*]}"
    echo "Re-execing inside nix shell with: openssl, jq, gh, openssh, coreutils"
    export INSTALL_SH_BOOTSTRAPPED=1
    exec nix shell --extra-experimental-features 'nix-command flakes' \
      nixpkgs#openssl nixpkgs#jq nixpkgs#gh nixpkgs#openssh nixpkgs#coreutils \
      --command bash "$0" "$@"
  fi
fi

REPO_ROOT="$(git -C "$(dirname "$0")/.." rev-parse --show-toplevel)"
CONFIG_PATH="${CONFIG_PATH:-/etc/nixos}"
DRY_RUN="${DRY_RUN:-0}"
GH_OWNER=jonathanmoregard
GH_REPO=nixos-config
GH_URL="https://github.com/$GH_OWNER/$GH_REPO"

cd "$REPO_ROOT"

# -------------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------------

color() { local c="$1"; shift; printf "\033[%sm%s\033[0m\n" "$c" "$*"; }
heading() { echo; color '1;34' "▸ $*"; }
note()    { color '0;36' "  $*"; }
prompt()  { color '1;33' "  $*"; }
ok()      { color '1;32' "  ✓ $*"; }
fail()    { color '1;31' "  ✗ $*"; exit 1; }

pause() {
  if [ "$DRY_RUN" = "1" ]; then
    note "DRY_RUN: auto-continuing past pause: $1"
    return 0
  fi
  prompt "$1"
  prompt "Press ENTER when done (or Ctrl-C to abort)..."
  read -r
}

# Sudo wrapper: in DRY_RUN, just runs the command without sudo (assumes
# tester has write perms on the fake CONFIG_PATH).
_sudo() {
  if [ "$DRY_RUN" = "1" ]; then
    "$@"
  else
    sudo "$@"
  fi
}

read_secret() {
  # $1 = prompt text. Prompt + final newline go to STDERR so
  # $(read_secret ...) captures only the value.
  local val
  prompt "$1" >&2
  IFS= read -rs val
  echo >&2
  printf '%s' "$val"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

# Treats a .age file as invalid if its ciphertext is at-or-below the
# empty-plaintext baseline (~322 bytes for 2 recipients). Real plaintext
# inflates it past 350.
age_file_valid() {
  local f="$1"
  [ -f "$f" ] && [ "$(wc -c < "$f")" -gt 350 ]
}

agenix_encrypt() {
  # Pipes stdin DIRECTLY to agenix; agenix detects non-interactive
  # stdin and internally uses cp /dev/stdin. Earlier draft used cat>tmp
  # which CONSUMED stdin before agenix → encrypted empty.
  local name="$1"
  (
    cd "$CONFIG_PATH/secrets"
    nix run --extra-experimental-features 'nix-command flakes' \
      github:ryantm/agenix -- -e "${name}.age"
  )
  local cipher_size
  cipher_size=$(wc -c < "$CONFIG_PATH/secrets/${name}.age")
  if [ "$cipher_size" -le 350 ]; then
    fail "agenix_encrypt $name: ciphertext only $cipher_size bytes (<= 350; empty-plaintext baseline). Encryption produced no plaintext."
  fi
}

# -------------------------------------------------------------------------
# Pre-flight
# -------------------------------------------------------------------------

heading "Pre-flight checks"

require_cmd ssh-keygen
require_cmd openssl
require_cmd gh
require_cmd jq
require_cmd nix
[ "$DRY_RUN" = "1" ] || require_cmd sudo

if [ ! -L "$CONFIG_PATH" ] && [ ! -d "$CONFIG_PATH" ]; then
  fail "$CONFIG_PATH does not exist"
fi

if [ "$REPO_ROOT" = "$CONFIG_PATH" ] || [ "$(readlink -f "$REPO_ROOT")" = "$(readlink -f "$CONFIG_PATH")" ]; then
  ok "Running from $CONFIG_PATH directly"
else
  ok "Running from worktree $REPO_ROOT"
  note "All edits target $CONFIG_PATH (sudo)"
fi

ETC_NIXOS_REAL=$(readlink -f "$CONFIG_PATH")
ETC_BRANCH=$(git -C "$ETC_NIXOS_REAL" rev-parse --abbrev-ref HEAD)
note "$CONFIG_PATH resolves to $ETC_NIXOS_REAL (branch: $ETC_BRANCH)"

if [ "$ETC_BRANCH" != "main" ]; then
  fail "$CONFIG_PATH is on branch '$ETC_BRANCH', not main. Merge feat/cicd-workflow → main first."
fi

# Round-7 content checks — skipped in DRY_RUN since the test fixture
# may not include the exact strings (only the markers we care about).
if [ "$DRY_RUN" != "1" ]; then
  if ! grep -q '"actions-runner-ssh-key.age"' "$CONFIG_PATH/secrets/secrets.nix" 2>/dev/null; then
    fail "$CONFIG_PATH/secrets/secrets.nix doesn't have round-7 entries. Merge feat/cicd-workflow → main first."
  fi
  if ! grep -q 'services.atticCache' "$CONFIG_PATH/hosts/dellan/default.nix" 2>/dev/null; then
    fail "$CONFIG_PATH/hosts/dellan/default.nix doesn't have round-7 service blocks. Merge feat/cicd-workflow → main first."
  fi
fi

ok "Pre-flight passed"

# -------------------------------------------------------------------------
# Phase 1: SSH key for the runner (also reused by nixos-deploy.service)
# -------------------------------------------------------------------------

heading "Phase 1: Generate runner SSH key"

KEYFILE_AGE="$CONFIG_PATH/secrets/actions-runner-ssh-key.age"
if age_file_valid "$KEYFILE_AGE"; then
  ok "$KEYFILE_AGE already exists; skipping keygen"
else
  TMPKEY=$(mktemp -d)/runner-key
  ssh-keygen -t ed25519 -f "$TMPKEY" -N '' -C "actions-runner@dellan" >/dev/null
  ok "Generated keypair at $TMPKEY"

  echo
  echo "    --- Public key (paste into GitHub Deploy Keys) ---"
  cat "$TMPKEY.pub"
  echo "    --- end ---"
  echo
  prompt "Open $GH_URL/settings/keys/new"
  prompt "  Title: actions-runner@dellan"
  prompt "  Paste the public key above"
  prompt "  CHECK 'Allow write access'"
  prompt "  Click 'Add key'"
  pause "Done?"

  agenix_encrypt actions-runner-ssh-key < "$TMPKEY"
  shred -u "$TMPKEY" "$TMPKEY.pub"
  ok "Encrypted as secrets/actions-runner-ssh-key.age"
fi

# -------------------------------------------------------------------------
# Phase 2: Runner registration token
# -------------------------------------------------------------------------

heading "Phase 2: Runner registration token"

TOKEN_AGE="$CONFIG_PATH/secrets/github-runner-token.age"
if age_file_valid "$TOKEN_AGE"; then
  ok "$TOKEN_AGE already exists; skipping"
  note "If token is expired, delete the .age and re-run."
else
  if [ -n "${TEST_RUNNER_TOKEN:-}" ]; then
    TOKEN="$TEST_RUNNER_TOKEN"
    note "Using TEST_RUNNER_TOKEN from env (no prompt)"
  else
    prompt "Open $GH_URL/settings/actions/runners/new"
    prompt "  Select Linux x64"
    prompt "  Copy the registration token"
    TOKEN=$(read_secret "Paste token (input hidden):")
  fi
  [ -n "$TOKEN" ] || fail "empty token"

  printf '%s' "$TOKEN" | agenix_encrypt github-runner-token
  unset TOKEN
  ok "Encrypted as secrets/github-runner-token.age"
fi

# -------------------------------------------------------------------------
# Phase 3: Webhook secret + Rulesets PAT + Attic RS256 secret
# -------------------------------------------------------------------------

heading "Phase 3: Webhook secret + Rulesets PAT + Attic RS256"

WEBHOOK_AGE="$CONFIG_PATH/secrets/github-webhook-secret.age"
if age_file_valid "$WEBHOOK_AGE"; then
  ok "$WEBHOOK_AGE already exists; skipping"
  WEBHOOK_SECRET_DISPLAY="(already encrypted)"
else
  WEBHOOK_SECRET=$(openssl rand -hex 32)
  printf 'WEBHOOK_SECRET=%s\n' "$WEBHOOK_SECRET" | agenix_encrypt github-webhook-secret
  ok "Generated + encrypted webhook secret"
  WEBHOOK_SECRET_DISPLAY="$WEBHOOK_SECRET"
fi

PAT_AGE="$CONFIG_PATH/secrets/gh-janitor-token.age"
if age_file_valid "$PAT_AGE"; then
  ok "$PAT_AGE already exists; skipping"
else
  if [ -n "${TEST_PAT:-}" ]; then
    PAT="$TEST_PAT"
    note "Using TEST_PAT from env (no prompt)"
  else
    prompt "Open https://github.com/settings/tokens/new"
    prompt "  Note: nixos-config-rulesets-bootstrap"
    prompt "  Expiration: 7 days OR 1 year"
    prompt "  Scope: 'repo' (full)"
    PAT=$(read_secret "Paste PAT (input hidden):")
  fi
  [ -n "$PAT" ] || fail "empty PAT"

  printf 'GH_TOKEN=%s\n' "$PAT" | agenix_encrypt gh-janitor-token
  RULESETS_PAT="$PAT"   # keep for Phase 8
  unset PAT
  ok "Encrypted as secrets/gh-janitor-token.age"
fi

ATTIC_AGE="$CONFIG_PATH/secrets/atticd-rs256-secret.age"
if age_file_valid "$ATTIC_AGE"; then
  ok "$ATTIC_AGE already exists; skipping"
else
  note "Generating Attic RS256 token-signing secret (4096-bit RSA, base64)..."
  ATTIC_SECRET=$(openssl genrsa -traditional 4096 2>/dev/null | base64 -w0)
  # NOTE: atticd expects ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64 (with _BASE64).
  printf 'ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64="%s"\n' "$ATTIC_SECRET" \
    | agenix_encrypt atticd-rs256-secret
  unset ATTIC_SECRET
  ok "Encrypted as secrets/atticd-rs256-secret.age"
fi

# -------------------------------------------------------------------------
# Phase 4: Uncomment service blocks; commit + push
# -------------------------------------------------------------------------

heading "Phase 4: Uncomment service blocks in $CONFIG_PATH"

HOST_NIX="$CONFIG_PATH/hosts/dellan/default.nix"

uncomment_block() {
  local anchor="$1" count="$2"
  _sudo sed -i "/$anchor/,+$count s/^  # /  /" "$HOST_NIX"
}

uncomment_line() {
  _sudo sed -i "s|^  # \\($1\\)|  \\1|" "$HOST_NIX"
}

# age.secrets declarations (5 lines)
uncomment_line 'age.secrets.github-runner-token.file'
uncomment_line 'age.secrets.actions-runner-ssh-key.file'
uncomment_line 'age.secrets.github-webhook-secret.file'
uncomment_line 'age.secrets.gh-janitor-token.file'
uncomment_line 'age.secrets.atticd-rs256-secret.file'

uncomment_line 'services.buildCoordination.enable = true;'
uncomment_line 'services.claudeAgentUsers.enable = true;'

uncomment_block 'services.atticCache =' 3
uncomment_block 'services.actionsRunner =' 5
uncomment_block 'services.githubWebhook =' 3
uncomment_block 'services.nixosDeploy =' 3

# Commit + push the .age files and config edits before bare-repo bootstrap
# destroys ~/Repos/nixos-config. The bootstrap reclones from origin/main,
# so anything not pushed is lost.
_sudo git -C "$CONFIG_PATH" add -A
if _sudo git -C "$CONFIG_PATH" diff --cached --quiet; then
  ok "No changes to commit (already done in a previous run)"
else
  _sudo git -C "$CONFIG_PATH" -c user.name=jonathanmoregard \
    -c user.email=jonathan.more@hotmail.com \
    commit -m "feat(install): encrypt CI/CD secrets + enable services"
  if [ "$DRY_RUN" = "1" ]; then
    note "DRY_RUN: skipping push to origin"
  elif [ -f "$HOME/.ssh/id_ed25519" ]; then
    sudo GIT_SSH_COMMAND="ssh -i $HOME/.ssh/id_ed25519 -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes" \
      git -C "$CONFIG_PATH" push origin main
  else
    fail "No SSH key at \$HOME/.ssh/id_ed25519. Cannot push to GitHub."
  fi
  ok "Committed + pushed config edits to origin/main"
fi

# -------------------------------------------------------------------------
# Phase 5: VM gate + nixos-rebuild switch
# -------------------------------------------------------------------------

heading "Phase 5: VM gate + nixos-rebuild switch"

if [ "$DRY_RUN" = "1" ]; then
  note "DRY_RUN: skipping VM gate + nixos-rebuild switch"
else
  if [ "${SKIP_VM_GATE:-0}" = "1" ]; then
    note "SKIP_VM_GATE=1 — skipping VM gate, going straight to switch"
  else
    note "Running VM gate (~2-3 min)..."
    nix build "${CONFIG_PATH}#checks.x86_64-linux.dellan-vm" -L --no-link
    ok "VM gate green"
  fi

  note "Running nixos-rebuild switch..."
  sudo nixos-rebuild switch --flake "${CONFIG_PATH}#dellan"
  ok "Rebuild applied"
fi

# -------------------------------------------------------------------------
# Phase 6: Bare-repo + deploy-target bootstraps
# -------------------------------------------------------------------------

heading "Phase 6: Bare-repo + deploy-target bootstraps"

if [ "$DRY_RUN" = "1" ]; then
  note "DRY_RUN: skipping bare-repo + deploy-target bootstraps"
else
  if [ -L "$HOME/Repos/nixos-config" ] || [ -f "$HOME/Repos/nixos-config/flake.nix" ]; then
    note "$HOME/Repos/nixos-config not yet a bare repo. Running bootstrap-bare-repo.sh..."
    "$REPO_ROOT/scripts/bootstrap-bare-repo.sh"
    ok "Bare repo conversion done"
  else
    ok "$HOME/Repos/nixos-config already a bare repo; skipping"
  fi

  if [ -L /etc/nixos ]; then
    note "/etc/nixos still a symlink. Running bootstrap-deploy-target.sh..."
    "$REPO_ROOT/scripts/bootstrap-deploy-target.sh"
    ok "Deploy target bootstrap done"
  else
    ok "/etc/nixos already a real checkout; skipping"
  fi
fi

# -------------------------------------------------------------------------
# Phase 7: Tailscale Funnel + GitHub Webhook UI
# -------------------------------------------------------------------------

heading "Phase 7: Tailscale Funnel + GitHub Webhook"

if [ "$DRY_RUN" = "1" ]; then
  note "DRY_RUN: skipping Tailscale Funnel + webhook UI"
else
  if sudo tailscale funnel status 2>/dev/null | grep -q ':9091'; then
    ok "Tailscale Funnel already exposing :9091"
  else
    note "Starting Tailscale Funnel on :9091..."
    sudo tailscale funnel --bg 9091
    sleep 2
    ok "Funnel started"
  fi
  FUNNEL_HOST=$(tailscale status --json 2>/dev/null \
    | jq -r '.Self.DNSName' | sed 's/\.$//')
  FUNNEL_URL="https://${FUNNEL_HOST}/"
  note "Funnel URL: $FUNNEL_URL"

  echo
  prompt "Open $GH_URL/settings/hooks/new"
  prompt "  Payload URL: ${FUNNEL_URL}webhook"
  prompt "  Content type: application/json"
  prompt "  Secret: $WEBHOOK_SECRET_DISPLAY"
  prompt "  Events: select 'Just the push event'"
  prompt "  Active: ✓"
  prompt "  Click 'Add webhook'"
  pause "Done?"
fi

# -------------------------------------------------------------------------
# Phase 8: Branch protection bootstrap
# -------------------------------------------------------------------------

heading "Phase 8: Branch protection bootstrap"

if [ "$DRY_RUN" = "1" ]; then
  note "DRY_RUN: skipping Branch protection bootstrap"
else
  if [ -z "${RULESETS_PAT:-}" ]; then
    if [ -n "${TEST_PAT:-}" ]; then
      RULESETS_PAT="$TEST_PAT"
    else
      prompt "Re-paste the Rulesets PAT for this run (input hidden):"
      RULESETS_PAT=$(read_secret "")
    fi
  fi

  note "Running bootstrap-branch-protection.sh in evaluate (dry-run) mode..."
  GH_TOKEN="$RULESETS_PAT" "$REPO_ROOT/scripts/bootstrap-branch-protection.sh" evaluate
  ok "Dry-run rulesets created"

  prompt "Review the proposed config above. Branch protection has no native dry-run; activate when ready."
  pause "Ready to activate?"

  note "Activating rulesets..."
  GH_TOKEN="$RULESETS_PAT" "$REPO_ROOT/scripts/bootstrap-branch-protection.sh" active
  ok "Rulesets active"

  unset RULESETS_PAT
fi

# -------------------------------------------------------------------------
# Phase 9: Smoke test
# -------------------------------------------------------------------------

heading "Phase 9: Smoke test"

if [ "$DRY_RUN" = "1" ]; then
  note "DRY_RUN: skipping smoke test"
else
  prompt "Optional: open a no-op test PR (e.g. README typo) to verify the"
  prompt "full pipeline (CI runs → classify → label → label-gate → mergeable)."
  pause "Done (or press ENTER to skip)?"
fi

ok "Install complete!"
echo
note "Next: open a real PR. Watch $GH_URL/actions for the runner picking it up."
note "Verify via: gh api repos/$GH_OWNER/$GH_REPO/commits/main/check-runs"
