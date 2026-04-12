{ ... }:
{
  # Conservative nix build settings for 2GB RAM VM
  nix.settings = {
    max-jobs = 1;
    cores = 1;
    # Trigger GC automatically when store is low on space
    min-free = 134217728;  # 128 MB in bytes
  };

  # Compressed RAM swap — good for memory pressure
  zramSwap.enable = true;

  # Additional disk swap for heavy nix builds
  swapDevices = [{
    device = "/swapfile";
    size = 2048;  # MB
  }];

  # Use disk for /tmp, not RAM (saves ~200MB)
  boot.tmp.useTmpfs = false;
}
