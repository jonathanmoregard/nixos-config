#!/usr/bin/env bash
# scripts/install.sh — guided, single-command installer for the CI/CD
# workflow on dellan. Walks through:
#   1. Generate runner SSH keypair → pause for user to add to GH Deploy Keys
#   2. Prompt for runner registration token (browser → settings/actions/runners/new)
#   3. Generate webhook secret + prompt for Rulesets PAT
#   4. Encrypt all 4 secrets via agenix
#   5. Uncomment age.secrets + service blocks in hosts/dellan/default.nix
#   6. Run nixos-rebuild switch
#   7. Run bare-repo + deploy-target bootstraps
#   8. Set up Tailscale Funnel + pause for GH Webhook URL config
#   9. Run Rulesets bootstrap (evaluate then active)
#   10. Open test PR via gh
#
# Run as your normal user; the script will sudo for the privileged steps.
# Idempotent-ish: each phase checks if it's already been done and skips
# cleanly. Re-runnable on partial failure.

set -euo pipefail

# ------------------------------------------------------------------------
# Self-bootstrap: ensure all required tools are on PATH. If any is missing,
# re-exec the script inside a `nix shell` that provides them. This makes
# the install one-shot from a fresh dellan even if `openssl`, `jq`, or
# `gh` aren't in the user's environment yet.
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
CONFIG_PATH=/etc/nixos
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
  prompt "$1"
  prompt "Press ENTER when done (or Ctrl-C to abort)..."
  read -r
}

