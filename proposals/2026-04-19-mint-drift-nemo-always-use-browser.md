---
status: proposed
category: drift
date: 2026-04-19
source: mint-drift-agent
---

## Nemo always-use-browser = true not declared

Live system has org.nemo.preferences always-use-browser = true (browser-mode navigation). Not in config; fresh install defaults to spatial mode (a new window per folder).

```
In home/cinnamon.nix dconf.settings."org/nemo/preferences", add:
  always-use-browser = true;
```
