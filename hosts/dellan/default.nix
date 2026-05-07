{ config, pkgs, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/nixos/desktop.nix
    ../../modules/nixos/laptop.nix
    ../../modules/nixos/tailscale.nix

    # CI/CD workflow modules. CI itself runs on GitHub-hosted runners
    # (ubuntu-latest); see .github/workflows/. The modules below cover
    # only the pieces that MUST live on dellan: webhook ingress and the
    # deploy-on-push systemd unit.
    ../../modules/nixos/github-webhook.nix
    ../../modules/nixos/nixos-deploy.nix
    ../../modules/nixos/build-coordination.nix
    ../../modules/nixos/ci-state.nix
    ../../modules/nixos/claude-agent-users.nix
  ];

  # ---------------------------------------------------------------------
  # CI/CD workflow — agenix secret declarations.
  # ---------------------------------------------------------------------

  age.secrets.deploy-ssh-key.file        = ../../secrets/deploy-ssh-key.age;
  age.secrets.github-webhook-secret.file = ../../secrets/github-webhook-secret.age;
  age.secrets.gh-janitor-token.file      = ../../secrets/gh-janitor-token.age;

  # LLM provider API keys consumed by claude-cl-sync.service and the
  # research-agent-mcp wrapper. Both load via env-format file (KEY=value
  # per line). owner=jonathan + mode=0400 because the consumers run as
  # the user, not root.
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

  # ---------------------------------------------------------------------
  # CI/CD workflow — service options.
  # ---------------------------------------------------------------------

  services.buildCoordination.enable = true;   # nix max-jobs/cores caps

  services.githubWebhook = {                  # Webhook ingress
    enable = true;
    secretFile = config.age.secrets.github-webhook-secret.path;
  };

  services.nixosDeploy = {                    # Auto-deploy on push:main
    enable = true;
    sshKeyFile = config.age.secrets.deploy-ssh-key.path;
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
