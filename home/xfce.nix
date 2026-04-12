{ pkgs, ... }:
{
  home.packages = [ pkgs.xcalib ];

  # Redshift — night light equivalent for X11 (replaces Cinnamon night light)
  services.redshift = {
    enable = true;
    latitude = "59.2";
    longitude = "18.03";
    temperature = {
      day = 6500;
      night = 2400;
    };
  };

  # Desaturate-all toggle script (equivalent of the Cinnamon applet)
  home.file.".local/bin/desaturate-toggle" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      STATE="''${XDG_RUNTIME_DIR:-/tmp}/desaturate_active"
      if [ -f "$STATE" ]; then
        ${pkgs.xcalib}/bin/xcalib -c
        rm -f "$STATE"
      else
        ${pkgs.xcalib}/bin/xcalib -alter -saturation -100 /dev/null
        touch "$STATE"
      fi
    '';
  };

  # Wire desaturate toggle as Super+G keyboard shortcut in XFCE
  xfconf.settings."xfce4-keyboard-shortcuts" = {
    "/commands/custom/<Super>g" = "/home/jonathan/.local/bin/desaturate-toggle";
  };
}
