---
status: proposed
category: drift
date: 2026-04-21
source: mint-drift-agent
---

## habit-tracker and sunset-walk-tracker cron jobs absent from declarative crontab

Two high-frequency cron jobs exist on the live system but are missing from the home.file.".config/crontab" block in home/jonathan-linux.nix:
  */30 6-22 * * * habit-tracker.py  (runs 32×/day)
  */30 * * * * sunset-walk-tracker.py  (runs 48×/day)
Both are wellbeing tracking scripts. They will not run on a fresh NixOS install.

```
Add to the crontab text in home/jonathan-linux.nix:

*/30 6-22 * * * /usr/bin/python3 /home/jonathan/.claude/wellbeing/habit-tracker.py >> /home/jonathan/.claude/logs/habit-tracker.log 2>&1
*/30 * * * * /usr/bin/python3 /home/jonathan/.claude/wellbeing/sunset-walk-tracker.py >> /home/jonathan/.claude/logs/sunset-walk-tracker.log 2>&1
```
