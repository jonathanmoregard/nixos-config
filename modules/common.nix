{ pkgs, ... }:
{
  # Allow unfree packages (required for claude-code)
  nixpkgs.config.allowUnfree = true;

  # Packages available on all machines
  environment.systemPackages = with pkgs; [
    claude-code
    git
    gh
    ripgrep
    fd
    jq
    curl
    wget
  ];

  # Nix flakes + nix-command enabled globally
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
}
