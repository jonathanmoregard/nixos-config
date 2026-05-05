---
status: discarded
category: drift
date: 2026-04-17
source: mint-drift-agent
---

## OBS Studio not in home packages

obs-studio is in apt-mark showmanual, indicating deliberate installation, but is absent from desktop-apps.nix. It would not be present after a rebuild.

```
# In home/desktop-apps.nix, add to home.packages:
obs-studio
```
