{ pkgs, inputs }:
let
  lib = pkgs.lib;
  # Use the flake entrypoint so nixpkgs injects its source with proper string
  # context. Importing eval-config.nix through pkgs.path makes Determinate Nix
  # synthesize an invalid double-hashed source path during parallel evaluation.
  evaluated = inputs.nixpkgs.lib.nixosSystem {
    pkgs = pkgs;
    modules = [
      ../modules/nixos/tuxedo-infinitybook-pro-15-gen10-amd.nix
      {
        boot.loader.grub.enable = false;
        # This eval-only contract inspects environment.systemPackages. Keep the
        # unrelated NixOS manual and its options.json derivation out of that list.
        documentation.enable = false;
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
# Option values the module sets are not restated here; evaluating and
# building this profile is their check. Kept: the kernel-parameter guards
# (nothing may force these before suspend/GPU stress is measured on the real
# machine) and the out-of-tree driver build against the profile's kernel.
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
