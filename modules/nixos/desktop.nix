{ pkgs, ... }:
{
  services.xserver = {
    enable = true;
    desktopManager.cinnamon.enable = true;
    displayManager.lightdm.enable = true;
  };

  # Silence X11 bell in the LightDM greeter. Pressing arrow keys
  # against a field boundary in the password entry otherwise fires
  # `XBell`, which the host audio stack plays as a "twoink" event
  # sound. `org.cinnamon.desktop.wm.preferences.audible-bell = false`
  # in home/cinnamon.nix covers jonathan's logged-in session, but the
  # greeter runs as the `lightdm` user with separate dconf state.
  # `xset b off` toggles the bell on the X server itself, so it
  # silences both the greeter session and any later session sharing
  # the same X server.
  services.xserver.displayManager.lightdm.extraSeatDefaults = ''
    greeter-setup-script=${pkgs.writeShellScript "lightdm-disable-bell" ''
      ${pkgs.xorg.xset}/bin/xset b off
    ''}
  '';

  services.gnome.gnome-keyring.enable = true;
  security.pam.services.lightdm.enableGnomeKeyring = true;
  security.pam.services.login.enableGnomeKeyring = true;

  # cron daemon — required for the home-manager-installed user crontab
  # in home/jonathan-linux.nix. Without this, `crontab` is missing from
  # PATH and the installCrontab activation silently skips.
  services.cron.enable = true;

  # Google Chrome: set Google as default search engine (recommended, user can override)
  environment.etc."opt/google/chrome/policies/recommended/search.json" = {
    text = builtins.toJSON {
      DefaultSearchProviderEnabled = true;
      DefaultSearchProviderName = "Google";
      DefaultSearchProviderSearchURL = "https://www.google.com/search?q={searchTerms}";
      DefaultSearchProviderKeyword = "google.com";
    };
    mode = "0644";
  };
}
