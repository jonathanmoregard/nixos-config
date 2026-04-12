# Placeholder — flesh out when Mac Mini (M-series, 64GB) arrives.
{ pkgs, ... }:
{
  # Basic nix-darwin system config
  system.stateVersion = 6;  # nix-darwin version, not NixOS

  # Enable Touch ID for sudo (convenient on Mac)
  security.pam.enableSudoTouchIdAuth = true;

  # Nix daemon settings
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Allow unfree (claude-code, etc.)
  nixpkgs.config.allowUnfree = true;

  # Shell
  programs.zsh.enable = true;
}
