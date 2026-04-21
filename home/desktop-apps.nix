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
    thunderbird
    android-studio  # RAM-hungry — fine on real hardware, avoid running in 4GB VM
    # NOTE: OBS Studio is installed via apt on Mint but is intentionally NOT
    # tracked here. Do not add obs-studio — user decision (drift-scan 2026-04-17).
  ];

}
