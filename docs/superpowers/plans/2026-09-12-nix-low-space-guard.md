# Nix Low-Space Guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (default) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Nix collect unreachable store paths daily and automatically reclaim space before Dellan's root filesystem becomes critically full.

**Architecture:** Extend the existing evaluated maintenance contract, then change only standard NixOS options in `modules/common.nix`. Keep the existing fourteen-day profile-generation retention and weekly optimisation schedule; add daily collection plus bounded Nix-daemon pressure thresholds.

**Tech Stack:** NixOS modules, Nix daemon settings, flake checks.

---

### Task 1: Specify Daily and Pressure-Triggered Collection

**Files:**
- Modify: `tests/nix-maintenance.nix`

- [x] **Step 1: Write the failing contract assertions**

Change the GC calendar assertion and add exact pressure-threshold assertions:

```nix
assert config.nix.gc.dates == [ "daily" ];
assert config.nix.settings.min-free == 200 * 1024 * 1024 * 1024;
assert config.nix.settings.max-free == 300 * 1024 * 1024 * 1024;
assert config.systemd.timers.nix-gc.timerConfig.OnCalendar == [ "daily" ];
```

Update the derivation message to describe daily and pressure-triggered collection.

- [x] **Step 2: Run the focused check to verify RED**

Run:

```bash
nix build --no-link .#checks.x86_64-linux.nix-maintenance -L
```

Expected: evaluation fails because `config.nix.gc.dates` still equals `[ "Sun 04:15" ]` and `min-free` remains zero.

- [x] **Step 3: Verify the edited test file**

Run:

```bash
git diff --check -- tests/nix-maintenance.nix
```

Expected: exit 0 with no output.

### Task 2: Configure Standard Nix Low-Space Controls

**Files:**
- Modify: `modules/common.nix`
- Modify: `modules/nixos/feature-vm.nix`
- Modify: `modules/nixos/vm-tweaks.nix`
- Modify: `tests/lib/common.nix`
- Modify: `tests/base.nix`
- Test: `tests/nix-maintenance.nix`

- [x] **Step 1: Implement the minimal configuration**

Change the GC calendar and add these settings inside the existing `nix.settings` attribute set:

```nix
nix.gc.dates = [ "daily" ];

nix.settings = {
  min-free = lib.mkDefault (200 * 1024 * 1024 * 1024);
  max-free = lib.mkDefault (300 * 1024 * 1024 * 1024);
};
```

Keep `nix.gc.options = "--delete-older-than 14d"` and the Wednesday optimisation schedule unchanged. Update the adjacent comment to explain daily cleanup and emergency collection.

- [x] **Step 2: Scale disposable VM thresholds**

Set `min-free` to 128 MiB and `max-free` to 1 GiB in the full-host test node, the legacy VM module, and `virtualisation.vmVariant`. Add runtime assertions to `tests/base.nix`:

```python
assert "min-free = 134217728" in nix_config
assert "max-free = 1073741824" in nix_config
```

These values prevent a VM with a 12–20 GiB disk from entering emergency GC immediately while retaining low-space protection appropriate to its size.

- [x] **Step 3: Run the focused check to verify GREEN**

Run:

```bash
nix build --no-link .#checks.x86_64-linux.nix-maintenance -L
```

Expected: build succeeds and the output says daily GC plus the 200/300 GiB pressure guard are enabled.

- [x] **Step 4: Evaluate the full Dellan and VM settings**

Run:

```bash
nix eval --json .#nixosConfigurations.dellan.config.nix.settings
nix eval --json .#nixosConfigurations.dellan.config.nix.gc.dates
nix eval --json .#nixosConfigurations.vm.config.nix.settings.min-free
nix eval --json .#nixosConfigurations.vm.config.nix.settings.max-free
```

Expected: Dellan's `min-free` is `214748364800`, `max-free` is `322122547200`, and dates equal `["daily"]`; legacy VM values are `134217728` and `1073741824`.

- [x] **Step 5: Build the Dellan system closure and VM gate**

Run:

```bash
nix build --no-link .#nixosConfigurations.dellan.config.system.build.toplevel -L
nix build --no-link .#checks.x86_64-linux.vm-base -L
```

Expected: both exit 0, and `vm-base` completes its real coordinated Nix build without a daemon coredump.

- [x] **Step 6: Smoke the interactive feature VM**

Launch `nix run .#feature-vm`, connect over SSH, assert `nix config show` reports the 128 MiB/1 GiB limits, and run a small `nix build --no-link` inside the VM. Stop the feature VM after capturing results.

- [x] **Step 7: Commit the implementation**

```bash
git add modules/common.nix modules/nixos/feature-vm.nix modules/nixos/vm-tweaks.nix tests/lib/common.nix tests/base.nix tests/nix-maintenance.nix
git commit -m "fix(storage): guard Nix against low disk space"
```

### Task 3: Review and Ship

**Files:**
- Review: `modules/common.nix`
- Review: `tests/nix-maintenance.nix`
- Review: `docs/superpowers/specs/2026-09-12-nix-low-space-guard-design.md`
- Review: `docs/superpowers/plans/2026-09-12-nix-low-space-guard.md`

- [x] **Step 1: Inspect the final diff and repository state**

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
