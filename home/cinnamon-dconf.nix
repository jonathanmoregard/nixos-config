{ pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    mint-themes
    mint-y-icons
    bibata-cursors
  ];

  dconf.settings = {
    "org/cinnamon/desktop/interface" = {
      gtk-theme = "Mint-Y-Dark-Red";
      icon-theme = "Mint-Y-Red";
      cursor-theme = "Bibata-Modern-Classic";
      cursor-size = 24;
    };

    "org/cinnamon/theme" = {
      name = "Mint-Y-Dark-Red";
    };

    "org/cinnamon" = {
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
      number-workspaces = 4;
    };

    "org/cinnamon/desktop/wm/preferences" = {
      tile-maximize = true;
    };

    "org/cinnamon/panels-enabled" = {
      panel-heights = "['1:47']";
    };

    "org/gnome/desktop/interface" = {
      gtk-theme = "Mint-Y-Dark-Red";
      icon-theme = "Mint-Y-Red";
      cursor-theme = "Bibata-Modern-Classic";
    };

    "org/cinnamon/settings-daemon/plugins/color" = {
      night-light-enabled = true;
      night-light-temperature = 2400;
      night-light-schedule-automatic = true;
      night-light-latitude = 59.2;
      night-light-longitude = 18.03;
    };

    "org/cinnamon/settings-daemon/plugins/power" = {
      lid-close-ac-action = "suspend";
      lid-close-battery-action = "suspend";
      sleep-display-ac = 1800;
      sleep-display-battery = 1800;
    };

    "org/gnome/desktop/peripherals/keyboard" = {
      repeat-interval = 30;
      delay = 500;
    };

    "org/cinnamon/desktop/peripherals/touchpad" = {
      two-finger-scroll-enabled = true;
      natural-scroll = false;
    };
  };

  # desaturate-all applet — cloned at activation time if missing
  home.activation.installDesaturateApplet = lib.hm.dag.entryAfter ["writeBoundary"] ''
    APPLET_DIR="$HOME/.local/share/cinnamon/applets/desaturate-all@hkoosha"
    if [ ! -d "$APPLET_DIR" ]; then
      mkdir -p "$(dirname "$APPLET_DIR")"
      ${pkgs.git}/bin/git clone --depth 1 --filter=blob:none --sparse \
        https://github.com/linuxmint/cinnamon-spices-applets.git /tmp/cinnamon-spices-tmp 2>/dev/null || true
      if [ -d /tmp/cinnamon-spices-tmp ]; then
        cd /tmp/cinnamon-spices-tmp && ${pkgs.git}/bin/git sparse-checkout set "desaturate-all@hkoosha"
        cp -r /tmp/cinnamon-spices-tmp/"desaturate-all@hkoosha" "$APPLET_DIR" 2>/dev/null || true
        rm -rf /tmp/cinnamon-spices-tmp
      fi
    fi
  '';
}
