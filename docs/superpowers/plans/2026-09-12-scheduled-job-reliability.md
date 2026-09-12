# Scheduled Job Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (default) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace quota-dependent drift analysis and unsafe local-main pulling with deterministic, observable systemd jobs, then remove obsolete Mint schedule.

**Architecture:** `home/drift-analyzer.nix` becomes offline invariant checker with atomic report publication. New `home/nixos-config-fetch.nix` updates only `origin/main` and publishes success heartbeat. Both jobs use user timers and `OnFailure` notification services; worktree guidance bases branches on `origin/main`.

**Tech Stack:** Nix flakes, Home Manager, generated Bash, systemd user units, Git, NixOS Python VM tests.

---

## File Map

- `home/drift-analyzer.nix`: deterministic probes, atomic output, heartbeat, notification, timer.
- `home/nixos-config-fetch.nix`: fetch-only runner, heartbeat, notification, timer.
- `home/jonathan-linux.nix`: module import and obsolete cron removal.
- `tests/base.nix`: runtime and unit-wiring assertions.
- `CLAUDE.md`, managed skill files, and `home/jonathan.nix`: `origin/main` workflow.

### Task 1: Deterministic drift analyzer

**Files:**
- Modify: `tests/base.nix`
- Modify: `home/drift-analyzer.nix`

- [ ] **Step 1: Write failing VM assertions**

Inspect rendered service and installed runner:

```python
assert "OnFailure=nixos-drift-analyzer-failure-notify.service" in drift_service
assert "claude" not in drift_runner.lower()
```

Create fixture HOME, deployed Git checkout, declarative and installed crontabs, fake `nix-env`, and bare repo with two forced `main` worktrees. Invoke runner with `NIXOS_DRIFT_*` overrides. Assert report names imperative package, unmanaged binary, crontab mismatch, dirty deployed checkout, and duplicate-main topology. Assert `last-success` exists.

Seed `latest.md` with `last-good`, make fake `nix-env` exit 23, invoke runner, then assert exit 23, unchanged report, and unchanged heartbeat.

Set same failing override in user systemd manager environment, start rendered
service, and poll notifier journal for `NixOS drift analyzer failed` marker.

- [ ] **Step 2: Run RED gate**

Run `nix build --no-link .#checks.x86_64-linux.vm-base -L`.

Expected: FAIL because current runner invokes Claude and lacks fixture seams, atomic publication, and notifier.

- [ ] **Step 3: Implement minimal runner**

Use `pkgs.writeShellApplication` with `coreutils`, `findutils`, `git`, `gnugrep`, `gnused`, and `nix`. Add overridable command/path seams with production defaults. Gather each deterministic finding without mutation. Preserve exact probe exit codes.

Create temporary report beside `latest.md`; publish through `mv` only after all probes finish. Atomically write XDG-state `last-success`. Add failure notifier, connect `Unit.OnFailure`, retain hourly persistent timer, and install runner in `home.packages`.

- [ ] **Step 4: Run GREEN gate**

Run same `vm-base` command. Expected: PASS with findings, failure preservation, timer, and notifier proven.

- [ ] **Step 5: Commit**

Stage `home/drift-analyzer.nix` and `tests/base.nix`; commit as `fix(drift): replace hourly model analysis with invariant checks`.

### Task 2: Fetch-only refresh and Mint removal

**Files:**
- Create: `home/nixos-config-fetch.nix`
- Modify: `home/jonathan-linux.nix`
- Modify: `tests/base.nix`

- [ ] **Step 1: Write failing VM assertions**

Assert declarative crontab contains neither `mint-drift-agent.sh` nor `nixos-config-worktrees/main pull`. Assert fetch timer and service include `OnFailure`, `Type=oneshot`, and `TimeoutStartSec=180`.

