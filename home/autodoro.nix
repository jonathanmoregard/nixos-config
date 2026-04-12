{ pkgs, ... }:
{
  systemd.user.services.autodoro = {
    Unit = {
      Description = "Autodoro pomodoro timer";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      ExecStart = "%h/Repos/autodoro/autodoro.sh";
      Restart = "on-failure";
      Environment = [
        "DISPLAY=:0"
        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
      ];
    };
    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
  };
}
