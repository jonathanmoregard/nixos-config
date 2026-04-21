---
status: proposed
category: drift
date: 2026-04-19
source: mint-drift-agent
---

## Touchpad two-finger-scrolling key name is wrong in cinnamon.nix

cinnamon.nix sets two-finger-scroll-enabled but the actual dconf key for org.cinnamon.desktop.peripherals.touchpad is two-finger-scrolling-enabled. The setting is silently ignored, leaving scrolling behaviour governed by the system default.

```
In home/cinnamon.nix, under dconf.settings."org/cinnamon/desktop/peripherals/touchpad", rename the key:
  two-finger-scroll-enabled = true;
to:
  two-finger-scrolling-enabled = true;
```
