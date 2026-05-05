---
status: proposed
category: drift
subcategory: cron
date: 2026-05-05
source: advice-refine-loop
---

## Wellbeing cron jobs hardcode `/usr/bin/python3` — won't exist on dellan

`home/jonathan-linux.nix` lines 28-29 (current crontab):

```
*/30 6-22 * * * /usr/bin/python3 /home/jonathan/.claude/wellbeing/habit-tracker.py >> /home/jonathan/.claude/logs/habit-tracker.log 2>&1
*/30 * * * *   /usr/bin/python3 /home/jonathan/.claude/wellbeing/sunset-walk-tracker.py >> /home/jonathan/.claude/logs/sunset-walk-tracker.log 2>&1
```

Mint had `/usr/bin/python3`. NixOS doesn't:
```
mint:    -rwxr-xr-x /usr/bin/python3 → python3.12
dellan:  ls: cannot access '/usr/bin/python3': No such file or directory
        which python3 → /etc/profiles/per-user/jonathan/bin/python3
```

Result on dellan: every 30 min the cron line silently fails (no `/usr/bin/python3` to invoke). habit-tracker + sunset-walk-tracker caches stay stale. Status hooks already complain (`[wellbeing] habit-tracker cache is stale (date=2026-05-04, today=2026-05-05). Nudges silent`).

Compounding: `habit-tracker.py` imports `python-dateutil` and `requests` (uses TickTick API). Default `pkgs.python3` doesn't ship those — needs `python3.withPackages`.

### Captured runtime deps

```
$ grep -hE '^(import |from )' ~/.claude/wellbeing/habit-tracker.py | sort -u
from __future__ import annotations
from datetime import date, datetime
from dateutil import tz, parser as dtparser  ← python-dateutil
import json
import os
import requests                              ← requests
import sys
import time

$ grep -hE '^(import |from )' ~/.claude/wellbeing/sunset-walk-tracker.py | sort -u
from __future__ import annotations
from datetime import datetime, timedelta, timezone
import json
import os
import requests                              ← requests
import sys
```

### Fix

Edit `home/jonathan-linux.nix`:

```nix
{ pkgs, lib, ... }:
let
  # Wellbeing scripts need stdlib + python-dateutil + requests.
  # Single derivation reused by both crontab lines so the path stays
  # stable across rebuilds.
  pythonForWellbeing = pkgs.python3.withPackages (ps: with ps; [
    python-dateutil
    requests
  ]);
in
{
  imports = [ ./jonathan.nix ./cinnamon.nix ./desktop-apps.nix
              ./ghostty.nix ./kitty.nix ./autodoro.nix
              ./drift-analyzer.nix ./router-services.nix
              ./claude-services.nix ./claude-skills.nix ];

  home.file.".config/crontab".text = ''
    CRON_TZ=Europe/Stockholm
    0 9 * * 1 /home/jonathan/.claude/date-check.sh
    0 10 * * 1 /home/jonathan/.claude/scripts/update-submodules.sh >> /home/jonathan/.claude/logs/submodule-update.log 2>&1
    0 11 * * 1 /home/jonathan/Repos/dotfiles/backup-crontab.sh >> /home/jonathan/Repos/dotfiles/backup-crontab.log 2>&1
    23 14 * * * /home/jonathan/Repos/dotfiles/sync-agent.sh >> /home/jonathan/Repos/dotfiles/sync.log 2>&1
    0 10 * * * /home/jonathan/Repos/nixos-config/scripts/mint-drift-agent.sh >> /home/jonathan/.local/share/mint-drift-analyzer/run.log 2>&1
    0 10 * * 1 git -C /home/jonathan/Repos/everything-claude-code pull --ff-only >> /home/jonathan/.claude/logs/ecc-pull.log 2>&1
    0 9 * * 1 touch /home/jonathan/.claude/homunculus/.evolve-reminder
    0 */6 * * * /home/jonathan/.claude/repo-autosync-data/token-optimizer/wrapper.sh
    */30 6-22 * * * ${pythonForWellbeing}/bin/python3 /home/jonathan/.claude/wellbeing/habit-tracker.py >> /home/jonathan/.claude/logs/habit-tracker.log 2>&1
    */30 * * * * ${pythonForWellbeing}/bin/python3 /home/jonathan/.claude/wellbeing/sunset-walk-tracker.py >> /home/jonathan/.claude/logs/sunset-walk-tracker.log 2>&1
    37 15 * * * /home/jonathan/Repos/superpowers/sync-agent.sh >> /home/jonathan/Repos/superpowers/sync.log 2>&1
  '';
  ...
}
```

### Verify on dellan

```bash
sudo nixos-rebuild switch --flake /etc/nixos#dellan
crontab -l | grep wellbeing  # confirm /nix/store/...-python3-with-deps/bin/python3 prefix
# Wait for next 30-min boundary, OR run manually:
$(grep habit-tracker ~/.config/crontab | awk '{print $6}') ~/.claude/wellbeing/habit-tracker.py
ls -la ~/.claude/tmp/.habit-cache.json  # mtime should update
ls -la ~/.claude/tmp/.sunset-walk-cache.json
```

### Notes
- Token at `~/.config/todo/env` (rsync'd from Mint 2026-05-05). habit-tracker reads it via `~/.claude/todo/_envfile.py` `load()`.
- The crontab string changes on every nixpkgs bump (different store hash) — that's fine, home-manager re-installs the crontab on every rebuild.