read_secret() {
  # Reads a secret from stdin without echo. $1 = prompt text.
  prompt "$1"
  IFS= read -rs val
  echo
  printf '%s' "$val"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

agenix_encrypt() {
  # Encrypts content from stdin → secrets/$1.age. agenix expects
  # secrets.nix to live next to the .age files, so we cd into
  # $CONFIG_PATH/secrets and pass a bare filename.
  local name="$1" tmp
  tmp=$(mktemp)
  cat > "$tmp"
  (
    cd "$CONFIG_PATH/secrets"
    EDITOR="cp -f $tmp" sudo -E nix run \
      --extra-experimental-features 'nix-command flakes' \
      github:ryantm/agenix -- -e "${name}.age"
  )
  rm -f "$tmp"
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
require_cmd sudo

if [ ! -L "$CONFIG_PATH" ] && [ ! -d "$CONFIG_PATH" ]; then
  fail "$CONFIG_PATH does not exist"
fi

# Determine: are we ALREADY running from /etc/nixos (post bare-repo bootstrap),
# or from a worktree under $HOME/Repos/nixos-config-worktrees?
if [ "$REPO_ROOT" = "$CONFIG_PATH" ] || [ "$(readlink -f "$REPO_ROOT")" = "$(readlink -f "$CONFIG_PATH")" ]; then
  CONFIG_FROM_WORKTREE=0
  ok "Running from $CONFIG_PATH directly"
else
  CONFIG_FROM_WORKTREE=1
  ok "Running from worktree $REPO_ROOT"
  note "Will edit config files in $CONFIG_PATH (sudo)"
fi

# Branch sanity
BRANCH=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)
note "Current branch: $BRANCH"
if [ "$BRANCH" != "feat/cicd-workflow" ] && [ "$BRANCH" != "main" ]; then
  prompt "Branch is '$BRANCH', expected feat/cicd-workflow or main. Continue anyway? (y/N)"
  read -r ans
  [ "$ans" = "y" ] || exit 1
fi

ok "Pre-flight passed"

# -------------------------------------------------------------------------
# Phase 1: SSH key for the runner (also reused by nixos-deploy.service)
# -------------------------------------------------------------------------

heading "Phase 1: Generate runner SSH key"

KEYFILE_AGE="$REPO_ROOT/secrets/actions-runner-ssh-key.age"
if [ -f "$KEYFILE_AGE" ]; then
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

TOKEN_AGE="$REPO_ROOT/secrets/github-runner-token.age"
if [ -f "$TOKEN_AGE" ]; then
  ok "$TOKEN_AGE already exists; skipping"
  note "If token is expired, delete the .age and re-run."
else
  prompt "Open $GH_URL/settings/actions/runners/new"
  prompt "  Select Linux x64"
  prompt "  Copy the registration token (starts with 'A...', visible after './config.sh --url ... --token ...')"
  TOKEN=$(read_secret "Paste token (input hidden):")
  [ -n "$TOKEN" ] || fail "empty token"

  printf '%s' "$TOKEN" | agenix_encrypt github-runner-token
  unset TOKEN
  ok "Encrypted as secrets/github-runner-token.age"
fi

# -------------------------------------------------------------------------
# Phase 3: Webhook secret + Rulesets PAT
# -------------------------------------------------------------------------

heading "Phase 3: Webhook secret + Rulesets PAT"

WEBHOOK_AGE="$REPO_ROOT/secrets/github-webhook-secret.age"
if [ -f "$WEBHOOK_AGE" ]; then
  ok "$WEBHOOK_AGE already exists; skipping"
  WEBHOOK_SECRET_DISPLAY="(already encrypted; cat manually if you need to re-paste in GH UI)"
else
  WEBHOOK_SECRET=$(openssl rand -hex 32)
  printf 'WEBHOOK_SECRET=%s\n' "$WEBHOOK_SECRET" | agenix_encrypt github-webhook-secret
  ok "Generated + encrypted webhook secret"
  WEBHOOK_SECRET_DISPLAY="$WEBHOOK_SECRET"
fi

PAT_AGE="$REPO_ROOT/secrets/gh-janitor-token.age"
if [ -f "$PAT_AGE" ]; then
  ok "$PAT_AGE already exists; skipping"
else
  prompt "Open https://github.com/settings/tokens/new"
  prompt "  Note: nixos-config-rulesets-bootstrap"
  prompt "  Expiration: 7 days (rulesets one-shot) OR 90 days (also covers janitor cron)"
  prompt "  Scope: 'repo' (full)"
  prompt "  Generate token, copy."
  PAT=$(read_secret "Paste PAT (input hidden):")
  [ -n "$PAT" ] || fail "empty PAT"

  printf 'GH_TOKEN=%s\n' "$PAT" | agenix_encrypt gh-janitor-token
  RULESETS_PAT="$PAT"   # keep for Phase 6
  unset PAT
  ok "Encrypted as secrets/gh-janitor-token.age"
fi

# -------------------------------------------------------------------------
# Phase 4: Stage encrypted .age files in /etc/nixos + uncomment config
# -------------------------------------------------------------------------

heading "Phase 4: Wire secrets + uncomment service blocks in $CONFIG_PATH"

# Copy newly-encrypted .age files into /etc/nixos if running from worktree
if [ "$CONFIG_FROM_WORKTREE" = 1 ]; then
  for f in actions-runner-ssh-key github-runner-token github-webhook-secret gh-janitor-token; do
    src="$REPO_ROOT/secrets/${f}.age"
    dst="$CONFIG_PATH/secrets/${f}.age"
    if [ -f "$src" ] && [ ! -f "$dst" ]; then
      sudo cp "$src" "$dst"
      ok "Copied secrets/${f}.age into $CONFIG_PATH"
    fi
  done
fi

# Uncomment age.secrets + service blocks in hosts/dellan/default.nix.
# Uses sed in place; idempotent because uncommenting a line that's already
# uncommented is a no-op (sed pattern won't match).
HOST_NIX="$CONFIG_PATH/hosts/dellan/default.nix"

uncomment_block() {
  # $1 = anchor regex (matched line marks where to start), $2 = number of
  # lines to uncomment. Strips leading '# ' from each line.
  local anchor="$1" count="$2"
  sudo sed -i "/$anchor/,+$count s/^  # /  /" "$HOST_NIX"
}

uncomment_line() {
  sudo sed -i "s|^  # \\($1\\)|  \\1|" "$HOST_NIX"
}

# age.secrets declarations (4 lines)
uncomment_line 'age.secrets.github-runner-token.file'
uncomment_line 'age.secrets.actions-runner-ssh-key.file'
uncomment_line 'age.secrets.github-webhook-secret.file'
uncomment_line 'age.secrets.gh-janitor-token.file'

# Service blocks
uncomment_line 'services.atticCache.enable = true;'
uncomment_line 'services.buildCoordination.enable = true;'
uncomment_line 'services.claudeAgentUsers.enable = true;'

# Multi-line service blocks
uncomment_block 'services.actionsRunner =' 5
uncomment_block 'services.githubWebhook =' 3
uncomment_block 'services.nixosDeploy =' 3

# Stage in git so the flake sees them
sudo git -C "$CONFIG_PATH" add -A

ok "Config edits staged in $CONFIG_PATH"

# -------------------------------------------------------------------------
# Phase 5: VM gate + nixos-rebuild switch
# -------------------------------------------------------------------------

heading "Phase 5: VM gate + nixos-rebuild switch"

note "Running VM gate (~2-3 min)..."
nix build "${CONFIG_PATH}#checks.x86_64-linux.dellan-vm" -L --no-link
ok "VM gate green"

note "Running nixos-rebuild switch..."
sudo nixos-rebuild switch --flake "${CONFIG_PATH}#dellan"
ok "Rebuild applied"

# -------------------------------------------------------------------------
# Phase 6: Bare-repo + deploy-target bootstraps
# -------------------------------------------------------------------------

heading "Phase 6: Bare-repo + deploy-target bootstraps"

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

# -------------------------------------------------------------------------
# Phase 7: Tailscale Funnel + GitHub Webhook UI
# -------------------------------------------------------------------------

heading "Phase 7: Tailscale Funnel + GitHub Webhook"

if sudo tailscale funnel status 2>/dev/null | grep -q ':9091'; then
  ok "Tailscale Funnel already exposing :9091"
  FUNNEL_URL=$(sudo tailscale funnel status --json 2>/dev/null | jq -r '.AllowedFunnel[]' | head -1 || echo "<your-funnel-url>")
else
  note "Starting Tailscale Funnel on :9091..."
  sudo tailscale funnel --bg 9091
  sleep 2
  FUNNEL_URL=$(sudo tailscale funnel status --json 2>/dev/null | jq -r '.AllowedFunnel[]' | head -1)
  ok "Funnel up at $FUNNEL_URL"
fi

echo
prompt "Open $GH_URL/settings/hooks/new"
prompt "  Payload URL: ${FUNNEL_URL}webhook"
prompt "  Content type: application/json"
prompt "  Secret: $WEBHOOK_SECRET_DISPLAY"
prompt "  Events: select 'Just the push event'"
prompt "  Active: ✓"
prompt "  Click 'Add webhook'"
pause "Done?"

# -------------------------------------------------------------------------
# Phase 8: Rulesets bootstrap
# -------------------------------------------------------------------------

heading "Phase 8: Rulesets bootstrap"

if [ -z "${RULESETS_PAT:-}" ]; then
  prompt "Re-paste the Rulesets PAT for this run (input hidden):"
  RULESETS_PAT=$(read_secret "")
fi

note "Running bootstrap-rulesets.sh in evaluate (dry-run) mode..."
GH_TOKEN="$RULESETS_PAT" "$REPO_ROOT/scripts/bootstrap-rulesets.sh" evaluate
ok "Dry-run rulesets created"

prompt "Open $GH_URL/rulesets — verify the 4 dry-run rulesets look right."
pause "Ready to activate?"

note "Activating rulesets..."
GH_TOKEN="$RULESETS_PAT" "$REPO_ROOT/scripts/bootstrap-rulesets.sh" active
ok "Rulesets active"

unset RULESETS_PAT

# -------------------------------------------------------------------------
# Phase 9: Smoke test (open a no-op PR)
# -------------------------------------------------------------------------

heading "Phase 9: Smoke test"

prompt "Optional: open a no-op test PR (e.g. README typo) to verify the"
prompt "full pipeline (CI runs → classify → label → label-gate → mergeable)."
prompt "Done?"

ok "Install complete!"
echo
note "Next: open a real PR. Watch $GH_URL/actions for the runner picking it up."
note "Verify via: gh api repos/$GH_OWNER/$GH_REPO/commits/main/check-runs"
