---
status: proposed
category: drift
date: 2026-04-21
source: mint-drift-agent
---

## gh-token service+timer not declared in home-manager

~/.config/systemd/user/gh-token.service and gh-token.timer exist and the timer is enabled (in timers.target.wants/). No declaration for these units appears in any shown nix file. GitHub token refresh will not run on a fresh install.

```
Read the live unit files:
  cat ~/.config/systemd/user/gh-token.service
  cat ~/.config/systemd/user/gh-token.timer

Then add to a nix module:

systemd.user.services.gh-token = { ... };
systemd.user.timers.gh-token = {
  Timer.OnCalendar = "<from live unit>";
  Install.WantedBy = [ "timers.target" ];
};
```
