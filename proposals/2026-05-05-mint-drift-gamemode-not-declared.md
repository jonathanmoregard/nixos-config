---
status: proposed
category: drift
subcategory: package
date: 2026-05-05
source: mint-drift-agent
---

## gamemode / gamemode-daemon not in nixos-config

gamemode and gamemode-daemon are manually installed on Mint but absent from nixos-config. NixOS exposes a programs.gamemode module. Without it, any game or launcher that calls gamemoderun for CPU/GPU performance tuning degrades silently on a fresh install (no error, just no boost).

```
# In modules/nixos/laptop.nix:
programs.gamemode.enable = true;
```
