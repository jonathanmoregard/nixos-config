---
status: proposed
category: drift
date: 2026-04-19
source: mint-drift-agent
---

## terraform, direnv, and jq not in home.packages

All three appear in apt-mark showmanual (explicit user installs) but are absent from every nix file. They will be missing on fresh install.

```
In home/jonathan.nix home.packages, add:
  terraform
  direnv
  jq
```
