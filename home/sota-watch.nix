{ pkgs, ... }:
# SOTA-watch daily runner — durable schedule replacing the 7-day Claude
# cron stopgap.
#
# The runner script lives in ~/Repos/sota-watch/runner/run-watch.sh, a
# separate userspace repo iterated on outside this flake. It is NOT
# cloned by the HM activation (deliberate — the SOTA-watch repo carries
# its own state layout and bootstrapping), so on any host without the
# checkout the wrapper here must stay green: log a "skipping" line and
# exit 0. That keeps the systemd unit from going red on VMs, fresh
# installs, or dellan before a manual `git clone` of the sota-watch
# repo.
#
# The unit is `Type = "oneshot"`; timer fires daily at 07:37 local with
# a 10-minute randomised jitter and `Persistent = true` so missed runs
# (suspend, offline) catch up on the next wake.
let
  runnerScript = pkgs.writeShellScript "sota-watch-run" ''
    set -euo pipefail

    LOG_DIR="$HOME/.local/share/sota-watch"
    mkdir -p "$LOG_DIR"
    RUNLOG="$LOG_DIR/run.log"
    RUNNER="$HOME/Repos/sota-watch/runner/run-watch.sh"

    if [ ! -x "$RUNNER" ]; then
      echo "$(date -Iseconds): runner not found at $RUNNER, skipping" >> "$RUNLOG"
      exit 0
    fi

    exec "$RUNNER" >> "$RUNLOG" 2>&1
  '';
in
{
  systemd.user.services.sota-watch = {
    Unit.Description = "SOTA-watch daily runner";
    Service = {
      Type = "oneshot";
      ExecStart = "${runnerScript}";
    };
  };

  systemd.user.timers.sota-watch = {
    Unit.Description = "SOTA-watch daily runner — 07:37 local";
    Timer = {
      OnCalendar = "*-*-* 07:37:00";
      Persistent = true;
      RandomizedDelaySec = "10m";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
