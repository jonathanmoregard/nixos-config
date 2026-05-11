# CI/CD-driven nixos-config workflow

**Status:** design (partially superseded — see migration note below)
**Date:** 2026-05-04 (original); migration note 2026-05-05
**Scope:** dellan host only (mac-mini and vm flake entries removed; auto-discovery picks up future hosts)
**Spec format:** umbrella with five orthogonal sub-specs (A–E), each independently extractable.

> **Migration note (2026-05-05):** the sections marked `[OBSOLETE-2026-05-05]`
> in this spec describe the original self-hosted-runner-on-dellan + Attic
> binary cache architecture. That architecture has been replaced with
> GitHub-hosted runners on `ubuntu-latest` (public repo = unlimited free
> minutes), `wimpysworld/nothing-but-nix` for disk pressure,
> `DeterminateSystems/determinate-nix-action` for the Nix install, and
> `nix-community/cache-nix-action` for /nix/store caching between runs.
> Webhook-driven `nixos-deploy.service` on dellan (Sub-spec B) is unchanged —
> only the CI runner location moved off-box. See `.github/workflows/`
> + the project `CLAUDE.md` for the canonical current state.

---

## Goal

Enable multiple AI agents to develop NixOS config changes in parallel — each agent in its own worktree, each PR tested in a sandboxed VM lane, low-risk changes auto-merging, high-risk changes gated on human review, production (`/etc/nixos`) auto-applying every merge to `main`. Single-developer workflow today; same primitives scale to multi-agent tomorrow.

## Locked decisions

| Decision | Choice | Rationale |
|---|---|---|
| Production scope | dellan only (now) | Mac-mini is aarch64-darwin placeholder, vm host being deleted; future hosts auto-discovered |
| Auto-apply cadence | Continuous on every merge to `main` | Highest velocity; NixOS boot generations + classifier gating make rollback rare |
| Auto-rollback | None — rely on NixOS generations + manual `nixos-rebuild switch --rollback` | Gate stack catches issues pre-merge; auto-rollback adds complexity without clear win |
| CI host | GitHub-hosted `ubuntu-latest` (post-migration; was self-hosted on dellan) | Public repo = unlimited free minutes; ephemeral runner per job; no secrets persisted on dellan |
| Cache | `nix-community/cache-nix-action` for /nix/store + cache.nixos.org as substituter | 10 GB GHA cache per repo, GC-bounded; replaces self-hosted Attic |
| Webhook ingress | Tailscale Funnel (already wired on dellan) | TLS-terminated public endpoint without NAT punching; secret in agenix |
| Concurrent VM lanes | 3 (matrix on GHA-hosted; each lane its own ephemeral runner) | KVM nested-virt available on `ubuntu-latest` since Feb 2023 |
| Repo layout | `~/Repos/nixos-config` is **bare**; all work in `~/Repos/nixos-config-worktrees/<branch>`; `/etc/nixos` is a separate root-owned clone of `origin/main` | Bare repo enforces worktree-only workflow by construction |
| Triggers | `pull_request` (open/sync) + `push: main` (merge). Branch pushes do NOT trigger CI. | Saves cycles; agents push WIP freely |
| Classification | Derivation-graph blast radius via `nix store diff-closures` → rule table → bucket → GitHub label | Nix-native; deterministic; sees outcome not source |
| Branch protection | Legacy Branch Protection (free on public repos) — required status checks only, `enforce_admins: false`, no required review | Solo-author repo; checks are the gate. CLI `gh pr merge` (any flags) denied at safe-bash MCP layer so merge stays a deliberate UI gesture |

---

## Architecture (umbrella)

```
                   GitHub (private repo)
                   ┌──────────────────────────────────┐
                   │ PRs, Rulesets, required reviewers│
                   └──────┬───────────────────────────┘
                          │ webhook (HMAC-signed) over Tailscale Funnel
                          ▼
         ┌─────────────────────────────────────────────────┐
         │ dellan (12c/32 GB, KVM)                         │
         │                                                 │
         │  systemd socket → webhook handler               │
         │     ├─ pull_request → enqueue runner job        │
         │     └─ push:main   → start nixos-deploy.service │
         │                                                 │
         │  ┌──────────────────────────────────────────┐   │
         │  │ self-hosted GHA runner (systemd user)    │   │
         │  │   CPUWeight=50, MemoryHigh=20G           │   │
         │  │   Slice=actions-runner.slice             │   │
         │  └──────────────┬───────────────────────────┘   │
         │                 │                               │
         │   ┌─────────────┴─────────────┐                 │
         │   ▼                           ▼                 │
         │ ┌──────────────┐    ┌──────────────────────┐    │
         │ │ Attic        │◄───┤ ~/Repos/nixos-       │    │
         │ │ binary cache │    │   config-worktrees/  │    │
         │ │ localhost    │    │   <branch-N>/        │    │
         │ │ :8080        │    │ (parallel VM lanes)  │    │
         │ └──────────────┘    └──────────────────────┘    │
         │                                                 │
         │  ┌──────────────────────────────────────────┐   │
         │  │ /etc/nixos (root-owned, read-only        │   │
         │  │  clone of origin/main)                   │   │
         │  │  → nixos-deploy.service runs             │   │
         │  │     git fetch && reset --hard            │   │
         │  │     && nixos-rebuild switch              │   │
         │  └──────────────────────────────────────────┘   │
         └─────────────────────────────────────────────────┘
```

---

## Sub-spec A: CI/CD plumbing

### Components

