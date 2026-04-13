{ pkgs, lib, ... }:
let
  desaturateApplet = pkgs.fetchgit {
    url = "https://github.com/linuxmint/cinnamon-spices-applets.git";
    rev = "f4db862d7555d3352c388588b7c646eb5a863eb8"; # pragma: allowlist secret
    sparseCheckout = [ "desaturate-all@hkoosha" ];
    hash = "sha256-H4KTWTHm/Iq7hutUFrJbuCVCeTTzOUCZfsdi4+yW/I8="; # pragma: allowlist secret
  };
in
{
  home.packages = with pkgs; [
    mint-themes
    mint-y-icons
    bibata-cursors
  ];

  # Install desaturate-all applet from nix store
  home.file.".local/share/cinnamon/applets/desaturate-all@hkoosha" = {
    source = "${desaturateApplet}/desaturate-all@hkoosha/files/desaturate-all@hkoosha";
    recursive = true;
  };

  dconf.settings = {
    # --- Cinnamon shell ---
    "org/cinnamon" = {
      alttab-switcher-delay = 100;
      enabled-applets = [
        "panel1:left:0:menu@cinnamon.org:0"
        "panel1:left:1:separator@cinnamon.org:1"
        "panel1:left:2:grouped-window-list@cinnamon.org:2"
        "panel1:right:0:desaturate-all@hkoosha:3"
        "panel1:right:1:systray@cinnamon.org:4"
        "panel1:right:2:xapp-status@cinnamon.org:5"
        "panel1:right:3:notifications@cinnamon.org:6"
        "panel1:right:4:printers@cinnamon.org:7"
        "panel1:right:5:removable-drives@cinnamon.org:8"
        "panel1:right:6:keyboard@cinnamon.org:9"
        "panel1:right:7:favorites@cinnamon.org:10"
        "panel1:right:8:network@cinnamon.org:11"
        "panel1:right:9:sound@cinnamon.org:12"
        "panel1:right:10:power@cinnamon.org:13"
        "panel1:right:11:calendar@cinnamon.org:14"
        "panel1:right:12:cornerbar@cinnamon.org:15"
      ];
      next-applet-id = 16;
      panels-height = [ "1:47" ];
      panel-zone-icon-sizes = ''[{"panelId": 1, "left": 32, "center": 0, "right": 24}]'';
      panel-zone-symbolic-icon-sizes = ''[{"panelId": 1, "left": 32, "center": 32, "right": 20}]'';
      panel-zone-text-sizes = ''[{"panelId": 1, "left": 10.0, "center": 0.0, "right": 0.0}]'';
    };

    "org/cinnamon/theme" = {
      name = "Mint-Y-Dark-Red";
    };

    # --- Cinnamon desktop ---
    "org/cinnamon/desktop/interface" = {
      gtk-theme = "Mint-Y-Dark-Red";
      icon-theme = "Mint-Y-Red";
      cursor-theme = "Bibata-Modern-Classic";
      cursor-blink-time = 1200;
      first-day-of-week = 1;
      toolkit-accessibility = false;
    };

    "org/cinnamon/desktop/sound" = {
      event-sounds = false;
    };

    "org/cinnamon/desktop/wm/preferences" = {
      min-window-opacity = 30;
    };

    "org/cinnamon/muffin" = {
      draggable-border-width = 10;
      tile-maximize = true;
    };

    # --- Cinnamon desktop peripherals ---
    "org/cinnamon/desktop/peripherals/keyboard" = {
      delay = lib.gvariant.mkUint32 500;
      repeat-interval = lib.gvariant.mkUint32 30;
    };

    "org/cinnamon/desktop/peripherals/touchpad" = {
      two-finger-scroll-enabled = true;
      natural-scroll = false;
    };

    # --- Touchpad gestures ---
    "org/cinnamon/gestures" = {
      swipe-down-2 = "PUSH_TILE_DOWN::end";
      swipe-down-3 = "TOGGLE_OVERVIEW::end";
      swipe-down-4 = "VOLUME_DOWN::end";
      swipe-left-2 = "PUSH_TILE_LEFT::end";
      swipe-left-3 = "WORKSPACE_NEXT::end";
      swipe-left-4 = "WINDOW_WORKSPACE_PREVIOUS::end";
      swipe-right-2 = "PUSH_TILE_RIGHT::end";
      swipe-right-3 = "WORKSPACE_PREVIOUS::end";
      swipe-right-4 = "WINDOW_WORKSPACE_NEXT::end";
      swipe-up-2 = "PUSH_TILE_UP::end";
      swipe-up-3 = "TOGGLE_EXPO::end";
      swipe-up-4 = "VOLUME_UP::end";
      tap-3 = "MEDIA_PLAY_PAUSE::end";
    };

    # --- Default apps ---
    "org/cinnamon/desktop/default-applications/terminal" = {
      exec = "ghostty";
      exec-arg = "-e";
    };

    # --- Night-light ---
    "org/cinnamon/settings-daemon/plugins/color" = {
      night-light-enabled = true;
      night-light-temperature = lib.gvariant.mkUint32 2400;
      night-light-schedule-automatic = true;
      night-light-latitude = 59.2;
      night-light-longitude = 18.03;
    };

    # --- Power ---
    "org/cinnamon/settings-daemon/plugins/power" = {
      lid-close-ac-action = "suspend";
      lid-close-battery-action = "suspend";
      sleep-display-ac = 1800;
      sleep-display-battery = 1800;
      sleep-inactive-ac-timeout = 0;
      sleep-inactive-battery-timeout = 0;
    };

    "org/cinnamon/settings-daemon/peripherals/keyboard" = {
      numlock-state = "off";
    };

    # --- Keybindings ---
    "org/cinnamon/desktop/keybindings/custom-keybindings/custom0" = {
      name = "Desaturate All";
      command = "dbus-send --session --type=method_call --dest=org.Cinnamon /org/Cinnamon org.Cinnamon.ToggleDesaturate";
      binding = [ "<Super>g" ];
    };

    "org/cinnamon/desktop/keybindings" = {
      custom-list = [ "custom0" ];
    };

    # --- GNOME / GTK settings ---
    "org/gnome/desktop/interface" = {
      gtk-theme = "Mint-Y-Dark-Red";
      icon-theme = "Mint-Y-Red";
      cursor-theme = "Bibata-Modern-Classic";
      cursor-size = 24;
      clock-format = "24h";
      font-name = "Ubuntu 10";
      enable-animations = true;
      toolkit-accessibility = false;
    };

    "org/gnome/desktop/sound" = {
      event-sounds = false;
    };

    "org/gnome/desktop/wm/preferences" = {
      button-layout = ":minimize,maximize,close";
      titlebar-font = "Ubuntu Medium 10";
      titlebar-uses-system-font = false;
      audible-bell = false;
      resize-with-right-button = true;
      num-workspaces = 4;
      theme = "Mint-Y";
    };

    "org/gnome/desktop/peripherals/keyboard" = {
      repeat-interval = lib.gvariant.mkUint32 30;
      delay = lib.gvariant.mkUint32 500;
    };

    # --- Nemo ---
    "org/nemo/preferences" = {
      show-hidden-files = true;
    };
  };

  # XDG MIME defaults (matches Mint)
  xdg.mimeApps = {
    enable = true;
    defaultApplications = {
      "x-scheme-handler/http" = "google-chrome.desktop";
      "x-scheme-handler/https" = "google-chrome.desktop";
      "text/html" = "google-chrome.desktop";
      "text/plain" = "org.x.editor.desktop";
      "application/pdf" = "xreader.desktop";
      "image/png" = "xviewer.desktop";
      "image/jpeg" = "xviewer.desktop";
      "image/gif" = "xviewer.desktop";
      "image/bmp" = "xviewer.desktop";
      "image/webp" = "xviewer.desktop";
      "inode/directory" = "nemo.desktop";
    };
  };
}
