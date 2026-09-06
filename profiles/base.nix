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
  #
  # NO `initialPassword` here, deliberately. It used to say `changeme`,
  # and this profile is what dellan — the machine holding the root-only
  # klaffat provisioning credentials — is built from. Since 2026-09-05
  # jonathan's sudo password is the ONE gate between an agent running as
  # jonathan and tokens that create and destroy servers
  # (`security.sudo.wheelNeedsPassword` below, and
  # modules/nixos/klaffat-infra.nix), so a published default belongs
  # nowhere near it.
  #
  # What the literal actually did, established from nixpkgs source rather
  # than assumed: with `users.mutableUsers = true` (dellan's setting)
  # update-users-groups.pl applies `initialPassword` only in the
  # `!defined($existing)` branch — at account CREATION — and the shadow
  # rewrite for an existing entry is gated on `!mutableUsers`. So removing
  # it changes nothing about the live account, and whether dellan's
  # password is still `changeme` is a fact only the founder can check.
  # That check is `pending_for_human.md`, 2026-09-05.
  #
  # Throwaway hosts keep theirs: hosts/vm/default.nix sets its own,
  # tests/lib/common.nix and modules/nixos/feature-vm.nix mkForce theirs.
  # Those machines are disposable and never hold a real credential.
  # Enforced by checks.x86_64-linux.dellan-initial-password-null.
  users.users.jonathan = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" "video" ];
    shell = pkgs.zsh;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPf3ZLrzmf0pNSTJS603CaNb6in/ctXc0hZSJ9BflOVl jonathan@nixos-vm"
    ];
  };

  # wheel must type a password for sudo.
  #
  # This was `false` until 2026-09-05. It changed because
  # modules/nixos/klaffat-infra.nix keeps provisioning credentials — Hetzner
  # and Cloudflare API tokens, the OpenTofu state passphrase, AWS keys, a
  # Nix binary-cache signing key — as root-only agenix secrets specifically
  # so that the principal an AI agent runs as (jonathan) cannot read them.
  # `NOPASSWD: ALL` for wheel made that a fiction: `sudo cat
  # /run/agenix/klaffat-hcloud-token` needed no password at all. Founder-
  # approved; the consequence is that every sudo on dellan now prompts.
  #
  # Asserted by checks.x86_64-linux.vm-klaffat-infra (`sudo -n true` as
  # jonathan must FAIL), so flipping this back cannot pass the gate quietly.
  # The one deliberate exception stays explicit and narrow: the deploy
  # webhook's NOPASSWD rule for `systemctl start nixos-deploy.service` in
  # modules/nixos/nixos-auto-deploy.nix.
  security.sudo.wheelNeedsPassword = true;

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
