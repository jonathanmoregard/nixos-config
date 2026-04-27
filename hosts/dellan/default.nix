{ config, pkgs, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/nixos/desktop.nix
    ../../modules/nixos/laptop.nix
    ../../modules/nixos/tailscale.nix
  ];

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
    # TODO: replace bootstrap vm key with dellan-specific key after first boot
    # (ssh-keygen -t ed25519 -C jonathan@dellan, then commit the new pubkey here)
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
