---
status: proposed
category: drift
date: 2026-04-24
source: mint-drift-agent
---

## tailscale installed on live system but absent from NixOS config

tailscale appears in apt-mark showmanual (explicitly user-installed) but no services.tailscale declaration exists in any visible NixOS module. The VPN and its tunnel interface will be absent after a fresh install.

```
# In modules/nixos/desktop.nix or a new modules/nixos/networking.nix:
services.tailscale.enable = true;
networking.firewall.trustedInterfaces = [ "tailscale0" ];
networking.firewall.allowedUDPPorts = [ config.services.tailscale.port ];
```
