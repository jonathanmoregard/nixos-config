---
status: proposed
category: drift
date: 2026-04-27
source: mint-drift-agent
---

## Tailscale installed on live system but absent from NixOS config

The apt package list includes 'tailscale' and 'tailscale-archive-keyring'. Neither services.tailscale.enable nor the tailscale package appears anywhere in the NixOS modules or home-manager files. A fresh NixOS install would have no mesh VPN.

```
Add to modules/nixos/desktop.nix (or a dedicated modules/nixos/networking.nix):

  services.tailscale.enable = true;
  environment.systemPackages = [ pkgs.tailscale ];
```
