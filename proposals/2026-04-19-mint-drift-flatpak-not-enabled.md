---
status: proposed
category: drift
date: 2026-04-19
source: mint-drift-agent
---

## services.flatpak.enable not declared despite Flatpak being installed

flatpak appears in apt-mark showmanual and two Flatpak apps (Discord, Android Studio) are installed. modules/nixos/desktop.nix does not enable services.flatpak. On fresh install, any workflow that relies on the Flatpak runtime (portals, sandboxed apps) will break.

```
In modules/nixos/desktop.nix:
  services.flatpak.enable = true;
```
