---
status: proposed
category: drift
date: 2026-04-19
source: mint-drift-agent
---

## Nemo thumbnail-limit 32 GB not captured

Live system sets org.nemo.preferences thumbnail-limit = 34359738368 (32 GB). The upstream default is 10 MB. Not in config; fresh install stops generating thumbnails for anything above the tiny default.

```
In home/cinnamon.nix dconf.settings."org/nemo/preferences", add:
  thumbnail-limit = lib.gvariant.mkUint64 34359738368;
```
