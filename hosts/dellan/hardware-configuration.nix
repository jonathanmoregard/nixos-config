# Placeholder — overwritten by `nixos-generate-config --root /mnt` on the target machine.
# After running nixos-generate-config on dellan, copy the generated file here and commit.
#
# Target install uses LUKS + btrfs subvolumes (@, @home, @nix, @log).
# nixos-generate-config will produce boot.initrd.luks.devices.cryptroot
# and fileSystems entries with `subvol=` options automatically.
# If btrfs is missing from boot.supportedFilesystems after generation, add it manually.
{ config, lib, pkgs, modulesPath, ... }:
{
  imports = [ ];

  boot.initrd.availableKernelModules = [ ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  fileSystems = { };
  swapDevices = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
