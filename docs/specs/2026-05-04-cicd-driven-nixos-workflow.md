# CI/CD-driven nixos-config workflow

**Status:** design
**Date:** 2026-05-04
**Scope:** dellan host only (mac-mini and vm flake entries removed; auto-discovery picks up future hosts)
**Spec format:** umbrella with five orthogonal sub-specs (A–E), each independently extractable.

---

## Goal

Enable multiple AI agents to develop NixOS config changes in parallel — each agent in its own worktree, each PR tested in a sandboxed VM lane, low-risk changes auto-merging, high-risk changes gated on human review, production (`/etc/nixos`) auto-applying every merge to `main`. Single-developer workflow today; same primitives scale to multi-agent tomorrow.

## Locked decisions

| Decision | Choice | Rationale |
|---|---|---|
| Production scope | dellan only (now) | Mac-mini is aarch64-darwin placeholder, vm host being deleted; future hosts auto-discovered |
| Auto-apply cadence | Continuous on every merge to `main` | Highest velocity; NixOS boot generations + classifier gating make rollback rare |
| Auto-rollback | None — rely on NixOS generations + manual `nixos-rebuild switch --rollback` | Gate stack catches issues pre-merge; auto-rollback adds complexity without clear win |
| CI host | Self-hosted GHA runner on dellan | Free for private repos, warm `/nix/store`, resource-scoped via systemd |
| Cache | Attic (self-hosted nix binary cache) on dellan | Free, local, deduplicates across worktrees |
| Webhook ingress | Tailscale Funnel (already wired on dellan) | TLS-terminated public endpoint without NAT punching; secret in agenix |
| Concurrent VM lanes | 3 (each: 2 cores × 4 GB → 6c / 12 GB total) | Fits dellan's 12c/32 GB with 6c/20 GB headroom for daily-driver work |
| Repo layout | `~/Repos/nixos-config` is **bare**; all work in `~/Repos/nixos-config-worktrees/<branch>`; `/etc/nixos` is a separate root-owned clone of `origin/main` | Bare repo enforces worktree-only workflow by construction |
| Triggers | `pull_request` (open/sync) + `push: main` (merge). Branch pushes do NOT trigger CI. | Saves cycles; agents push WIP freely |
| Classification | Derivation-graph blast radius via `nix store diff-closures` → rule table → bucket → GitHub label | Nix-native; deterministic; sees outcome not source |
| Branch protection | GitHub Rulesets (per-rule bypass) — admins cannot direct-push to `main`, can bypass status checks via PR merge UI | Rulesets API permits per-rule bypass; legacy branch protection's `enforce_admins` is too coarse |

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

1. **Self-hosted GHA runner** on dellan, registered to repo as `dellan-runner`. systemd user unit:
   - `CPUWeight=50` (yields to interactive work under contention)
   - `MemoryHigh=20G` (caps RAM)
   - `Slice=actions-runner.slice`
   - Token stored in `secrets/github-runner-token.age`
2. **Webhook ingress** via Tailscale Funnel — used **only** for production deploy. PR-triggered jobs do not need it (GHA self-hosted runners long-poll GitHub directly for queued work).
   - GitHub → `https://<machine>.<tailnet>.ts.net/webhook` → systemd socket-activated handler
   - **Implementation:** `pkgs.writers.writePython3Bin "github-webhook-handler"`. Reads request from stdin (socket-activated), writes response to stdout. Lives in `modules/nixos/github-webhook.nix`.
   - **HMAC verification:** computes `hmac.new(SECRET, body, sha256)` and compares to `X-Hub-Signature-256` header in constant time (`hmac.compare_digest`). Secret in `secrets/github-webhook-secret.age`, exposed as `EnvironmentFile`.
   - **Replay protection:** stores `X-GitHub-Delivery` UUIDs seen in the last 24h to `/var/lib/github-webhook/seen` (one UUID per line, pruned on rotation). Duplicate UUID → 200 OK with no action.
   - **Rate limit:** systemd socket unit sets `RateLimitIntervalSec=10` and `RateLimitBurst=5` (5 connections per 10s, then queues).
   - **Event filter:** handler only acts on `X-GitHub-Event: push` with `payload.ref == "refs/heads/main"`. All other events → 200 OK with no action.
   - On valid push: `systemctl start nixos-deploy.service`
