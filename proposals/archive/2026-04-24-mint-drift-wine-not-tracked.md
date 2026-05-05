---
status: proposed
category: drift
date: 2026-04-24
source: mint-drift-agent
---

## winehq-stable and winetricks not in home.packages

winehq-stable and winetricks are explicitly installed on the live system and not present in any nix module. Running Windows binaries would break on a fresh install.

```
# In home/desktop-apps.nix, add to home.packages:
wineWowPackages.stable
winetricks
```
