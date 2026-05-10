{ pkgs, ... }:
{
  home.username = "jonathan";
  home.homeDirectory = "/home/jonathan";
  home.stateVersion = "25.11";

  programs.home-manager.enable = true;

  home.packages = with pkgs; [
    zsh-powerlevel10k
    nodejs_22
    pnpm
    gitleaks
    gh
    direnv
    jq
    # Fonts
    nerd-fonts.jetbrains-mono
    # Dev toolchains
    rustc
    cargo
    python3
    uv
    # Intentionally NOT included (drift-scan 2026-04-19):
    # - terraform: not used for now
    # - yt-dlp: not wanted
    # - virt-manager / libvirtd stack: not needed on this host
  ];

  programs.git = {
    enable = true;
    settings = {
      user.name = "jonathanmoregard";
      user.email = "jonathan.more@hotmail.com";
      init.defaultBranch = "main";
      pull.rebase = true;
      credential."https://github.com".helper = "!/run/current-system/sw/bin/gh auth git-credential";
      core.hooksPath = "~/.config/git/hooks";
      core.excludesfile = "~/.config/git/ignore";
    };
  };

  # Global gitignore
  home.file.".config/git/ignore".text = ''
    **/.claude/settings.local.json
  '';

  # Husky pre-commit hook helper — loads nvm so node-based hooks find the
  # right binary regardless of which shell the commit was made from.
  home.file.".huskyrc".text = ''
    # Load nvm for husky hooks
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
  '';

  # gitleaks pre-commit hook — blocks commits containing secrets
  home.file.".config/git/hooks/pre-commit" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      ${pkgs.gitleaks}/bin/gitleaks git --staged --redact --no-banner
      if [ $? -ne 0 ]; then
        echo ""
        echo "gitleaks: potential secret detected — commit blocked."
        echo "To bypass (only if you're sure): git commit --no-verify"
        exit 1
      fi
    '';
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
      drift = "cat ~/.local/share/nixos-drift-analyzer/latest.md 2>/dev/null || echo 'No drift report yet.'";
    };

    loginExtra = ''
      # NixOS drift check — runs once on login
      _nixos_drift_check() {
        local warnings=()

        # Imperatively installed packages (nix-env) — outside the flake, lost on rebuild
        local imperative
        imperative=$(nix-env --query 2>/dev/null | grep -v '^$')
        if [[ -n "$imperative" ]]; then
          warnings+=("Imperative nix-env installs (not in flake, lost on rebuild):\n$(echo "$imperative" | sed 's/^/    /')")
        fi

        # Packages in PATH not traceable to /nix/store (rough heuristic)
        if [[ -d "$HOME/.local/bin" ]] && [[ -n "$(ls -A "$HOME/.local/bin" 2>/dev/null)" ]]; then
          warnings+=("~/.local/bin has files — check if these should be in home.packages")
        fi

        # Surface latest drift report if it exists
        local report="$HOME/.local/share/nixos-drift-analyzer/latest.md"
        if [[ -f "$report" ]]; then
          warnings+=("Drift report available: $report")
        fi

        if [[ ''${#warnings[@]} -gt 0 ]]; then
          echo ""
          echo "  NixOS drift warning — the following may be lost on rebuild:"
          for w in "''${warnings[@]}"; do
            echo "  * $w"
          done
          echo "  Encode these in your flake: /home/jonathan/Repos/nixos-config"
          echo ""
        fi
      }
      _nixos_drift_check
    '';

    initContent = ''
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

      # claude wrapper: resume the most recent session by default.
      # Pass --no-continue (consumed here, not forwarded) to start fresh.
      claude() {
        local cont=(--continue)
        local args=()
        for a in "$@"; do
          if [[ "$a" == "--no-continue" ]]; then
            cont=()
          else
            args+=("$a")
          fi
        done
        command claude "''${cont[@]}" "''${args[@]}"
      }
    '';

    envExtra = ''
      export ANDROID_HOME="$HOME/Android/Sdk"
      export PATH="$PATH:$ANDROID_HOME/emulator:$ANDROID_HOME/platform-tools"
      # Prepend so user-installed binaries (e.g. claude-code native
      # installer at ~/.local/share/claude/versions/) win over nix-pkg
      # fallbacks. Required for picking up self-updating tools.
      export PATH="$HOME/.local/bin:$PATH"
    '';
  };

  home.file.".p10k.zsh".source = ../dotfiles/p10k.zsh;
}
