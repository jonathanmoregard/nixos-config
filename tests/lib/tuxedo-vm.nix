# hosts/tuxedo as a QEMU test guest: the real host module minus what a VM
# cannot model. Imported by every full-host node (tests/lib/common.nix
# `node`, tests/microvm.nix), so each of these holds in one place.
{ lib, pkgs, ... }:
{
  imports = [ ../../hosts/tuxedo/default.nix ];

  # The laptop's real hardware/disk config. The virtualisation module
  # provides a virtio rootfs and the test framework boots without a
  # bootloader.
  disabledModules = [ ../../hosts/tuxedo/hardware-configuration.nix ];

  # The TUXEDO platform driver: boot.kernelModules loads tuxedo_keyboard,
  # which probes the laptop's embedded controller, and a udev rule writes
  # the charging profile into that driver's sysfs. A QEMU guest has
  # neither. The driver's build against the profile's kernel is still
  # gated by tests/tuxedo-profile.nix, which vm-base builds.
  hardware.tuxedo-drivers.enable = lib.mkForce false;

  # The NixOS test framework turns the manual off for every node
  # (nixos/lib/testing/nixos-test-base.nix, "no-manual"), so
  # system.build.manual does not exist, and modules/nixos/offline-ai.nix
  # interpolates its optionsJSON and manualHTML into the offline-ai
  # wrapper. An empty stand-in lets the node evaluate without building
  # the manual. No VM lane runs offline-ai; the wrapper tuxedo really
  # deploys, manual paths included, is exercised by the `offline-ai`
  # check.
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
