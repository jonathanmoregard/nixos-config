---
status: done
category: drift
subcategory: autostart
date: 2026-05-05
source: advice-refine-loop
done_evidence: home.file autostart block removed from home/cinnamon.nix 2026-06-07; voquill.service confirmed sole launcher (systemctl --user is-active voquill → active, pgrep shows release binary).
---

## Voquill cinnamon autostart .desktop races with systemd-managed unit

Two separate launch mechanisms target Voquill on dellan:

1. **systemd user unit (the canonical, correct one).** `home/router-services.nix:126-138` declares `systemd.user.services.voquill` invoking `${voquillWrapper}/bin/voquill-launch --voquill-autostart-hidden`. The wrapper at `home/router-services.nix:44-53` injects `LD_LIBRARY_PATH` from `voquillRuntimeLibs` and execs the **release** binary at `~/Repos/voquill/apps/desktop/src-tauri/target/release/Voquill (local)`. Verified running: `pgrep -af Voquill` → PID 477406 active.

2. **Stale cinnamon autostart .desktop (the buggy one).** `home/cinnamon.nix:70-81` declares `home.file.".config/autostart/voquill.desktop".text` whose `Exec=` line points at `/home/jonathan/Repos/voquill/apps/desktop/src-tauri/target/debug/Voquill --voquill-autostart-hidden`. That path is the **debug** binary rsync'd from Mint host on 2026-05-05 — no wrapper, no `LD_LIBRARY_PATH`, links against missing `/lib/x86_64-linux-gnu/lib*.so.*`. Cinnamon's autostart spec runs it on every login regardless of the systemd unit.

Net effect on dellan today:
- Login → cinnamon fires the autostart entry, the debug binary attempts to launch, fails silently (missing libs).
- Login → systemd starts `voquill.service`, the wrapper launches the release binary, succeeds.
- No user-visible bug because the systemd path wins, but the failed cinnamon launch logs an error every login.

### Fix — delete the cinnamon autostart entry

Edit `home/cinnamon.nix`, remove the entire `home.file.".config/autostart/voquill.desktop".text = ''...''` block (currently lines 70-81). The systemd unit + the `xdg.desktopEntries.voquill` entry in `home/router-services.nix:116-124` together cover both auto-launch + Cinnamon menu visibility.

```nix
# DELETE this whole block from home/cinnamon.nix:
home.file.".config/autostart/voquill.desktop".text = ''
  [Desktop Entry]
  Type=Application
  Version=1.0
  Name=Voquill (local)
  Comment=Voquill (local) startup script
  Exec=/home/jonathan/Repos/voquill/apps/desktop/src-tauri/target/debug/Voquill --voquill-autostart-hidden
  StartupNotify=false
  Terminal=false
  Hidden=false
  X-GNOME-Autostart-enabled=true
'';
```

### Verify

```bash
sudo nixos-rebuild switch --flake /etc/nixos#dellan
ls /home/jonathan/.config/autostart/voquill.desktop  # expect: ENOENT (HM removed it)
ls /home/jonathan/.config/autostart/                  # other entries (kitty, dropbox, keepassxc) intact
# Log out + back in:
pgrep -af Voquill
# Expect: exactly one PID, running the release binary via voquillWrapper.
journalctl --user -u voquill.service -n 5 --no-pager
# Expect: "Started" + no errors.
```

### Notes
- Once verified, the rsync'd debug binary at `target/debug/Voquill` can
  be deleted (`rm /home/jonathan/Repos/voquill/.../target/debug/Voquill`)
  to free 580 MB. Source repo is intact for future `cargo build`.
- This finding closes the parallel `2026-05-05-voquill-nix-ld-libs-needed.md`
  proposal (now marked superseded).
