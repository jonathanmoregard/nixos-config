{ pkgs, ... }:
{
  # NB: `nixpkgs.config.allowUnfree` and `nixpkgs.overlays` live in
  # flake.nix at the pkgs-construction level. Setting them here would
  # make the test framework's externally-injected pkgs read-only conflict
  # with the modules. See tests/dellan-vm.nix.

  # Packages available on all machines.
  #
  # Curated "expected-to-have" Unix CLI toolbox: small/tiny binaries
  # that Claude (and humans) reach for routinely. Grouped by category
  # for legibility. A few attribute names don't match their binary
  # name: tealdeer → tldr, du-dust → dust, dnsutils → dig.
  environment.systemPackages = with pkgs; [
    # --- pre-existing core ---
    claude-code
    git
    gh
    ripgrep        # rg — fast grep, respects .gitignore
    fd             # find replacement
    jq             # JSON query/transform
    curl
    wget
    cachix

    # --- text processing ---
    yq-go          # YAML/JSON/XML query (Mike Farah)
    fzf            # fuzzy finder
    miller         # mlr — awk/sed/cut/join for CSV/TSV/JSON

    # --- binary / hex / encoding ---
    xxd            # hex dump + reverse
    hexyl          # colored hex viewer
    # base64 / od / stat / basenc ship in coreutils (already present)

    # --- file inspection ---
    file           # identify file type via magic bytes
    eza            # modern ls
    bat            # cat with syntax highlight + git
    tree           # recursive dir listing

    # --- disk / filesystem ---
    ncdu           # curses disk usage
    dust           # intuitive du (formerly du-dust)
    duf            # better df

    # --- process / system ---
    htop
    lsof
    strace

    # --- network ---
    xh             # rust httpie clone — smaller than httpie
    dnsutils       # provides dig / nslookup / host
    mtr            # traceroute + ping combined
    socat          # bidirectional data relay
    netcat         # nc

    # --- archive ---
    zip
    unzip
    zstd
    xz

    # --- diff / compare ---
    delta          # syntax-highlighted git/diff viewer

    # --- misc developer ---
    tealdeer       # binary: tldr — fast tldr-pages client
    entr           # run commands when files change
    just           # command runner (make without build-system baggage)
    direnv         # per-directory env vars
    hyperfine      # CLI benchmarking
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
