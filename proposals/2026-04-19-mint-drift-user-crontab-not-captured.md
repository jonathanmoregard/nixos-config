---
status: proposed
category: drift
date: 2026-04-19
source: mint-drift-agent
---

## Entire user crontab is not captured in the nix config

The live system has 12 cron jobs (CRON_TZ=Europe/Stockholm) covering drift checks, submodule updates, crontab backup, sync agent, mint-drift agent, nightly intent tests, ecc weekly pull, evolve reminder, token-optimizer updater, habit tracker, and sunset-walk tracker. None are declared anywhere in the nix config; all will be lost on fresh install.

```
Model each job as a systemd user timer in home/jonathan-linux.nix. Example for the weekly submodule update:
  systemd.user.services.update-submodules = {
    Unit.Description = "Weekly submodule update";
    Service.ExecStart = "%h/.claude/scripts/update-submodules.sh";
  };
  systemd.user.timers.update-submodules = {
    Timer = { OnCalendar = "Mon *-*-* 10:00"; Persistent = true; };
    Install.WantedBy = [ "timers.target" ];
  };
Repeat for each cron entry. Set Environment="TZ=Europe/Stockholm" on timers that need it.
```
