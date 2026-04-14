{ pkgs, lib, ... }:
{
  imports = [
    ./jonathan.nix
    ./cinnamon.nix
    ./desktop-apps.nix
    ./ghostty.nix
    ./autodoro.nix
    ./drift-analyzer.nix
  ];

  home.activation.cloneRepos = lib.hm.dag.entryAfter ["writeBoundary"] ''
    mkdir -p "$HOME/Repos"

    clone_if_missing() {
      local repo="$1"
      local dir="$2"
      if [ ! -d "$dir" ]; then
        GIT_TERMINAL_PROMPT=0 GIT_ASKPASS="" SSH_ASKPASS="" ${pkgs.git}/bin/git clone "https://github.com/jonathanmoregard/$repo.git" "$dir" 2>/dev/null || true
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
  '';
}
