# RAM Pressure Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (default) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Share aggregator query state, serialize memory-heavy VM/build workflows, and make systemd-oomd kill offending workload scopes before the desktop thrashes.

**Architecture:** Nix packages one loopback aggregator backend and unchanged-command stdio proxies. A shared lock plus dedicated `ram-heavy.slice` coordinates Nix and feature-VM workloads. Nix per-build cgroups and narrow OOMD enrollment make builders/scopes eligible without enrolling the graphical session.

**Tech Stack:** NixOS, Home Manager, systemd user/system units, systemd-oomd, Bash, NixOS VM tests, QEMU feature VM.

---

### Task 1: Write failing VM assertions

**Files:**
- Modify: `tests/base.nix`
- Modify: `tests/auto-deploy.nix`

- [ ] In `vm-base`, assert `nix.settings.use-cgroups=true`, `max-jobs=1`, and `cores=4`; inspect `oomctl` and require only `nix-daemon.service` and `ram-heavy.slice` as monitored workload ancestors.
- [ ] Add an outside-session sentinel, then prove a transient test scope lands below `ram-heavy.slice` while the sentinel stays outside and alive.
- [ ] Start one lock holder, prove a second coordinated process cannot cross the lock, release the holder, and prove the waiter completes. Set `NIX_MEMORY_COORDINATION_HELD=1` for a nested invocation and prove immediate completion.
- [ ] Start two `aggregator-mcp` proxies against the user backend, prove the backend has one PID, and prove proxies do not have model-stack mappings or children.
- [ ] In `vm-auto-deploy`, hold the shared lock and prove the deploy tick reports deferred without writing poison state; release it and prove the normal rebuild fixture executes.
- [ ] Stage both tests and run `nix build .#checks.x86_64-linux.vm-base -L` plus `nix build .#checks.x86_64-linux.vm-auto-deploy -L`; expect failures because units and helpers do not exist.

### Task 2: Package proxy and backend commands

**Files:**
- Modify: `flake.nix`
- Modify: `flake.lock`
- Modify: `overlays/aggregator.nix`

- [ ] Pin `aggregator-src` to the pushed shared-backend implementation SHA and run `nix flake lock`.
- [ ] Keep `aggregator-mcp` in the existing aggregate package, but wrap it with `AGGREGATOR_MCP_BACKEND_URL=http://127.0.0.1:8765/mcp` and a bounded FastMCP client initialization timeout.
- [ ] Add `aggregator-mcp-backend`, wrapping the original venv entry point with proxy URL removed and `FASTMCP_TRANSPORT=http`, `FASTMCP_HOST=127.0.0.1`, and `FASTMCP_PORT=8765`.
- [ ] Keep `aggregator-schema-probe` beside the proxy command so current command-derived probe resolution continues to work.
- [ ] Run `git add flake.nix flake.lock overlays/aggregator.nix` then `nix eval --no-warn-dirty .#nixosConfigurations.dellan.config.home-manager.users.jonathan.home.packages --apply builtins.length`.

### Task 3: Add hardened shared backend service

**Files:**
- Create: `home/aggregator-mcp-backend.nix`
- Modify: `home/jonathan-linux.nix`
- Modify: `tests/base.nix`

- [ ] Add a user service wanted by `default.target`, with restart-on-failure, loopback-only address families/IP policy, read-only home, writable `%h/.local/share/aggregator`, `MemoryHigh=6G`, and `MemoryMax=8G`.
- [ ] Import the module only for Jonathan's Linux Home Manager profile.
- [ ] Extend `vm-base` to stop/start the backend, assert restart and one listening loopback socket, then initialize two production proxy commands against it.
- [ ] Run `nix eval --no-warn-dirty .#checks.x86_64-linux.vm-base.drvPath` and inspect the generated Home Manager unit and both wrappers in the evaluated closure.

### Task 4: Implement coordination helper and Nix wrapper

**Files:**
- Modify: `modules/nixos/build-coordination.nix`
- Modify: `tests/base.nix`

