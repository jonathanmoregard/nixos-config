{ pkgs, ... }:
{
  home.packages = [ pkgs.kitty ];

  home.file.".config/kitty/kitty.conf".text = ''
    # Scrolling — momentum-style kinetic scroll on Linux/X11 touchpad.
    # Reason for switching from Ghostty: Ghostty 1.3.1 doesn't fire kinetic
    # scroll for GDK_SOURCE_TOUCHPAD on X11 (GTK4 limitation, tracked at
    # ghostty#11460). Kitty 0.46+ shipped first-class momentum_scroll.
    momentum_scroll yes
    pixel_scroll yes

    # Remote control — JSON-over-Unix-socket for scripts / future MCP server
    # exposing pane management (`kitty @ ls`, launch, send-text, focus, ...).
    allow_remote_control yes
    listen_on unix:/tmp/kitty.sock

    # Splits layout enables hsplit/vsplit launch locations
    enabled_layouts splits,stack

    # Keybinds — mirror Ghostty config (home/ghostty.nix). These override
    # kitty defaults like ctrl+minus = decrease_font_size.
    map ctrl+minus launch --location=hsplit --cwd=current
    map ctrl+w close_window
    map ctrl+up neighboring_window up
    map ctrl+down neighboring_window down
  '';
}