1. **CI runner [OBSOLETE-2026-05-05 — replaced by GHA-hosted].** Originally a self-hosted GHA runner on dellan registered as `dellan-runner` (system service, dedicated `actions-runner` user, CPUWeight=50, MemoryHigh=20G, slice-scoped). Migrated to GitHub-hosted `ubuntu-latest` runners — public repo = unlimited free minutes, ephemeral runner per job, no agenix master key or attic signing key persisted on dellan. Module `modules/nixos/actions-runner.nix` and secrets `secrets/github-runner-token.age` deleted.
2. **Webhook ingress** via Tailscale Funnel — used **only** for production deploy. PR-triggered jobs do not need it (GHA self-hosted runners long-poll GitHub directly for queued work).
   - GitHub → `https://<machine>.<tailnet>.ts.net/webhook` → systemd socket-activated handler
   - **Implementation:** `pkgs.writers.writePython3Bin "github-webhook-handler"`. Reads request from stdin (socket-activated), writes response to stdout. Lives in `modules/nixos/github-webhook.nix`.
   - **HMAC verification:** computes `hmac.new(SECRET, body, sha256)` and compares to `X-Hub-Signature-256` header in constant time (`hmac.compare_digest`). Secret in `secrets/github-webhook-secret.age`, exposed as `EnvironmentFile`.
   - **Replay protection:** stores `X-GitHub-Delivery` UUIDs seen in the last 24h to `/var/lib/github-webhook/seen` (one UUID per line, pruned on rotation). Duplicate UUID → 200 OK with no action.
   - **Rate limit (accept-side):** systemd socket unit sets `RateLimitIntervalSec=10` and `RateLimitBurst=10` (10 new connections per 10s, then queues). GitHub retries failed webhooks up to 3x with exponential backoff over ~30s; burst=5 risked dropping retries during transient errors.
   - **Slowloris protection (read-side):** socket unit sets `MaxConnections=4` (cap on concurrent in-flight workers); service unit sets `TimeoutStartSec=10s` (kill the handler if it exceeds 10s); python handler calls `socket.settimeout(5)` on its read loop so a dripping connection cannot stall the worker indefinitely.
   - **Event filter:** handler only acts on `X-GitHub-Event: push` with `payload.ref == "refs/heads/main"`. All other events → 200 OK with no action.
   - On valid push: `systemctl start nixos-deploy.service`
