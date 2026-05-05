---
status: proposed
category: drift
date: 2026-04-27
source: mint-drift-agent
---

## Voquill (local).desktop autostart not captured in config

The live autostart directory contains 'Voquill (local).desktop' which does not correspond to any home.file entry in cinnamon.nix. The four other autostart entries (Beeper, Dropbox, KeePassXC, xbindkeys) are all declared; this one is not. On a fresh install Voquill would not launch at login.

```
First inspect the live file to get the correct Exec line:

  cat ~/.config/autostart/'Voquill (local).desktop'

Then add to home/cinnamon.nix:

  home.file.".config/autostart/voquill.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Voquill
    Exec=<value from Exec= line above>
    Hidden=false
    X-GNOME-Autostart-enabled=true
  '';
```
