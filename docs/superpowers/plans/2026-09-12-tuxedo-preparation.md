# TUXEDO InfinityBook Pro 15 Gen10 AMD Preparation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (default) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a tested, dormant AMD/TUXEDO laptop profile while preserving every current Dell Latitude behaviour and documenting hardware-gated follow-up.

**Architecture:** Split generic laptop services from Dell/Intel hardware support, then add one directly-importable TUXEDO module containing only safe pre-arrival defaults. A focused derivation evaluates the profile and builds its packages as part of the existing `vm-base` lane, avoiding CI workflow changes and fake hardware configuration.

**Tech Stack:** NixOS modules, nixpkgs unstable, NixOS VM tests, `nixfmt`, Git worktrees, GitHub Actions.

---

## File map

- Create `modules/nixos/dell-latitude-7440.nix`: Intel, TLP, thermald,
  IPU6, v4l2loopback, and camera recovery code currently in the generic file.
- Modify `modules/nixos/laptop.nix`: shared firmware, input, Bluetooth,
  dynamic-binary, lid, audio, printing, mDNS, and font configuration.
- Create `modules/nixos/tuxedo-infinitybook-pro-15-gen10-amd.nix`: dormant
  AMD/TUXEDO profile with no guessed kernel, disk, fan, or NPU runtime.
- Modify `hosts/dellan/default.nix`: import generic and Dell-specific modules.
- Create `tests/tuxedo-profile.nix`: evaluate the TUXEDO module and build its
  kernel/userspace dependencies.
- Modify `tests/base.nix`: preserve observable Dell services and environment.
- Modify `flake.nix`: make `vm-base` build its VM and TUXEDO contract.
- Modify `CLAUDE.md`: record dormant-profile and arrival boundaries.

### Task 1: Add Dell characterization assertions

**Files:**

- Modify: `tests/base.nix` near the existing IPU6 assertions

- [ ] **Step 1: Add observable assertions before refactoring**

Insert immediately before the existing IPU6 section:

```python
    # Dell Latitude hardware profile must survive extraction from the generic
    # laptop module. These are observable contracts, not source-text checks.
    dellan.succeed("systemctl cat tlp.service >/dev/null")
    dellan.succeed("systemctl cat thermald.service >/dev/null")
    dellan.succeed(
        "grep -q 'export LIBVA_DRIVER_NAME=\"iHD\"' /etc/set-environment"
    )
```

Change its heading to:

```python
    # ── IPU6 camera self-heal watchdog (dell-latitude-7440.nix) ──
```

- [ ] **Step 2: Run characterization before moving code**

Run:

```bash
nix build --no-link .#checks.x86_64-linux.vm-base -L
```

Expected: exit 0; both services, `iHD`, and existing camera assertions pass.

### Task 2: Split generic and Dell-specific laptop modules

**Files:**

- Create by rename: `modules/nixos/dell-latitude-7440.nix`
- Recreate: `modules/nixos/laptop.nix`
- Modify: `hosts/dellan/default.nix`

- [ ] **Step 1: Preserve Dell implementation under its own name**

Run:

```bash
git mv modules/nixos/laptop.nix modules/nixos/dell-latitude-7440.nix
```

Keep the `v4l2loopback-buffers.nix` import and all Intel/IPU6 code. Delete the
firmware-update block, touchpad block, Bluetooth block, and complete tail from
`# nix-ld` through `fonts.packages`. Retain the final module closing brace.

- [ ] **Step 2: Recreate complete generic module**

Create `modules/nixos/laptop.nix`:

```nix
{ pkgs, ... }:
{
  # Firmware updates (LVFS) — `fwupdmgr refresh && fwupdmgr update`
  services.fwupd.enable = true;

  services.libinput = {
    enable = true;
    touchpad = {
      tapping = true;
      naturalScrolling = true;
      disableWhileTyping = true;
    };
  };

  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };

  # Support dynamically linked vendor applications such as Voquill's current
  # repo-local Tauri release while its package remains a separate change.
  programs.nix-ld.enable = true;

  services.logind.settings.Login = {
    HandleLidSwitch = "suspend";
    HandleLidSwitchExternalPower = "ignore";
    HandleLidSwitchDocked = "ignore";
  };

  # Voquill uses libpulse on Linux; PipeWire's PulseAudio compatibility layer
  # keeps the recorder independent of laptop-specific audio hardware.
  services.pulseaudio.enable = false;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };
  security.rtkit.enable = true;

  services.printing.enable = true;
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };

  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-color-emoji
    noto-fonts-cjk-sans
    liberation_ttf
    dejavu_fonts
  ];
}
```

