{ pkgs, ... }:
# User services ported from ~/.config/systemd/user/ + migrated from autostart.
# - Router services: originals under ~/.local/share/router-agent (uv-managed venv).
# - Voquill: migrated from ~/.config/autostart/ to a proper systemd user service.
{
  systemd.user.services.router-ingestor = {
    Unit = {
      Description = "Router personal-assistant ingestor (inlet -> inbox)";
      After = [ "default.target" ];
    };
    Service = {
      Type = "simple";
      WorkingDirectory = "/home/jonathan/.local/share/router-agent";
      Environment = "PATH=/home/jonathan/.local/bin:/usr/local/bin:/usr/bin:/bin";
      ExecStart = "/home/jonathan/.local/bin/uv run router-ingestor --paths /home/jonathan/.config/router/paths.yaml watch";
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install.WantedBy = [ "default.target" ];
  };

  systemd.user.services.router-worker = {
    Unit = {
      Description = "Router worker (inbox -> HITL queue)";
      After = [ "router-ingestor.service" ];
    };
    Service = {
      Type = "simple";
      WorkingDirectory = "/home/jonathan/.local/share/router-agent";
      Environment = "PATH=/home/jonathan/.local/bin:/usr/local/bin:/usr/bin:/bin";
      ExecStart = "/home/jonathan/.local/bin/uv run router-worker --paths /home/jonathan/.config/router/paths.yaml watch";
      Restart = "on-failure";
      RestartSec = 10;
    };
    Install.WantedBy = [ "default.target" ];
  };

  systemd.user.services.router-ingestor-scan = {
    Unit.Description = "Router ingestor hourly safety-net scan (scan-once)";
    Service = {
      Type = "oneshot";
      WorkingDirectory = "/home/jonathan/.local/share/router-agent";
      Environment = "PATH=/home/jonathan/.local/bin:/usr/local/bin:/usr/bin:/bin";
      ExecStart = "/bin/sh -c '/home/jonathan/.local/bin/uv run router-ingestor --paths /home/jonathan/.config/router/paths.yaml scan-once >> /home/jonathan/.local/state/router/audit/ingestor-cron.log 2>&1'";
    };
  };

  systemd.user.timers.router-ingestor-scan = {
    Unit.Description = "Hourly trigger for router-ingestor-scan.service";
    Timer = {
      OnBootSec = "5min";
      OnUnitActiveSec = "1h";
      Persistent = true;
      Unit = "router-ingestor-scan.service";
    };
    Install.WantedBy = [ "timers.target" ];
  };

  # Voquill voice-typing app. Live binary at
  # ~/Repos/voquill/apps/desktop/src-tauri/target/debug/Voquill (debug build).
  # The prior autostart .desktop entry pointed at a stale Voice-typing/ path;
  # this service uses the current path.
  systemd.user.services.voquill = {
    Unit = {
      Description = "Voquill voice-typing";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      Type = "simple";
      ExecStart = "/home/jonathan/Repos/voquill/apps/desktop/src-tauri/target/debug/Voquill --voquill-autostart-hidden";
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
