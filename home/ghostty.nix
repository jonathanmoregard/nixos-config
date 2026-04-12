{ pkgs, ... }:
{
  home.packages = [ pkgs.ghostty ];

  home.file.".config/ghostty/config".text = ''
    # Disable single-instance mode — requires a running D-Bus session to connect to,
    # which isn't guaranteed in XFCE; without it the app fails to launch from the menu.
    gtk-single-instance = false

    # Split panes
    keybind = ctrl+minus=new_split:down
    keybind = ctrl+w=close_surface
    keybind = ctrl+up=goto_split:top
    keybind = ctrl+down=goto_split:bottom
  '';
}
