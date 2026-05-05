---
status: proposed
category: drift
date: 2026-04-24
source: mint-drift-agent
---

## claude-cl-sync service+timer enabled but not declared in home-manager

~/.config/systemd/user/claude-cl-sync.service and claude-cl-sync.timer exist, and claude-cl-sync.timer is symlinked in timers.target.wants/ (enabled). No corresponding systemd.user declaration exists in any visible module. The sync job will not be recreated on a fresh install.

```
# Read the live unit files first:
# cat ~/.config/systemd/user/claude-cl-sync.service
# cat ~/.config/systemd/user/claude-cl-sync.timer
# Then declare in a suitable module (e.g., home/jonathan-linux.nix):
systemd.user.services.claude-cl-sync = {
  Unit.Description = "Claude config sync";
  Service.ExecStart = "<ExecStart from live .service>";
  Service.Type = "oneshot";
};
systemd.user.timers.claude-cl-sync = {
  Unit.Description = "Claude config sync timer";
  Timer.OnCalendar = "<OnCalendar from live .timer>";
  Timer.Persistent = true;
  Install.WantedBy = [ "timers.target" ];
};
```
