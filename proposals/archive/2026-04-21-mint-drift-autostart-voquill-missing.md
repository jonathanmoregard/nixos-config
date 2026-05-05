---
status: proposed
category: drift
date: 2026-04-21
source: mint-drift-agent
---

## Voquill (local) autostart entry not captured in config

~/.config/autostart/Voquill (local).desktop is present on the live system and will launch Voquill at every login. There is no corresponding home.file autostart declaration in cinnamon.nix or anywhere else in the config. On a fresh NixOS install Voquill will never start automatically.

```
Inspect the live file (`cat ~/.config/autostart/Voquill\ \(local\).desktop`) then add to home/cinnamon.nix:

home.file.".config/autostart/voquill.desktop".text = ''
  [Desktop Entry]
  Type=Application
  Name=Voquill
  Exec=<Exec line from live file>
  Hidden=false
  X-GNOME-Autostart-enabled=true
'';
```
