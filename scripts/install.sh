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
  # Prompt + final newline go to STDERR so $(read_secret ...) doesn't
  # capture them into the value.
  local val
  prompt "$1" >&2
  IFS= read -rs val
  echo >&2
  printf '%s' "$val"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

agenix_encrypt() {
  # Encrypts content from stdin → $CONFIG_PATH/secrets/$1.age.
  # Verifies non-empty plaintext + non-zero ciphertext + roundtrip
  # decrypt to catch cases where the EDITOR=cp trick silently produces
  # an empty file.
  local name="$1"
  local tmp
  tmp=$(mktemp)
  cat > "$tmp"
  local plaintext_size
  plaintext_size=$(wc -c < "$tmp")
  if [ "$plaintext_size" -eq 0 ]; then
    rm -f "$tmp"
    fail "agenix_encrypt $name: stdin was empty (refusing to encrypt 0 bytes)"
  fi
  (
    cd "$CONFIG_PATH/secrets"
    EDITOR="cp -f $tmp" nix run \
      --extra-experimental-features 'nix-command flakes' \
      github:ryantm/agenix -- -e "${name}.age"
  )
  rm -f "$tmp"
  # Roundtrip: decrypt and verify size matches the input.
  local decrypted_size
  decrypted_size=$(
    cd "$CONFIG_PATH/secrets" && \
    nix run --extra-experimental-features 'nix-command flakes' \
      github:ryantm/agenix -- -d "${name}.age" 2>/dev/null | wc -c
  )
  if [ "$decrypted_size" -ne "$plaintext_size" ]; then
    fail "agenix_encrypt $name: decrypted size $decrypted_size != input size $plaintext_size — encryption corrupted content"
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
require_cmd sudo

if [ ! -L "$CONFIG_PATH" ] && [ ! -d "$CONFIG_PATH" ]; then
  fail "$CONFIG_PATH does not exist"
fi

# Note where we're running from (informational only — install operates
# on $CONFIG_PATH regardless).
if [ "$REPO_ROOT" = "$CONFIG_PATH" ] || [ "$(readlink -f "$REPO_ROOT")" = "$(readlink -f "$CONFIG_PATH")" ]; then
  ok "Running from $CONFIG_PATH directly"
else
  ok "Running from worktree $REPO_ROOT"
  note "All edits target $CONFIG_PATH (sudo)"
fi

# Pre-flight: feat must already be merged to main, AND /etc/nixos must
# point at that merged main. Otherwise the secrets.nix lookup, the sed
# config-edits, and the rebuild all fail in cascading ways.
ETC_NIXOS_REAL=$(readlink -f "$CONFIG_PATH")
ETC_BRANCH=$(git -C "$ETC_NIXOS_REAL" rev-parse --abbrev-ref HEAD)
note "/etc/nixos resolves to $ETC_NIXOS_REAL (branch: $ETC_BRANCH)"

if [ "$ETC_BRANCH" != "main" ]; then
  fail "/etc/nixos is on branch '$ETC_BRANCH', not main. Merge feat/cicd-workflow → main first."
fi

# Confirm the merged main contains round-7 content.
if ! grep -q '"actions-runner-ssh-key.age"' "$CONFIG_PATH/secrets/secrets.nix" 2>/dev/null; then
  fail "/etc/nixos/secrets/secrets.nix doesn't have round-7 entries. Merge feat/cicd-workflow → main first."
fi
if ! grep -q 'services.atticCache' "$CONFIG_PATH/hosts/dellan/default.nix" 2>/dev/null; then
  fail "/etc/nixos/hosts/dellan/default.nix doesn't have round-7 service blocks. Merge feat/cicd-workflow → main first."
fi

ok "Pre-flight passed (main has round-7 content)"

# -------------------------------------------------------------------------
# Phase 1: SSH key for the runner (also reused by nixos-deploy.service)
# -------------------------------------------------------------------------

heading "Phase 1: Generate runner SSH key"

KEYFILE_AGE="$CONFIG_PATH/secrets/actions-runner-ssh-key.age"
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

TOKEN_AGE="$CONFIG_PATH/secrets/github-runner-token.age"
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

WEBHOOK_AGE="$CONFIG_PATH/secrets/github-webhook-secret.age"
if [ -f "$WEBHOOK_AGE" ]; then
  ok "$WEBHOOK_AGE already exists; skipping"
  WEBHOOK_SECRET_DISPLAY="(already encrypted; cat manually if you need to re-paste in GH UI)"
else
  WEBHOOK_SECRET=$(openssl rand -hex 32)
  printf 'WEBHOOK_SECRET=%s\n' "$WEBHOOK_SECRET" | agenix_encrypt github-webhook-secret
  ok "Generated + encrypted webhook secret"
  WEBHOOK_SECRET_DISPLAY="$WEBHOOK_SECRET"
fi

PAT_AGE="$CONFIG_PATH/secrets/gh-janitor-token.age"
if [ -f "$PAT_AGE" ]; then
  ok "$PAT_AGE already exists; skipping"
else
  prompt "Open https://github.com/settings/tokens/new"
  prompt "  Note: nixos-config-rulesets-bootstrap"
  prompt "  Expiration: 7 days (rulesets one-shot) OR 1 year (also covers janitor cron)"
  prompt "  Scope: 'repo' (full)"
  prompt "  Generate token, copy."
  PAT=$(read_secret "Paste PAT (input hidden):")
  [ -n "$PAT" ] || fail "empty PAT"

  printf 'GH_TOKEN=%s\n' "$PAT" | agenix_encrypt gh-janitor-token
  RULESETS_PAT="$PAT"   # keep for Phase 6
  unset PAT
  ok "Encrypted as secrets/gh-janitor-token.age"
fi

ATTIC_AGE="$CONFIG_PATH/secrets/atticd-rs256-secret.age"
if [ -f "$ATTIC_AGE" ]; then
  ok "$ATTIC_AGE already exists; skipping"
else
  note "Generating Attic RS256 token-signing secret (4096-bit RSA, base64)..."
  ATTIC_SECRET=$(openssl genrsa -traditional 4096 2>/dev/null | base64 -w0)
  # NOTE: atticd expects the env var name to end with _BASE64 (verified
  # against actual panic message at server/src/config.rs:335).
  printf 'ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64="%s"\n' "$ATTIC_SECRET" \
    | agenix_encrypt atticd-rs256-secret
  unset ATTIC_SECRET
  ok "Encrypted as secrets/atticd-rs256-secret.age"
fi

# -------------------------------------------------------------------------
# Phase 4: Uncomment service blocks in /etc/nixos/hosts/dellan/default.nix
# -------------------------------------------------------------------------

heading "Phase 4: Uncomment service blocks in $CONFIG_PATH"

# Uncomment age.secrets + service blocks. Uses sed in place; idempotent
# because uncommenting an already-uncommented line is a no-op.
HOST_NIX="$CONFIG_PATH/hosts/dellan/default.nix"

uncomment_block() {
  # $1 = anchor regex, $2 = number of lines after anchor to uncomment.
  local anchor="$1" count="$2"
  sudo sed -i "/$anchor/,+$count s/^  # /  /" "$HOST_NIX"
}

uncomment_line() {
  sudo sed -i "s|^  # \\($1\\)|  \\1|" "$HOST_NIX"
}

# age.secrets declarations (5 lines)
uncomment_line 'age.secrets.github-runner-token.file'
uncomment_line 'age.secrets.actions-runner-ssh-key.file'
uncomment_line 'age.secrets.github-webhook-secret.file'
uncomment_line 'age.secrets.gh-janitor-token.file'
uncomment_line 'age.secrets.atticd-rs256-secret.file'

# Single-line service options
uncomment_line 'services.buildCoordination.enable = true;'
uncomment_line 'services.claudeAgentUsers.enable = true;'

# Multi-line service blocks
uncomment_block 'services.atticCache =' 3
uncomment_block 'services.actionsRunner =' 5
uncomment_block 'services.githubWebhook =' 3
uncomment_block 'services.nixosDeploy =' 3

# Commit + push the .age files and config edits BEFORE bare-repo bootstrap
# destroys ~/Repos/nixos-config. The bootstrap reclones from origin/main,
# so anything not pushed is lost.
sudo git -C "$CONFIG_PATH" add -A
if sudo git -C "$CONFIG_PATH" diff --cached --quiet; then
  ok "No changes to commit (already done in a previous run)"
else
  sudo git -C "$CONFIG_PATH" -c user.name=jonathanmoregard \
    -c user.email=jonathan.more@hotmail.com \
    commit -m "feat(install): encrypt CI/CD secrets + enable services"
  # Push uses jonathan's SSH key (root has no GH credentials).
  # GIT_SSH_COMMAND points at jonathan's id_ed25519 explicitly so the
  # sudo'd push authenticates as jonathan to GitHub.
  if [ -f "$HOME/.ssh/id_ed25519" ]; then
    sudo GIT_SSH_COMMAND="ssh -i $HOME/.ssh/id_ed25519 -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes" \
      git -C "$CONFIG_PATH" push origin main
  else
    fail "No SSH key at \$HOME/.ssh/id_ed25519. Cannot push to GitHub. Generate one and register as a Deploy Key, then re-run."
  fi
  ok "Committed + pushed config edits to origin/main"
fi

# -------------------------------------------------------------------------
# Phase 5: VM gate + nixos-rebuild switch
# -------------------------------------------------------------------------

heading "Phase 5: VM gate + nixos-rebuild switch"

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
else
  note "Starting Tailscale Funnel on :9091..."
  sudo tailscale funnel --bg 9091
  sleep 2
  ok "Funnel started"
fi
# Funnel hostname comes from this node's tailnet DNS name; trim trailing dot.
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
pause "Done (or press ENTER to skip)?"

ok "Install complete!"
echo
note "Next: open a real PR. Watch $GH_URL/actions for the runner picking it up."
note "Verify via: gh api repos/$GH_OWNER/$GH_REPO/commits/main/check-runs"
