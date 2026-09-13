# Home Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (default) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a buildable, non-deployed `home-server` NixOS host that consumes smarthome, runs private home automation and Matrix services after evidence-driven bootstrap, and follows existing CI/deploy patterns.

**Architecture:** Host-specific facts live under `hosts/home-server`; reusable service composition lives in focused modules/profile. Null required-value options keep only hardware/identity-dependent services off. Existing auto-deploy module remains unchanged and activates only after deploy credentials exist.

**Tech Stack:** NixOS 26.11pre pinned nixpkgs, agenix-rekey, Tailscale, Mosquitto 2.1, Zigbee2MQTT 2.13, Synapse 1.157, PostgreSQL 17, systemd, GitHub Actions.

---

## File map

- `flake.nix`, `flake.lock`: public smarthome input, host, checks.
- `profiles/home-server-base.nix`: headless boot/network/security/maintenance.
- `modules/nixos/home-server-services.nix`: readiness options, Mosquitto, Zigbee2MQTT, automation, Matrix/PostgreSQL, firewall, hardening glue.
- `hosts/home-server/{default,hardware-configuration}.nix`: host composition and label-based pre-hardware storage.
- `tests/home-server.nix`: behavioral VM lane.
- `.github/workflows/ci.yml`: separate home-server closure build and lane.
- `scripts/bootstrap-branch-protection.sh`: stable new required check.
- `docs/home-server/README.md`: bootstrap, secrets, firmware, pairing, state, backups, recovery.

### Task 1: Write failing host contract

- [ ] Add `tests/home-server.nix` importing intended host/module paths and asserting hostname, ext4 root label, key-only SSH, Tailscale-only ports, journal limits, scaled Nix free-space guard, active Mosquitto, active automation daemon, and `/healthz` success.
- [ ] Add `vm-home-server` check reference in `flake.nix` before implementation.
- [ ] Stage new files and run `nix build --no-link .#checks.x86_64-linux.vm-home-server -L`; expect missing host/module failure.
- [ ] Commit is deferred until GREEN.

### Task 2: Add smarthome input and host scaffold

- [ ] Pin exact public smarthome commit in flake input and make its nixpkgs follow this repository.
- [ ] Add explicit `nixosConfigurations.home-server` using shared `pkgsLinux`, host file, `modules/common.nix`, agenix modules, and smarthome module; omit Home Manager and microVM.
- [ ] Add `hosts/home-server/hardware-configuration.nix` with generic Wyse CPU/initrd modules, `/dev/disk/by-label/nixos` ext4 root, and `/dev/disk/by-label/EFI` vfat boot; no UUID or serial.
- [ ] Run `nix eval .#nixosConfigurations.home-server.config.networking.hostName`; expect `home-server`.

### Task 3: Build secure server base

- [ ] Implement `profiles/home-server-base.nix`: systemd-boot, systemd-networkd wired DHCP, Stockholm timezone, timesyncd, key-only OpenSSH including keyboard-interactive off, user key reuse, zsh, firewall, Tailscale, persistent bounded journal, smartd, state version, and no Btrfs scrub.
- [ ] Override shared Nix `min-free`/`max-free` for 128 GB disk while retaining daily 14-day GC and Wednesday optimization.
- [ ] Run cheap evals for SSH settings, journal config, networkd, GC, and free-space values; expect exact configured values.
- [ ] Run host-contract VM; expect remaining service failures only.

### Task 4: Compose MQTT, Zigbee, and automation services

- [ ] Implement typed `homeServer` options: nullable `ageHostPublicKey`, stable `zigbeeSerialPort`, Matrix server/secret file, deploy key file, optional MQTT network listener credential, TellStick address/token, and static house settings.
- [ ] Configure loopback Mosquitto persistence and anonymous local-only listener; optional Tailscale listener uses `passwordFile`/ACL and explicit firewall port.
- [ ] Configure Zigbee2MQTT only when serial path is non-null; assert `/dev/serial/by-id/` prefix; set `adapter=ember`, `permit_join=false`, native base topic, local broker, frontend on port 8080, service ordering on Mosquitto/device availability, and restart policy.
- [ ] Configure `services.houseAutomation` always with local broker, `/var/lib` persistence, 04:00 reset, example anonymous topology, and loopback health.
- [ ] Add Tailscale-only firewall ports for enabled frontend/services; keep MQTT public ports closed.
- [ ] Run eval assertions and host VM; expect Mosquitto/automation health pass and Zigbee absent without serial evidence.
- [ ] Commit `feat(home-server): add automation service stack` with required risky pre-push trailer evidence.

