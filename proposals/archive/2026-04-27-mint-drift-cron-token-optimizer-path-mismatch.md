---
status: proposed
category: drift
date: 2026-04-27
source: mint-drift-agent
---

## Token-optimizer cron script path diverges between live and config

The live crontab runs the token-optimizer via:
  /home/jonathan/.claude/repo-autosync-data/token-optimizer/wrapper.sh
But the declared config in jonathan-linux.nix runs:
  /home/jonathan/.claude/workers/token-optimizer-updater/run.sh
One path is stale. Whichever is wrong silently fails every 6 hours.

```
Check which path actually exists on the live system:

  ls -la ~/.claude/repo-autosync-data/token-optimizer/wrapper.sh
  ls -la ~/.claude/workers/token-optimizer-updater/run.sh

Then update the crontab entry in home/jonathan-linux.nix to match the real path.
```
