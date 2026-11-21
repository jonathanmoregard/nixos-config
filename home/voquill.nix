{ pkgs, ... }:
# Voquill voice-typing: package, menu entry and systemd user service.
{
  # Voquill voice-typing app, built by its own flake (`pkgs.voquill`, wired up
  # in flake.nix). What changed is not that LD_LIBRARY_PATH went away — the
  # package's own wrapper still prefixes one, for the libs it dlopens — but
  # that every entry on it now comes from voquill's OWN closure instead of
  # this flake's nixpkgs. That is the whole fix: one nixpkgs per process, so
  # this flake's pin moving can no longer strand the binary, and the closure
  # is GC-rooted so nothing it needs can be swept.
  #
  # The package keeps the `com.voquill.desktop.local` identifier, so it reads
  # the existing data directory at ~/.config/com.voquill.desktop.local.
  #
  # Known, upstream: that wrapper exports LD_LIBRARY_PATH to CHILDREN too, so
  # anything voquill spawns (xdg-open -> browser, pactl, gdbus) sees voquill's
  # libs ahead of its own RUNPATH. Belongs in voquill's derivation, not here.
  home.packages = [ pkgs.voquill ];

  # Start-menu entry for Voquill. Placed at ~/.local/share/applications by
  # home-manager so Cinnamon's menu picks it up without imperative edits.
  xdg.desktopEntries.voquill = {
    name = "Voquill";
    comment = "AI voice dictation";
    exec = "${pkgs.voquill}/bin/voquill";
    icon = "voquill";
    terminal = false;
    type = "Application";
    categories = [ "Utility" "AudioVideo" ];
  };

  systemd.user.services.voquill = {
    Unit = {
      Description = "Voquill voice-typing";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      Type = "simple";
      ExecStart = "${pkgs.voquill}/bin/voquill --voquill-autostart-hidden";
      Restart = "on-failure";
      RestartSec = 5;
      # Dictation is interactive: five shares to a default sibling's one
      # under CPU contention (the STT units themselves carry ten, see
      # modules/nixos/local-stt.nix).
      CPUWeight = 500;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
