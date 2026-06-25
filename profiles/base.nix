{ pkgs, ... }:
{
  # Boot loader (UEFI / systemd-boot). Tests `mkForce false` this in
  # tests/lib/common.nix' minimal node so the framework can boot the
  # ephemeral VM without touching EFI variables.
  boot.loader.systemd-boot.enable = true;
  # Cap boot menu to 8 most recent generations (older ones still GC-able
  # via nix-collect-garbage; this only trims the menu + /boot entries).
  boot.loader.systemd-boot.configurationLimit = 8;
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
