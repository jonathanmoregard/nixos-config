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
  # Written as XML directly — xfconf-query requires a live session and fails during HM activation
  home.file.".config/xfce4/xfconf/xfce-perchannel-xml/xfce4-keyboard-shortcuts.xml" = {
    text = ''
      <?xml version="1.0" encoding="UTF-8"?>
      <channel name="xfce4-keyboard-shortcuts" version="1.0">
        <property name="commands" type="empty">
          <property name="custom" type="empty">
            <property name="&lt;Super&gt;g" type="string" value="/home/jonathan/.local/bin/desaturate-toggle"/>
          </property>
        </property>
      </channel>
    '';
  };
}
