# Install checklist

Branch: `feat/cicd-workflow`. Modules already imported into `hosts/dellan/default.nix` with all `enable=` options commented out — flake builds clean today, nothing activates until you uncomment.

Run each step in order. Each `[YOU]` block is the minimum interactive work; each `[CLAUDE]` block is something I already did.

---

## Pre-flight

- [CLAUDE] All 7 NixOS modules written + parse-clean
- [CLAUDE] All 7 modules imported into `hosts/dellan/default.nix` (inert — `enable=false` defaults)
- [CLAUDE] 4 agenix secrets declared in `secrets/secrets.nix` (recipients: `[jonathan, dellan]`)
- [CLAUDE] Classifier 17/17 unit tests pass
- [CLAUDE] VM gate passes (`nix build .#checks.x86_64-linux.dellan-vm` green, 68.96s test script)

---

## Step 1 — Attic binary cache (no GitHub interaction)

- [YOU] Edit `hosts/dellan/default.nix`, uncomment:
  ```nix
  services.atticCache.enable = true;
  services.buildCoordination.enable = true;
  ```
- [YOU] `cd /etc/nixos && nix build .#checks.x86_64-linux.dellan-vm -L`
- [YOU] `sudo nixos-rebuild switch --flake /etc/nixos#dellan`
- [YOU] After Attic starts, capture pub key and commit it to `flake.nix`'s `pkgsLinux.config.nix.settings.trusted-public-keys`:
  ```bash
  sudo cat /var/lib/atticd/server.pub
  ```
- [YOU] git commit and push.

## Step 2 — Self-hosted runner

- [YOU] Generate runner SSH key (private repo clone access):
  ```bash
  ssh-keygen -t ed25519 -f /tmp/runner-key -N '' -C 'actions-runner@dellan'
  cat /tmp/runner-key.pub
  ```
- [YOU] Browser → `https://github.com/jonathanmoregard/nixos-config/settings/keys/new` → paste `/tmp/runner-key.pub`, give it write access, save.
- [YOU] Encrypt private half:
  ```bash
  cd /etc/nixos
  sudo -E nix run github:ryantm/agenix -- -e secrets/actions-runner-ssh-key.age < /tmp/runner-key
  shred -u /tmp/runner-key /tmp/runner-key.pub
  ```
- [YOU] Browser → `https://github.com/jonathanmoregard/nixos-config/settings/actions/runners/new` → copy registration token (starts with `A...`).
- [YOU] Encrypt runner token:
  ```bash
  echo -n "$TOKEN" | sudo -E nix run github:ryantm/agenix -- -e secrets/github-runner-token.age
  ```
- [YOU] Edit `hosts/dellan/default.nix`, uncomment:
  ```nix
  age.secrets.github-runner-token.file    = ../../secrets/github-runner-token.age;
  age.secrets.actions-runner-ssh-key.file = ../../secrets/actions-runner-ssh-key.age;

  services.actionsRunner = {
    enable = true;
    url = "https://github.com/jonathanmoregard/nixos-config";
    tokenFile  = config.age.secrets.github-runner-token.path;
    sshKeyFile = config.age.secrets.actions-runner-ssh-key.path;
  };
  ```
- [YOU] `git add -A && nix build .#checks.x86_64-linux.dellan-vm -L && sudo nixos-rebuild switch --flake /etc/nixos#dellan`
- [YOU] Verify runner online: `https://github.com/jonathanmoregard/nixos-config/settings/actions/runners` should show `dellan-runner` idle.
- [YOU] git push.

## Step 3 — Bare repo + worktree directory (DESTRUCTIVE)

- [YOU] **Pre-flight (mandatory):**
  ```bash
  cd /etc/nixos
  git status --porcelain      # MUST be empty
  git stash list              # MUST be empty
  git for-each-ref --format='%(refname:short)' refs/heads/  # all branches must be on origin
  ```
- [YOU] If any check fails, push/stash/clean first.
- [YOU] Run conversion:
  ```bash
  ~/Repos/nixos-config-worktrees/cicd-workflow/scripts/bootstrap-bare-repo.sh
  ```

## Step 4 — Production deploy target

- [YOU] Snapshot before destructive op:
  ```bash
  sudo cp -a /etc/nixos /etc/nixos.bak.$(date +%s)
  ```
- [YOU] Run conversion:
  ```bash
  sudo ~/Repos/nixos-config-worktrees/cicd-workflow/scripts/bootstrap-deploy-target.sh
  ```
- [YOU] Confirm: `ls -la /etc/nixos/.git` should show a real `.git` directory (not a symlink).
- [YOU] Edit `/etc/nixos/hosts/dellan/default.nix`, uncomment:
  ```nix
  services.nixosDeploy = {
    enable = true;
    sshKeyFile = config.age.secrets.actions-runner-ssh-key.path;
  };
  ```
- [YOU] `cd /etc/nixos && git add -A && nix build .#checks.x86_64-linux.dellan-vm -L && sudo nixos-rebuild switch --flake /etc/nixos#dellan`

## Step 5 — Webhook ingress (Tailscale Funnel)

- [YOU] Generate webhook secret:
  ```bash
  cd /etc/nixos
  SEC=$(openssl rand -hex 32)
  echo "WEBHOOK_SECRET=$SEC" | sudo -E nix run github:ryantm/agenix -- -e secrets/github-webhook-secret.age
  echo "WEBHOOK_SECRET=$SEC"   # save this string for the next step
  ```
