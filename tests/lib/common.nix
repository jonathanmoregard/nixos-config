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
      users.jonathan = import ../../home/jonathan-linux.nix;
    };

    users.users.jonathan = {
      linger = true;
      initialPassword = lib.mkForce "test";
    };

    # Auto-login into a real X session so kitty has a DISPLAY to attach to
    # and we can drive it via remote control — the e2e signal the no-op
    # path alone misses.
    services.xserver.displayManager.autoLogin = {
      enable = true;
      user = "jonathan";
    };

    virtualisation = {
      memorySize = 4096;
      cores = 2;
      diskSize = 8192;
    };
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
