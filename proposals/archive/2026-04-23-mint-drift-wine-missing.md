---
status: proposed
category: drift
date: 2026-04-23
source: mint-drift-agent
---

## Wine (winehq-stable + winetricks) installed on Mint but absent from home.packages

winehq-stable and winetricks are both present in the live apt package list but are absent from desktop-apps.nix and all other home.packages declarations. On NixOS the equivalent is wineWowPackages.stable (provides both 64-bit and 32-bit Wine) plus winetricks.

```
# Add to home/desktop-apps.nix inside home.packages = with pkgs; [...]:
wineWowPackages.stable
winetricks
```