- [YOU] Edit `/etc/nixos/hosts/dellan/default.nix`, uncomment:
  ```nix
  age.secrets.github-webhook-secret.file = ../../secrets/github-webhook-secret.age;

  services.githubWebhook = {
    enable = true;
    secretFile = config.age.secrets.github-webhook-secret.path;
  };
  ```
- [YOU] `git add -A && nix build .#checks.x86_64-linux.dellan-vm -L && sudo nixos-rebuild switch --flake /etc/nixos#dellan`
- [YOU] Expose port:
  ```bash
  sudo tailscale funnel --bg 9091
  sudo tailscale funnel status
  ```
  Note the `https://<machine>.<tailnet>.ts.net/` URL.
- [YOU] Browser → `https://github.com/jonathanmoregard/nixos-config/settings/hooks/new`
  - Payload URL: `<funnel URL>/webhook`
  - Content type: `application/json`
  - Secret: paste the `$SEC` from above
  - Events: only the `push` event
  - Active: yes

## Step 6 — Workflows + classifier on main

- [YOU]
  ```bash
  cd /etc/nixos
  git checkout main
  git checkout feat/cicd-workflow -- .github/ scripts/
  git add -A
  git commit -m 'feat(ci): bring CI workflows + classifier to main'
  git push origin main
  ```
- [YOU] Open a no-op test PR (e.g. add a comment to `flake.nix`). Watch:
  - `https://github.com/jonathanmoregard/nixos-config/actions` — runner picks it up
  - PR labels — should get `risk:trivial`
  - PR checks — `eval`, `build`, `vm-minimal`, `classify`, `label-gate` should all show green

## Step 7 — `[HUMAN-CHECKPOINT]` Wait for first green run on main

- [YOU] Verify ALL named status checks have produced at least one green run on `main`:
  ```bash
  gh api repos/jonathanmoregard/nixos-config/commits/main/check-runs \
    --jq '.check_runs[] | "\(.name): \(.conclusion)"'
  ```
  Expected: `eval: success`, `build: success`, `vm-minimal: success`, `classify: success`, `label-gate: success`.
- [YOU] STOP if any check is missing — Rulesets activation in Step 8 would lock out merges.

## Step 8 — Rulesets activation

- [YOU] Browser → `https://github.com/settings/tokens/new`
  - Note: `nixos-config Rulesets bootstrap`
  - Expiration: 7 days
  - Scope: `repo:admin` (full repo admin)
  - Generate, copy.
- [YOU] Dry-run first:
  ```bash
  cd /etc/nixos
  GH_TOKEN=<paste> ./scripts/bootstrap-rulesets.sh evaluate
  ```
- [YOU] Browser → `https://github.com/jonathanmoregard/nixos-config/rulesets` — review the dry-run rulesets, verify they look right.
- [YOU] Activate:
  ```bash
  GH_TOKEN=<paste> ./scripts/bootstrap-rulesets.sh active
  ```
- [YOU] Commit state file:
  ```bash
  git add scripts/rulesets-state.json
  git commit -m 'feat(ci): pin Rulesets state'
  git push origin main
  ```

## Step 9 — End-to-end smoke

- [YOU] Open a TRIVIAL PR (README typo). Expect:
  - Auto-mergeable (label-gate passes for `risk:trivial` without human approval)
- [YOU] Open a HIGH PR (e.g. modify `modules/nixos/desktop.nix`). Expect:
  - Label = `risk:high`
  - `label-gate` FAILS until you `gh pr review --approve <PR>` (or click Approve in UI)
  - After approval: mergeable.

## Step 10 — claude-agent users (later, when wanted)

- [YOU] Edit `hosts/dellan/default.nix`, uncomment:
  ```nix
  services.claudeAgentUsers.enable = true;
  ```
- [YOU] Decide which agents migrate from `jonathan` to `claude-agent-{1..N}` users.
- [YOU] (Optional, recommended) Move `gh` shell wrapper out of `home/jonathan.nix`'s zsh init so agent users don't inherit it. Spec section "Threat model" describes the rationale.

---

## Recovery

| Scenario | Recovery |
|---|---|
| Bad deploy reached dellan | `sudo nixos-rebuild switch --rollback` |
| Bad merge reached main | `gh api .../branches/main/protection -X PATCH ...` to disable Rulesets temp; then `git revert <bad>; git push origin main` |
| Bare-repo bootstrap went wrong | `mv /etc/nixos.bak.<timestamp> /etc/nixos` (snapshot from Step 4) |
| Deploy poison-latch | `sudo rm /var/lib/nixos-deploy/current-poison && sudo systemctl reset-failed nixos-deploy` |

---

## Known gaps still TODO (low priority)

- VM-graphical tier (E.1) — placeholder in `ci.yml`; baseline-diff harness not written
- VM-realapp tier (E.2) — out of scope
- comin alternative to webhook→deploy (research recommendation; not adopted)
- microvm.nix runner isolation (research recommendation; not implemented)
- Two-App split (label-bot vs merge-bot) — single App used currently
- Janitor cron for stale GHA jobs (`gh-janitor-token.age` declared in secrets but no cron)

None block the core "PR → classifier → label → merge → auto-deploy" flow.
