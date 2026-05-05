---
status: discarded
category: drift
date: 2026-04-17
source: mint-drift-agent
---

## ~/.huskyrc dotfile not managed by home-manager

~/.huskyrc is listed as untracked on the live system and is not referenced anywhere in home-manager. Its contents (husky git hook configuration) would be lost on rebuild.

```
# Read ~/.huskyrc on the live system, then in home/jonathan.nix:
home.file.".huskyrc".text = ''<content of ~/.huskyrc>'';
```
