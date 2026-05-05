---
status: implemented
category: drift
date: 2026-04-17
source: mint-drift-agent
---

## All user cron jobs lost on rebuild

Ten cron jobs exist on the live system (mint-drift, sync-agent, submodule updates, date-check, backup-crontab, ecc-pull, token-optimizer, nightly intent tests, evolve-reminder). None are declared in home-manager. They would be absent after a fresh install.

```
# In home/jonathan.nix, add a home.activation block:
home.activation.installCrontab = lib.hm.dag.entryAfter ["writeBoundary"] ''
  ${pkgs.cron}/bin/crontab - << 'CRON_EOF'
CRON_TZ=Europe/Stockholm
0 9 * * 1 /home/jonathan/.claude/date-check.sh
0 10 * * 1 /home/jonathan/.claude/scripts/update-submodules.sh >> /home/jonathan/.claude/logs/submodule-update.log 2>&1
0 11 * * 1 /home/jonathan/Repos/dotfiles/backup-crontab.sh >> /home/jonathan/Repos/dotfiles/backup-crontab.log 2>&1
23 14 * * * /home/jonathan/Repos/dotfiles/sync-agent.sh >> /home/jonathan/Repos/dotfiles/sync.log 2>&1
0 10 * * * /home/jonathan/Repos/nixos-config/scripts/mint-drift-agent.sh >> /home/jonathan/.local/share/mint-drift-analyzer/run.log 2>&1
0 10 * * 1 git -C /home/jonathan/Repos/everything-claude-code pull --ff-only >> /home/jonathan/.claude/logs/ecc-pull.log 2>&1
0 9 * * 1 touch ~/.claude/homunculus/.evolve-reminder
0 */6 * * * /home/jonathan/.claude/workers/token-optimizer-updater/run.sh
CRON_EOF
'';
```
