---
status: proposed
category: drift
date: 2026-04-27
source: mint-drift-agent
---

## habit-tracker and sunset-walk-tracker cron jobs absent from declared crontab

The live crontab contains two high-frequency wellbeing jobs (every 30 min) that are entirely absent from the home.file.".config/crontab".text block in home/jonathan-linux.nix:
  */30 6-22 * * *  habit-tracker.py
  */30 * * * *     sunset-walk-tracker.py
These would be silently dropped on every rebuild.

```
Add to the home.file.".config/crontab".text block in home/jonathan-linux.nix:

  */30 6-22 * * * /usr/bin/python3 /home/jonathan/.claude/wellbeing/habit-tracker.py >> /home/jonathan/.claude/logs/habit-tracker.log 2>&1 # habit-tracker
  */30 * * * * /usr/bin/python3 /home/jonathan/.claude/wellbeing/sunset-walk-tracker.py >> /home/jonathan/.claude/logs/sunset-walk-tracker.log 2>&1 # sunset-walk-tracker
```
