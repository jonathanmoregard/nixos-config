---
status: proposed
category: drift
date: 2026-04-24
source: mint-drift-agent
---

## gh-token systemd user service+timer enabled but not declared in home-manager

~/.config/systemd/user/gh-token.service and gh-token.timer exist, and gh-token.timer is symlinked in timers.target.wants/ (i.e., enabled). No matching systemd.user.services.gh-token or systemd.user.timers.gh-token declaration exists in any visible home-manager module. The periodic token refresh will be absent after a fresh install.

```
# Read the live unit files first:
# cat ~/.config/systemd/user/gh-token.service
# cat ~/.config/systemd/user/gh-token.timer
# Then declare in a suitable module (e.g., home/jonathan-linux.nix):
systemd.user.services.gh-token = {
  Unit.Description = "Refresh GitHub token";
  Service.ExecStart = "<ExecStart from live .service>";
  Service.Type = "oneshot";
};
systemd.user.timers.gh-token = {
  Unit.Description = "GitHub token refresh timer";
  Timer.OnCalendar = "<OnCalendar from live .timer>";
  Timer.Persistent = true;
  Install.WantedBy = [ "timers.target" ];
};
```
