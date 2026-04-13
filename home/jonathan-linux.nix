{ pkgs, lib, ... }:
{
  imports = [
    ./jonathan.nix
    ./cinnamon.nix
    ./desktop-apps.nix
    ./ghostty.nix
    ./autodoro.nix
  ];

  home.activation.cloneRepos = lib.hm.dag.entryAfter ["writeBoundary"] ''
    mkdir -p "$HOME/Repos"

    clone_if_missing() {
      local repo="$1"
      local dir="$2"
      if [ ! -d "$dir" ]; then
        GIT_TERMINAL_PROMPT=0 ${pkgs.git}/bin/git clone "https://github.com/jonathanmoregard/$repo.git" "$dir" 2>/dev/null || true
      fi
    }

    clone_if_missing autodoro "$HOME/Repos/autodoro"
    clone_if_missing intender "$HOME/Repos/intender"
    clone_if_missing weekend "$HOME/Repos/weekend"
    clone_if_missing nixos-config "$HOME/Repos/nixos-config"
  '';
}