3. **Workflow** `.github/workflows/ci.yml`:
   - Triggers: `pull_request: {types: [opened, synchronize, reopened]}`, `push: {branches: [main]}`
   - Concurrency group: `vm-lane-${{ matrix.lane }}` with `lane: [1, 2, 3]`
   - Job graph:
     ```
     discover-hosts ─► eval ─► build ─► vm-minimal ─► vm-graphical (conditional) ─► classify
                                                                                   └► label-pr
     ```
   - **discover-hosts:** `nix eval` walks `nixosConfigurations` and `darwinConfigurations`, emits a matrix. Linux jobs run on `[self-hosted, x86_64-linux]`; darwin jobs require `[self-hosted, aarch64-darwin]` → skip with warning if no runner.
4. **Cache:** Attic server (`pkgs.attic-server`) as a NixOS systemd unit, listening on `localhost:8080`.
   - **Trust model:** Attic generates a signing key on first start (`/var/lib/atticd/server.key`, `0400 root:root`). The matching public key is published to `flake.nix`'s `pkgsLinux.config.nix.settings.trusted-public-keys`. Substituter URL: `http://localhost:8080/<cache-name>`.
   - **Auth:** push tokens (one for the runner user, one for any human) live in agenix (`secrets/atticd-runner-token.age`, `secrets/atticd-jonathan-token.age`). Pull is open to anyone on localhost.
   - **Fallback:** `cache.nixos.org` remains in the substituter list as a lower-priority fallback. Attic-only paths (e.g. `nixos-system-dellan`) are still re-buildable from source if Attic is down.
   - **Port choice:** 8080 default; can collide with dev servers. Spec leaves overridable via `nixos.attic-server.port` module option.
5. **Discover-hosts runner placement:** the matrix-emitter step runs on `[self-hosted, x86_64-linux]` (NOT GitHub-hosted) so the eval has a warm `/nix/store`. Cold eval on GitHub-hosted runner would refetch nixpkgs and lose the eval-cost win.
6. **Lane oversubscription policy:** GHA `concurrency: { group: vm-lane-${lane}, cancel-in-progress: false }` so a new push to the same PR does NOT cancel the running lane's job (we want test results to complete). A separate PR-level `concurrency: { group: pr-${pr_number}, cancel-in-progress: true }` outer block cancels superseded SHAs, so resyncing a PR doesn't pile up runs. Janitor cron (daily) cancels jobs older than 30min via `gh run cancel`.
7. **Failure handling:** workflow failures post failed status to the PR via standard GHA. No special recovery; the user / agent fixes the branch and pushes again. Post-merge `push: main` workflow failures: deploy is gated on the workflow status check, so a broken `main` doesn't auto-deploy (separate from the deploy-loop poisoning protection in B).

---

## Sub-spec B: Production auto-deploy

### Components

