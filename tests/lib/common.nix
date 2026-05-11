# Shared dellan-VM scaffolding for the per-feature checks
# (tests/base.nix, tests/desktop.nix, tests/keyring.nix, tests/kitty.nix,
# tests/claude-pane.nix).
#
# Lifts the node config out of every lane so the 5 test files don't
# each redeclare imports / disabledModules / autoLogin / linger /
# virtualisation. The testScript stays explicit per-lane so each lane
# is self-contained when read top-to-bottom.
{ pkgs, inputs }:

let
  lib = pkgs.lib;

  # Same dellan-in-a-VM node every lane uses. Mirrors the production
  # host config (hosts/dellan/default.nix) under the test framework's
  # read-only nixpkgs injection.
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
in
{
  # Each lane calls `mkTest { name = "vm-..."; testScript = ''...''; }`.
  # skipTypeCheck mirrors the original monolith — mypy mis-parses some
  # of the testScript heredocs (e.g. `import json` indent in claude-pane);
  # keeping it uniform across lanes avoids surprise when blocks move.
  mkTest = { name, testScript }: pkgs.testers.runNixOSTest {
    inherit name testScript;
    skipTypeCheck = true;
    nodes.dellan = node;
  };
}
