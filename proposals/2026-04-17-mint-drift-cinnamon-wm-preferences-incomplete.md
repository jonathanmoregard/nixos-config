---
status: implemented
category: drift
date: 2026-04-17
source: mint-drift-agent
---

## Cinnamon WM preferences declared only in gnome schema

button-layout, titlebar-font, num-workspaces, theme, audible-bell, resize-with-right-button are set under 'org/gnome/desktop/wm/preferences' in cinnamon.nix but Muffin (Cinnamon's WM) reads from 'org/cinnamon/desktop/wm/preferences'. Only min-window-opacity is set in the cinnamon schema.

```
# In cinnamon.nix dconf.settings, expand 'org/cinnamon/desktop/wm/preferences':
"org/cinnamon/desktop/wm/preferences" = {
  min-window-opacity = 30;
  button-layout = ":minimize,maximize,close";
  titlebar-font = "Ubuntu Medium 10";
  titlebar-uses-system-font = false;
  num-workspaces = 4;
  theme = "Mint-Y";
  audible-bell = false;
  resize-with-right-button = true;
  focus-mode = "click";
  action-double-click-titlebar = "toggle-maximize";
  action-middle-click-titlebar = "lower";
};
```
