---
status: proposed
category: drift
date: 2026-04-21
source: mint-drift-agent
---

## claude-cl-sync service+timer not declared in home-manager

~/.config/systemd/user/claude-cl-sync.service and claude-cl-sync.timer exist on the live system and the timer is enabled (present in timers.target.wants/). No systemd.user.services or systemd.user.timers declaration for this unit appears in any shown nix file. The sync will not run on a fresh install.

```
Read the live unit files:
  cat ~/.config/systemd/user/claude-cl-sync.service
  cat ~/.config/systemd/user/claude-cl-sync.timer

Then add to a nix module (e.g. home/jonathan-linux.nix):

systemd.user.services.claude-cl-sync = {
  Unit.Description = "Claude CL sync";
  Service = {
    ExecStart = "<from live unit>";
    Type = "oneshot";
  };
};
systemd.user.timers.claude-cl-sync = {
  Unit.Description = "Claude CL sync timer";
  Timer = {
    OnCalendar = "<from live unit>";
    Persistent = true;
  };
  Install.WantedBy = [ "timers.target" ];
};
```
