{ ... }:
{
  services.xserver = {
    enable = true;
    desktopManager.cinnamon.enable = true;
    displayManager.lightdm.enable = true;
  };

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
