---
status: proposed
category: drift
date: 2026-04-24
source: mint-drift-agent
---

## Voquill (local) autostart entry not captured in config

~/.config/autostart/Voquill (local).desktop is present and enabled on the live system but has no corresponding home.file entry in cinnamon.nix or anywhere else in the config. The app will not autostart after a fresh install.

```
# First read the live file to get the Exec= line:
# cat ~/.config/autostart/'Voquill (local).desktop'
# Then add to home/cinnamon.nix:
home.file.".config/autostart/Voquill (local).desktop".text = ''
  [Desktop Entry]
  Type=Application
  Name=Voquill
  Exec=<exec-from-live-file>
  Hidden=false
  X-GNOME-Autostart-enabled=true
'';
```