### Task 5: Add private Matrix/PostgreSQL composition

- [ ] RED: extend host VM with `matrix.example.invalid` and store-backed test secret config; assert PostgreSQL owns database, Synapse becomes active, registration is disabled, listener responds, and no non-Tailscale firewall opening exists.
- [ ] Run VM lane; verify Matrix assertions fail before configuration.
- [ ] GREEN: enable PostgreSQL 17 with C/UTF8 initialization and local peer-owned `matrix-synapse` DB; enable Synapse only when permanent server name plus secret file exist; use `extraConfigFiles`, closed registration, bounded upload/media settings, journald, and Tailscale-scoped port 8008.
- [ ] Run VM lane; expect pass.
- [ ] Commit `feat(home-server): add private Matrix service` with risky trailer.

### Task 6: Wire agenix and existing deploy path

- [ ] Configure agenix-rekey per-host storage/public key only when real host public key is non-null. Declare service secrets only from explicitly provided source paths; modes/owners remain least-privilege.
- [ ] Enable existing `services.nixos-auto-deploy` polling only when host public key and deploy key path exist; set `flakeAttr=home-server`, webhook disabled, no desktop notification, and existing rollback/poison behavior unchanged.
- [ ] Add eval tests proving absent values do not declare secrets or auto-deploy, partial values fail assertions, and complete fixture values select correct flake attribute.
- [ ] Run targeted eval/check and interactive feature VM service probe; capture real unit state and health output.
- [ ] Commit `feat(home-server): prepare secrets and pull deployment` with risky trailer.

### Task 7: Extend CI without changing Dellan behavior

- [ ] Add `build home-server toplevel` job beside unchanged Dellan job, using same Nix/cache setup and exact `nixosConfigurations.home-server` build target.
- [ ] Add `home-server` to VM matrix/discovery or explicitly always-run lane; preserve every existing required job name.
- [ ] Add new context to `scripts/bootstrap-branch-protection.sh`; do not apply remote branch-protection changes during implementation.
- [ ] Run workflow YAML parse/check-fork-guards and docs command checks; expect pass.
- [ ] Build full home-server toplevel locally.
- [ ] Commit `ci: build and test home-server` with risky trailer and behavioral evidence.

### Task 8: Bootstrap and operations documentation

- [ ] Write `docs/home-server/README.md` with architecture diagram, Wyse assumptions, BIOS AC recovery, label-based ext4 install, temporary installer SSH, hardware config review, host key/agenix-rekey flow, Tailscale enrollment before final switch, stable dongle discovery, Ember firmware validation/flash sources, Zigbee pairing/groups, Matrix permanent-name warning, TellStick `/api` discovery/auth, mutable state inventory, consistent export commands, rollback, full rebuild, and debugging.
- [ ] State clearly: no off-host destination means mutable data is not backed up.
- [ ] Document mains routers vs battery end devices, USB extension/RF interference, Zigbee-only coordinator, separate Z-Wave/Zigbee meshes, no Wi-Fi need, no Home Assistant, and cloud-AI secrets pattern only.
- [ ] Run `git diff --check` and docs eval check.
- [ ] Commit `docs(home-server): add bootstrap and recovery guide` with pure-data trailer if isolated from risky diff.

### Task 9: Full local gate and interactive smoke

- [ ] Stage every new file; run `nix eval .#checks.x86_64-linux --apply builtins.attrNames` and confirm `vm-home-server` exists.
- [ ] Run `nix build --no-link .#checks.x86_64-linux.vm-home-server -L`.
- [ ] Run `nix build --no-link .#nixosConfigurations.home-server.config.system.build.toplevel -L`.
- [ ] Run affected fast checks plus `scripts/check-eval-warnings.sh` and `scripts/check-fork-guards.sh`.
- [ ] Start headless feature VM, SSH in, call automation health, connect/publish/subscribe through Mosquitto, verify Matrix endpoint with fixture, inspect firewall and unit hardening, capture journal evidence, then stop VM.
- [ ] Record commands/results in progress notes and final commit trailer.

