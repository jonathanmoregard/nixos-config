---
status: proposed
category: drift
date: 2026-04-28
source: mint-drift-agent
---

## jonathan-claude-marketplace nightly-intent cron jobs not in declared crontab

The live crontab contains two date-restricted entries for the RSI harness in jonathan-claude-marketplace (fire-if-needed.sh at 03:07 and aggregate-if-ready.sh at 08:13, both restricted to April 17-30). Neither appears in the crontab text in home/jonathan-linux.nix. Because the activation script overwrites the live crontab unconditionally, the next rebuild will delete these entries mid-run (today is April 28; two firing days remain). Even if they finish this month, the pattern should be in the declared crontab so future test windows can be re-enabled by editing one file.

```
Add to the home.file.".config/crontab".text block in home/jonathan-linux.nix:

  7 3 17-30 4 * /home/jonathan/Repos/jonathan-claude-marketplace/dev/rsi/harness/scheduler/fire-if-needed.sh >> /home/jonathan/Repos/jonathan-claude-marketplace/dev/rsi/harness/logs-nightly/cron.log 2>&1 # nightly-intent-test
  13 8 17-30 4 * /home/jonathan/Repos/jonathan-claude-marketplace/dev/rsi/harness/scheduler/aggregate-if-ready.sh >> /home/jonathan/Repos/jonathan-claude-marketplace/dev/rsi/harness/logs-nightly/cron.log 2>&1 # nightly-intent-aggregate
```
