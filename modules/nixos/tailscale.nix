{ ... }:
# Tailscale mesh VPN. After rebuild, `sudo tailscale up` once to auth.
{
  services.tailscale.enable = true;
}
