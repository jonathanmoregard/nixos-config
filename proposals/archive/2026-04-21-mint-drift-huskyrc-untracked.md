---
status: proposed
category: drift
date: 2026-04-21
source: mint-drift-agent
---

## .huskyrc dotfile not managed by home-manager

~/.huskyrc is listed as UNTRACKED in the dotfile tracking status and does not appear in any home.file declaration in the nixos-config. Husky-enabled projects depend on this file for git hook configuration. On a fresh install it will be absent, causing Husky to fall back to defaults.

```
Inspect the live file content:
  cat ~/.huskyrc

Then add to home/jonathan.nix:

home.file.".huskyrc".text = ''
  <content from live ~/.huskyrc>
'';

Alternatively, commit the file to the dotfiles repo and reference it via home.file.".huskyrc".source.
```
