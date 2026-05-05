---
status: proposed
category: drift
date: 2026-04-27
source: mint-drift-agent
---

## Wine (winehq-stable + winetricks) installed on live but not in NixOS config

The apt package list includes winehq-stable and winetricks but no Wine package appears in home.packages or systemPackages. Any Windows-compatibility workflows would be unavailable on a fresh install.

```
Add to home/desktop-apps.nix home.packages:

  wineWowPackages.stable  # 32+64-bit Wine; use pkgs.wine for 64-bit only
  winetricks
```
