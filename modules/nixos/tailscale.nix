{ ... }:
# Tailscale mesh VPN. After rebuild, `sudo tailscale up` once to auth.
# Comment-only churn under ci-stability-101 (2026-05-25) to exercise CI; revert before merge.
{
  services.tailscale.enable = true;
}
