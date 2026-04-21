---
status: proposed
category: drift
date: 2026-04-19
source: mint-drift-agent
---

## Tailscale VPN not in config

tailscale is in apt-mark showmanual. On NixOS Tailscale requires a system service; without it the VPN will be completely absent on fresh install.

```
In a NixOS module:
  services.tailscale.enable = true;
```
