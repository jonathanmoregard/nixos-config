{ config, pkgs, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/nixos/desktop.nix
    ../../modules/nixos/laptop.nix
    ../../modules/nixos/tailscale.nix

    # CI/CD workflow modules — all enable=false by default so importing
    # is inert. Flip enables one at a time per the install order in
    # pending_for_human.md.
    ../../modules/nixos/atticd.nix
    ../../modules/nixos/actions-runner.nix
    ../../modules/nixos/github-webhook.nix
    ../../modules/nixos/nixos-deploy.nix
    ../../modules/nixos/build-coordination.nix
    ../../modules/nixos/ci-state.nix
    ../../modules/nixos/claude-agent-users.nix
  ];

  # ---------------------------------------------------------------------
  # CI/CD workflow — agenix secret declarations.
  # ---------------------------------------------------------------------

  age.secrets.github-runner-token.file    = ../../secrets/github-runner-token.age;
  age.secrets.actions-runner-ssh-key.file = ../../secrets/actions-runner-ssh-key.age;
  age.secrets.github-webhook-secret.file  = ../../secrets/github-webhook-secret.age;
  age.secrets.gh-janitor-token.file       = ../../secrets/gh-janitor-token.age;
  age.secrets.atticd-rs256-secret.file    = ../../secrets/atticd-rs256-secret.age;

  # ---------------------------------------------------------------------
  # CI/CD workflow — service options.
  # ---------------------------------------------------------------------

  services.atticCache = {                     # Step 2: Attic binary cache
    enable = true;
    rs256SecretFile = config.age.secrets.atticd-rs256-secret.path;
  };
  services.buildCoordination.enable = true;   # Step 2b: nix max-jobs/cores caps

  services.actionsRunner = {                  # Step 1: self-hosted GHA runner
    enable = true;
    url = "https://github.com/jonathanmoregard/nixos-config";
    tokenFile  = config.age.secrets.github-runner-token.path;
    sshKeyFile = config.age.secrets.actions-runner-ssh-key.path;
  };

  services.githubWebhook = {                  # Step 5: webhook ingress
    enable = true;
    secretFile = config.age.secrets.github-webhook-secret.path;
  };

  services.nixosDeploy = {                    # Step 6: production auto-deploy
    enable = true;
    sshKeyFile = config.age.secrets.actions-runner-ssh-key.path;
  };

  services.claudeAgentUsers.enable = true;    # Step 7: claude-agent-N users


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