- [ ] Add read-only module options exposing `nix-memory-run` and the coordinated Nix package to other modules and flake apps.
- [ ] Implement `nix-memory-run [--nonblock] -- command ...`: validate argv; bypass when `NIX_MEMORY_COORDINATION_HELD=1`; lock a fixed path under `/run/user/1000`; return 75 on nonblocking contention; otherwise export the marker and preserve child status/signals.
- [ ] Wrap production Nix. Coordinate `build`, `eval`, `flake check`, and feature-VM app invocations; bypass other commands and `feature-vm-screencap`. When the user manager is reachable, execute coordinated client work in a collected transient scope below `ram-heavy.slice` with group kill policy.
- [ ] Change daemon settings to `max-jobs=1`, `cores=4`, and `use-cgroups=true`.
- [ ] Directly exercise the built helper with missing delimiter/command, child exit 42, nested marker, a waiting contender, nonblocking contention, and a timeout-wrapped hanging child. All diagnostics and statuses must match the contract.
- [ ] Run `nix build .#checks.x86_64-linux.vm-base -L`; expect coordination assertions green while OOMD/feature-VM assertions remain red.

### Task 5: Route feature VM and auto-deploy through coordination

**Files:**
- Modify: `flake.nix`
- Modify: `modules/nixos/nixos-auto-deploy.nix`
- Modify: `tests/base.nix`
- Modify: `tests/auto-deploy.nix`

- [ ] Wrap the feature-VM QEMU command with exposed `nix-memory-run` and a named collected `feature-vm.scope` below `ram-heavy.slice`; keep screencap uncoordinated.
- [ ] Wrap only auto-deploy's rebuild phase with `nix-memory-run --nonblock`; treat status 75 as a clean deferral and leave existing fetch, poison, rollback, and notification behavior unchanged.
- [ ] Preserve nested marker through `nixos-rebuild`, so its Nix subprocess cannot deadlock on the held lock.
- [ ] Run `nix build .#checks.x86_64-linux.vm-base -L` and `nix build .#checks.x86_64-linux.vm-auto-deploy -L`.

### Task 6: Configure narrow OOMD enrollment

**Files:**
- Create: `modules/nixos/memory-pressure.nix`
- Modify: `hosts/dellan/default.nix`
- Modify: `modules/nixos/build-coordination.nix`
- Modify: `tests/base.nix`

- [ ] Enable systemd-oomd with root, system, and broad user-slice enrollment disabled and `SwapUsedLimit=80%`.
- [ ] Define `ram-heavy.slice` with accounting, `MemoryHigh=12G`, swap killing, and pressure killing at 40 percent for 10 seconds.
- [ ] Add matching managed-OOM settings and `MemoryHigh=12G` to `nix-daemon.service`, relying on `use-cgroups` descendants as candidates and leaving daemon `OOMPolicy` unchanged.
- [ ] Import the module on dellan. Prove `oomctl` contains the two intended paths and excludes root, system, `user.slice`, `user-1000.slice`, and graphical session scopes.
- [ ] In the VM only, override the heavy slice to a small `MemoryHigh` and one-second pressure duration. Start one memory hog below it, require OOMD to terminate that scope, and require the outside-session sentinel to remain alive. This is the negative control proving kill scope, not settings presence.
- [ ] Run `nix build .#checks.x86_64-linux.vm-base -L`.

### Task 7: Interactive feature-VM smoke

**Files:**
- No source changes unless smoke finds a defect.

- [ ] Run `nix run .#feature-vm` from the worktree and wait for SSH readiness.
- [ ] On the host, assert QEMU is a descendant of `ram-heavy.slice/feature-vm.scope` and `oomctl` lists only intended monitored ancestors.
- [ ] Start a second coordinated Nix evaluation and prove it waits while VM holds the lock.
- [ ] Run `nix run .#feature-vm-screencap -- <qmp-sock> <output.png>` and inspect the PNG while the lock remains held.
- [ ] Stop the VM, prove the waiting evaluation proceeds, and confirm the feature scope is collected.

### Task 8: Review, rebase, and publish

**Files:**
- No source changes unless review finds a defect.

- [ ] Run `advice-refine-test-loop`; fix every blocker/high issue and rerun affected gates.
- [ ] Run `nix eval --no-warn-dirty .#checks.x86_64-linux.vm-base.drvPath`, build the Home Manager path, inspect generated scripts, then rebuild both affected VM lanes.
- [ ] Fetch and rebase on current `origin/main`, rerun affected gates, and complete the repository's risky-change pre-push checklist with exact evidence.
- [ ] Push `feat/ram-pressure`, open a PR against `main`, and wait for required checks. Merge only after aggregator dependency is available and CI is green.
