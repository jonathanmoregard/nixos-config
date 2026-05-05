---
status: proposed
category: drift
date: 2026-04-24
source: mint-drift-agent
---

## touchegg installed and gesture bindings configured but service not enabled in NixOS

The live system has touchegg installed (apt-mark showmanual) and cinnamon.nix configures org.cinnamon.gestures.* swipe/tap bindings. org.cinnamon.gestures.enabled is false on the live system, which means Cinnamon's built-in gesture engine is off and events are routed through touchegg instead. Without services.touchegg.enable = true in the NixOS system config, the swipe/tap bindings in cinnamon.nix will silently do nothing after a fresh install.

```
# In modules/nixos/desktop.nix:
services.touchegg.enable = true;
```
