---
status: proposed
category: drift
subcategory: dotfile
date: 2026-05-05
source: mint-drift-agent
---

## ~/.xbindkeysrc key bindings untracked — xbindkeys starts but has no rules

cinnamon.nix declares the xbindkeys autostart so the daemon launches on login, but ~/.xbindkeysrc — the file containing the actual key binding rules — is listed as UNTRACKED and has no home.file declaration. On a fresh install xbindkeys runs with an empty/default config and all custom bindings are silently lost.

```
# 1. Inspect current bindings:
cat ~/.xbindkeysrc

# 2. Add to home/cinnamon.nix:
home.file.".xbindkeysrc".text = ''
  # paste ~/.xbindkeysrc contents here
'';
```
