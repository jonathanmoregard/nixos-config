# modules/nixos/build-coordination.nix
#
# Nix daemon settings for parallel VM-lane testing on dellan.
# Caps total thread usage to 12 (3 lanes × 4 cores) so parallel CI
# work doesn't starve the daily-driver.
{ config, lib, pkgs, ... }:
{
  options.services.buildCoordination = {
    enable = lib.mkEnableOption "build coordination caps for 3 parallel VM lanes";
  };

  config = lib.mkIf config.services.buildCoordination.enable {
    nix.settings = {
      max-jobs = 3;     # at most 3 derivations building concurrently
      cores = 4;        # 4 threads per build → 12-thread cap total
    };
  };
}