- [ ] **Step 3: Import both layers on Dellan**

Replace the single laptop import in `hosts/dellan/default.nix` with:

```nix
    ../../modules/nixos/laptop.nix
    ../../modules/nixos/dell-latitude-7440.nix
```

- [ ] **Step 4: Format, evaluate, then run Dell gates**

Run:

```bash
nix shell .#nixosConfigurations.dellan.pkgs.nixfmt -c nixfmt modules/nixos/laptop.nix
nix-instantiate --parse modules/nixos/dell-latitude-7440.nix >/dev/null
nix-instantiate --parse hosts/dellan/default.nix >/dev/null
nix eval --raw .#nixosConfigurations.dellan.config.system.build.toplevel.drvPath
nix build --no-link .#checks.x86_64-linux.vm-base -L
nix build --no-link .#checks.x86_64-linux.vm-camera-relay -L
```

Expected: eval prints one Dellan derivation; both checks exit 0.

### Task 3: Write failing TUXEDO profile contract

**Files:**

- Create: `tests/tuxedo-profile.nix`
- Modify: `flake.nix` in `checks.${linuxSystem}`

- [ ] **Step 1: Create contract before profile exists**

Create `tests/tuxedo-profile.nix`:

```nix
{ pkgs, ... }:
let
  lib = pkgs.lib;
  evaluated = import "${pkgs.path}/nixos/lib/eval-config.nix" {
    system = pkgs.stdenv.hostPlatform.system;
    modules = [
      ../modules/nixos/tuxedo-infinitybook-pro-15-gen10-amd.nix
      {
        boot.loader.grub.enable = false;
        fileSystems."/" = {
          device = "none";
          fsType = "tmpfs";
        };
        system.stateVersion = "25.11";
      }
    ];
  };
  cfg = evaluated.config;
in
assert cfg.hardware.cpu.amd.updateMicrocode;
assert cfg.hardware.enableRedistributableFirmware;
assert cfg.hardware.graphics.enable;
assert cfg.hardware.graphics.enable32Bit;
assert cfg.hardware.tuxedo-drivers.enable;
assert cfg.hardware.tuxedo-drivers.settings.charging-profile == "stationary";
assert cfg.services.power-profiles-daemon.enable;
assert !cfg.services.tlp.enable;
assert !cfg.services.thermald.enable;
assert lib.elem pkgs.libva-utils cfg.environment.systemPackages;
assert lib.elem pkgs.lm_sensors cfg.environment.systemPackages;
assert lib.elem pkgs.vulkan-tools cfg.environment.systemPackages;
assert lib.elem pkgs.whisper-cpp-vulkan cfg.environment.systemPackages;
assert !(lib.elem "amd_pstate=active" cfg.boot.kernelParams);
assert !(lib.elem "amdxdna" cfg.boot.kernelModules);
pkgs.runCommand "tuxedo-profile-contract"
  {
    nativeBuildInputs = [
      cfg.boot.kernelPackages.tuxedo-drivers
      pkgs.libva-utils
      pkgs.lm_sensors
      pkgs.vulkan-tools
      pkgs.whisper-cpp-vulkan
    ];
  }
  ''
    mkdir -p "$out"
    printf '%s\n' 'TUXEDO profile contract passed' > "$out/result"
  ''
```

- [ ] **Step 2: Attach contract to already-required base lane**

Change only `vm-base` in `flake.nix`:

```nix
        vm-base = pkgsLinux.symlinkJoin {
          name = "vm-base-with-tuxedo-profile";
          paths = [
            (mkLane ./tests/base.nix)
            (mkLane ./tests/tuxedo-profile.nix)
          ];
        };
```

- [ ] **Step 3: Verify intended red state**

Run:

```bash
git add tests/tuxedo-profile.nix flake.nix
nix build --no-link .#checks.x86_64-linux.vm-base -L
```

Expected: evaluation fails because the referenced TUXEDO module is absent,
not because of syntax or an unrelated option.

### Task 4: Implement safe TUXEDO hardware profile

**Files:**

- Create: `modules/nixos/tuxedo-infinitybook-pro-15-gen10-amd.nix`

