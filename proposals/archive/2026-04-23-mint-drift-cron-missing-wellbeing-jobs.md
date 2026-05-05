---
status: proposed
category: drift
date: 2026-04-23
source: mint-drift-agent
---

## habit-tracker and sunset-walk-tracker cron jobs absent from declarative crontab

Two high-frequency cron jobs that call wellbeing Python scripts exist in the live crontab but are completely absent from the home.file.".config/crontab".text block in home/jonathan-linux.nix. habit-tracker fires every 30 min during waking hours; sunset-walk-tracker fires every 30 min around the clock. Both will be silently dropped on a fresh rebuild.

```
Add to the home.file.".config/crontab".text block in home/jonathan-linux.nix:
*/30 6-22 * * * /usr/bin/python3 /home/jonathan/.claude/wellbeing/habit-tracker.py >> /home/jonathan/.claude/logs/habit-tracker.log 2>&1 # habit-tracker
*/30 * * * * /usr/bin/python3 /home/jonathan/.claude/wellbeing/sunset-walk-tracker.py >> /home/jonathan/.claude/logs/sunset-walk-tracker.log 2>&1 # sunset-walk-tracker
```
