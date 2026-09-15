# Home-server CD VM Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (default) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a disposable, target-sized NixOS VM lane that proves the existing home-server pull-deploy service can fetch a Git revision, perform a real NixOS switch, preserve services, no-op on replay, and honor a rollback.

**Architecture:** A test-only home-server fixture is used for both boot generation `v1` and deployed generation `v2`, keeping NixOS test instrumentation alive across switches. A local bare repository replaces only GitHub/Tailscale transport. Production `nixos-deploy.service`, Git operations, memory admission, `nixos-rebuild switch`, system profiles, and rollback guard remain unchanged.

**Tech Stack:** NixOS test driver, QEMU/KVM, systemd, Git, Nix flakes, existing `services.nixos-auto-deploy`, Mosquitto, house-automation health endpoint.

---

### Task 1: Add target-shaped deployment fixture

**Files:**
- Create: `tests/fixtures/home-server-cd-module.nix`
- Create: `tests/fixtures/home-server-cd-release`

- [ ] Define one fixture module importing production `hosts/home-server/default.nix`, common modules, agenix, smarthome, and NixOS test instrumentation.
- [ ] Disable physical hardware module and bootloader writes; provide ext4 `/` and `/boot` fixture filesystems.
- [ ] Give VM four vCPUs, 8 GiB RAM, and a sparse 128 GiB disk from test node configuration.
- [ ] Enable existing home-server deploy route with fixture host public key and runtime deploy key path; leave webhook disabled.
- [ ] Disable runtime SMART/Zigbee units only where QEMU lacks physical devices; keep Mosquitto and house-automation health active.
- [ ] Expose `/etc/cd-release` from `tests/fixtures/home-server-cd-release`, initially `v1`.
- [ ] Run `nix-instantiate --parse tests/fixtures/home-server-cd-module.nix` after each edit.

### Task 2: Write failing real-CD scenario

**Files:**
- Create: `tests/home-server-cd.nix`
- Modify: `flake.nix`

- [ ] Add `vm-home-server-cd` to flake checks with every locked input needed by nested offline evaluation.
- [ ] Copy clean repository source into VM `/etc/nixos`, initialize `v1`, and create a local bare origin.
- [ ] Produce and push a `v2` commit by changing only the release fixture, then restore working tree to `v1`.
- [ ] Start real `nixos-deploy.service`; assert exact `v2` checkout, `last-good`, empty poison latch, newer system generation, `/etc/cd-release=v2`, Mosquitto active, health endpoint successful, and zero failed units.
- [ ] Run deploy again; assert generation unchanged and journal reports exact-SHA no-op.
- [ ] Run real `nixos-rebuild switch --rollback`; assert `v1`, then invoke deploy and assert rollback guard keeps `v1` active while `last-good` remains `v2`.
- [ ] Stage new files and run `nix build --no-link --rebuild .#checks.x86_64-linux.vm-home-server-cd -L`; first behavioral run must fail before fixture/offline activation is complete.

### Task 3: Make nested activation offline and green

**Files:**
- Modify: `tests/fixtures/home-server-cd-module.nix`
- Modify: `tests/home-server-cd.nix`
- Modify: `flake.nix`

- [ ] Add repository source and required locked flake input sources to guest store through `system.extraDependencies`.
- [ ] Ensure candidate `nixosConfigurations.home-server` imports same fixture and can evaluate without external network access or real secrets.
- [ ] Preserve test-driver backdoor and serial diagnostics across both real switch and rollback.
- [ ] Print initial/deployed/rolled-back generations, system store paths, Git SHAs, markers, and deploy journal before assertions.
- [ ] Repeat targeted build until full scenario passes without stubbing `nixos-rebuild` or switch activation.

### Task 4: Interactive smoke and operator documentation

**Files:**
- Modify: `docs/home-server/README.md`

- [ ] Build and start interactive `vm-home-server-cd` test driver.
- [ ] Manually inspect 4 vCPU, roughly 8 GiB memory, sparse 128 GiB ext4 disk, deploy unit, `/etc/nixos` Git state, generation list, release marker, Mosquitto, health endpoint, and rollback guard journal.
- [ ] Document `vm-home-server-cd` command and covered CD boundary.
- [ ] Document excluded physical boundaries: J5005 microarchitecture, SMART, ZBDongle-E/Ember/RF, BIOS AC recovery, Tailscale identity, and real GitHub transport.
- [ ] Run docs evaluation/check command and `git diff --check`.

### Task 5: Full verification, review, and delivery

**Files:**
- Modify if needed: `.github/workflows/ci.yml`

- [ ] Confirm CI discovery includes `vm-home-server-cd`; add explicit matrix lane only if existing discovery/matrix needs it.
- [ ] Run check-name evaluation, rebuilt `vm-home-server-cd`, existing `vm-home-server`, and full production `home-server` toplevel build.
- [ ] Run repository warning/fork guards, `git diff --check`, and gitleaks.
- [ ] Run fresh-context spec and quality review; fix and re-run affected checks.
- [ ] Commit with measured risky pre-push trailer, update PR #234, push, and observe every new CI job to terminal state without merging.
