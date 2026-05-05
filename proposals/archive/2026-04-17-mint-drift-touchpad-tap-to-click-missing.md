---
status: implemented
category: drift
date: 2026-04-17
source: mint-drift-agent
---

## Touchpad tap-to-click and tap-and-drag absent from dconf config

Live system has org.cinnamon.desktop.peripherals.touchpad tap-to-click=true and tap-and-drag=true. These keys are absent from the 'org/cinnamon/desktop/peripherals/touchpad' block in cinnamon.nix. A rebuild would leave tap-to-click disabled.

```
# In cinnamon.nix dconf.settings, update the touchpad block:
"org/cinnamon/desktop/peripherals/touchpad" = {
  two-finger-scrolling-enabled = true;
  natural-scroll = true;
  tap-to-click = true;
  tap-and-drag = true;
  disable-while-typing = true;
};
```
