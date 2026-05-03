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
2. **Webhook ingress** via Tailscale Funnel:
   - GitHub → `https://<machine>.<tailnet>.ts.net/webhook` → systemd socket-activated handler
   - HMAC signature verified using secret in `secrets/github-webhook-secret.age`
   - Handler dispatches: `pull_request.{opened,synchronize}` → no-op (GHA listens directly), `push: main` → `systemctl start nixos-deploy.service`
3. **Workflow** `.github/workflows/ci.yml`:
   - Triggers: `pull_request: {types: [opened, synchronize, reopened]}`, `push: {branches: [main]}`
   - Concurrency group: `vm-lane-${{ matrix.lane }}` with `lane: [1, 2, 3]`
   - Job graph:
     ```
     discover-hosts ─► eval ─► build ─► vm-minimal ─► vm-graphical (conditional) ─► classify
                                                                                   └► label-pr
     ```
   - **discover-hosts:** `nix eval` walks `nixosConfigurations` and `darwinConfigurations`, emits a matrix. Linux jobs run on `[self-hosted, x86_64-linux]`; darwin jobs require `[self-hosted, aarch64-darwin]` → skip with warning if no runner.
4. **Cache:** Attic server as a NixOS systemd unit, listening on `localhost:8080`. Configured as substituter in `flake.nix`'s `pkgsLinux`. All workflow runs read/write through it.
5. **Failure handling:** workflow failures post failed status to the PR via standard GHA. No special recovery; the user / agent fixes the branch and pushes again.

---

## Sub-spec B: Production auto-deploy

### Components

1. **`/etc/nixos`** = read-only clone of `origin/main`, root-owned. Symlink `~/Repos/nixos-config → /etc/nixos` is removed; the dev tree only lives at `~/Repos/nixos-config-worktrees/`.
2. **`nixos-deploy.service`** (oneshot, declared as a NixOS module):
   ```
   ExecStart =
     git -C /etc/nixos fetch origin main
     && git -C /etc/nixos reset --hard origin/main
     && nixos-rebuild switch --flake /etc/nixos#dellan
   ```
   Logs to journal.
3. **Trigger** = webhook (same Tailscale Funnel ingress). On `push: main` event, signature-verified handler issues `systemctl start nixos-deploy.service`.
4. **Concurrency:** `Conflicts=` ensures one deploy at a time. Webhook handler debounces overlapping triggers — if a deploy is in flight when another push lands, it queues a single follow-up.
5. **No auto-rollback.** NixOS retains last 10 generations; bootloader menu and `nixos-rebuild switch --rollback` are the recovery path.

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
   - Total: 6 cores / 12 GB → 6c / 20 GB headroom for daily-driver
4. **Build coordination:** all worktrees share `/nix/store`. Nix daemon: `max-jobs = 3`, `cores = 4` per build → 12-thread cap. Attic deduplicates store paths across worktrees.
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

**One-time conversion:** scripted in the implementation plan as `scripts/bootstrap-bare-repo.sh`:
```
git clone --bare git@github.com:jonathanmoregard/nixos-config.git ~/Repos/nixos-config-bare
mv ~/Repos/nixos-config{,.old}
mv ~/Repos/nixos-config-bare ~/Repos/nixos-config
git -C ~/Repos/nixos-config config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
git -C ~/Repos/nixos-config worktree add ../nixos-config-worktrees/main main
```

### Failure handling

- Worktree create fails → GHA job fails; agent retries with a fresh slug
- VM lane oversubscribed → GHA concurrency queues
- Stale worktree (PR closed, branch deleted) → daily systemd timer sweeps

---

## Sub-spec D: Merge classification policy

### Components

1. **Classifier script** `scripts/classify-pr.sh` (GHA step):
   - Inputs: `BASE_REF` (default `main`), `HEAD_REF` (PR head)
   - Builds both `system.build.toplevel` derivations (cache-hit via Attic)
   - Runs `nix store diff-closures $base $head`
   - Maps changed paths → bucket via declarative rule table
   - Emits highest bucket as `::set-output name=risk::<bucket>`
2. **Rule table** `scripts/risk-rules.nix`:
   ```nix
   {
     critical = [
       "boot/" "kernel-" "initrd-" "systemd-boot" "grub" "bootspec"
     ];
     high = [
       "etc/systemd/system/" "etc/pam.d/" "etc/sudoers" "etc/ssh/"
       "openssh-" "agenix-" "secrets-"
     ];
     medium-by-pattern = [ "added-pkg" "removed-pkg" ];
     low = [ "home/jonathan/.config/" "home/jonathan/.local/" ];
     trivial = [ "docs/" "README" "tests/" "comments-only" ];
   }
   ```
3. **Bucket → GitHub label:**

   | Bucket | Label | Effect |
   |---|---|---|
   | CRITICAL | `risk:critical` | Required reviewer (you) + 24h cooldown |
   | HIGH | `risk:high` | Required reviewer |
   | MEDIUM | `risk:medium` | AI code-review subagent posts review; `risk:medium` blocks auto-merge until either `ai-approved` label OR human approval |
   | LOW | `risk:low` | Auto-merge if all checks green |
   | TRIVIAL | `risk:trivial` | Auto-merge; non-essential gates skipped (eval+build still run) |
4. **AI code-review subagent (MEDIUM bucket):** GHA step calls a Claude-Code subagent via the existing skill set; verdict `approve` → bot adds `ai-approved` label; verdict `request-changes` → comment posted, `ai-approved` not added. Branch protection consumes the label.
5. **GitHub Rulesets** (set up by `scripts/bootstrap-rulesets.sh`, idempotent):
   - Rule 1: require PR before merging `main` — bypass actors: **none** (admins can't direct-push)
   - Rule 2: require status checks (`eval`, `build`, `vm-minimal`, `classify`) — bypass actors: **[admin]** (admin can merge a failing PR via UI)
   - Rule 3: block force pushes — bypass actors: **none**
   - Rule 4: block branch deletion — bypass actors: **none**
   - Rule 5: require reviewers when label `risk:critical|high` is present — bypass actors: **none**
   - Rule 6: require label `ai-approved` OR human reviewer when `risk:medium` — bypass actors: **none**

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
| **VM-realapp** | opt-in label `test:realapp`; auto on `risk:high`+ | ~5-10min | Chrome/Beeper/Dropbox/KeePassXC launch, autostart fires, desktop notifications work, MIME defaults route correctly |

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

### VM-graphical implementation

Extends `nodes.dellan` block in `tests/dellan-vm.nix` (or splits into `tests/dellan-vm-graphical.nix`) — drives `xdotool` / `kitty @` to open windows, take screenshots, compare. Boilerplate lives in `tests/lib/screenshot.nix` to keep test files focused.

---

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
