# NixOS Mint Environment Migration Plan

## Context

Jonathan runs Linux Mint 22.2 with Cinnamon as his daily driver. A NixOS VM (4GB RAM, QEMU/KVM) is running. The goal is to mirror the Mint environment in NixOS so he can gradually switch over, then move to a new machine with more RAM using the same NixOS config.

## Current Status: IMPLEMENTED — pending manual verification

All phases are deployed on the VM (192.168.122.27).

**Deploy workflow:** `rsync -az --delete ~/Repos/nixos-config/ jonathan@192.168.122.27:~/nixos-config/ --exclude='.git'` then `sudo nixos-rebuild switch --flake ~/nixos-config#vm` on the VM. Cannot use `github:` URL — repo is private and VM has no GitHub credentials.

## What's Deployed

### Architecture decisions made
- **Cinnamon DE** — matches Linux Mint daily driver; enables native desaturate-all applet
- **Split HM entrypoints:** VM uses `home/jonathan-linux.nix`, Darwin keeps `home/jonathan.nix`
- `modules/nixos/desktop.nix` enables Cinnamon + LightDM

### File structure (actual)
```
nixos-config/
├── flake.nix                          # agenix input added; VM HM → jonathan-linux.nix
├── modules/
│   ├── common.nix                     # claude-code, git, gh, ripgrep, fd, jq, curl, wget
│   ├── nixos/
│   │   ├── vm-tweaks.nix              # low-RAM tuning
│   │   ├── desktop.nix                # XFCE + LightDM
│   │   └── docker.nix                 # Docker daemon + user group
│   └── darwin/inference.nix           # unchanged placeholder
├── hosts/vm/
│   ├── default.nix                    # imports desktop.nix + docker.nix
│   └── hardware-configuration.nix
├── home/
│   ├── jonathan.nix                   # OMZ + P10k + gh credential + gitleaks + nodejs/pnpm
│   ├── jonathan-linux.nix             # imports all desktop modules + cloneRepos activation
│   ├── cinnamon.nix                    # Cinnamon dconf, themes, desaturate-all applet, night-light
│   ├── desktop-apps.nix               # Chrome, Discord, GIMP, Calibre, LibreOffice, qbittorrent, KeePassXC, zoom, zenity, dropbox
│   ├── ghostty.nix                    # Ghostty + gtk-single-instance=false + split keybinds
│   └── autodoro.nix                   # systemd user service with ExecCondition guard
├── dotfiles/
│   └── p10k.zsh
└── secrets/
    └── secrets.nix                    # agenix recipients: jonathan key + VM host key
```

### Security
- **agenix** wired (NixOS module + CLI). No secrets stored yet — infrastructure ready.
- **gitleaks** pre-commit hook via `~/.config/git/hooks/pre-commit` + `core.hooksPath`

### Shell
- OMZ + Powerlevel10k, p10k.zsh dotfile sourced from nix store
- gh credential helper: `!/run/current-system/sw/bin/gh auth git-credential`
- Aliases: `ll`, `rebuild`, `update`

### Desktop features
- **Night-light:** Cinnamon built-in via dconf (2400K, Stockholm 59.2/18.03) — replaces redshift
- **Desaturate-all:** `desaturate-all@hkoosha` Cinnamon applet, installed from nix store via fetchFromGitHub. Super+G keybinding via dconf custom keybinding.
- **Ghostty:** `gtk-single-instance = false` so it launches from Run Apps and menu
- **autodoro:** systemd user service; skips start if `~/Repos/autodoro/autodoro.sh` missing (ExecCondition)

### Repo cloning (Phase 6)
Public repos clone automatically on HM activation (GIT_TERMINAL_PROMPT=0).
Private repos (weekend, nixos-config) silently skip — need `gh auth login` on VM first.

## Pending manual verification (log into VM GUI)
- [ ] Redshift tray icon visible after login
- [ ] Super+G toggles desaturation
- [ ] Ghostty launches from Run Apps (alt+F2) — just fixed in last commit

## Known gaps / not yet done
- **Beeper:** not addressed — check `pkgs.beeper` in nixpkgs, else use `appimageTools.wrapType2`
- **Private repo cloning:** weekend + nixos-config won't clone until `gh auth login` on VM
- **Android Studio:** excluded (too heavy for 4GB VM)

## ~/.claude on VM
Synced via rsync (not git — `projects/` is gitignored in ~/.claude). Re-sync with:
```
rsync -az --delete --exclude='cache/' --exclude='history.jsonl' --exclude='logs/' \
  --exclude='tmp/' --exclude='debug/' --exclude='downloads/' --exclude='backups/' \
  --exclude='sessions/' --exclude='telemetry/' --exclude='paste-cache/' \
  --exclude='shell-snapshots/' --exclude='file-history/' --exclude='__pycache__/' \
  --exclude='.git/' ~/.claude/ jonathan@192.168.122.27:~/.claude/
```
