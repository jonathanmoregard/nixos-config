{ ... }:
# Tailscale mesh VPN. After rebuild, `sudo tailscale up` once to auth.
# Comment-only churn under ci-stability-loop-2 to exercise CI; revert before merge.
{
  services.tailscale.enable = true;
}
