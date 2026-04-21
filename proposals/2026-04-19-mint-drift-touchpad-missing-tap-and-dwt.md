---
status: proposed
category: drift
date: 2026-04-19
source: mint-drift-agent
---

## tap-to-click and disable-while-typing missing from touchpad config

Live gsettings shows tap-to-click = true and disable-while-typing = true for org.cinnamon.desktop.peripherals.touchpad, but neither is declared in cinnamon.nix. Both revert to defaults on fresh install.

```
In home/cinnamon.nix dconf.settings."org/cinnamon/desktop/peripherals/touchpad", add:
  tap-to-click = true;
  disable-while-typing = true;
```