- [ ] **Step 1: Add locally-verifiable safe settings**

Create the module:

```nix
{ pkgs, ... }:
{
  hardware.cpu.amd.updateMicrocode = true;
  hardware.enableRedistributableFirmware = true;

  # Radeon 890M uses upstream amdgpu + Mesa. Do not force kernel parameters
  # before suspend and GPU stress have been measured on the real machine.
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  # Upstream driver provides Fn keys, keyboard controls, and charging policy.
  # Tailor stays disabled until its Gen10 support is hardware-tested.
  hardware.tuxedo-drivers = {
    enable = true;
    settings.charging-profile = "stationary";
  };

  # AMD platform/EPP integration is the conservative baseline. Dellan's
  # Intel-specific TLP policy lives in dell-latitude-7440.nix.
  services.power-profiles-daemon.enable = true;
  services.tlp.enable = false;
  services.thermald.enable = false;

  # Arrival diagnostics plus first local dictation candidate.
  environment.systemPackages = with pkgs; [
    libva-utils
    lm_sensors
    vulkan-tools
    whisper-cpp-vulkan
  ];
}
```

- [ ] **Step 2: Format and run full base lane**

Run:

```bash
nix shell .#nixosConfigurations.dellan.pkgs.nixfmt -c nixfmt modules/nixos/tuxedo-infinitybook-pro-15-gen10-amd.nix tests/tuxedo-profile.nix
nix-instantiate --parse flake.nix >/dev/null
nix build --no-link .#checks.x86_64-linux.vm-base -L
```

Expected: exit 0; Dell VM passes and `tuxedo-profile-contract` builds.

- [ ] **Step 3: Confirm prohibited guesses remain absent**

Run:

```bash
rg -n 'amd_pstate|amdxdna|linuxPackages|ryzenadj|memlock|tailor|fan' modules/nixos/tuxedo-infinitybook-pro-15-gen10-amd.nix
```

Expected: only explanatory Tailor text; no kernel/NPU/watt/memlock/fan config.

### Task 5: Document operational boundary

**Files:**

- Modify: `CLAUDE.md`

- [ ] **Step 1: Add planned host-table row**

```markdown
| `tuxedo` | Planned InfinityBook Pro 15 Gen10 AMD; dormant hardware profile only until arrival evidence exists |
```

- [ ] **Step 2: Add pre-arrival status before known gaps**

```markdown
## TUXEDO InfinityBook Pro 15 Gen10 AMD preparation

`modules/nixos/tuxedo-infinitybook-pro-15-gen10-amd.nix` is a dormant,
directly-importable hardware profile. It deliberately is not a
`nixosConfigurations` host yet: real disk topology, generated hardware config,
SSH host key, audio devices, kernel stability, and XDNA userspace compatibility
require the delivered machine.

Use Radeon 890M Vulkan through `whisper-cpp-vulkan` as the first local Voquill
benchmark. Do not enable XRT/FastFlowLM merely because `amdxdna` loads; require
an end-to-end workload and review memlock/device permissions first. Keep hostile
honeypot agents inside the existing microVM + bubblewrap boundary with remote
inference; never pass GPU/NPU devices into that guest.

Arrival order and evidence sources are recorded in
`docs/superpowers/specs/2026-09-12-tuxedo-preparation-design.md`.
```

- [ ] **Step 3: Check docs**

Run:

```bash
git diff --check
rg -n '[T]BD|[T]ODO|[F]IXME|[P]LACEHOLDER' CLAUDE.md docs/superpowers/specs/2026-09-12-tuxedo-preparation-design.md docs/superpowers/plans/2026-09-12-tuxedo-preparation.md
```

Expected: whitespace check passes; placeholder scan returns no matches.

### Task 6: Run required verification

**Files:**

- Verify every changed Nix/test file

- [ ] **Step 1: Stage new files for flake evaluation**

```bash
git add CLAUDE.md flake.nix hosts/dellan/default.nix modules/nixos/laptop.nix modules/nixos/dell-latitude-7440.nix modules/nixos/tuxedo-infinitybook-pro-15-gen10-amd.nix tests/base.nix tests/tuxedo-profile.nix
```

- [ ] **Step 2: Run format and eval gates**

