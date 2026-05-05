---
status: proposed
category: drift
date: 2026-04-21
source: mint-drift-agent
---

## Wine (winehq-stable + winetricks) not in home.packages

winehq-stable and winetricks are installed via apt on the live system. Neither appears in desktop-apps.nix or any home.packages list. Any Windows applications run through Wine would be unavailable after a fresh NixOS install.

```
Add to home/desktop-apps.nix:

home.packages = with pkgs; [
  # ...existing...
  wineWowPackages.stable
  winetricks
];
```
