# Swap + zram for tuxedo. Same two layers as hosts/dellan/swap.nix (see its
# header for the OOM incident that motivated them): zram first, then a
# 16 GiB swapfile on the LUKS-backed root as the backstop. 64 GiB RAM makes
# the backstop rarer, not unnecessary — the microvms and Chrome still burst.
{ ... }:
{
  zramSwap.enable = true;

  # Test VMs override the size in tests/lib/common.nix `node`.
  swapDevices = [{
    device = "/var/lib/swapfile";
    size = 16384;  # MiB
  }];
}
