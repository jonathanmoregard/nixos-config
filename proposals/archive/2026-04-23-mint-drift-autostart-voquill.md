---
status: proposed
category: drift
date: 2026-04-23
source: mint-drift-agent
---

## Voquill (local) autostart entry not declared in home-manager

~/.config/autostart/Voquill (local).desktop exists on the live system but has no corresponding home.file entry in home/cinnamon.nix. It will not be recreated on a fresh build. The Exec command is unknown without reading the file.

```
cat ~/.config/autostart/'Voquill (local).desktop'
# Then add to home/cinnamon.nix:
home.file.".config/autostart/Voquill (local).desktop".text = ''
  [Desktop Entry]
  Type=Application
  Name=Voquill (local)
  Exec=<paste Exec= value from above>
  Hidden=false
  X-GNOME-Autostart-enabled=true
'';
```
