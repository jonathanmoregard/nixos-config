---
status: proposed
category: drift
date: 2026-04-23
source: mint-drift-agent
---

## superpowers-fork-sync cron job absent from declarative crontab

A daily sync job (37 15 * * *) for /home/jonathan/Repos/superpowers is in the live crontab but absent from the declarative crontab in home/jonathan-linux.nix. It will not exist after a rebuild.

```
Add to the home.file.".config/crontab".text block in home/jonathan-linux.nix:
37 15 * * * /home/jonathan/Repos/superpowers/sync-agent.sh >> /home/jonathan/Repos/superpowers/sync.log 2>&1 # superpowers-fork-sync
```