3. **Workflows — split by trust boundary.** PRs run their own workflow code on the self-hosted runner, so any step running on `pull_request` is PR-controllable (a malicious PR could rewrite `scripts/classify-pr.sh` or add a `gh pr edit --add-label ai-approved` step). Two workflow files separate trusted from untrusted execution:

   **`.github/workflows/ci.yml`** — runs on `pull_request` from the PR branch. Allowed to do builds, tests, lint. **Forbidden** from labelling, AI review, or any decision that gates merge. Workflow declares `permissions: { contents: read, pull-requests: read }`.
   - Triggers: `pull_request: {types: [opened, synchronize, reopened]}`, `push: {branches: [main]}`
   - Concurrency group: `vm-lane-${{ matrix.lane }}` with `lane: [1, 2, 3]`
   - Job graph:
     ```
     discover-hosts ─► eval ─► build ─► vm-minimal ─► vm-graphical (conditional)
     ```
   - **discover-hosts:** `nix eval` walks `nixosConfigurations` and `darwinConfigurations`, emits a matrix. Linux jobs run on `[self-hosted, x86_64-linux]`; darwin jobs require `[self-hosted, aarch64-darwin]` → skip with warning if no runner.

   **`.github/workflows/gate.yml`** — runs on `pull_request_target` (which checks out the BASE branch's workflow file, NOT the PR's). All merge-gating logic — classifier, AI review, label-add, label-gate status check — lives here. PR diff is fetched explicitly via `gh pr diff` and treated as untrusted data. Workflow declares `permissions: { contents: read, pull-requests: write, issues: write }` (label-add needs these scopes).
   - Triggers: `pull_request_target: {types: [opened, synchronize, reopened, labeled, unlabeled]}`
   - Concurrency: `pr-${{ github.event.pull_request.number }}` with `cancel-in-progress: true`
   - Job graph:
     ```
     classify ─► label-pr ─► (if MEDIUM) ai-review ─► label-pr (ai-approved)
                          └► label-gate (status check)
     ```
   - **Step skeleton (resolves how SHAs and PR diff arrive):**
     ```yaml
     env:
       BASE_SHA: ${{ github.event.pull_request.base.sha }}
       HEAD_SHA: ${{ github.event.pull_request.head.sha }}
       PR_NUMBER: ${{ github.event.pull_request.number }}
     steps:
       - uses: actions/checkout@v4
         with:
           ref: ${{ github.event.pull_request.base.sha }}   # base branch — trusted code
           fetch-depth: 0
       - name: Fetch PR head into refs/remotes/pr/head
         run: |
           git fetch origin "+refs/pull/${PR_NUMBER}/head:refs/remotes/pr/head"
       - name: Run classifier (script loaded from base checkout)
         run: ./scripts/classify-pr.sh
       # gh pr diff is used by the AI-review step to read PR contents as untrusted data
     ```
   - The `pull_request_target` trigger runs with full repo permissions but checks out the base branch by default. PR-modified `scripts/classify-pr.sh` is NEVER executed here. The script identity is pinned by base checkout (option a above). Option b — `nix run github:jonathanmoregard/nixos-config/main#classify-pr -- "$BASE_SHA" "$HEAD_SHA"` — is documented as an alternative if pinning to a specific SHA is wanted later.
   - PR diff and PR body/comments are wrapped in `<untrusted_external_content>` before passing to the AI subagent (per global CLAUDE.md security rules).
   - This split is the standard GitHub Actions pattern for "validate untrusted PR contents from a trusted context"; documented in [GitHub Security Lab "Keeping your GitHub Actions and workflows secure" guidance](https://securitylab.github.com/research/github-actions-untrusted-input/).
4. **Cache [OBSOLETE-2026-05-05 — replaced by cache-nix-action + cache.nixos.org].** Originally a self-hosted Attic server (`pkgs.attic-server`) on dellan localhost:8080 with multi-host signing-key bootstrap and per-host trusted-public-keys list. Migrated to `nix-community/cache-nix-action@v6` (GHA-side /nix/store cache, ~10 GB per repo, GC-bounded between runs) plus `cache.nixos.org` as the upstream substituter. Module `modules/nixos/atticd.nix` and secret `secrets/atticd-rs256-secret.age` deleted.
5. **Discover-hosts runner placement [OBSOLETE-2026-05-05].** Original concern was warm `/nix/store` eval cost on a self-hosted runner. With GHA-hosted runners cold-starting per job, eval time is recovered via `cache-nix-action` keyed on `hashFiles('**/*.nix', '**/flake.lock')` — incremental between runs.
6. **Lane oversubscription policy:** `strategy.max-parallel: 3` on the `vm-minimal` matrix; each lane is its own ephemeral GHA-hosted runner. PR-level `concurrency: { group: pr-${pr_number}, cancel-in-progress: true }` cancels superseded SHAs so resyncing doesn't pile runs. Janitor cron (daily) on dellan cancels jobs older than 30min via `gh run cancel` (uses `secrets/gh-janitor-token.age`).
7. **Failure handling:** workflow failures post failed status to the PR via standard GHA. No special recovery; the user / agent fixes the branch and pushes again. Post-merge `push: main` workflow failures: deploy is gated on the workflow status check, so a broken `main` doesn't auto-deploy (separate from the deploy-loop poisoning protection in B).

---

## Sub-spec B: Production auto-deploy

### Components

1. **`/etc/nixos`** = read-only clone of `origin/main`, root-owned. Symlink `~/Repos/nixos-config → /etc/nixos` is removed; the dev tree only lives at `~/Repos/nixos-config-worktrees/`.
2. **`nixos-deploy.service`** (oneshot, root, declared as a NixOS module):
   ```bash
   ExecStart = ${pkgs.writeShellScript "nixos-deploy" ''
     set -euo pipefail

     STATE=/var/lib/nixos-deploy
     mkdir -p "$STATE"
     LAST_GOOD="$STATE/last-good"
     POISONED_LOG="$STATE/poisoned.log"      # append-only history
     CURRENT_POISON="$STATE/current-poison"  # latest SHA refused

     git -C /etc/nixos fetch origin main
     TARGET=$(git -C /etc/nixos rev-parse origin/main)
     CURRENT=$(git -C /etc/nixos rev-parse HEAD)

     # Skip if already at target
     [ "$CURRENT" = "$TARGET" ] && exit 0

     # Refuse to re-attempt the last poisoned commit unless cleared
     if [ -f "$CURRENT_POISON" ] && [ "$(cat "$CURRENT_POISON")" = "$TARGET" ]; then
       echo "deploy: target $TARGET is poisoned; manual reset required"
       echo "  log:    $POISONED_LOG"
       echo "  clear:  sudo rm $CURRENT_POISON && sudo systemctl reset-failed nixos-deploy"
       exit 1
     fi

     git -C /etc/nixos reset --hard "$TARGET"
     if nixos-rebuild switch --flake /etc/nixos#dellan; then
       echo "$TARGET" > "$LAST_GOOD"
       rm -f "$CURRENT_POISON"
       # Operator signal — see "Operator notification" subsection below
       touch "$STATE/notify-success"
     else
       echo "$TARGET" > "$CURRENT_POISON"
       printf '%s\t%s\t%s\n' "$(date -Iseconds)" "$TARGET" "FAILED" >> "$POISONED_LOG"
       touch "$STATE/notify-failure"
       exit 1
     fi
   ''}";
   ```
   - Tracks `last-good` SHA and `current-poison` (latest refused SHA); poisoned history is append-only at `poisoned.log`
   - Logs to journal under `nixos-deploy.service`

   **Operator notification** (separate user-scoped services per flag, so DBUS works AND each `path` unit watches exactly one path):
   ```nix
   # Failure path: watch flag, run service, service notifies + clears flag.
   systemd.user.paths.nixos-deploy-notify-failure = {
     Unit.Description = "Watch for nixos-deploy failure flag";
     Path.PathExists = "/var/lib/nixos-deploy/notify-failure";
     Install.WantedBy = [ "default.target" ];
   };
   systemd.user.services.nixos-deploy-notify-failure.Service = {
     Type = "oneshot";
     ExecStart = "${pkgs.writeShellScript "deploy-notify-failure" ''
       SHA=$(cat /var/lib/nixos-deploy/current-poison 2>/dev/null || echo unknown)
       ${pkgs.libnotify}/bin/notify-send -u critical "nixos-deploy FAILED" \
         "Commit $SHA failed activation. Recovery: sudo nixos-rebuild switch --rollback"
       sudo /run/current-system/sw/bin/rm -f /var/lib/nixos-deploy/notify-failure
     ''}";
   };

   # Success path: same shape, watches notify-success.
   systemd.user.paths.nixos-deploy-notify-success = {
     Unit.Description = "Watch for nixos-deploy success flag";
     Path.PathExists = "/var/lib/nixos-deploy/notify-success";
     Install.WantedBy = [ "default.target" ];
   };
   systemd.user.services.nixos-deploy-notify-success.Service = {
     Type = "oneshot";
     ExecStart = "${pkgs.writeShellScript "deploy-notify-success" ''
       SHA=$(cat /var/lib/nixos-deploy/last-good)
       ${pkgs.libnotify}/bin/notify-send -u low "nixos-deploy" "Applied $SHA"
       sudo /run/current-system/sw/bin/rm -f /var/lib/nixos-deploy/notify-success
     ''}";
   };
   ```
   - Two path units required because systemd's `Path.PathExists=` watches a single path; merging into one watching the parent dir would re-fire on `last-good` writes too (false positives)
   - Root deploy script writes flag files; user-bus services consume them and surface via libnotify
   - **Linger prerequisite (must be added — verified empirically that linger is NOT set in current `hosts/dellan/default.nix`):**
     ```nix
     users.users.jonathan.linger = true;
     ```
     Without linger, the user systemd doesn't run before first login, so deploys before login emit no notification.
   - **Sudoers stanza (must be drafted explicitly — relying on `wheelNeedsPassword = false` couples the notification path to a global passwordless-sudo setting that may tighten later):**
     ```nix
     security.sudo.extraRules = [{
       users = [ "jonathan" ];
       commands = [
         { command = "${pkgs.coreutils}/bin/rm -f /var/lib/nixos-deploy/notify-failure"; options = [ "NOPASSWD" ]; }
         { command = "${pkgs.coreutils}/bin/rm -f /var/lib/nixos-deploy/notify-success"; options = [ "NOPASSWD" ]; }
       ];
     }];
     ```
   - Flag files in `/var/lib/nixos-deploy/` (root-writable; jonathan reads them, deletes via the sudoers-allowed `rm`)
3. **Trigger** = webhook (same Tailscale Funnel ingress). On `push: main` event, signature-verified handler issues `systemctl start nixos-deploy.service`.
4. **Concurrency:** `Conflicts=` ensures one deploy at a time. Webhook handler debounces overlapping triggers — if a deploy is in flight when another push lands, it queues a single follow-up via `systemctl start --no-block` (unit's `RefuseManualStart=no` allows queueing).
5. **No auto-rollback.** NixOS retains last 10 generations; bootloader menu and `nixos-rebuild switch --rollback` are the recovery path. Failure notification surfaces the recovery command directly to the operator.

### B.6: Bootstrap script for the deploy target

`scripts/bootstrap-deploy-target.sh` — converts the old symlinked `/etc/nixos` into a fresh root-owned clone:

```bash
#!/usr/bin/env bash
set -euo pipefail

if [ ! -L /etc/nixos ] && [ -d /etc/nixos/.git ]; then
  echo "/etc/nixos is already a real git checkout; skipping"
  exit 0
fi

# Pre-flight 1: verify origin/main builds before destroying the old layout
nix build --no-link "git+ssh://git@github.com/jonathanmoregard/nixos-config?ref=main#nixosConfigurations.dellan.config.system.build.toplevel"

# Pre-flight 2: refuse to destroy local diagnostic edits inside the existing
# /etc/nixos (mirrors C.1's bare-repo bootstrap discipline)
if [ -d /etc/nixos/.git ] || [ -L /etc/nixos ]; then
  REAL=$(readlink -f /etc/nixos)
  if [ -n "$(git -C "$REAL" status --porcelain 2>/dev/null)" ]; then
    echo "abort: $REAL has uncommitted changes; resolve before bootstrap" >&2
    git -C "$REAL" status --short >&2
    exit 1
  fi
fi

# Stop deploy timer/service to avoid a race
sudo systemctl stop nixos-deploy.service nixos-deploy.timer 2>/dev/null || true

# Clone fresh, then atomically replace
sudo git clone --branch main git@github.com:jonathanmoregard/nixos-config.git /etc/nixos.new
sudo git -C /etc/nixos.new config safe.directory /etc/nixos

# Snapshot the old symlink target before removing
if [ -L /etc/nixos ]; then
  TARGET=$(readlink /etc/nixos)
  echo "old /etc/nixos was symlink to: $TARGET"
fi
sudo rm -rf /etc/nixos       # safe: pre-flight 2 verified no uncommitted work
sudo mv /etc/nixos.new /etc/nixos

# Restart deploy
sudo systemctl start nixos-deploy.service
```
- Pre-flight 1 (build) ensures we don't strand the host on a broken commit
- Pre-flight 2 (dirty-tree) ensures manual diagnostic edits aren't silently nuked
- The `rm -rf /etc/nixos` is the only destructive action and it's predicated on both pre-flights passing

### Why this is safe without auto-rollback

Every commit on `main` already passed: eval + build + VM-minimal + VM-graphical (when relevant) + classifier. CRITICAL/HIGH bucket changes can't auto-merge — the Rulesets gate forces human review first. Only LOW/TRIVIAL deltas reach `main` unattended.

---

## Sub-spec C: Branch-test infra

### Components

1. **Worktree base:** `~/Repos/nixos-config-worktrees/<branch-slug>/`. Created via `git worktree add` on PR open / first push from an agent. Cleaned by GHA post-job + a daily cron sweep (worktrees older than 7 days, no live PR).
2. **Per-worktree `flake.lock`:** worktrees inherit lock from `main` but can diverge. Agents iterating on `nix flake update` don't poison sibling worktrees.
3. **Parallel VM lanes:**
   - GHA matrix `lane: [1, 2, 3]` → at most 3 VM tests in flight
   - Per lane: 2 cores × 4 GB (matches existing `tests/dellan-vm.nix`)
   - Total at run-time: 6 cores / 12 GB → 6c / 20 GB headroom for daily-driver
   - **Build-phase peak is higher than run-phase**: `runNixOSTest` first builds the test derivation in the sandbox (separate from the VM's own RAM). 3 concurrent builds + 3 concurrent VM-runs can transiently overlap. Empirical check before merging: `for i in 1 2 3; do nix build .#checks.x86_64-linux.dellan-vm -L --no-link & done; wait` and watch `free -m`. If peak > 28 GB, reduce concurrent lanes to 2 or stagger via systemd `Slice` accounting.
4. **Build coordination:** all worktrees share `/nix/store`. Set in NixOS config (`hosts/dellan/default.nix` or a new `modules/nixos/build-coordination.nix`):
   ```nix
   nix.settings = {
     max-jobs = 3;
     cores = 4;          # 3 × 4 = 12-thread cap
   };
   ```
   Attic deduplicates store paths across worktrees.
5. **Agent isolation primitive:** each AI agent gets one worktree. `git worktree add ... <branch>` → work inside → push. The `using-git-worktrees` skill is the standard wrapper.
6. **Test harness for the harness:** `advice-refine-test-loop` skill runs as a per-job step on PRs touching shared infra (`flake.nix`, `modules/`, `home/cinnamon.nix`).

### C.1: Repo layout enforcement (worktree-only by construction)

```
~/Repos/nixos-config/                   ← bare repo (no working tree)
~/Repos/nixos-config-worktrees/
    main/                               ← worktree for read-only browsing
    <branch-slug>/                      ← dev worktrees per branch
/etc/nixos/                             ← separate root-owned clone, deploy target
```

The bare repo means there is no `flake.nix` at `~/Repos/nixos-config/` to edit. `git worktree add` is the only way to obtain a working tree. No defensive hooks needed — workflow is enforced by construction.

**One-time conversion:** scripted in the implementation plan as `scripts/bootstrap-bare-repo.sh`. **Pre-flight refuses to proceed if any local work would be lost:**
```bash
#!/usr/bin/env bash
set -euo pipefail

OLD=~/Repos/nixos-config       # currently a symlink to /etc/nixos
ETC=/etc/nixos                 # the actual checkout
BARE=~/Repos/nixos-config

# 1. Pre-flight: refuse if uncommitted, unpushed, stashed, or untracked outside .gitignore
cd "$ETC"
if [ -n "$(git status --porcelain)" ]; then
  echo "abort: $ETC has uncommitted/untracked changes" >&2
  git status --short >&2
  exit 1
fi
if git stash list | grep -q .; then
  echo "abort: $ETC has stashed changes; pop or drop first" >&2; exit 1
fi
# Find any local branch not in origin/
local_only=$(git for-each-ref --format='%(refname:short)' refs/heads/ \
  | while read -r b; do
      git rev-parse --verify "origin/$b" >/dev/null 2>&1 || echo "$b"
    done)
if [ -n "$local_only" ]; then
  echo "abort: local-only branches not on origin (push or delete first):" >&2
  echo "$local_only" >&2; exit 1
fi
# Confirm all local branches at-or-behind their tracking branches
for b in $(git for-each-ref --format='%(refname:short)' refs/heads/); do
  if [ -n "$(git log "origin/$b..$b" --oneline 2>/dev/null)" ]; then
    echo "abort: branch $b has unpushed commits" >&2; exit 1
  fi
done

# 2. Convert. /etc/nixos is root-owned → use sudo for the destructive moves.
sudo systemctl stop nixos-deploy.service 2>/dev/null || true
git clone --bare git@github.com:jonathanmoregard/nixos-config.git ${BARE}.new
sudo rm "$OLD"   # the symlink
mv ${BARE}.new "$BARE"
git -C "$BARE" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
mkdir -p ~/Repos/nixos-config-worktrees
git -C "$BARE" worktree add ../nixos-config-worktrees/main main

# 3. /etc/nixos is now disconnected from ~/Repos. It will be reconverted in step B
#    (Production auto-deploy) into its own root-owned clone.
echo "Bare conversion done. Run B's bootstrap next to re-establish /etc/nixos."
```
Note: this script does NOT touch `/etc/nixos` directly. Sub-spec B's bootstrap (`scripts/bootstrap-deploy-target.sh`, see B.6 below) reclones `/etc/nixos` from `origin/main` as a root-owned tree, severing the old symlink relationship.

### Failure handling

- Worktree create fails → GHA job fails; agent retries with a fresh slug
- VM lane oversubscribed → GHA concurrency queues
- Stale worktree (PR closed, branch deleted) → daily systemd timer sweeps

---

## Sub-spec D: Merge classification policy

### Components

1. **Classifier script** `scripts/classify-pr.sh` — runs in the **trusted** `gate.yml` workflow (see A.3) under `pull_request_target`, **NOT** in the PR-controlled `ci.yml`. The script identity is pinned to base-branch content by either loading from a base checkout OR via `nix run github:.../nixos-config/main#classify-pr -- ...`, never from the PR branch. Two data sources are required because no single Nix command exposes both package-set deltas AND etc-tree path-prefix changes (verified empirically: `nix store diff-closures` emits package-version lines keyed by package name, e.g. `linux: 6.1 → 6.2, +12 MiB`, `unit-podman.service: ε → ∅`, `nerd-fonts-jetbrains-mono: ∅ → 3.4.0`, *not* store-path prefixes).

   **Source 1 — package-set delta:**
   ```bash
   nix store diff-closures "$base_toplevel" "$head_toplevel" > /tmp/pkg-delta.txt
   ```
   Lines are matched by package name against the `packages` rule table.

   **Source 2 — etc-tree path delta:** the system closure references an `etc` derivation as `<hash>-etc/etc`. Walk it on both sides:
   ```bash
   base_etc=$(nix-store -q --references "$base_toplevel" | grep -- '-etc$' | head -1)
   head_etc=$(nix-store -q --references "$head_toplevel" | grep -- '-etc$' | head -1)
   diff <(cd "$base_etc/etc" && find . -type f -o -type l | sort) \
        <(cd "$head_etc/etc" && find . -type f -o -type l | sort) > /tmp/etc-paths.diff
   ```
   Resulting paths matched as prefixes against the `etcPaths` rule table.

   **Source 1b — derivation churn** (closes the 3 nix-diff blind spots: kernel config flip without version bump, patches added to existing packages, build env var changes):
   ```bash
   nix-store -qR "$base_toplevel" | sort > /tmp/base-paths.txt
   nix-store -qR "$head_toplevel" | sort > /tmp/head-paths.txt
   # Strip /nix/store/<32-char-hash>- prefix to get name-version key.
   # Find name-version values present in both, then check if their hashes differ.
   ```
   Same package name+version present in both closures but with different store hash = derivation differs. Same package rule table as Source 1; matching is EXACT on the package name token (extracted by stripping the trailing `-<digits...>` from name-version). Cheaper than `nix-diff` (no derivation graph walk, no 17k-line parse), covers ~95% of risk-relevant changes.

   **Source 3 — source-tree delta** (for non-derivation files: docs, README, tests):
   ```bash
   git diff --name-only "$base_sha" "$head_sha" > /tmp/source-paths.diff
   ```

   - Inputs: `BASE_SHA`, `HEAD_SHA`
   - Step fetches `BASE_SHA` explicitly (`git fetch origin main:refs/remotes/origin/main`); `actions/checkout` only fetches PR head by default
   - Builds both `system.build.toplevel` derivations (cache-hit via Attic)
   - Runs all FOUR sources (1, 1b, 2, 3), merges results
   - **No-op short-circuit:** if all four diffs are empty (closure unchanged AND no churn AND etc-tree unchanged AND `git diff` is empty or whitespace/comment-only), classify as **TRIVIAL** without consulting the rule table. Reason: no signal at all = no risk by definition; only fall back to fail-closed MEDIUM when there's a signal we can't categorize.
   - **Fail-closed default:** if signal exists in any source but no rule matches, default = MEDIUM
   - Highest matched bucket wins (CRITICAL > HIGH > MEDIUM > LOW > TRIVIAL)
   - Emits highest bucket via `$GITHUB_OUTPUT` (modern replacement for the deprecated `::set-output`)
   - **PR comment with breakdown:** classify step posts a markdown table to the PR showing per-source contributions, so reviewers see why a bucket was chosen rather than just the verdict. A change observable in multiple sources is shown in each row that matched it; final bucket = max, not sum:
     ```
     | Source            | Matched          | Contribution |
     |-------------------|------------------|--------------|
     | diff-closures     | linux: 6.1→6.2   | CRITICAL     |
     | etc-tree paths    | (none)           | —            |
     | source-tree (git) | flake.nix        | —            |
     | **Final**         | linux is critical| **CRITICAL** |
     ```

2. **Rule table** `scripts/risk-rules.nix` — split by data source. **Matching semantics specified explicitly per source to avoid the `linux` ⊂ `linux-firmware` ambiguity:**

   ```nix
   {
     # Source 1: package names — EXACT match on the package-name token left of
     # the colon in `diff-closures` output. `linux: 6.1→6.2` matches the literal
     # string "linux", NOT "linux-firmware". Add both names if you want both.
     # DO NOT add flake.lock to trivial — closure delta is the only signal for
     # lock bumps.
     packages = {
       critical = [ "linux" "linux-firmware" "systemd-boot" "grub" "bootspec" ];
       high     = [ "openssh" "systemd" "agenix" "pam" ];
       # any package add/remove not matched above → MEDIUM
     };
     # Source 1b: agenix secret rotation appears as `*.age: ε → ∅` lines.
     # Match: filename SUFFIX `.age` on the package-name token.
     secrets = {
       high = [ ".age" ];   # rotation triggers HIGH (was CRITICAL — softened: rotation is routine)
     };
     # Source 2: paths inside the etc/ derivation. Match: PREFIX from /etc-relative
     # path. `systemd/system/` matches `systemd/system/foo.service` but NOT
     # `dbus-1/systemd/system/`.
     #
     # NOTE: bootloader/kernel risk is NOT detected here — boot.json lives at
     # /run/current-system/boot.json (not /etc), and kernel-modules at
     # /run/{current,booted}-system/kernel-modules/. Those changes surface in
     # Source 1 via the `linux`, `systemd-boot`, `grub`, `bootspec` package
     # entries. Don't add boot.json/kernel-modules to etcPaths — they would
     # be dead rules.
     etcPaths = {
       critical = [ ];   # nothing currently — bootloader/kernel covered by packages
       high     = [ "systemd/system/" "pam.d/" "sudoers" "ssh/" "shadow" "passwd" ];
       # other etc paths → MEDIUM
     };
     # Source 3: source-tree paths from `git diff --name-only`. Match: PREFIX.
     sourceTree = {
       trivial = [ "docs/" "README" "tests/baselines/" ];
       # other source paths fall through to derivation-based scoring
     };
   }
   ```

   A unit-test script `scripts/risk-rules.test.sh` is part of the implementation (currently 17 cases, all green). Test cases include:
   - `linux-firmware: 20240101 → 20240601` → CRITICAL (exact match on `linux-firmware`)
   - `util-linux: 2.39 → 2.40` → MEDIUM (no exact match on `util-linux`; falls through to default-medium)
   - `openssh: 9.0 → 9.1` → HIGH
   - `unit-podman.service: ε → ∅` → MEDIUM (no rule match → default)
   - `pam.d/sshd` → HIGH (etc path prefix match)
   - `dbus-1/systemd/system/...` → MEDIUM (etc path NOT prefix-matched by `systemd/system/`)
   - `flake.lock` only changed AND closure unchanged → TRIVIAL via no-op short-circuit
   - `flake.lock` changed AND closure shifts (e.g. nixpkgs bump) → bucket determined by closure delta, not lock file
   - **Source 1b churn cases:** `linux` churn (kernel config flip) → CRITICAL; `openssh` churn (patch without version bump) → HIGH; `bash` churn (unrelated patch) → MEDIUM default; `linux-firmware` churn (exact-match, NOT substring of `linux`) → CRITICAL; churn + version-bump multi-source → CRITICAL (max wins)

   Note: HM-managed paths under `~/.config` / `~/.local` do NOT appear in `/etc`. They live in the `home-manager-jonathan` derivation. For now, source-tree changes touching only `home/*.nix` (no resulting kernel/systemd/etc delta) classify via fall-through to closure-based scoring. If finer HM-path discrimination is needed later, add a Source 4 walking `home-manager-jonathan` outputs.
3. **Bucket → GitHub label:**

   | Bucket | Label | Effect |
   |---|---|---|
   | CRITICAL | `risk:critical` | Required fresh human reviewer + 24h cooldown |
   | HIGH | `risk:high` | Required fresh human reviewer |
   | MEDIUM | `risk:medium` | Required fresh human reviewer (default for "we don't know what this change does") |
   | LOW | `risk:low` | Auto-merge if all checks green |
   | TRIVIAL | `risk:trivial` | Auto-merge; non-essential gates skipped (eval+build still run) |
4. **AI reviewer removed (round 7).** Original spec had a Claude-Code subagent on MEDIUM-bucket PRs that could add `ai-approved` to satisfy the gate. Research surfaced multiple latent bypasses (same-vendor prompt-injection susceptibility between author and reviewer, hidden HTML-comment / invisible-char attacks, GITHUB_TOKEN abuse via injected instructions). Removed in favour of "humans gate everything ambiguous, classifier handles the deterministic cases" — simpler attack surface, same effective coverage given low-volume single-developer use.

   Dropped artifacts:
   - `ai-review` job in `gate.yml`
   - `scripts/ai-review.sh` (was placeholder)
   - `secrets/anthropic-api-key.age`
   - `ai-approved` label + label-add allowlist for it
   - Circuit-breaker logic (3-consecutive AI merges, 24h-post-failure)
   - `ai-approved-merges.jsonl` state file + tamper-detection snapshot timer

5. **Label-gate enforcement:** Rulesets cannot read PR labels directly. The `gate.yml` workflow's `label-gate` job runs on `pull_request_target: types: [opened, synchronize, reopened, labeled, unlabeled]` (the `labeled`/`unlabeled` types are required because GitHub does NOT re-trigger `pull_request_target` workflows on label changes by default). The job posts a status check `label-gate` that fails when:
   - `risk:critical`, `risk:high`, or `risk:medium` is set AND no fresh human approval (filtered by `commit_id == HEAD_SHA`), OR
   - `tests/baselines/**` changed AND `baseline:approved` label missing.

   The Ruleset requires this status check to pass — that's how labels translate into a merge gate.

6. **Label-add authorization:** the gate is only sound if labels can't be added by the same actor whose review they're supposed to gate. The `label-gate` job walks the PR's timeline every run and refuses to count any current label toward bypass if its most recent `labeled` actor is not in the allowlist:
   - `baseline:approved`: addable only by `jonathan`
   - `risk:*`: addable only by `github-actions[bot]` (set by the classifier step)

   A label added by a disallowed actor → status check fails. The `gh api .../timeline` walk is the live source of truth for audit — no separate append-only log needed (the previous round's `label-events.jsonl` was dropped because the workflow can re-derive it on demand).
7. **GitHub Rulesets** (set up by `scripts/bootstrap-rulesets.sh`, idempotent via the `PUT /repos/.../rulesets/{id}` API path).
   - **Idempotency strategy:** ruleset IDs stored in `scripts/rulesets-state.json` (committed). On bootstrap: if state file lists IDs, the script issues `PUT` to update; if missing, `POST` to create and writes back the IDs.
   - **Bootstrap order safety (lockout prevention):** Rulesets created in `enforcement: "evaluate"` mode first (dry-run; failures recorded but don't block merges). Only after the workflow has produced at least one successful run on `main` for each named status check is the ruleset flipped to `enforcement: "active"`. This sequencing prevents a misconfigured ruleset from locking out the very merges that would deploy the fix.
   - Rule 1: require PR before merging `main` — bypass actors: **none** (admins can't direct-push)
   - Rule 2: require status checks (`eval`, `build`, `vm-minimal`, `classify`, `label-gate`) — bypass actors: **[admin]** (admin can merge a failing PR via UI)
   - Rule 3: block force pushes — bypass actors: **none**
   - Rule 4: block branch deletion — bypass actors: **none**
   - Rule 5: require approval of most recent reviewable push (Rulesets native option, October 2022) — bypass actors: **none**. Belt-and-suspenders alongside the `label-gate`'s commit_id == HEAD_SHA filter.

### Why Rulesets, not legacy branch protection

Legacy branch protection's `enforce_admins` is all-or-nothing. Rulesets allow per-rule bypass actor lists, which lets us: forbid admin direct-push to `main` AND allow admin to bypass status checks via PR merge UI.

---

## Sub-spec E: VM ↔ userspace fidelity

### Tiered escalation gate

| Tier | Trigger | Wall time | Catches |
|---|---|---|---|
| **eval** | every PR + `push: main` | ~1s | Nix syntax, module-type errors |
| **build** | every PR + `push: main` | ~30s warm | Derivation compile, generated-script lint (shellcheck, flake8) |
| **VM-minimal** | every PR | ~90s warm | HM activation, systemd user units, binary presence, X session up, kitty save/restore (= existing `tests/dellan-vm.nix`) |
| **VM-graphical** | path-filter (`home/cinnamon.nix`, `modules/nixos/desktop.nix`, `home/kitty.nix`, theme files) | ~3-5min | Cinnamon panel renders, applets load, taskbar pins resolve, kitty renders glyphs (screenshot diff vs baseline) |
| **VM-realapp** | opt-in label `test:realapp`; auto-applied when classifier label is `risk:critical` or `risk:high` | ~5-10min | Chrome/Beeper/Dropbox/KeePassXC launch, autostart fires, desktop notifications work, MIME defaults route correctly |

### Documented gaps (cannot be VM-tested)

- Real GPU (intel/amd-specific rendering) — VM uses swrast/virtio
- Touchpad gestures, kernel input quirks
- LUKS unlock + bootloader interaction
- Battery / suspend / resume
- Bluetooth pairing
- WiFi with real radios (VM uses NAT)
- Sound hardware

These known gaps are accepted risk. If an issue surfaces in real use post-deploy, manual `nixos-rebuild switch --rollback` is the recovery path. No automated smoke check is wired.

### Screenshot diff baseline (VM-graphical)

- Baselines stored in `tests/baselines/<test-name>.png`, committed to repo
- Test takes scrot, runs perceptual hash diff via `imagemagick compare -metric AE -fuzz 5%`
- Threshold pass/fail; visual diff posted to PR as artifact when failing
- **Baseline drift gate:** the same PR that legitimately changes pixels also bumps baselines. To prevent silent baseline corruption, baseline file changes (any modification under `tests/baselines/`) require label `baseline:approved` on the PR. The `label-gate` workflow refuses to pass if `tests/baselines/**` changed without the label. Reviewer adds the label only after eyeballing the diff artifact.

### VM-graphical implementation

Extends `nodes.dellan` block in `tests/dellan-vm.nix` (or splits into `tests/dellan-vm-graphical.nix`) — drives `xdotool` / `kitty @` to open windows, take screenshots, compare. Boilerplate lives in `tests/lib/screenshot.nix` to keep test files focused.

---

## Secrets (consolidated; all live in `secrets/` via agenix)

| File | Used by | Purpose |
|---|---|---|
| `secrets/github-webhook-secret.age` | `github-webhook.service` (A.2 / B.3) | HMAC verifies incoming webhooks |
| `secrets/deploy-ssh-key.age` | `nixos-deploy.service` (B) | SSH key the deploy unit uses to `git fetch origin main`. Public key registered in GitHub Deploy Keys for the repo. |
| `secrets/gh-janitor-token.age` | janitor cron `gh run cancel` (A.6) | Personal Access Token (or fine-grained app token) with `actions:write` scope to cancel stale jobs. Mounted as `EnvironmentFile=` (KEY=VALUE format: `GH_TOKEN=ghp_...`) on the timer-triggered cleanup unit. |

[OBSOLETE-2026-05-05] removed entries: `github-runner-token.age` (no self-hosted runner), `actions-runner-ssh-key.age` (renamed to `deploy-ssh-key.age` after the runner moved to GHA-hosted), `atticd-runner-token.age` + `atticd-jonathan-token.age` + `atticd-rs256-secret.age` (no Attic).

All keys must be added to `secrets/secrets.nix` `allKeys` list. CI keys are runner-host-bound (`age.secrets.<name>.publicKeys = [ jonathanKey dellanHostKey ];`) so a leaked key from one workstation doesn't auto-decrypt on other machines.

## Inter-section dependencies

- B trusts A (no auto-deploy until CI signal exists)
- C runs on A (worktree-aware GHA jobs)
- D is a step inside A's workflow
- E is a tier configuration consumed by A
- All five compose into the umbrella; each implementable in isolation given A's primitives

## Threat model assumptions

- **Repo is private; single-developer.** Fork PRs are NOT supported; `pull_request` events from forks are out of scope. If forks are accepted later, the trust split (A.3 `ci.yml` vs `gate.yml`) already handles it correctly — the merge-gating logic is in `pull_request_target` which doesn't run fork-controlled code.
- **Trusted actors:** `jonathan` (admin), `github-actions[bot]` (only when running base-branch workflow code via `pull_request_target`). AI agents working on PRs run AS PR contributors — their workflow code is untrusted and runs only in `ci.yml`.
- **Critical: AI agents must NOT have GitHub credentials authenticated as `jonathan`.** The current `gh` wrapper in `home/jonathan.nix` auto-runs `gh auth login` for the user; an AI agent with shell access in a worktree could otherwise call `gh pr review --approve <its-own-PR>` and bypass the entire human-review gate (since admin is in the bypass list for status checks). Mitigation, **declared as part of this spec's required changes**:
  1. AI agents run under a **dedicated unprivileged user `claude-agent`** (or per-agent users `claude-agent-{1,2,3}`), with no `gh` token in their HOME, no membership in `wheel`, no sudo access.
  2. The shared bare repo `~/Repos/nixos-config` and worktree directory `~/Repos/nixos-config-worktrees/` are group-readable (`jonathan:claude-agents` 0775), so agents can read/clone/edit their own worktree but cannot push as `jonathan`. Agents push using their own SSH key with `repo:write` scope only (no admin, no PR-merge approval).
  3. The `gh` wrapper at `home/jonathan.nix:130-135` is moved out of the per-user shell init into a dedicated wrapper that's only on `jonathan`'s PATH, never on `claude-agent`'s PATH.
  4. As an additional belt: the `ai-approved` label-add allowlist (D.4) restricts to `github-actions[bot]` only — `jonathan` cannot add the label manually. So even if a Claude agent somehow gets `jonathan` credentials, it cannot use them to short-circuit AI-review.
- **Out-of-scope threats:** physical access to dellan, kernel-level compromise, supply-chain attacks on nixpkgs/flake inputs (mitigated by `nix.settings.trusted-public-keys` but not by anything in this spec).

## Out of scope for this spec

- Multi-host CI matrix beyond Linux (mac-mini darwin support — re-enable when mac-mini arrives; auto-discovery already accommodates)
- Hydra-style build farm (overkill for one developer)
- Custom approval UI (GitHub Rulesets cover this)
- Real-hardware test bed (no second machine)
- Migration of MCP server / dotfile repos to the same workflow (separate spec if needed)

## Implementation order (for the implementation plan)

Each step is annotated `[auto]` (Claude can do start-to-finish in one autonomous session), `[human]` (needs a token registration, GitHub UI step, or one-time interactive bootstrap), or `[human-checkpoint]` (an autonomous run must STOP here and wait for explicit user confirmation before proceeding). Reordered to put Rulesets activation AFTER the workflow has produced its first green run on `main`, preventing lockout.

1. **A.1 [OBSOLETE-2026-05-05]** Self-hosted runner. Replaced by GHA-hosted runners on `ubuntu-latest` declared directly in `.github/workflows/ci.yml` + `gate.yml`. No registration token, no agenix entry.
2. **A.2 [OBSOLETE-2026-05-05]** Attic cache. Replaced by `nix-community/cache-nix-action@v6` per workflow + `cache.nixos.org` upstream. No NixOS module, no pub-key bootstrap.
3. **A.3 (`ci.yml` only first)** Skeleton workflow with `eval` + `build` + existing VM-minimal — `[auto]`
4. **(Bootstrap snapshot before destructive steps)** `sudo cp -a /etc/nixos /etc/nixos.bak.$(date +%s)` — `[auto]`. Documented recovery: `sudo rm -rf /etc/nixos && sudo mv /etc/nixos.bak.<timestamp> /etc/nixos`.
5. **C.1** Bare-repo conversion + worktree directory — `[human]` (destructive on `~/Repos/nixos-config`; pre-flight asserts no unpushed work, but operator should review before running). On failure: pre-flight refuses; on partial success without B-bootstrap, recover via step 4's snapshot.
6. **B (deploy target only, no activation yet)** `bootstrap-deploy-target.sh` clones `/etc/nixos` from main (without enabling the auto-deploy service) — `[human]`. On failure: recover via step 4's snapshot.
7. **B** Production auto-deploy service + flag-file notification chain (linger, sudoers, two path units) — `[auto]` after step 6
8. **A.6** Webhook ingress over Tailscale Funnel — `[human]` (Funnel hostname + GitHub webhook URL must be configured via `tailscale funnel` and GitHub `Settings → Webhooks`)
9. **D.1** Classifier script + rule table + classifier unit tests — `[auto]`
10. **A.3 (`gate.yml`)** Add gate workflow (`pull_request_target`, classifier, label-pr) — `[auto]`
11. **A.5** `ci.yml` extends to discover-hosts matrix + lanes — `[auto]`
12. **`[human-checkpoint]`** STOP. Wait for at least one green run of all named status checks on `main` (eval, build, vm-minimal, classify, label-gate). An autonomous implementer MUST NOT proceed past this checkpoint without explicit user confirmation; doing so risks locking out merges if the next step's Rulesets reference a status check that hasn't produced a check-run yet.
13. **D.2** Bootstrap script for Rulesets, in `enforcement: "evaluate"` mode first — `[human]` (PAT with `repo:admin` for ruleset CRUD)
14. **D.2 (active)** Flip Rulesets to `enforcement: "active"` once verified — `[human-checkpoint]` (verifies dry-run results match expectations before activation)
15. **E.1** VM-graphical tier + screenshot baseline scaffolding — `[auto]`
16. **claude-agent** user split + gh-wrapper PATH scoping (threat model) — `[auto]`
17. **E.2** VM-realapp tier (opt-in) — `[auto]`

Each `[auto]` step has a VM-gateable check. `[human]` steps are tokens / interactive bootstrap; the implementation plan documents the exact UI clicks. `[human-checkpoint]` steps are mandatory stops where autonomous implementation must pause for user confirmation. Spec'd steps map 1:1 to plan items.
