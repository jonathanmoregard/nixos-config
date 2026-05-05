---
status: proposed
category: drift
date: 2026-04-23
source: mint-drift-agent
---

## claude-cl-sync.service and .timer enabled on live but not declared in home-manager

~/.config/systemd/user/claude-cl-sync.service and claude-cl-sync.timer both exist, and the timer is actively enabled (symlinked under timers.target.wants). No systemd.user.services or systemd.user.timers block in any provided home-manager module declares them. They will not be created or enabled on a fresh build.

```
cat ~/.config/systemd/user/claude-cl-sync.service ~/.config/systemd/user/claude-cl-sync.timer
# Then add to a home-manager module (e.g. home/jonathan-linux.nix):
systemd.user.services.claude-cl-sync = {
  Unit.Description = "<from Unit.Description in service file>";
  Service.ExecStart = "<from ExecStart in service file>";
};
systemd.user.timers.claude-cl-sync = {
  Unit.Description = "<from Unit.Description in timer file>";
  Timer = { OnCalendar = "<from OnCalendar in timer file>"; Persistent = true; };
  Install.WantedBy = [ "timers.target" ];
};
```
