---
status: proposed
category: drift
date: 2026-04-19
source: mint-drift-agent
---

## Default terminal exec-arg is -e instead of --

Live system has org.cinnamon.desktop.default-applications.terminal exec-arg = '--'. The nix config declares exec-arg = "-e", which is an xterm flag that Ghostty does not recognise. Commands launched from file managers and other apps that open a terminal will fail.

```
In home/cinnamon.nix dconf.settings."org/cinnamon/desktop/default-applications/terminal":
  exec-arg = "--";
```
