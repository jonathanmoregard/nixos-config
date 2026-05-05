---
status: proposed
category: drift
date: 2026-04-27
source: mint-drift-agent
---

## ~/.huskyrc untracked — not in home.file or dotfiles repo

The drift report flags ~/.huskyrc as UNTRACKED. It is not declared via home.file in any .nix file and is not symlinked from the dotfiles repo. Husky's global config affects pre-commit hooks across all repos; a fresh install would lack it.

```
Inspect the file, then add to home/jonathan.nix:

  home.file.".huskyrc".text = ''
    # paste contents of ~/.huskyrc
  '';
```
