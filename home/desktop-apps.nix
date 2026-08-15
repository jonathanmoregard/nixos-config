{ pkgs, ... }:
# Intentionally NOT using Flatpak (drift-scan 2026-04-19).
# Discord + Android Studio are pulled from nixpkgs instead — do not enable
# services.flatpak or add flatpak runtimes.
{
  home.packages = with pkgs; [
    google-chrome
    signal-desktop
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
    obsidian # markdown vault editor for ~/Dropbox/1. Exocortex
    mpv # CLI + GUI media player; default for MP3 output from tts-tool
    vlc # GUI video player; mpv playback unreliable on long MP4 recordings
    cheese # GNOME webcam viewer/capture (see Dellan IPU6 camera notes)
    gnome-text-editor # GTK4 — used for scroll-behavior comparison vs Mint (drift-debug 2026-04-28)
    android-studio # nixpkgs, NOT flatpak — RAM-hungry, avoid in 4GB VM
    tor-browser
    gnupg          # gpg CLI; gpg-agent is enabled via programs.gnupg.agent in modules/nixos/desktop.nix
    seahorse       # GTK key manager (PGP + SSH); discoverable via Cinnamon menu as "Passwords and Keys"
    # claude-desktop installed via modules/nixos/desktop.nix (environment.systemPackages).
    # HISTORY: the ~230 MiB Electron closure tripped home-manager-jonathan.service's
    # default 5min start timeout inside the 4 GiB / 2-core CI VM, so we moved it out
    # of home.packages (PR #171). That 5min ceiling has since been raised to 20min in
    # modules/common.nix + drift-asserted in tests/base.nix (PR #175 companion commit),
    # so system-level installation is no longer FORCED by the timeout. Closure-size
    # discipline is still preferred; prefer environment.systemPackages only when the
    # package genuinely benefits from system scope (this one does — it's a GUI app
    # shared across any future user on this host), not just to shave HM activation.
    # cursor: package name in nixpkgs is `code-cursor`. Re-add as
    #   code-cursor # rarely used but kept (drift-scan 2026-04-19)
    # if Cursor IDE actually wanted on this host.
    # NOTE: OBS Studio is installed via apt on Mint but is intentionally NOT
    # tracked here. Do not add obs-studio — user decision (drift-scan 2026-04-17).
  ];

}
