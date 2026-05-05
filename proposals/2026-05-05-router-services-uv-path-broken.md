---
status: proposed
category: drift
subcategory: systemd
date: 2026-05-05
source: advice-refine-loop
---

## router-ingestor + router-worker services failing every 5–10s on dellan — uv path is Mint-only

`home/router-services.nix` declares three router services (`router-ingestor.service`, `router-worker.service`, plus an `OnUnitInactiveSec` cron-style scan) whose `ExecStart` lines hardcode `/home/jonathan/.local/bin/uv`:

```nix
# home/router-services.nix:66
ExecStart = "/home/jonathan/.local/bin/uv run router-ingestor --paths /home/jonathan/.config/router/paths.yaml watch";
# line 82
ExecStart = "/home/jonathan/.local/bin/uv run router-worker --paths /home/jonathan/.config/router/paths.yaml watch";
# line 95
ExecStart = "/bin/sh -c '/home/jonathan/.local/bin/uv run router-ingestor --paths /home/jonathan/.config/router/paths.yaml scan-once >> /home/jonathan/.local/state/router/audit/ingestor-cron.log 2>&1'";
```

On Mint, `/home/jonathan/.local/bin/uv` was a pip-installed binary. On dellan it doesn't exist — `uv` comes from nixpkgs at `/etc/profiles/per-user/jonathan/bin/uv`. Result: services fail at `Failed at step EXEC` every restart attempt, with the timer/Restart firing every 5–10 seconds.

### Captured live failure (dellan, 2026-05-05)

```
$ ssh dellan 'journalctl --user -p err --since today --no-pager | grep router | head'
May 05 00:00:00 dellan (uv)[869596]: router-ingestor.service: Failed at step EXEC spawning /home/jonathan/.local/bin/uv: No such file or directory
May 05 00:00:00 dellan (uv)[869597]: router-worker.service: Failed at step EXEC spawning /home/jonathan/.local/bin/uv: No such file or directory
May 05 00:00:06 dellan (uv)[869915]: router-ingestor.service: Failed at step EXEC spawning /home/jonathan/.local/bin/uv: No such file or directory
... (continuous flood since dellan first booted)
```

Same idiom as the wellbeing-cron `/usr/bin/python3` Mint-isms covered in `2026-05-05-cron-wellbeing-python-paths-broken.md`.

### Fix

Edit `home/router-services.nix`. Replace `/home/jonathan/.local/bin/uv` with `${pkgs.uv}/bin/uv` in all three `ExecStart` lines:

```nix
# diff
- ExecStart = "/home/jonathan/.local/bin/uv run router-ingestor --paths /home/jonathan/.config/router/paths.yaml watch";
+ ExecStart = "${pkgs.uv}/bin/uv run router-ingestor --paths /home/jonathan/.config/router/paths.yaml watch";

- ExecStart = "/home/jonathan/.local/bin/uv run router-worker --paths /home/jonathan/.config/router/paths.yaml watch";
+ ExecStart = "${pkgs.uv}/bin/uv run router-worker --paths /home/jonathan/.config/router/paths.yaml watch";

- ExecStart = "/bin/sh -c '/home/jonathan/.local/bin/uv run router-ingestor --paths /home/jonathan/.config/router/paths.yaml scan-once >> /home/jonathan/.local/state/router/audit/ingestor-cron.log 2>&1'";
+ ExecStart = "/bin/sh -c '${pkgs.uv}/bin/uv run router-ingestor --paths /home/jonathan/.config/router/paths.yaml scan-once >> /home/jonathan/.local/state/router/audit/ingestor-cron.log 2>&1'";
```

The module's argument list (top of file) probably already includes `{ pkgs, ... }` — confirm before editing. If not, add `pkgs` to the function signature.

### Verify

```bash
sudo nixos-rebuild switch --flake /etc/nixos#dellan
systemctl --user status router-ingestor.service
# expect: active (running), no "Failed at step EXEC"
journalctl --user -u router-ingestor.service --since '5 minutes ago' --no-pager | tail
# expect: actual router-ingestor log lines, not the EXEC failure
journalctl --user -u router-worker.service --since '5 minutes ago' --no-pager | tail
```

### Prerequisite — runtime state directories

The systemd units also reference these absolute paths (lines 64/80/93/95):

```
WorkingDirectory = "/home/jonathan/.local/share/router-agent";
ExecStart = "... >> /home/jonathan/.local/state/router/audit/ingestor-cron.log ...";
```

If dellan's rsync from Mint didn't bring these across, fixing the `uv` path will only swap the EXEC failure for a `chdir` failure or a shell-redirect "no such file or directory". Verify both exist before committing the rebuild:

```bash
ssh dellan 'ls -d /home/jonathan/.local/share/router-agent /home/jonathan/.local/state/router/audit 2>&1'
```

If either is missing, either:
- Re-rsync from the `mint-backup-2026-05-05/` snapshot:
  `rsync -a /home/jonathan/mint-backup-2026-05-05/.local/share/router-agent/ ~/.local/share/router-agent/`
  (and similar for state/router).
- Or declaratively pre-create via a `home.activation` block:
  ```nix
  home.activation.routerStateDirs = lib.hm.dag.entryAfter ["writeBoundary"] ''
    mkdir -p "$HOME/.local/share/router-agent" "$HOME/.local/state/router/audit"
  '';
  ```
  Empty dirs let the services start; the project's own bootstrap then populates them.

### Notes
- The router project lives at `~/.local/share/router-agent` per the
  comment at `home/router-services.nix:3`. `uv run` will pick up the
  project's `pyproject.toml` from `--paths` config, no PWD coupling.
- Same uv hardcode pattern may exist in other places — grep the repo
  to be safe: `grep -rn '/home/jonathan/.local/bin/uv' /etc/nixos`
  before merging.
