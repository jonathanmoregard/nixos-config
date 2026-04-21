---
status: proposed
category: drift
date: 2026-04-19
source: mint-drift-agent
---

## org/cinnamon/desktop/wm/preferences is missing all key window manager settings

button-layout, titlebar-font, titlebar-uses-system-font, audible-bell, resize-with-right-button, num-workspaces, and theme are set in org/gnome/desktop/wm/preferences but not in org/cinnamon/desktop/wm/preferences. Cinnamon reads its own schema; the gnome keys do not propagate. A fresh install gets Cinnamon defaults (e.g. wrong button layout, wrong titlebar font, only 2 workspaces).

```
In home/cinnamon.nix, expand dconf.settings."org/cinnamon/desktop/wm/preferences":
  button-layout = ":minimize,maximize,close";
  titlebar-font = "Ubuntu Medium 10";
  titlebar-uses-system-font = false;
  audible-bell = false;
  resize-with-right-button = true;
  num-workspaces = 4;
  theme = "Mint-Y";
```
