---
status: proposed
category: drift
date: 2026-04-19
source: mint-drift-agent
---

## Voquill (local).desktop in autostart is not captured

~/.config/autostart/Voquill (local).desktop exists on the live system but is not declared in the nix config. Whatever Voquill is, it will not autostart on fresh install.

```
Inspect the live file to identify the binary and flags:
  cat ~/.config/autostart/'Voquill (local).desktop'
Then add it to home.packages and declare the autostart in home/cinnamon.nix:
  home.file.".config/autostart/Voquill (local).desktop".text = <content from live file>;
```
