{ ... }:
{
  services.xserver = {
    enable = true;
    desktopManager.cinnamon.enable = true;
    displayManager.lightdm.enable = true;
  };

  # gnome-keyring service + login PAM moved to profiles/keyring.nix so
  # vm-keyring can pull in the keyring slice without dragging the full
  # Cinnamon/LightDM closure. lightdm-PAM extension stays here — it's
  # display-manager-coupled.
  security.pam.services.lightdm.enableGnomeKeyring = true;

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
