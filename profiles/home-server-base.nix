{
  lib,
  pkgs,
  ...
}:

{
  imports = [ ../modules/nixos/tailscale.nix ];

  boot.loader.systemd-boot = {
    enable = true;
    configurationLimit = 8;
  };
  boot.loader.efi.canTouchEfiVariables = true;

  networking = {
    hostName = "home-server";
    networkmanager.enable = false;
    useDHCP = false;
    useNetworkd = true;
    firewall = {
      enable = true;
      interfaces.tailscale0.allowedTCPPorts = [ 22 ];
    };
  };

  systemd.network = {
    enable = true;
    wait-online.anyInterface = true;
    networks."10-wired-dhcp" = {
      matchConfig.Name = [
        "en*"
        "eth*"
      ];
      networkConfig.DHCP = "yes";
      linkConfig.RequiredForOnline = "routable";
    };
  };

  services.resolved.enable = true;
  # NixOS VM tests disable host time sync; real hardware keeps this default.
  services.timesyncd.enable = lib.mkDefault true;

  time.timeZone = "Europe/Stockholm";
  i18n.defaultLocale = "en_US.UTF-8";
  console.keyMap = "sv-latin1";

  services.openssh = {
    enable = true;
    openFirewall = false;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };
  users.users.jonathan = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    shell = pkgs.zsh;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPf3ZLrzmf0pNSTJS603CaNb6in/ctXc0hZSJ9BflOVl jonathan@nixos-vm"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINT9HeHhu82OoNsAHe/QAh116pSEANuZUr1h5m8R8kpp jonathan@dellan"
    ];
  };
  security.sudo.wheelNeedsPassword = true;
  programs.zsh.enable = true;

  services.journald.extraConfig = ''
    Storage=persistent
    SystemMaxUse=512M
    RuntimeMaxUse=64M
    MaxRetentionSec=14day
  '';

  services.smartd = {
    enable = true;
    autodetect = true;
  };

  # A 128 GB server cannot use Dellan's 200/300 GiB workstation reserve.
  # Keep the same reactive-GC policy at a size that leaves useful headroom.
  nix.settings = {
    min-free = lib.mkForce (1024 * 1024 * 1024);
    max-free = lib.mkForce (5 * 1024 * 1024 * 1024);
    keep-derivations = false;
    keep-outputs = false;
  };

  system.stateVersion = "26.05";
}
