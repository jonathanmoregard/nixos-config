---
status: superseded
category: drift
subcategory: docs
date: 2026-05-05
source: advice-refine-loop
supersedes_reason: Voquill is already correctly wired on dellan via voquillWrapper in home/router-services.nix, which injects LD_LIBRARY_PATH per-process — no system-wide programs.nix-ld.libraries change needed. Real bug is the autostart .desktop entry in home/cinnamon.nix racing with the systemd-managed unit. See sibling proposal 2026-05-05-voquill-autostart-race.md.
---

## SUPERSEDED — Voquill nix-ld libs already covered by voquillWrapper

This proposal originally suggested adding the Tauri lib closure to `programs.nix-ld.libraries` in `modules/nixos/laptop.nix`. After verification on dellan it turns out:

1. `home/router-services.nix:11-54` already declares `voquillRuntimeLibs` and a `voquillWrapper` that injects `LD_LIBRARY_PATH` per-launch.
2. The release binary at `~/Repos/voquill/apps/desktop/src-tauri/target/release/Voquill (local)` is **currently running** on dellan via `systemd.user.services.voquill` (PID confirmed 2026-05-05).
3. nix-ld libs would be a redundant second mechanism.

The actual bug is documented in `2026-05-05-voquill-autostart-race.md` — the cinnamon autostart .desktop entry references the wrong (debug, no-wrapper) binary path and races with the wrapped systemd unit. Fix that one instead.

This file kept as a record so future drift scans don't re-propose the same nix-ld change.
