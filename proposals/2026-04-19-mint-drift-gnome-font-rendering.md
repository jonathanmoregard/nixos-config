---
status: proposed
category: drift
date: 2026-04-19
source: mint-drift-agent
---

## Font antialiasing, hinting, and auxiliary fonts not declared

Live system sets font-antialiasing = 'grayscale', font-hinting = 'slight', monospace-font-name = 'DejaVu Sans Mono 10', and document-font-name = 'Sans 10' in org.gnome.desktop.interface. None are in the config; fresh install gets different font rendering across GTK apps.

```
In home/cinnamon.nix dconf.settings."org/gnome/desktop/interface", add:
  font-antialiasing = "grayscale";
  font-hinting = "slight";
  monospace-font-name = "DejaVu Sans Mono 10";
  document-font-name = "Sans 10";
```
