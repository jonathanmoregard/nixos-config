---
status: proposed
category: drift
date: 2026-04-28
source: mint-drift-agent
---

## voquill upstream-sync cron job absent from declared crontab

The live crontab contains '0 */6 * * * /home/jonathan/.claude/repo-autosync-data/voquill/wrapper.sh >> .../last-update.log 2>&1 # voquill-upstream-sync' but the crontab text declared in home/jonathan-linux.nix only captures the token-optimizer sync — the parallel voquill entry was never added. Because home.activation.installCrontab overwrites the live crontab on every rebuild, this job will be silently dropped the next time nixos-rebuild switch runs.

```
Add to the home.file.".config/crontab".text block in home/jonathan-linux.nix, immediately after the token-optimizer line:

  0 */6 * * * /home/jonathan/.claude/repo-autosync-data/voquill/wrapper.sh >> /home/jonathan/.claude/repo-autosync-data/voquill/last-update.log 2>&1 # voquill-upstream-sync
```