Against local Git fixture, stage anchor change, advance remote main, run `nixos-config-fetch`, then assert local HEAD unchanged, `origin/main` advanced, staged path preserved, and heartbeat contains pushed commit. For failure, use missing remote and assert old heartbeat survives. Trigger rendered service failure and assert notifier journal marker.

- [ ] **Step 2: Run RED gate**

Run `nix build --no-link .#checks.x86_64-linux.vm-base -L`.

Expected: FAIL because fetch service is absent and obsolete cron entries remain.

- [ ] **Step 3: Implement fetch module**

Generated runner executes only:

```bash
git -C "$anchor" fetch --no-tags --no-write-fetch-head "$remote" "+refs/heads/$branch:refs/remotes/$remote/$branch"
commit=$(git -C "$anchor" rev-parse --verify "refs/remotes/$remote/$branch^{commit}")
```

Atomically record timestamp and commit. Add 30-minute persistent timer, oneshot service, 180-second timeout, and dedicated notifier. Import module. Remove Mint and legacy pull cron entries; retain Mint source files.

- [ ] **Step 4: Run GREEN gate**

Run same `vm-base` command. Expected: PASS; fetch advances only `origin/main`, dirty index survives, heartbeat and notifier work.

- [ ] **Step 5: Commit**

Stage new module, `home/jonathan-linux.nix`, and tests; commit as `fix(git): fetch nixos-config without moving shared main`.

### Task 3: Base worktrees on origin/main

**Files:**
- Modify: `CLAUDE.md`
- Modify: `home/claude-skills/nixos-config-dev/SKILL.md`
- Modify: `home/claude-skills/nixos-agenix-secret/SKILL.md`
- Modify: `home/jonathan.nix`
- Modify: `tests/base.nix`

- [ ] **Step 1: Write failing source assertions**

Assert active managed guidance uses `worktree add ... -b feat/slug origin/main`. Leave local-main lifecycle fixtures unchanged.

- [ ] **Step 2: Run RED gate**

Run `vm-base`. Expected: FAIL because managed guidance still uses local `main`.

- [ ] **Step 3: Update guidance**

State three invariants: anchor commands on `nixos-config-worktrees/main`; fetch before branch creation; branch from `origin/main`. State unattended automation never moves local `main`.

- [ ] **Step 4: Run GREEN gate and commit**

Run `vm-base`. Stage four guidance files and tests; commit as `docs(worktrees): base new branches on origin main`.

### Task 4: Runtime and interactive verification

- [ ] **Step 1: Read testing skills**

Read `nixos-automated-testing` and `nixos-agent-testing` fully.

- [ ] **Step 2: Run adversarial script checks**

Directly prove: drift empty state succeeds; exit 23 propagates; old report survives; missing anchor becomes finding. Prove fetch preserves dirty index/local HEAD; missing remote fails; old heartbeat survives. Use systemd timeout path for hanging commands.

- [ ] **Step 3: Run interactive VM smoke**

Start feature VM. Manually start both services with fixture overrides. Inspect report, heartbeats, exit status, and failure-notifier journals through SSH.

- [ ] **Step 4: Run final automated gate**

Run `nix eval .#checks.x86_64-linux --apply builtins.attrNames`, then `nix build --no-link .#checks.x86_64-linux.vm-base -L`. Expected: evaluation and lane PASS.

### Task 5: Review and publish

- [ ] **Step 1: Review**

Run `verification-before-completion` and `advice-refine-test-loop`. Convert valid findings into failing assertions before fixes; rerun behavioral checks.

- [ ] **Step 2: Rebase**

Fetch origin main and rebase onto `origin/main`. Resolve only branch-owned changes. Rerun `vm-base` after conflicts.

- [ ] **Step 3: Prepare risky commit trailer**

Ensure HEAD commit contains complete pre-push checklist with real gate, smoke, review, risky-marker, and behavioral evidence results.

- [ ] **Step 4: Publish**

Push `fix/scheduled-job-reliability`, open PR against `main`, monitor required checks, fix branch-owned failures, and do not merge.
