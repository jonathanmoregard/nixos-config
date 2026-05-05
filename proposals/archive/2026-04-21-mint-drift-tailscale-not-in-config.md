---
status: proposed
category: drift
date: 2026-04-21
source: mint-drift-agent
---

## tailscale VPN not declared anywhere in the NixOS config

tailscale is installed via apt on the live system but appears in neither home.packages nor the NixOS system modules. On NixOS, tailscale must be a system service — adding it to home.packages alone is insufficient. A fresh install would have no VPN connectivity.

```
Add to modules/nixos/desktop.nix (or a dedicated network module):

services.tailscale.enable = true;

Then on first boot run: sudo tailscale up --auth-key=<key>
```
