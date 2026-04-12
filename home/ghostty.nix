{ pkgs, ... }:
{
  home.packages = [ pkgs.ghostty ];

  home.file.".config/ghostty/config".text = ''
    # Split panes
    keybind = ctrl+minus=new_split:down
    keybind = ctrl+w=close_surface
    keybind = ctrl+up=goto_split:top
    keybind = ctrl+down=goto_split:bottom
  '';
}
