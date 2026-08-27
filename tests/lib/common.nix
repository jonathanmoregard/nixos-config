# Shared scaffolding for the per-feature checks
# (tests/base.nix, tests/desktop.nix, tests/keyring.nix, tests/kitty.nix,
# tests/claude-pane.nix).
#
# Three builders:
#   mkTest         — full dellan host import (HM + autoLogin + everything).
#                    Lanes that exercise the integrated graphical stack
#                    use this; closure tracks the prod system.
#   mkMinimalTest  — base profile + caller-supplied extraModules. No HM,
#                    no autoLogin. Use when the lane only touches a
#                    specific system profile (e.g. keyring → /etc/pam.d/login).
#   mkFeatureTest  — base profile + extraModules + caller-supplied per-test
#                    HM entrypoint (`hm` arg → home/_test-<lane>.nix). Use
#                    when the lane exercises HM-installed bits but only a
#                    subset of feature modules. Cache hash is invariant to
#                    edits in HM modules NOT imported by the per-test
#                    entrypoint.
{ pkgs, inputs }:

let
  lib = pkgs.lib;

  # Full-host node — mirrors hosts/dellan/default.nix under the test
  # framework's read-only nixpkgs injection.
  node = { config, ... }: {
    imports = [
      inputs.agenix.nixosModules.default
      inputs.agenix-rekey.nixosModules.default
      inputs.home-manager.nixosModules.home-manager
      inputs.microvm.nixosModules.host
      ../../hosts/dellan/default.nix
      ../../modules/common.nix
    ];

    # Strip the laptop's real hardware/disk config — virtualisation module
    # provides a virtio rootfs and the test framework boots without a
    # bootloader.
    disabledModules = [ ../../hosts/dellan/hardware-configuration.nix ];

    boot.loader.systemd-boot.enable = lib.mkForce false;
    boot.loader.efi.canTouchEfiVariables = lib.mkForce false;

    home-manager = {
      useGlobalPkgs = true;
      useUserPackages = true;
      # Mirrors flake.nix's host blocks — home/aggregator-embed.nix imports
      # the embed units from the pinned aggregator source tree, so the home
      # config needs the source path.
      extraSpecialArgs = { inherit (inputs) aggregator-src; };
      users.jonathan = import ../../home/jonathan-linux.nix;
    };

    users.users.jonathan = {
      linger = true;
      initialPassword = lib.mkForce "test";
    };

    # Auto-login into a real X session so kitty has a DISPLAY to attach to
    # and we can drive it via remote control — the e2e signal the no-op
    # path alone misses.
    services.displayManager.autoLogin = {
      enable = true;
      user = "jonathan";
    };

    # GitHub Actions ubuntu-latest gives 16 GiB / 4 cores. 4 GiB / 2-core
    # (the prior sizing) had jonathan's HM activation on the knife's edge
    # of systemd's default 5min TimeoutStartSec — PR #171 moved
    # claude-desktop out of home.packages to fit, PR #175 vm-autodoro
    # still tripped it at 316s. modules/common.nix now raises the ceiling
    # to 20min AND we give the VM more headroom here so the activation
    # runs faster; leaves ~10 GiB for host + KVM overhead on the runner.
    virtualisation = {
      memorySize = 6144;
      cores = 4;
      diskSize = 8192;
    };

    # Do not boot the production microvms inside a test VM, and stub the
    # host paths they share. This node imports hosts/dellan, so without
    # both halves every full-host lane inherits research-agent and
    # scraper and tries to run them nested.
    #
    # Measured 2026-08-27, in that order, in real (uncached) vm-base runs:
    #
    #   1. With neither: virtiofsd EXITS when a share source is missing
    #      rather than degrading, so the microvm restart-loops. 64
    #      restarts in one execution, each logging
    #      `/home/jonathan/Repos/research-agent/reports does not exist`.
    #      vm-base went ~340s -> ~1840s and CI failed the lane on its
    #      wall-clock budget with no assertion failing anywhere.
    #
    #   2. With the tmpfiles stubs ALONE: the restart loop is gone (2
    #      start events, zero virtiofsd errors) but the microvm now boots
    #      far enough to reach research-agent-egress-init, which resolves
    #      allowlist FQDNs into an nftables set. That unit retries DNS
    #      forever under TimeoutStartSec=infinity — deliberately, so an
    #      offline laptop cannot strand the host — and a test VM has no
    #      egress, so multi-user.target blocks indefinitely. Observed
    #      hanging past 11min on a single start job. Strictly worse than
    #      the crash loop, which at least terminated.
    #
    # So the property every lane needs is not "make the share exist", it
    # is "do not boot nested production microvms". The stubs stay because
    # tests/base.nix builds under /home/jonathan/Repos and expects the
    # path to be present, and because scraper-microvm.nix shares the
    # research-agent level too.
    #
    # This mirrors tests/microvm.nix, which had both halves from the
    # start; that is why vm-microvm was immune and why the pattern read
    # as microvm-lane-specific rather than as a property of every
    # full-host lane. It also hid behind cachix, which serves a cached
    # vm-base for any PR that does not perturb the HM closure, so no CI
    # run had actually EXECUTED the lane since the microvm landed.
    # Living here, in the node every full-host lane builds on, no future
    # lane has to remember either half.
    #
    # Unit installation and the qemu runner contract are still asserted,
    # by vm-microvm. Full boot + ssh + egress smoke lives in the
    # interactive `nix run .#feature-vm`, per the SessionStart HARD RULE.
    #
    # All three tmpfiles levels are listed deliberately: tmpfiles creates
    # missing parents as root, and the jonathan -> root -> jonathan
    # ownership hop makes it refuse with "unsafe path transition".
    systemd.tmpfiles.rules = [
      "d /home/jonathan/Repos 0755 jonathan users -"
      "d /home/jonathan/Repos/research-agent 0755 jonathan users -"
      "d /home/jonathan/Repos/research-agent/reports 0755 jonathan users -"
    ];
    systemd.services."install-microvm-research-agent".wantedBy =
      lib.mkForce [ ];
    systemd.services."microvm@research-agent".wantedBy = lib.mkForce [ ];
    systemd.services."microvm-virtiofsd@research-agent".wantedBy =
      lib.mkForce [ ];
    systemd.services."install-microvm-scraper".wantedBy = lib.mkForce [ ];
    systemd.services."microvm@scraper".wantedBy = lib.mkForce [ ];
    systemd.services."microvm-virtiofsd@scraper".wantedBy = lib.mkForce [ ];
  };

  # Minimal node — base profile + agenix scaffolding only. Lanes opt in
  # to feature profiles via `extraModules`.
  mkMinimalNode = extraModules: { config, ... }: {
    imports = [
      inputs.agenix.nixosModules.default
      ../../profiles/base.nix
    ] ++ extraModules;

    boot.loader.systemd-boot.enable = lib.mkForce false;
    boot.loader.efi.canTouchEfiVariables = lib.mkForce false;

    users.users.jonathan.initialPassword = lib.mkForce "test";

    virtualisation = {
      memorySize = 1024;
      cores = 2;
      diskSize = 2048;
    };
  };

  # Feature node — base + agenix + extraModules + a per-test HM
  # entrypoint. The HM entrypoint (e.g. home/_test-claude-pane.nix)
  # imports only the HM modules the lane exercises, so the resulting
  # vm-* derivation hash is independent of HM modules NOT in that import
  # graph.
  mkFeatureNode = { extraModules, hm }: { config, ... }: {
    imports = [
      inputs.agenix.nixosModules.default
      inputs.home-manager.nixosModules.home-manager
      ../../profiles/base.nix
    ] ++ extraModules;

    boot.loader.systemd-boot.enable = lib.mkForce false;
    boot.loader.efi.canTouchEfiVariables = lib.mkForce false;

    home-manager = {
      useGlobalPkgs = true;
      useUserPackages = true;
      # Passed even though no per-lane HM entrypoint imports the aggregator
      # module today: an unused specialArg costs nothing, and a lane that
      # starts importing it should not fail with an unrelated "called
      # without required argument" error.
      extraSpecialArgs = { inherit (inputs) aggregator-src; };
      users.jonathan = import hm;
    };

    users.users.jonathan = {
      linger = true;
      initialPassword = lib.mkForce "test";
    };

    virtualisation = {
      memorySize = 2048;
      cores = 2;
      diskSize = 4096;
    };
  };
in
{
  # skipTypeCheck mirrors the original monolith — mypy mis-parses some
  # of the testScript heredocs (e.g. `import json` indent in claude-pane);
  # keeping it uniform across lanes avoids surprise when blocks move.
  mkTest = { name, testScript }: pkgs.testers.runNixOSTest {
    inherit name testScript;
    skipTypeCheck = true;
    nodes.dellan = node;
  };

  mkMinimalTest = { name, testScript, extraModules ? [] }:
    pkgs.testers.runNixOSTest {
      inherit name testScript;
      skipTypeCheck = true;
      nodes.dellan = mkMinimalNode extraModules;
    };

  mkFeatureTest = { name, testScript, hm, extraModules ? [] }:
    pkgs.testers.runNixOSTest {
      inherit name testScript;
      skipTypeCheck = true;
      nodes.dellan = mkFeatureNode { inherit extraModules hm; };
    };
}
