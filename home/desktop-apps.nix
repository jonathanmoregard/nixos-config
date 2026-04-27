{ pkgs, ... }:
# Intentionally NOT using Flatpak (drift-scan 2026-04-19).
# Discord + Android Studio are pulled from nixpkgs instead — do not enable
# services.flatpak or add flatpak runtimes.
{
  home.packages = with pkgs; [
    google-chrome
    beeper
    discord        # nixpkgs, NOT flatpak
    gimp
    calibre
    libreoffice
    qbittorrent
    keepassxc
    zoom-us
    zenity
    dropbox
    thunderbird
    android-studio # nixpkgs, NOT flatpak — RAM-hungry, avoid in 4GB VM
    wineWowPackages.stable  # 32+64-bit Wine for Windows app compatibility
    winetricks
    # cursor: package name in nixpkgs is `code-cursor`. Re-add as
    #   code-cursor # rarely used but kept (drift-scan 2026-04-19)
    # if Cursor IDE actually wanted on this host.
    # NOTE: OBS Studio is installed via apt on Mint but is intentionally NOT
    # tracked here. Do not add obs-studio — user decision (drift-scan 2026-04-17).
  ];

}
