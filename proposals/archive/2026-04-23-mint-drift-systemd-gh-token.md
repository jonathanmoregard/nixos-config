---
status: proposed
category: drift
date: 2026-04-23
source: mint-drift-agent
---

## gh-token.service and .timer enabled on live but not declared in home-manager

~/.config/systemd/user/gh-token.service and gh-token.timer both exist, and the timer is actively enabled (symlinked under timers.target.wants). No home-manager module declares them. They will not be created or enabled on a fresh build, breaking the periodic GitHub token refresh.

```
cat ~/.config/systemd/user/gh-token.service ~/.config/systemd/user/gh-token.timer
# Then add to a home-manager module (e.g. home/jonathan-linux.nix):
systemd.user.services.gh-token = {
  Unit.Description = "<from Unit.Description in service file>";
  Service.ExecStart = "<from ExecStart in service file>";
};
systemd.user.timers.gh-token = {
  Unit.Description = "<from Unit.Description in timer file>";
  Timer = { OnCalendar = "<from OnCalendar in timer file>"; Persistent = true; };
  Install.WantedBy = [ "timers.target" ];
};
```
