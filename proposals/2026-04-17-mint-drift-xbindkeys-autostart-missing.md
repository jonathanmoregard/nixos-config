---
status: implemented
category: drift
date: 2026-04-17
source: mint-drift-agent
---

## xbindkeys autostart not declared in config

Live system has ~/.config/autostart/xbindkeys.desktop and xbindkeys in apt-mark showmanual. Neither the package nor the autostart entry exists in home-manager. xbindkeys keybindings would be absent after rebuild.

```
# In home/cinnamon.nix, add to home.packages:
xbindkeys

# Add autostart entry:
home.file.".config/autostart/xbindkeys.desktop".text = ''
  [Desktop Entry]
  Type=Application
  Name=xbindkeys
  Exec=xbindkeys
  Hidden=false
  X-GNOME-Autostart-enabled=true
'';
```
