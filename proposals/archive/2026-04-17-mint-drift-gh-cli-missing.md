---
status: implemented
category: drift
date: 2026-04-17
source: mint-drift-agent
---

## GitHub CLI (gh) not in home.packages

gh is installed via apt on the live system and is used both in the zsh gh() wrapper and as the git credential helper (credential.https://github.com.helper). It is not declared in home.packages and would be absent after a rebuild, breaking git auth.

```
# In home/jonathan.nix, add to home.packages:
gh
```
