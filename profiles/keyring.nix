{ ... }:
{
  # gnome-keyring + login-PAM wiring. Owns the /etc/pam.d/login lines
  # that vm-keyring asserts on. The lightdm-PAM extension lives in
  # modules/nixos/desktop.nix because it's display-manager-coupled —
  # this profile is safe to import without lightdm.
  services.gnome.gnome-keyring.enable = true;
  security.pam.services.login.enableGnomeKeyring = true;
}
