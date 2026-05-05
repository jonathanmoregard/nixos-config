---
status: reviewed
category: drift
date: 2026-04-14
source: mint-drift-agent
---

## Findings

- **[implemented]** Touchpad natural-scroll: `natural-scroll = true` in cinnamon.nix
- **[implemented]** Thunderbird added to desktop-apps.nix
- **[discarded]** OBS Studio — not needed
- **[discarded]** yt-dlp — not needed
- **[discarded]** Wine + winetricks — not needed
- **[implemented]** KeePassXC autostart added to cinnamon.nix
- **[implemented]** Beeper autostart added to cinnamon.nix
- **[discarded]** `.huskyrc` untracked — already covered by dotfiles symlink
- **[discarded]** `.config/git/ignore` untracked — already covered by dotfiles symlink
- **[implemented]** Nemo preferences: enable-delete, confirm-move-to-trash, sort-directories-first, sort-favorites-first
- **[implemented]** date-format = "YYYY-MM-DD" added to org/cinnamon
- **[implemented]** Android Studio added via nixpkgs (android-studio); RAM-hungry, skip in 4GB VM
