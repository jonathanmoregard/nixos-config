{ pkgs, lib, ... }:
{
  imports = [
    ./jonathan.nix
    ./cinnamon.nix
    ./desktop-apps.nix
    ./ghostty.nix
    ./kitty.nix
    ./autodoro.nix
    ./drift-analyzer.nix
    ./router-services.nix
    ./claude-services.nix
    ./claude-symlinks.nix
  ];

  # User crontab — declarative source of truth. Re-applied on every rebuild
  # (overwrites any ad-hoc `crontab -e` edits).
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
    */30 6-22 * * * /usr/bin/python3 /home/jonathan/.claude/wellbeing/habit-tracker.py >> /home/jonathan/.claude/logs/habit-tracker.log 2>&1
    */30 * * * * /usr/bin/python3 /home/jonathan/.claude/wellbeing/sunset-walk-tracker.py >> /home/jonathan/.claude/logs/sunset-walk-tracker.log 2>&1
    37 15 * * * /home/jonathan/Repos/superpowers/sync-agent.sh >> /home/jonathan/Repos/superpowers/sync.log 2>&1
  '';

  home.activation.installCrontab = lib.hm.dag.entryAfter ["writeBoundary"] ''
    if command -v crontab >/dev/null 2>&1; then
      crontab "$HOME/.config/crontab" || true
    fi
  '';

  # Clone user repos into ~/Repos on first activation.
  #
  # Strategy: try SSH first (works for both public + private once the host's
  # SSH key is added at https://github.com/settings/keys), fall back to
  # HTTPS (works for public repos only). All clones are best-effort —
  # failures are silent so a missing key/network doesn't block rebuild.
  #
  # Re-running activation (every nixos-rebuild switch) is a no-op for any
  # repo that already exists. Update existing repos via the cron-driven
  # repo-autosync agent or `git pull` manually.
  #
  # ~/.claude is intentionally NOT auto-cloned: claude-code populates
  # ~/.claude with runtime state (backups/, projects/, sessions/, cache/)
  # on first run, and the .claude *repo* needs to coexist with that state.
  # On a fresh host: move runtime dirs aside, `git clone
  # git@github.com:jonathanmoregard/.claude.git ~/.claude`, restore
  # runtime dirs, `git submodule update --init --recursive`.
  home.activation.cloneRepos = lib.hm.dag.entryAfter ["writeBoundary"] ''
    mkdir -p "$HOME/Repos"

    clone_if_missing() {
      local repo="$1"
      local dir="$2"
      if [ ! -d "$dir" ]; then
        GIT_TERMINAL_PROMPT=0 GIT_ASKPASS="" SSH_ASKPASS="" \
          ${pkgs.git}/bin/git clone "git@github.com:jonathanmoregard/$repo.git" "$dir" 2>/dev/null \
        || GIT_TERMINAL_PROMPT=0 GIT_ASKPASS="" SSH_ASKPASS="" \
             ${pkgs.git}/bin/git clone "https://github.com/jonathanmoregard/$repo.git" "$dir" 2>/dev/null \
        || true
      fi
    }

    clone_if_missing autodoro "$HOME/Repos/autodoro"
    clone_if_missing intender "$HOME/Repos/intender"
    clone_if_missing weekend "$HOME/Repos/weekend"
    clone_if_missing nixos-config "$HOME/Repos/nixos-config"
    clone_if_missing artcraft "$HOME/Repos/artcraft"
    clone_if_missing claude-code "$HOME/Repos/claude-code"
    clone_if_missing claude-exam "$HOME/Repos/claude-exam"
    clone_if_missing jhana "$HOME/Repos/jhana"
    clone_if_missing jonathan-claude-marketplace "$HOME/Repos/jonathan-claude-marketplace"
    clone_if_missing survival-corpus "$HOME/Repos/survival-corpus"
    clone_if_missing superpowers "$HOME/Repos/superpowers"
    clone_if_missing voquill "$HOME/Repos/voquill"
    clone_if_missing dotfiles "$HOME/Repos/dotfiles"
    clone_if_missing everything-claude-code "$HOME/Repos/everything-claude-code"
  '';
}