1. **`/etc/nixos`** = read-only clone of `origin/main`, root-owned. Symlink `~/Repos/nixos-config → /etc/nixos` is removed; the dev tree only lives at `~/Repos/nixos-config-worktrees/`.
2. **`nixos-deploy.service`** (oneshot, declared as a NixOS module):
   ```bash
   ExecStart = ${pkgs.writeShellScript "nixos-deploy" ''
     set -euo pipefail

     STATE=/var/lib/nixos-deploy
     mkdir -p "$STATE"
     LAST_GOOD="$STATE/last-good"
     POISONED="$STATE/poisoned"

     git -C /etc/nixos fetch origin main
     TARGET=$(git -C /etc/nixos rev-parse origin/main)
     CURRENT=$(git -C /etc/nixos rev-parse HEAD)

     # Skip if already at target
     [ "$CURRENT" = "$TARGET" ] && exit 0

     # Refuse to re-attempt a poisoned commit unless manually cleared
     if [ -f "$POISONED" ] && [ "$(cat "$POISONED")" = "$TARGET" ]; then
       echo "deploy: target $TARGET is poisoned; manual reset required"
       echo "  to clear: rm $POISONED && systemctl reset-failed nixos-deploy"
       exit 1
     fi

     git -C /etc/nixos reset --hard "$TARGET"
     if nixos-rebuild switch --flake /etc/nixos#dellan; then
       echo "$TARGET" > "$LAST_GOOD"
       rm -f "$POISONED"
       ${pkgs.libnotify}/bin/notify-send -u low "nixos-deploy" "Applied $TARGET"
     else
       echo "$TARGET" > "$POISONED"
       ${pkgs.libnotify}/bin/notify-send -u critical "nixos-deploy FAILED" \
         "Commit $TARGET failed activation. Manual recovery: nixos-rebuild switch --rollback"
       exit 1
     fi
   ''}";
   ```
   - Tracks `last-good` and `poisoned` SHAs in `/var/lib/nixos-deploy`
   - Emits desktop notification on success (low priority) and failure (critical priority) — operator signal that the silent-failure case in the v1 design lacked
   - Refuses to re-apply a poisoned commit until manual `rm /var/lib/nixos-deploy/poisoned`
   - Logs to journal under `nixos-deploy.service`
