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
    mpv # CLI + GUI media player; default for MP3 output from tts-tool
    gnome-text-editor # GTK4 — used for scroll-behavior comparison vs Mint (drift-debug 2026-04-28)
    android-studio # nixpkgs, NOT flatpak — RAM-hungry, avoid in 4GB VM
    tor-browser
    # cursor: package name in nixpkgs is `code-cursor`. Re-add as
    #   code-cursor # rarely used but kept (drift-scan 2026-04-19)
    # if Cursor IDE actually wanted on this host.
    # NOTE: OBS Studio is installed via apt on Mint but is intentionally NOT
    # tracked here. Do not add obs-studio — user decision (drift-scan 2026-04-17).
  ];

}
