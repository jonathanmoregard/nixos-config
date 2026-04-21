---
status: implemented
category: drift
date: 2026-04-17
source: mint-drift-agent
---

## Cinnamon interface clock-use-24h and font-name not in dconf

Live has org.cinnamon.desktop.interface clock-use-24h=true and font-name='Ubuntu 10'. Neither key is in the 'org/cinnamon/desktop/interface' dconf block (only the gnome schema gets font-name). Cinnamon reads its own schema for the panel clock and font.

```
# In cinnamon.nix dconf.settings, add to "org/cinnamon/desktop/interface":
clock-use-24h = true;
font-name = "Ubuntu 10";
```
