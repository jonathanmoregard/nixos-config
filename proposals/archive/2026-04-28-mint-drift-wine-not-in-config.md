---
status: proposed
category: drift
date: 2026-04-28
source: mint-drift-agent
---

## Wine (winehq-stable + winetricks) installed on Mint but not declared in NixOS config

Both winehq-stable and winetricks are in the apt manual-install list, indicating the user runs Windows applications under Wine. Neither package appears in any home.packages list or NixOS module in the config. On a fresh NixOS install, any .exe launchers or Wine prefixes would have nothing to execute them.

```
Add to home/desktop-apps.nix:

  home.packages = with pkgs; [
    # ... existing packages ...
    wineWowPackages.stable  # 32+64-bit Wine, matches winehq-stable behaviour
    winetricks
  ];
```