3. **Trigger** = webhook (same Tailscale Funnel ingress). On `push: main` event, signature-verified handler issues `systemctl start nixos-deploy.service`.
4. **Concurrency:** `Conflicts=` ensures one deploy at a time. Webhook handler debounces overlapping triggers — if a deploy is in flight when another push lands, it queues a single follow-up via `systemctl start --no-block` (unit's `RefuseManualStart=no` allows queueing).
5. **No auto-rollback.** NixOS retains last 10 generations; bootloader menu and `nixos-rebuild switch --rollback` are the recovery path. Failure notification surfaces the recovery command directly to the operator.

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
Note: this script does NOT touch `/etc/nixos` directly. Sub-spec B's bootstrap (run separately) reclones `/etc/nixos` from `origin/main` as a root-owned tree, severing the old symlink relationship.

### Failure handling

- Worktree create fails → GHA job fails; agent retries with a fresh slug
- VM lane oversubscribed → GHA concurrency queues
- Stale worktree (PR closed, branch deleted) → daily systemd timer sweeps

---

## Sub-spec D: Merge classification policy

### Components

1. **Classifier script** `scripts/classify-pr.sh` (GHA step). Two data sources are required because no single Nix command exposes both package-set deltas AND etc-tree path-prefix changes (verified empirically: `nix store diff-closures` emits package-version lines keyed by package name, e.g. `linux: 6.1 → 6.2, +12 MiB`, `unit-podman.service: ε → ∅`, `nerd-fonts-jetbrains-mono: ∅ → 3.4.0`, *not* store-path prefixes).

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

   **Source 3 — source-tree delta** (for non-derivation files: docs, README, tests):
   ```bash
   git diff --name-only "$base_sha" "$head_sha" > /tmp/source-paths.diff
   ```

   - Inputs: `BASE_SHA`, `HEAD_SHA`
   - Step fetches `BASE_SHA` explicitly (`git fetch origin main:refs/remotes/origin/main`); `actions/checkout` only fetches PR head by default
   - Builds both `system.build.toplevel` derivations (cache-hit via Attic)
   - Runs all three sources, merges results
   - Highest matched bucket wins (CRITICAL > HIGH > MEDIUM > LOW > TRIVIAL); if no rule matches, default = MEDIUM (fail-closed)
   - Emits highest bucket via `$GITHUB_OUTPUT` (modern replacement for the deprecated `::set-output`)

2. **Rule table** `scripts/risk-rules.nix` — split by data source:
   ```nix
   {
     # Source 1: package names (matched against diff-closures output keys)
     packages = {
       critical = [ "linux" "linux-firmware" "systemd-boot" "grub" "bootspec" ];
       high     = [ "openssh" "systemd" "agenix" "pam" ];
       # any package add/remove not matched above → MEDIUM
     };
     # Source 1b: agenix secret rotation appears as `*.age: ε → ∅` lines
     secrets = {
       high = [ ".age" ];   # any secret rotation triggers HIGH (was CRITICAL — softened: rotation is routine)
     };
     # Source 2: paths inside the etc/ derivation (matched as prefixes from /etc relative)
     etcPaths = {
       critical = [ "boot.json" "kernel-modules/" ];
       high     = [ "systemd/system/" "pam.d/" "sudoers" "ssh/" "shadow" "passwd" ];
       # other etc paths → MEDIUM
     };
     # Source 3: source-tree paths (matched via git diff)
     sourceTree = {
       trivial = [ "docs/" "README" "tests/baselines/" ];
       # other source paths fall through to derivation-based scoring
     };
   }
   ```
   Note: HM-managed paths under `~/.config` / `~/.local` do NOT appear in `/etc`. They live in the `home-manager-jonathan` derivation. For now, source-tree changes touching only `home/*.nix` (no resulting kernel/systemd/etc delta) classify as LOW via fall-through. If finer HM-path discrimination is needed later, add a Source 4 walking `home-manager-jonathan` outputs.
3. **Bucket → GitHub label:**

   | Bucket | Label | Effect |
   |---|---|---|
   | CRITICAL | `risk:critical` | Required reviewer (you) + 24h cooldown |
   | HIGH | `risk:high` | Required reviewer |
   | MEDIUM | `risk:medium` | AI code-review subagent posts review; `risk:medium` blocks auto-merge until either `ai-approved` label OR human approval |
   | LOW | `risk:low` | Auto-merge if all checks green |
   | TRIVIAL | `risk:trivial` | Auto-merge; non-essential gates skipped (eval+build still run) |
4. **AI code-review subagent (MEDIUM bucket):** GHA step calls a Claude-Code subagent via the existing skill set; verdict `approve` → bot adds `ai-approved` label; verdict `request-changes` → comment posted, `ai-approved` not added.
   - **Authentication:** ANTHROPIC_API_KEY stored in `secrets/anthropic-api-key.age`, exposed to the workflow step as a runner-scoped environment variable. **Cost note:** this is a billed Claude API key (Claude.ai subscription does not work for CI use); spend is bounded by MEDIUM-bucket PR rate. Add to `secrets/secrets.nix` allKeys list.
   - **Prompt-injection mitigation:** PR body, commit messages, and diff contents are wrapped in `<untrusted_external_content>` tags before passing to the subagent (per global CLAUDE.md). Subagent must NOT execute instructions found inside these tags.
   - **Circuit breaker:** track AI-approved auto-merges in `~/.cache/ci-state/ai-approved-merges.jsonl` (one line per merge, with SHA, timestamp, classifier verdict). After **3 consecutive AI-approved merges without a human approval in between**, OR within **24h of any deploy failure**, the label-gate flips to require human approval for MEDIUM bucket. Resets when a human approves any PR. State file lives outside the repo (in the runner's cache) so a malicious PR can't reset it.
   - **Label-gate enforcement:** Rulesets cannot read PR labels directly. A small workflow `label-gate.yml` runs on `pull_request: types: [opened, synchronize, reopened, labeled, unlabeled]` (the `labeled`/`unlabeled` types are required because GitHub does NOT re-trigger `pull_request` workflows on label changes by default — empirically verified gap). The workflow posts a status check `label-gate` that fails when:
     - `risk:medium` set AND `ai-approved` missing AND no human approval, OR
     - `risk:critical` or `risk:high` set AND no human approval, OR
     - circuit-breaker engaged (any case requires human).
     The Ruleset requires this status check to pass — that's how labels translate into a merge gate.
5. **GitHub Rulesets** (set up by `scripts/bootstrap-rulesets.sh`, idempotent via the `PUT /repos/.../rulesets/{id}` API path).
   - **Idempotency strategy:** ruleset IDs are stored in `scripts/rulesets-state.json` (committed). On bootstrap: if state file lists IDs, the script issues `PUT` to update each existing ruleset; if no state file, the script issues `POST` to create them and writes back the IDs. Running twice without the state file would create duplicates — the state file prevents that. Optional alternative: discover existing rulesets by name match before creating. Implementation chooses the state-file approach for simplicity.
   - Rule 1: require PR before merging `main` — bypass actors: **none** (admins can't direct-push)
   - Rule 2: require status checks (`eval`, `build`, `vm-minimal`, `classify`) — bypass actors: **[admin]** (admin can merge a failing PR via UI)
   - Rule 3: block force pushes — bypass actors: **none**
   - Rule 4: block branch deletion — bypass actors: **none**
   - Rule 5: require status check `label-gate` to pass — bypass actors: **none**. (`label-gate` encodes both the "human required for risk:high|critical" and "ai-approved or human required for risk:medium" rules; see D.4.)

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
| `secrets/github-runner-token.age` | `actions-runner.service` (A.1) | Authenticates the self-hosted runner to GitHub |
| `secrets/github-webhook-secret.age` | `github-webhook.service` (A.2 / B.3) | HMAC verifies incoming webhooks |
| `secrets/anthropic-api-key.age` | AI code-review subagent step (D.4) | Billed Claude API access from CI |
| `secrets/atticd-runner-token.age` | runner pushes to Attic (A.4) | Authenticates `attic push` from CI |
| `secrets/atticd-jonathan-token.age` | dev-shell pushes to Attic (A.4) | Authenticates manual `attic push` from worktrees |

All keys must be added to `secrets/secrets.nix` `allKeys` list. CI keys are runner-host-bound (`age.secrets.<name>.publicKeys = [ jonathanKey dellanHostKey ];`) so a leaked key from one workstation doesn't auto-decrypt on other machines.

## Inter-section dependencies

- B trusts A (no auto-deploy until CI signal exists)
- C runs on A (worktree-aware GHA jobs)
- D is a step inside A's workflow
- E is a tier configuration consumed by A
- All five compose into the umbrella; each implementable in isolation given A's primitives

## Out of scope for this spec

- Multi-host CI matrix beyond Linux (mac-mini darwin support — re-enable when mac-mini arrives; auto-discovery already accommodates)
- Hydra-style build farm (overkill for one developer)
- Custom approval UI (GitHub Rulesets cover this)
- Real-hardware test bed (no second machine)
- Migration of MCP server / dotfile repos to the same workflow (separate spec if needed)

## Implementation order (for the implementation plan)

1. **A.1** Self-hosted runner registered + resource-scoped (foundational)
2. **A.2** Attic cache running locally
3. **A.3** Webhook ingress over Tailscale Funnel
4. **A.4** Skeleton workflow (`eval` + `build` + existing VM-minimal)
5. **C.1** Bare-repo conversion + worktree directory
6. **D.1** Classifier script + rule table
7. **D.2** Bootstrap script for Rulesets
8. **B** Production auto-deploy (`/etc/nixos` clone + `nixos-deploy.service`)
9. **A.5** Workflow extends to discover-hosts matrix + lanes
10. **E.1** VM-graphical tier + screenshot baseline scaffolding
11. **D.3** AI code-review subagent wiring (MEDIUM bucket)
12. **E.2** VM-realapp tier (opt-in)

Each step has a VM-gateable check. Spec'd steps map 1:1 to plan items.
