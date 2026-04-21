---
status: proposed
category: drift
date: 2026-04-19
source: mint-drift-agent
---

## xbindkeys package and autostart entry not declared

xbindkeys is user-installed and has an autostart entry (~/.config/autostart/xbindkeys.desktop). Neither the package nor the autostart is in the nix config. Keyboard remappings loaded from ~/.xbindkeysrc will be absent on fresh install, and the config file itself is not tracked.

```
In home/cinnamon.nix:
1. Add to home.packages: xbindkeys
2. Add autostart:
   home.file.".config/autostart/xbindkeys.desktop".text = ''
     [Desktop Entry]
     Type=Application
     Name=xbindkeys
     Exec=xbindkeys
     Hidden=false
     X-GNOME-Autostart-enabled=true
   '';
3. Capture the key bindings:
   home.file.".xbindkeysrc".source = ../dotfiles/xbindkeysrc;
   (and commit the live ~/.xbindkeysrc to dotfiles/xbindkeysrc)
```
