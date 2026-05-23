{ config, pkgs, lib, ... }:
let
  # Wellbeing tracker cron jobs need python-dateutil (habit-tracker.py)
  # plus stdlib. Cron's PATH is `/usr/bin:/bin` which has no `python3`
  # on NixOS, so the .py invocations need an absolute store path.
  wellbeingPython = pkgs.python3.withPackages (ps: with ps; [ python-dateutil ]);

  # PATH for cron jobs. Vixie-cron parses `NAME=value` lines at the top
  # of the crontab as env assignments (no shell expansion — `$HOME` and
  # `~` don't work, neither do systemd `%h` specifiers; only Nix
  # interpolation works here, evaluated at activation time).
  # nix-profile paths first so user-installed binaries win over the
  # system; /run/wrappers/bin last so a cron job can't accidentally
  # resolve to a setuid wrapper ahead of its nix-profile equivalent.
  cronPath = lib.concatStringsSep ":" [
    "${config.home.homeDirectory}/.nix-profile/bin"
    "/etc/profiles/per-user/${config.home.username}/bin"
    "/run/current-system/sw/bin"
    "/run/wrappers/bin"
    "/usr/bin"
    "/bin"
  ];
in
{
  imports = [
    ./jonathan.nix
    ./cinnamon.nix
    ./desktop-apps.nix
    ./calibre-plugins.nix
    ./ghostty.nix
    ./kitty.nix
    ./autodoro.nix
    ./drift-analyzer.nix
    ./router-services.nix
    ./claude-services.nix
    ./claude-skills.nix
    ./research-agent-mcp.nix
  ];

  # User crontab — declarative source of truth. Re-applied on every rebuild
  # (overwrites any ad-hoc `crontab -e` edits).
  home.file.".config/crontab".text = ''
    CRON_TZ=Europe/Stockholm
    PATH=${cronPath}
    0 9 * * 1 /home/jonathan/.claude/date-check.sh
    0 10 * * 1 /home/jonathan/.claude/scripts/update-submodules.sh >> /home/jonathan/.claude/logs/submodule-update.log 2>&1
    0 11 * * 1 /home/jonathan/Repos/dotfiles/backup-crontab.sh >> /home/jonathan/Repos/dotfiles/backup-crontab.log 2>&1
    23 14 * * * /home/jonathan/Repos/dotfiles/sync-agent.sh >> /home/jonathan/Repos/dotfiles/sync.log 2>&1
    0 10 * * * /home/jonathan/Repos/nixos-config/scripts/mint-drift-agent.sh >> /home/jonathan/.local/share/mint-drift-analyzer/run.log 2>&1
    0 10 * * 1 git -C /home/jonathan/Repos/everything-claude-code pull --ff-only >> /home/jonathan/.claude/logs/ecc-pull.log 2>&1
    0 9 * * 1 touch /home/jonathan/.claude/homunculus/.evolve-reminder
    0 */6 * * * /home/jonathan/.claude/repo-autosync-data/token-optimizer/wrapper.sh
    */30 6-22 * * * ${wellbeingPython}/bin/python3 /home/jonathan/.claude/wellbeing/habit-tracker.py >> /home/jonathan/.claude/logs/habit-tracker.log 2>&1
    */30 * * * * ${wellbeingPython}/bin/python3 /home/jonathan/.claude/wellbeing/sunset-walk-tracker.py >> /home/jonathan/.claude/logs/sunset-walk-tracker.log 2>&1
    37 15 * * * /home/jonathan/Repos/superpowers/sync-agent.sh >> /home/jonathan/Repos/superpowers/sync.log 2>&1
    # Keep the bare nixos-config repo's local `main` ref in sync with
    # origin/main so new worktrees (`git worktree add ... main`) don't
    # start behind. Bare repo = no working tree, no conflicts possible;
    # `main:main` refspec advances the ref in-place.
    */30 * * * * git -C /home/jonathan/Repos/nixos-config fetch origin main:main >> /home/jonathan/.claude/logs/nixos-config-fetch.log 2>&1
  '';

  # `crontab` is a setuid wrapper at /run/wrappers/bin/crontab (provided by
  # services.cron.enable). Home-manager activation runs with a minimal PATH
  # that doesn't include /run/wrappers/bin, so `command -v crontab` returned
  # nothing here and the if-guard silently skipped the reinstall — leaving
  # the active crontab stale after every `nixos-rebuild switch`. The
  # backup-sync agent (~/Repos/dotfiles/sync-agent.sh, scheduled daily)
  # didn't compensate either, because it bails out without gitleaks.
  # Result: cron entries on disk drifted from the active crontab for days
  # (caught when wellbeing trackers kept failing with /usr/bin/python3
  # after the python-path fix had already deployed).
  #
  # Ordering: entryAfter ["linkGeneration"], NOT ["writeBoundary"]. The
  # writeBoundary marker fires before the new generation's symlinks
  # under $HOME are swapped in; the symlink at $HOME/.config/crontab
  # still points at the PREVIOUS generation's store path during any
  # activation hook running between writeBoundary and linkGeneration.
  # An earlier iteration of this hook reinstalled the OLD content on
  # every rebuild, which is how PR #52's PATH= addition didn't reach
  # the active crontab even after a successful deploy. linkGeneration
  # is the step that updates the symlinks; running after it guarantees
  # crontab reads the new generation.
  home.activation.installCrontab = lib.hm.dag.entryAfter ["linkGeneration"] ''
    if [ -x /run/wrappers/bin/crontab ]; then
      /run/wrappers/bin/crontab "$HOME/.config/crontab" || true
    fi
  '';

  # router-agent expects ~/.config/router/paths.yaml. Project is cloned
  # by cloneRepos activation but its config dir lives outside the repo.
  # Content migrated 1:1 from the prior Mint install (mint-backup-2026-05-05).
  # Contains no secrets — just Dropbox roots and local-state directory
  # paths.
  home.file.".config/router/paths.yaml".text = ''
    version: 1

    # Dropbox roots — sync target for ingestion and exocortex artifacts.
    # Change ~/Dropbox to wherever your Dropbox folder lives.
    dropbox_root: ~/Dropbox
    inlet_transcripts: ''${dropbox_root}/1. Exocortex/_Inlet/Android/Transcripts
    exocortex_root: ''${dropbox_root}/1. Exocortex

    # Local-disk roots (per-machine, never in Dropbox).
    state_root: ~/.local/state/router
    inbox_root: ''${state_root}/inbox
    processed_root: ''${state_root}/processed
    queue_root: ''${state_root}/queue
    audit_root: ''${state_root}/audit
    ingestor_ledger: ''${state_root}/ingestor-ledger.db
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
    mkdir -p "$HOME/.local/share"

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

    # router-agent lives outside ~/Repos because router-services.nix
    # configures the systemd units' WorkingDirectory to
    # %h/.local/share/router-agent (uv-managed venv lands alongside).
    # uv will bootstrap the venv on first `uv run`; if resolution fails
    # the unit goes into Restart=on-failure (journal-visible, not
    # silent).
    clone_if_missing router-agent "$HOME/.local/share/router-agent"

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
