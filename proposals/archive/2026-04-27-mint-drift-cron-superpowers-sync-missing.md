---
status: proposed
category: drift
date: 2026-04-27
source: mint-drift-agent
---

## superpowers-fork-sync cron job absent from declared crontab

The live crontab includes a daily sync job at 15:37 — '37 15 * * * /home/jonathan/Repos/superpowers/sync-agent.sh' — that is not present in the home.file.".config/crontab".text block in home/jonathan-linux.nix. It would be lost on rebuild.

```
Add to the home.file.".config/crontab".text block in home/jonathan-linux.nix:

  37 15 * * * /home/jonathan/Repos/superpowers/sync-agent.sh >> /home/jonathan/Repos/superpowers/sync.log 2>&1 # superpowers-fork-sync
```
