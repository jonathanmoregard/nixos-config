---
status: proposed
category: drift
date: 2026-04-21
source: mint-drift-agent
---

## Nightly RSI scheduler cron entries not in declarative crontab

Two cron entries for the jonathan-claude-marketplace RSI harness are live right now (April 17-30 window, today is April 21) but absent from home/jonathan-linux.nix:
  7 3 17-30 4 * fire-if-needed.sh
  13 8 17-30 4 * aggregate-if-ready.sh
A rebuild this week would drop them mid-test-cycle.

```
Add to the crontab text in home/jonathan-linux.nix:

7 3 17-30 4 * /home/jonathan/Repos/jonathan-claude-marketplace/dev/rsi/harness/scheduler/fire-if-needed.sh >> /home/jonathan/Repos/jonathan-claude-marketplace/dev/rsi/harness/logs-nightly/cron.log 2>&1
13 8 17-30 4 * /home/jonathan/Repos/jonathan-claude-marketplace/dev/rsi/harness/scheduler/aggregate-if-ready.sh >> /home/jonathan/Repos/jonathan-claude-marketplace/dev/rsi/harness/logs-nightly/cron.log 2>&1
```
