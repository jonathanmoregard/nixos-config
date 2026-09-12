# Nix Low-Space Guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (default) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Nix collect unreachable store paths daily and automatically reclaim space before Dellan's root filesystem becomes critically full.

**Architecture:** Extend the existing evaluated maintenance contract, then change only standard NixOS options in `modules/common.nix`. Keep the existing fourteen-day profile-generation retention and weekly optimisation schedule; add daily collection plus bounded Nix-daemon pressure thresholds.

**Tech Stack:** NixOS modules, Nix daemon settings, flake checks.

---

### Task 1: Specify Daily and Pressure-Triggered Collection

**Files:**
- Modify: `tests/nix-maintenance.nix`

- [ ] **Step 1: Write the failing contract assertions**

Change the GC calendar assertion and add exact pressure-threshold assertions:

```nix
assert config.nix.gc.dates == [ "daily" ];
assert config.nix.settings.min-free == 200 * 1024 * 1024 * 1024;
assert config.nix.settings.max-free == 300 * 1024 * 1024 * 1024;
assert config.systemd.timers.nix-gc.timerConfig.OnCalendar == [ "daily" ];
```

Update the derivation message to describe daily and pressure-triggered collection.

- [ ] **Step 2: Run the focused check to verify RED**

Run:

```bash
nix build --no-link .#checks.x86_64-linux.nix-maintenance -L
```

Expected: evaluation fails because `config.nix.gc.dates` still equals `[ "Sun 04:15" ]` and `min-free` remains zero.

- [ ] **Step 3: Verify the edited test file**

Run:

```bash
git diff --check -- tests/nix-maintenance.nix
```

Expected: exit 0 with no output.

### Task 2: Configure Standard Nix Low-Space Controls

**Files:**
- Modify: `modules/common.nix`
- Test: `tests/nix-maintenance.nix`

- [ ] **Step 1: Implement the minimal configuration**

Change the GC calendar and add these settings inside the existing `nix.settings` attribute set:

```nix
nix.gc.dates = [ "daily" ];

nix.settings = {
  min-free = 200 * 1024 * 1024 * 1024;
  max-free = 300 * 1024 * 1024 * 1024;
};
```

Keep `nix.gc.options = "--delete-older-than 14d"` and the Wednesday optimisation schedule unchanged. Update the adjacent comment to explain daily cleanup and emergency collection.

- [ ] **Step 2: Run the focused check to verify GREEN**

Run:

```bash
nix build --no-link .#checks.x86_64-linux.nix-maintenance -L
```

Expected: build succeeds and the output says daily GC plus the 200/300 GiB pressure guard are enabled.

- [ ] **Step 3: Evaluate the full Dellan settings**

Run:

```bash
nix eval --json .#nixosConfigurations.dellan.config.nix.settings
nix eval --json .#nixosConfigurations.dellan.config.nix.gc.dates
```

Expected: `min-free` is `214748364800`, `max-free` is `322122547200`, and dates equal `["daily"]`.

- [ ] **Step 4: Build the Dellan system closure**

Run:

```bash
nix build --no-link .#nixosConfigurations.dellan.config.system.build.toplevel -L
```

Expected: exit 0. Interactive VM smoke is not required because no repository-side branch, executable script, or new daemon is introduced.

- [ ] **Step 5: Commit the implementation**

```bash
git add modules/common.nix tests/nix-maintenance.nix
git commit -m "fix(storage): guard Nix against low disk space"
```

### Task 3: Review and Ship

**Files:**
- Review: `modules/common.nix`
- Review: `tests/nix-maintenance.nix`
- Review: `docs/superpowers/specs/2026-09-12-nix-low-space-guard-design.md`
- Review: `docs/superpowers/plans/2026-09-12-nix-low-space-guard.md`

- [ ] **Step 1: Inspect the final diff and repository state**

Run:

```bash
git diff --check origin/main...HEAD
git diff --stat origin/main...HEAD
git status --short --branch
```

Expected: no whitespace errors and no uncommitted files.

- [ ] **Step 2: Push and open the pull request**

Push `feat/storage-low-space-guard`, then open a pull request against `main`. Include the measured incident evidence, exact threshold values, focused-check result, and full Dellan closure-build result.

- [ ] **Step 3: Watch required checks**

Run:

```bash
gh pr checks --watch --fail-fast
```

Expected: all required checks pass. Leave merge to the GitHub UI.
