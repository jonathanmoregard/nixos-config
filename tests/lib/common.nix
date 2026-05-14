# Shared scaffolding for the per-feature checks
# (tests/base.nix, tests/desktop.nix, tests/keyring.nix, tests/kitty.nix,
# tests/claude-pane.nix).
#
# Two builders:
#   mkTest         — full dellan host import (HM + autoLogin + everything).
#                    Lanes that exercise HM-installed bits or graphical
#                    state use this; closure tracks the prod system.
#   mkMinimalTest  — base profile + caller-supplied extraModules. No HM,
#                    no autoLogin. Use when the lane only touches a
#                    specific profile (e.g. keyring → /etc/pam.d/login)
#                    so its derivation hash is independent of unrelated
#                    files; cachix can then serve it across PRs that
#                    don't touch the relevant profile.
{ pkgs, inputs }:

let
  lib = pkgs.lib;

  # Full-host node — mirrors hosts/dellan/default.nix under the test
  # framework's read-only nixpkgs injection.
  node = { config, ... }: {
    imports = [
      inputs.agenix.nixosModules.default
      inputs.home-manager.nixosModules.home-manager
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
}
