# Recurring Claude-to-Codex Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (default) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run the latest `ai-client-config/main` hourly to mirror Claude configuration into Codex safely.

**Architecture:** Home Manager installs one bounded sync wrapper, one user service, one persistent calendar timer, and one failure notifier. Every run uses a disposable shallow clone and renders into a fake home inside isolated namespaces. A trusted wrapper publishes only allowlisted outputs after success. Environment seams let VM tests substitute a local Git remote and shorter timeout without adding a production-only test route.

**Tech Stack:** Nix, Home Manager, systemd user units, Bash, Git, Python, NixOS VM tests.

---

### Task 1: Write failing integration assertions

**Files:**
- Modify: `tests/base.nix`

- [ ] Add a local Git fixture whose `scripts/sync_codex.py` writes its revision to `AI_CLIENT_CONFIG_TEST_OUTPUT`.
- [ ] Start `ai-client-config-codex-sync.service` with the fixture remote and assert revision one runs.
- [ ] Commit revision two, start the same unit again, and assert revision two runs.
- [ ] Commit a renderer that exits non-zero and assert the unit fails while its failure record names the render stage.
- [ ] Commit a sleeping renderer, lower `AI_CLIENT_CONFIG_SYNC_TIMEOUT_SECONDS`, and assert the unit terminates it within the deadline.
- [ ] Run `nix build .#checks.x86_64-linux.vm-base -L`; expect failure because the unit does not exist.

### Task 2: Implement wrapper and units

**Files:**
- Create: `home/ai-client-config-sync.nix`
- Modify: `home/jonathan-linux.nix`

- [ ] Add a `writeShellApplication` that validates its remote, ref, and timeout; shallow-clones into `$XDG_RUNTIME_DIR`; logs the exact commit; runs `scripts/sync_codex.py` under `timeout`; records failure stage; clears recovered failure state; and removes its temporary clone.
- [ ] Add a hardened oneshot user service with access only to required Claude inputs and Codex/plugin outputs.
- [ ] Add `OnBootSec=5min`, `OnCalendar=hourly`, `Persistent=true`, and bounded jitter to the user timer.
- [ ] Add an `OnFailure` user service that logs the persistent failure record and sends a best-effort desktop alert.
- [ ] Import the module from `home/jonathan-linux.nix`.
- [ ] Re-run `nix build .#checks.x86_64-linux.vm-base -L`; expect all assertions to pass.

### Task 3: Prove generated runtime behavior

**Files:**
- No source changes.

- [ ] Evaluate `.#checks.x86_64-linux.vm-base.drvPath`; expect success.
- [ ] Build the dellan Home Manager path and inspect the generated wrapper and unit text.
- [ ] Invoke the generated wrapper against empty, missing-script, non-zero, and hanging fixtures; assert its diagnostics and exit status.
- [ ] Launch `nix run .#feature-vm`, drive the real user service against a local two-revision fixture over SSH, and capture the observed revision and journal commit.

### Task 4: Review and ship

**Files:**
- No source changes unless review finds a defect.

- [ ] Run `advice-refine-test-loop`; fix and re-test any findings.
- [ ] Rebase on current `origin/main` and re-run the affected gates.
- [ ] Commit with the required risky-change pre-push checklist.
- [ ] Push `feat/ai-client-config-sync`, open a PR, and wait for required checks to pass.
