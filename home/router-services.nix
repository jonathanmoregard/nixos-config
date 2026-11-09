{ pkgs, ... }:
# User services ported from ~/.config/systemd/user/ + migrated from autostart.
# - Router services: originals under ~/.local/share/router-agent (uv-managed venv).
# - Voquill: migrated from ~/.config/autostart/ to a proper systemd user service.
{
  # Router services: ExecStart was hardcoded to /home/jonathan/.local/bin/uv,
  # which existed on the prior Mint host (pip-installed) but not on NixOS.
  # nixpkgs provides uv at ${pkgs.uv}/bin/uv (resolved at activation time).
  # ConditionPathExists guards against the project dir not being present —
  # the router-agent project (uv-managed venv at %h/.local/share/router-agent)
  # is jonathan's personal repo, not part of the flake closure, so it may be
  # absent on fresh installs or rollbacks. Without the guard, systemd
  # auto-restart floods journal with CHDIR failures.
  systemd.user.services.router-ingestor = {
    Unit = {
      Description = "Router personal-assistant ingestor (inlet -> inbox)";
      After = [ "default.target" ];
      ConditionPathExists = "%h/.local/share/router-agent";
    };
    Service = {
      Type = "simple";
      WorkingDirectory = "%h/.local/share/router-agent";
      ExecStart = "${pkgs.uv}/bin/uv run router-ingestor --paths %h/.config/router/paths.yaml watch";
      Restart = "on-failure";
      RestartSec = 5;
      # The watcher answers SIGTERM in under a second when idle (6 of 7 stops
      # on 2026-10-02), but once, stopped minutes after a restart with a
      # backlog, it sat in stop-sigterm for the full default 90 s and was
      # SIGKILLed. offline-ai stops this unit synchronously when it loads
      # the model, so that wait is the operator's. Its graceful teardown
      # joins its threads for at most 5 s each; 20 s is generous for that
      # and short for a wedge. The wedge itself belongs to router-agent.
      TimeoutStopSec = 20;
    };
    Install.WantedBy = [ "default.target" ];
  };

  systemd.user.services.router-worker = {
    Unit = {
      Description = "Router worker (inbox -> HITL queue)";
      After = [ "router-ingestor.service" ];
      ConditionPathExists = "%h/.local/share/router-agent";
    };
    Service = {
      Type = "simple";
      WorkingDirectory = "%h/.local/share/router-agent";
      ExecStart = "${pkgs.uv}/bin/uv run router-worker --paths %h/.config/router/paths.yaml watch";
      Restart = "on-failure";
      RestartSec = 10;
    };
    Install.WantedBy = [ "default.target" ];
  };

  systemd.user.services.router-ingestor-scan = {
    Unit = {
      Description = "Router ingestor hourly safety-net scan (scan-once)";
      ConditionPathExists = "%h/.local/share/router-agent";
    };
    Service = {
      Type = "oneshot";
      WorkingDirectory = "%h/.local/share/router-agent";
      ExecStart = "/bin/sh -c '${pkgs.uv}/bin/uv run router-ingestor --paths %h/.config/router/paths.yaml scan-once >> %h/.local/state/router/audit/ingestor-cron.log 2>&1'";
    };
  };

  systemd.user.timers.router-ingestor-scan = {
    Unit.Description = "Hourly trigger for router-ingestor-scan.service";
    Timer = {
      OnBootSec = "5min";
      OnUnitActiveSec = "1h";
      # No Persistent on a monotonic timer — see gh-token in
      # claude-services.nix: with a prior-boot stamp and an elapsed
      # OnBootSec it leaves the timer with no next elapse.
      Unit = "router-ingestor-scan.service";
    };
    Install.WantedBy = [ "timers.target" ];
  };

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
