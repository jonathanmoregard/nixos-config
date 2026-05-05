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
    cachix
  ];

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];

    # Cachix binary cache. Public read; CI pushes via CACHIX_AUTH_TOKEN
    # GitHub repo secret (see .github/workflows/ci.yml + gate.yml). Local
    # rebuilds substitute from here; dellan auto-deploy substitutes too.
    # cache.nixos.org stays in the default substituter list (nix prepends
    # it). Trusted-public-keys is additive.
    substituters = [
      "https://jonathanmoregard.cachix.org"
    ];
    trusted-public-keys = [
      "jonathanmoregard.cachix.org-1:Qzksr/c2ciAaV4j/U2mGFd1HTgOAicks8gJNs1Ztxo8="
    ];
  };
}
