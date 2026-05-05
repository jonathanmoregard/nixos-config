---
status: proposed
category: drift
date: 2026-04-23
source: mint-drift-agent
---

## tailscale installed on Mint but absent from NixOS system config

tailscale and tailscale-archive-keyring are both in the live apt package list. On NixOS, tailscale requires services.tailscale.enable = true at the system level to start the tailscaled daemon. No such declaration appears in modules/nixos/desktop.nix or any other provided module. The VPN would be completely unavailable on a fresh NixOS install.

```
# Add to a NixOS system module (e.g. modules/nixos/desktop.nix or a new modules/nixos/networking.nix):
services.tailscale.enable = true;
# The tailscale package and daemon are included automatically by the service module.
```
