{ pkgs, ... }:
{
  home.packages = with pkgs; [
    google-chrome
    discord
    gimp
    calibre
    libreoffice
    qbittorrent
    keepassxc
    zoom-us
    zenity
    dropbox
  ];

  # Autostart KeePassXC
  home.file.".config/autostart/keepassxc.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=KeePassXC
    Exec=${pkgs.keepassxc}/bin/keepassxc
    Hidden=false
    NoDisplay=false
    X-GNOME-Autostart-enabled=true
  '';

  # Autostart Dropbox
  home.file.".config/autostart/dropbox.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Dropbox
    Exec=${pkgs.dropbox}/bin/dropbox
    Hidden=false
    NoDisplay=false
    X-GNOME-Autostart-enabled=true
  '';
}
