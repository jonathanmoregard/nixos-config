---
status: proposed
category: drift
date: 2026-04-28
source: mint-drift-agent
---

## Tailscale installed on Mint but no NixOS system service declared

apt shows tailscale installed on the live system, meaning it is actively used for VPN connectivity. On NixOS, installing the tailscale package alone does nothing — the tailscaled daemon must be enabled via a system-level service. The current modules/nixos/ tree has no services.tailscale declaration, so a fresh NixOS install would have no Tailscale daemon and no VPN.

```
Add to modules/nixos/desktop.nix (or a new modules/nixos/networking.nix):

  services.tailscale.enable = true;
  # Optional but recommended — prevents firewall from blocking tailscale traffic:
  networking.firewall.checkReversePath = "loose";
```
