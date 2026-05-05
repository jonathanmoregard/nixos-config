---
status: proposed
category: drift
date: 2026-04-27
source: mint-drift-agent
---

## gh-token.service + gh-token.timer not declared in home-manager

~/.config/systemd/user/gh-token.service and gh-token.timer exist on the live system with the timer enabled via timers.target.wants. No corresponding home-manager declarations are visible in any .nix file. GitHub token refresh would not occur on a fresh install.

```
Read the unit files:

  cat ~/.config/systemd/user/gh-token.service
  cat ~/.config/systemd/user/gh-token.timer

Then add to home-manager:

  systemd.user.services.gh-token = { ... };
  systemd.user.timers.gh-token = { ... };
```
