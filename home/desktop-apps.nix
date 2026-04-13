{ pkgs, ... }:
{
  home.packages = with pkgs; [
    google-chrome
    beeper
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
