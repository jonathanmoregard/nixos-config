{ config, pkgs, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/nixos/desktop.nix
    ../../modules/nixos/laptop.nix
    ../../modules/nixos/tailscale.nix

    # CI/CD workflow modules. CI itself runs on GitHub-hosted runners
    # (ubuntu-latest); see .github/workflows/. The modules below cover
    # only the pieces that MUST live on dellan: pull-based deploy +
    # webhook latency optimization.
    ../../modules/nixos/nixos-auto-deploy.nix
    ../../modules/nixos/build-coordination.nix
    ../../modules/nixos/cachix-push.nix
    ../../modules/nixos/claude-agent-users.nix

    # research-agent microvm. The MCP server spawned by Claude Code
    # (via home/research-agent-mcp.nix) ssh's into the long-running
    # research-agent microvm for every research() call. The microvm is
    # synthesized as microvm@research-agent.service by microvm.nix.
    #
    # docker.nix kept for now (no remaining Nix consumer after this PR,
    # but interactive use is out of scope — removing it host-wide is a
    # separate audit).
    ../../modules/nixos/docker.nix
    ../../modules/nixos/research-agent-microvm.nix

    # Feature VM overrides — no-op for prod toplevel, only activates
    # under `config.system.build.vm`. See module header for usage.
    ../../modules/nixos/feature-vm.nix

    # `substack-url-tool` + `tts-tool` — Substack-article-to-MP3 CLI
    # pipeline. Both live in standalone flakes; this module installs
    # them and wraps tts-tool to inject FISH_AUDIO_API_KEY_FILE from
    # the agenix secret at runtime.
    ../../modules/nixos/listen-tools.nix
  ];

  # ---------------------------------------------------------------------
  # CI/CD workflow — agenix secret declarations.
  # ---------------------------------------------------------------------

  age.secrets.deploy-ssh-key.file        = ../../secrets/deploy-ssh-key.age;
  age.secrets.github-webhook-secret.file = ../../secrets/github-webhook-secret.age;
  age.secrets.gh-janitor-token.file      = ../../secrets/gh-janitor-token.age;

  # LLM provider + research-agent secrets consumed by claude-cl-sync.service
  # and the research-agent-mcp wrapper. Both read raw key values with
  # `$(< file)` and export the matching env var themselves — `.age` files
  # contain the raw key only (no `KEY=` prefix). owner=jonathan + mode=0400
  # because the consumers run as the user, not root.
  age.secrets.anthropic-api-key = {
    file = ../../secrets/anthropic-api-key.age;
    owner = "jonathan";
    group = "users";
    mode = "0400";
  };
  age.secrets.openai-api-key = {
    file = ../../secrets/openai-api-key.age;
    owner = "jonathan";
    group = "users";
    mode = "0400";
  };
  age.secrets.exa-api-key = {
    file = ../../secrets/exa-api-key.age;
    owner = "jonathan";
    group = "users";
    mode = "0400";
  };
  age.secrets.tavily-api-key = {
    file = ../../secrets/tavily-api-key.age;
    owner = "jonathan";
    group = "users";
    mode = "0400";
  };
  age.secrets.claude-token = {
    file = ../../secrets/claude-token.age;
    owner = "jonathan";
    group = "users";
    mode = "0400";
  };

  # Private half of the SSH keypair the MCP server uses to ssh into the
  # research-agent microvm. Matching public key is plaintext inside
  # modules/nixos/research-agent-microvm.nix as authorized_keys.
  age.secrets.research-agent-host-key = {
    file = ../../secrets/research-agent-host-key.age;
    owner = "jonathan";
    group = "users";
    mode = "0400";
  };

  # ---------------------------------------------------------------------
  # research-agent microvm — persisted state.
  #
  # The VM's SSH host keys live on this virtiofs RW share so the
  # host-side `known_hosts` pin (StrictHostKeyChecking=accept-new in
  # the MCP server's ssh command — pinned on first connect, then
  # verified strictly) remains valid across VM reboots. The dir must
  # exist before the microvm boots, otherwise virtiofsd mounts an
  # empty source and services.openssh fails to write its hostKey path.
  #
  # /var/lib (not /home/jonathan/.local/) because systemd-tmpfiles
  # refuses to canonicalize across an ownership boundary
  # (jonathan → root → jonathan) — fails with "unsafe path transition".
  # /var/lib has no such hop and is the conventional spot for daemon
  # state anyway.
  # ---------------------------------------------------------------------
  systemd.tmpfiles.rules = [
    "d /var/lib/research-agent 0700 root root -"
    "d /var/lib/research-agent/vm-ssh 0700 root root -"
  ];

  # ---------------------------------------------------------------------
  # CI/CD workflow — service options.
  # ---------------------------------------------------------------------

  services.buildCoordination.enable = true;   # nix max-jobs/cores caps

  services.nixos-auto-deploy = {              # Pull-based deploy + webhook
    enable = true;
    sshKeyFile = config.age.secrets.deploy-ssh-key.path;
    webhook = {
      enable = true;
      secretFile = config.age.secrets.github-webhook-secret.path;
    };
  };

  services.claudeAgentUsers.enable = true;    # claude-agent-N users


  # systemd-boot on UEFI
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Networking — NetworkManager + hostname
  networking = {
    hostName = "dellan";
    networkmanager.enable = true;
  };

  # Locale + timezone
  time.timeZone = "Europe/Stockholm";
  i18n.defaultLocale = "en_US.UTF-8";

  # Swedish keyboard layout (system console; Cinnamon DE handles X/Wayland separately)
  console.keyMap = "sv-latin1";
  services.xserver.xkb = {
    layout = "se";
    variant = "";
  };

  # SSH server
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # User account
  users.users.jonathan = {
    isNormalUser = true;
    initialPassword = "changeme"; # pragma: allowlist secret
    extraGroups = [ "wheel" "networkmanager" "video" ];
    shell = pkgs.zsh;
    # Incoming SSH: keys whose PRIVATE half lives on the OTHER machine.
    # jonathan@nixos-vm = host's key (used to drive dellan from host repo).
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPf3ZLrzmf0pNSTJS603CaNb6in/ctXc0hZSJ9BflOVl jonathan@nixos-vm"
    ];
  };

  # Allow wheel group to use sudo without password
  security.sudo.wheelNeedsPassword = false;

  # Enable zsh system-wide (required for it to be a valid login shell)
  programs.zsh.enable = true;

  # Btrfs maintenance — weekly scrub on root
  services.btrfs.autoScrub = {
    enable = true;
    interval = "weekly";
    fileSystems = [ "/" ];
  };

  system.stateVersion = "25.11";
}
