{ config, pkgs, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/nixos/desktop.nix
    ../../modules/nixos/docker.nix  # TODO(nixos-migration): swap for microvm.nix (Firecracker)
    ../../modules/nixos/tailscale.nix
    ../../modules/nixos/agenix-rekey-common.nix
  ];

  # Legacy nixos-vm has its own ssh host pubkey (matches the pre-rekey
  # `vm` constant from the old secrets.nix). No rekey-managed secrets
  # consume anything on this host today, but the module assertion needs
  # SOME pubkey to evaluate.
  age.rekey.hostPubkey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJaYUR/n99axrFFFr/uv987jwaa6fYik7Ykf9iRSieZV root@nixos-vm";
  age.rekey.localStorageDir = ../../secrets/rekeyed/nixos-vm;

  # systemd-boot works cleanly with the GPT+ESP partition scheme used during install
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Networking — NetworkManager + hostname
  networking = {
    hostName = "nixos-vm";
    networkmanager.enable = true;
  };

  # Locale + timezone
  time.timeZone = "Europe/Stockholm";
  i18n.defaultLocale = "en_US.UTF-8";

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
    extraGroups = [ "wheel" "networkmanager" ];
    shell = pkgs.zsh;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPf3ZLrzmf0pNSTJS603CaNb6in/ctXc0hZSJ9BflOVl jonathan@nixos-vm"
    ];
  };

  # Allow wheel group to use sudo without password
  security.sudo.wheelNeedsPassword = false;

  # Enable zsh system-wide (required for it to be a valid login shell)
  programs.zsh.enable = true;

  system.stateVersion = "25.11";
}
