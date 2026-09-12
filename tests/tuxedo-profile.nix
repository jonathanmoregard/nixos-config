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
