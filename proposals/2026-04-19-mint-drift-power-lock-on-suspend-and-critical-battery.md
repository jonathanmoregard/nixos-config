---
status: proposed
category: drift
date: 2026-04-19
source: mint-drift-agent
---

## lock-on-suspend and critical-battery-action not declared

Live system has lock-on-suspend = true and critical-battery-action = 'hibernate' in org.cinnamon.settings-daemon.plugins.power. Both are absent from cinnamon.nix: the screen will not lock on suspend and a critically low battery will not hibernate on fresh install.

```
In home/cinnamon.nix dconf.settings."org/cinnamon/settings-daemon/plugins/power", add:
  lock-on-suspend = true;
  critical-battery-action = "hibernate";
```
