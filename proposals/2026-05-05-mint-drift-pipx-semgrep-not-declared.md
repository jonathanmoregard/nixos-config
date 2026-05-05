---
status: proposed
category: drift
subcategory: package
date: 2026-05-05
source: mint-drift-agent
---

## semgrep (pipx) not in nixos-config — binary lost on rebuild

semgrep 1.159.0 is installed via pipx but absent from home.packages and all nix modules. On a fresh install the CLI disappears. semgrep is a static-analysis tool commonly used in pre-commit hooks and dev scripts; losing it silently breaks those workflows.

```
# In home/jonathan.nix, add to home.packages:
semgrep
# pkgs.semgrep is in nixpkgs.
```
