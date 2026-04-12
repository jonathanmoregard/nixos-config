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

}
