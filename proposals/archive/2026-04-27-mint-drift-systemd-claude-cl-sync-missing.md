---
status: proposed
category: drift
date: 2026-04-27
source: mint-drift-agent
---

## claude-cl-sync.service + claude-cl-sync.timer not declared in home-manager

~/.config/systemd/user/claude-cl-sync.service and claude-cl-sync.timer are present and the timer is enabled via timers.target.wants. Neither unit is declared in any visible .nix file. The sync job would not run after a fresh rebuild.

```
Read the unit files:

  cat ~/.config/systemd/user/claude-cl-sync.service
  cat ~/.config/systemd/user/claude-cl-sync.timer

Then add to home-manager:

  systemd.user.services.claude-cl-sync = { ... };
  systemd.user.timers.claude-cl-sync = { ... };
```
