---
status: proposed
category: drift
date: 2026-04-23
source: mint-drift-agent
---

## ~/.huskyrc is untracked and not managed by home-manager

~/.huskyrc (husky git-hook manager config) is listed as an UNTRACKED file that is neither in the dotfiles repo nor declared as a home.file in any home-manager module. It will not exist on a fresh build, breaking any project that relies on husky hooks matching this global config.

```
cat ~/.huskyrc
# Then add to home/jonathan.nix:
home.file.".huskyrc".text = ''
  <paste content from above>
'';
```
