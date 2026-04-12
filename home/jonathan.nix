{ pkgs, ... }:
{
  home.username = "jonathan";
  home.homeDirectory = "/home/jonathan";
  home.stateVersion = "25.11";

  programs.home-manager.enable = true;

  home.packages = with pkgs; [
    zsh-powerlevel10k
    nodejs_22
    nodePackages.pnpm
  ];

  programs.git = {
    enable = true;
    settings = {
      user.name = "jonathanmoregard";
      user.email = "jonathan.more@hotmail.com";
      init.defaultBranch = "main";
      pull.rebase = true;
      credential."https://github.com".helper = "!/run/current-system/sw/bin/gh auth git-credential";
    };
  };

  programs.zsh = {
    enable = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;

    oh-my-zsh = {
      enable = true;
      plugins = [ "git" ];
    };

    shellAliases = {
      ll = "ls -la";
      rebuild = "sudo nixos-rebuild switch --flake /etc/nixos#vm";
      update = "sudo nix flake update /etc/nixos && sudo nixos-rebuild switch --flake /etc/nixos#vm";
    };

    initExtra = ''
      # Powerlevel10k
      source ${pkgs.zsh-powerlevel10k}/share/zsh-powerlevel10k/powerlevel10k.zsh-theme
      [[ -f ~/.p10k.zsh ]] && source ~/.p10k.zsh

      # gh wrapper: ensure auth before gh commands
      gh() {
        if ! command gh auth status &>/dev/null 2>&1; then
          command gh auth login
        fi
        command gh "$@"
      }

      # claude wrapper: set up env if needed
      claude() {
        command claude "$@"
      }
    '';

    envExtra = ''
      export ANDROID_HOME="$HOME/Android/Sdk"
      export PATH="$PATH:$ANDROID_HOME/emulator:$ANDROID_HOME/platform-tools"
      export PATH="$PATH:$HOME/.local/bin"
    '';
  };

  home.file.".p10k.zsh".source = ../dotfiles/p10k.zsh;
}
