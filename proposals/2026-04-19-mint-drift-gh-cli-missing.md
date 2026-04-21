---
status: proposed
category: drift
date: 2026-04-19
source: mint-drift-agent
---

## GitHub CLI (gh) not in home.packages despite the zsh wrapper depending on it

jonathan.nix defines a gh() shell function that falls back to 'command gh auth login', but gh is not listed in home.packages. On fresh install gh is absent from PATH and every git remote operation using the wrapper silently fails.

```
In home/jonathan.nix home.packages, add:
  gh
```
