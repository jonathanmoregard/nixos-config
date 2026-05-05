---
status: proposed
category: drift
date: 2026-04-24
source: mint-drift-agent
---

## .huskyrc dotfile is not tracked by home-manager

~/.huskyrc exists on the live system and is listed as UNTRACKED (not symlinked, not managed via home.file). Husky uses this as the global git hooks configuration file. Its contents will be absent on a fresh install.

```
# Option A — inline content in home/jonathan.nix:
home.file.".huskyrc".text = ''
  # paste output of: cat ~/.huskyrc
'';
# Option B — track in dotfiles repo:
home.file.".huskyrc".source = ../dotfiles/huskyrc;
```
