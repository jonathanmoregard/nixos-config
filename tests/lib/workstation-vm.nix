# The daily-driver workstation as a QEMU test guest: the same modules
# flake.nix's mkWorkstation builds the real host from, minus what a VM
# cannot model. Every full-host node imports it (tests/lib/common.nix
# `node`, tests/microvm.nix), and lanes call that node `workstation`.
#
# Which host it models is flake.nix's `primaryHost`, passed in as
# `workstation.host` with `workstation.modules` (= workstationModules).
# A machine upgrade is a change to `primaryHost`, not to the tests.
{ workstation }:
{ lib, pkgs, ... }:
let
  hostDir = ../../hosts + "/${workstation.host}";
  githubAppKeyFixture = import ./github-app-key-fixture.nix { inherit pkgs; };
in
{
  imports = workstation.modules ++ [ (hostDir + "/default.nix") ];

  # The GitHub App key the broker signs with
  # (modules/nixos/github-app-broker), as a fixture this VM can open: the
  # real ciphertext is encrypted to the laptop's host key, and may not exist
  # yet.
  age.identityPaths = [ "${githubAppKeyFixture}/id_ed25519" ];
  services.githubAppBroker.keyCiphertext =
    lib.mkForce "${githubAppKeyFixture}/github-app-key.age";

  # The laptop's real hardware/disk config. The virtualisation module
  # provides a virtio rootfs and the test framework boots without a
  # bootloader.
  disabledModules = [ (hostDir + "/hardware-configuration.nix") ];
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.efi.canTouchEfiVariables = lib.mkForce false;

  # Hardware-only options a QEMU guest cannot model, forced off whatever
  # host is primary (a no-op where a host leaves one off). A new host that
  # enables another platform driver adds it here.
  #
  # tuxedo-drivers: boot.kernelModules loads tuxedo_keyboard, which probes
  # the laptop's embedded controller, and a udev rule writes the charging
  # profile into that driver's sysfs. The driver's build against the
  # profile's kernel stays gated by tests/tuxedo-profile.nix, which vm-base
  # builds.
  hardware.tuxedo-drivers.enable = lib.mkForce false;

  # The NixOS test framework turns the manual off for every node
  # (nixos/lib/testing/nixos-test-base.nix, "no-manual"), so
  # system.build.manual does not exist, and modules/nixos/offline-ai.nix
  # interpolates its optionsJSON and manualHTML into the offline-ai
  # wrapper. An empty stand-in lets the node evaluate without building the
  # manual. No VM lane runs offline-ai; the wrapper the host really
  # deploys, manual paths included, is exercised by the `offline-ai` check.
  system.build.manual =
    let
      stub = pkgs.runCommand "nixos-manual-test-stub" { } ''
        mkdir -p "$out/share/doc/nixos"
        printf '{}\n' > "$out/share/doc/nixos/options.json"
      '';
    in
    {
      optionsJSON = stub;
      manualHTML = stub;
    };
}
