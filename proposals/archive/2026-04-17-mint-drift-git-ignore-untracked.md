---
status: implemented
category: drift
date: 2026-04-17
source: mint-drift-agent
---

## ~/.config/git/ignore not tracked in home-manager

The global gitignore file ~/.config/git/ignore is listed as untracked and is not managed via programs.git.ignores or home.file. Any global ignore patterns would be absent after a rebuild.

```
# Read ~/.config/git/ignore on the live system, then in home/jonathan.nix:
programs.git.ignores = [
  "<patterns from file>"
];
# Or as a raw file:
home.file.".config/git/ignore".text = ''<content>'';
```
