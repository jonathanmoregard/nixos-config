---
status: proposed
category: drift
date: 2026-04-19
source: mint-drift-agent
---

## ~/.config/git/ignore (global gitignore) is untracked

~/.config/git/ignore is listed as UNTRACKED in dotfile tracking status and is not managed by home-manager. Its contents will be lost on fresh install.

```
Option A — inline in home/jonathan.nix:
  programs.git.ignores = [ ".DS_Store" /* ... read live file and list entries */ ];
Option B — source file:
  home.file.".config/git/ignore".source = ../dotfiles/gitignore;
  (and commit the live file to dotfiles/gitignore)
```
