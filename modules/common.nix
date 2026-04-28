{ pkgs, ... }:
{
  # NB: `nixpkgs.config.allowUnfree` and `nixpkgs.overlays` live in
  # flake.nix at the pkgs-construction level. Setting them here would
  # make the test framework's externally-injected pkgs read-only conflict
  # with the modules. See tests/dellan-vm.nix.

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
