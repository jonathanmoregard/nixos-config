---
status: proposed
category: drift
date: 2026-04-19
source: mint-drift-agent
---

## ~/.huskyrc is untracked

~/.huskyrc configures the husky git-hooks manager and is listed as UNTRACKED. It is not managed by home-manager and will be lost on fresh install.

```
Add to home/jonathan.nix:
  home.file.".huskyrc".source = ../dotfiles/huskyrc;
and commit the live ~/.huskyrc to dotfiles/huskyrc.
```
