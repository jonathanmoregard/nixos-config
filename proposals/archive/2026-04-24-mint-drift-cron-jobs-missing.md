---
status: proposed
category: drift
date: 2026-04-24
source: mint-drift-agent
---

## Three live cron jobs absent from the declared crontab in jonathan-linux.nix

jonathan-linux.nix declares a crontab that overwrites ad-hoc edits on rebuild. Three jobs present in the live crontab are missing from the declared version and will be silently deleted on the next rebuild: habit-tracker (every 30 min, 6-22 h), sunset-walk-tracker (every 30 min all hours), and superpowers-fork-sync (daily 15:37).

```
# In home/jonathan-linux.nix, append to the home.file.".config/crontab".text block:
*/30 6-22 * * * /usr/bin/python3 /home/jonathan/.claude/wellbeing/habit-tracker.py >> /home/jonathan/.claude/logs/habit-tracker.log 2>&1 # habit-tracker
*/30 * * * * /usr/bin/python3 /home/jonathan/.claude/wellbeing/sunset-walk-tracker.py >> /home/jonathan/.claude/logs/sunset-walk-tracker.log 2>&1 # sunset-walk-tracker
37 15 * * * /home/jonathan/Repos/superpowers/sync-agent.sh >> /home/jonathan/Repos/superpowers/sync.log 2>&1 # superpowers-fork-sync
```
