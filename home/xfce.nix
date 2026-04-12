{ pkgs, ... }:
{
  home.packages = with pkgs; [ xcalib sxhkd redshift ];

  # Redshift config (read by both redshift and redshift-gtk)
  home.file.".config/redshift.conf" = {
    force = true;
    text = ''
      [redshift]
      temp-day=6500
      temp-night=2400
      location-provider=manual

      [manual]
      lat=59.2
      lon=18.03
    '';
  };

  # Autostart redshift-gtk so it appears in the system tray
  # (XFCE doesn't activate systemd graphical-session.target, so services.redshift won't start)
  home.file.".config/autostart/redshift.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Redshift
    Exec=${pkgs.redshift}/bin/redshift-gtk
    Hidden=false
    X-GNOME-Autostart-enabled=true
  '';

  # Desaturate-all toggle script
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

  # sxhkd for keyboard shortcuts — DE-agnostic, no XFCE session dependency
  home.file.".config/sxhkd/sxhkdrc".text = ''
    # Toggle desaturate-all (Super+G)
    super + g
      /home/jonathan/.local/bin/desaturate-toggle
  '';

  # Autostart sxhkd with the XFCE session
  home.file.".config/autostart/sxhkd.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=sxhkd
    Exec=${pkgs.sxhkd}/bin/sxhkd
    Hidden=false
    X-GNOME-Autostart-enabled=true
  '';
}
