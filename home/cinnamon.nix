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
    xdotool
    scrot
    xbindkeys
  ];

  # Notification sound
  home.file.".local/share/sounds/tink.oga".source = ../assets/sounds/tink.oga;

  # Install desaturate-all applet from nix store
  home.file.".local/share/cinnamon/applets/desaturate-all@hkoosha" = {
    source = "${desaturateApplet}/desaturate-all@hkoosha/files/desaturate-all@hkoosha";
    recursive = true;
  };

  # KeePassXC autostart
  home.file.".config/autostart/org.keepassxc.KeePassXC.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=KeePassXC
    Exec=${pkgs.keepassxc}/bin/keepassxc
    Hidden=false
    X-GNOME-Autostart-enabled=true
  '';

  # Beeper autostart
  home.file.".config/autostart/beeper.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Beeper
    Exec=beeper
    Hidden=false
    X-GNOME-Autostart-enabled=true
  '';

  # xbindkeys autostart — binds defined in ~/.xbindkeysrc (managed via dotfiles repo)
  home.file.".config/autostart/xbindkeys.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=xbindkeys
    Exec=${pkgs.xbindkeys}/bin/xbindkeys
    Hidden=false
    X-GNOME-Autostart-enabled=true
  '';

  # Dropbox autostart
  home.file.".config/autostart/dropbox.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Dropbox
    Exec=${pkgs.dropbox}/bin/dropbox start -i
    Hidden=false
    X-GNOME-Autostart-enabled=true
  '';

  # Voquill (local) autostart — locally built voice typing app
  home.file.".config/autostart/voquill.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Version=1.0
    Name=Voquill (local)
    Comment=Voquill (local) startup script
    Exec=/home/jonathan/Repos/voquill/apps/desktop/src-tauri/target/debug/Voquill --voquill-autostart-hidden
    StartupNotify=false
    Terminal=false
    Hidden=false
    X-GNOME-Autostart-enabled=true
  '';

  # Cinnamon applet configs — written as real files (not symlinks) so applets can read/write them
  home.activation.cinnamonAppletConfigs = lib.hm.dag.entryAfter ["writeBoundary"] ''
    # Desaturate-all applet config
    mkdir -p "$HOME/.config/cinnamon/spices/desaturate-all@hkoosha"
    DESAT_CFG="$HOME/.config/cinnamon/spices/desaturate-all@hkoosha/desaturate-all@hkoosha.json"
    rm -f "$DESAT_CFG"
    cat > "$DESAT_CFG" << 'DESAT_EOF'
    ${builtins.toJSON {
      saturation = { type = "scale"; default = 0; min = 0; max = 100; step = 1; value = 9; description = "Color saturation"; };
      keybinding = { type = "keybinding"; default = ""; value = "<Super>g"; description = "Shortcut to toggle desaturation effect"; };
      automatic = { type = "switch"; default = false; value = false; description = "Automatic"; tooltip = "Automatically enable and disable the desaturation effect based on the time of day"; };
      start-timechooser = { type = "timechooser"; default = { h = 22; m = 0; s = 0; }; value = { h = 22; m = 0; s = 0; }; description = "Time of day to automatically enable"; dependency = "automatic"; };
      end-timechooser = { type = "timechooser"; default = { h = 6; m = 0; s = 0; }; value = { h = 6; m = 0; s = 0; }; description = "Time of day to automatically disable"; dependency = "automatic"; };
      resume-on-startup = { type = "switch"; default = false; value = true; description = "Restore desaturation effect state on startup"; tooltip = "Restore the previously set desaturation state when cinnamon starts"; dependency = "!automatic"; };
      state = { type = "generic"; default = 0; value = false; };
    }}
    DESAT_EOF

    # Grouped-window-list pinned apps
    mkdir -p "$HOME/.config/cinnamon/spices/grouped-window-list@cinnamon.org"
    GWL_CFG="$HOME/.config/cinnamon/spices/grouped-window-list@cinnamon.org/2.json"
    rm -f "$GWL_CFG"
    cat > "$GWL_CFG" << 'GWL_EOF'
    ${builtins.toJSON {
      pinned-apps = {
        type = "generic";
        default = [ "nemo.desktop" "firefox.desktop" "org.gnome.Terminal.desktop" ];
        value = [
          "nemo.desktop"
          "kitty.desktop"
          "org.keepassxc.KeePassXC.desktop"
          "google-chrome.desktop"
        ];
      };
    }}
    GWL_EOF
  '';

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
      date-format = "YYYY-MM-DD";
    };

    "org/cinnamon/theme" = {
      name = "Mint-Y-Dark-Red";
    };

    "org/cinnamon/desktop/background" = {
      picture-uri = "file://${../wallpapers/misty-landscape.jpg}";
      picture-options = "zoom";
    };

    # --- Cinnamon desktop ---
    "org/cinnamon/desktop/interface" = {
      gtk-theme = "Mint-Y-Dark-Red";
      icon-theme = "Mint-Y-Red";
      cursor-theme = "Bibata-Modern-Classic";
      cursor-blink-time = 1200;
      first-day-of-week = 1;
      toolkit-accessibility = false;
      clock-use-24h = true;
      font-name = "Ubuntu 10";
    };

    "org/cinnamon/sounds" = {
      notification-enabled = true;
      notification-file = "/home/jonathan/.local/share/sounds/tink.oga";
    };

    "org/cinnamon/desktop/sound" = {
      event-sounds = false;
    };

    "org/cinnamon/desktop/wm/preferences" = {
      min-window-opacity = 30;
      button-layout = ":minimize,maximize,close";
      titlebar-font = "Ubuntu Medium 10";
      titlebar-uses-system-font = false;
      num-workspaces = 4;
      theme = "Mint-Y";
      audible-bell = false;
      resize-with-right-button = true;
      focus-mode = "click";
      action-double-click-titlebar = "toggle-maximize";
      action-middle-click-titlebar = "lower";
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
      two-finger-scrolling-enabled = true; # key name fix — "scroll-enabled" was silently ignored
      natural-scroll = true;
      tap-to-click = true;
      tap-and-drag = true;
      disable-while-typing = true;
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
      exec = "kitty";
      exec-arg = "-e"; # kitty supports "-e CMD ARGS..." for Nemo "Open in Terminal"
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
      lock-on-suspend = true;
      critical-battery-action = "hibernate";
    };

    "org/cinnamon/settings-daemon/peripherals/keyboard" = {
      numlock-state = "off";
    };

    # Keybinding for desaturate-all is in the applet config (Super+G)

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
      font-antialiasing = "grayscale";
      font-hinting = "slight";
      monospace-font-name = "DejaVu Sans Mono 10";
      document-font-name = "Sans 10";
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
      enable-delete = true;
      confirm-move-to-trash = false;
      sort-directories-first = true;
      sort-favorites-first = true;
      always-use-browser = true;
      thumbnail-limit = lib.gvariant.mkUint64 34359738368; # 32 GB
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