```bash
nix shell .#nixosConfigurations.dellan.pkgs.nixfmt -c nixfmt --check modules/nixos/laptop.nix modules/nixos/tuxedo-infinitybook-pro-15-gen10-amd.nix tests/tuxedo-profile.nix
nix-instantiate --parse flake.nix >/dev/null
nix-instantiate --parse hosts/dellan/default.nix >/dev/null
nix-instantiate --parse modules/nixos/dell-latitude-7440.nix >/dev/null
nix-instantiate --parse tests/base.nix >/dev/null
./scripts/check-eval-warnings.sh
nix eval .#checks.x86_64-linux --apply builtins.attrNames
```

Expected: all exit 0; authoritative lanes still include `vm-base` and
`vm-camera-relay`, with no aggregate added.

- [ ] **Step 3: Run automated behavioural gates**

```bash
nix build --no-link .#checks.x86_64-linux.vm-base -L
nix build --no-link .#checks.x86_64-linux.vm-camera-relay -L
```

Expected: both exit 0. Base runs Dell VM and builds TUXEDO contract; camera
lane completes producer-consumer frame test.

- [ ] **Step 4: Run interactive smoke because multistep scripts moved**

Follow `nixos-agent-testing`, launch `nix run .#feature-vm`, then use its SSH
channel:

```bash
systemctl cat tlp.service >/dev/null
systemctl cat thermald.service >/dev/null
systemctl start ipu6-camera-watchdog.service
systemctl is-failed ipu6-camera-watchdog.service || true
grep -q 'export LIBVA_DRIVER_NAME="iHD"' /etc/set-environment
```

Expected: services installed; watchdog not `failed`; `iHD` remains. Stop VM
through the skill's QMP shutdown path.

### Task 7: Review, commit, push, and watch CI

**Files:**

- Review complete branch diff

- [ ] **Step 1: Inspect branch delta**

```bash
git diff --cached --stat
git diff --cached --check
git diff --cached -- modules/nixos/laptop.nix modules/nixos/dell-latitude-7440.nix modules/nixos/tuxedo-infinitybook-pro-15-gen10-amd.nix tests/tuxedo-profile.nix flake.nix hosts/dellan/default.nix
```

Expected: generic/Dell blocks each exist once; no TUXEDO host or CI change.

- [ ] **Step 2: Run `advice-refine-test-loop` and re-test any fix**

Expected: no unresolved high/medium issue. Each edit gets its fastest check.

- [ ] **Step 3: Commit with production checklist**

Use actual observed evidence in this structure:

```text
feat(tuxedo): prepare AMD laptop hardware profile

Split Dell-specific laptop support from shared services and add a tested
dormant profile for the incoming InfinityBook.

Pre-push checklist:
- Type: risky
- Rebased on origin/main: yes
- Local gate: nix build --no-link .#checks.x86_64-linux.vm-base rc=0; nix build --no-link .#checks.x86_64-linux.vm-camera-relay rc=0
- Interactive smoke (nixos-agent-testing): yes — feature VM retained TLP, thermald, iHD environment, and clean camera-watchdog no-device path
- Advisor review (advice-refine-test-loop): yes — final verdict clean
- feature-vm.nix modified: no
- Risky markers in diff: ExecStart and writeShellApplication moved unchanged into dell-latitude-7440.nix
- Behavioural evidence: vm-base exercised Dell services/camera watchdog and built TUXEDO driver/Vulkan contract; vm-camera-relay completed producer-consumer frame test
```

- [ ] **Step 4: Confirm ancestry and clean state**

```bash
git fetch origin main
git merge-base --is-ancestor origin/main HEAD
git status --short --branch
```

Expected: ancestry exits 0 and worktree is clean. If main advanced, merge it
normally, re-run affected checks, and update evidence.

- [ ] **Step 5: Push and open one PR**

```bash
git push -u origin feat/tuxedo-laptop
gh pr create --base main --head feat/tuxedo-laptop --title "feat(tuxedo): prepare AMD laptop hardware profile" --body-file /tmp/tuxedo-pr-body.md
```

PR body separates local facts, sourced findings, inference, hardware-gated
work, and test evidence. Never merge from CLI.

- [ ] **Step 6: Watch required checks**

```bash
tuxedo_pr_number=$(gh pr view feat/tuxedo-laptop --json number --jq .number)
gh pr checks --watch --fail-fast "$tuxedo_pr_number"
```

Expected: all required checks green. Report PR URL and hardware-only gaps;
leave merge for deliberate GitHub UI action.
