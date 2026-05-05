---
status: proposed
category: drift
subcategory: package
date: 2026-05-05
source: mint-drift-agent
---

## detect-secrets (pipx) not in nixos-config — binary lost on rebuild

detect-secrets 1.5.0 is installed via pipx on Mint but has no entry in home.packages or any nix module. On a fresh install the CLI is absent. Given gitleaks is already declared as a pre-commit guard, detect-secrets likely serves a complementary scanning role in dev workflows or CI hooks.

```
# In home/jonathan.nix, add to home.packages:
detect-secrets
# pkgs.detect-secrets is in nixpkgs (wraps the Python package).
```
