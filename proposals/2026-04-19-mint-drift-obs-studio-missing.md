---
status: proposed
category: drift
date: 2026-04-19
source: mint-drift-agent
---

## OBS Studio not in home.packages

obs-studio is in apt-mark showmanual (user-installed) but not declared in any nix file. It will be missing on fresh install.

```
In home/desktop-apps.nix home.packages, add:
  obs-studio
```
