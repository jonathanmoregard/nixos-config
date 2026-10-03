# ai-throttle + host-telemetry — keep background AI quiet and measurable.
#
# The embedding backfill, speech-to-text and any honeypot run all share one
# iGPU and one memory bus, and the iGPU has no scheduling priority a cgroup can
# set. Left alone the backfill keeps the fans up for days and makes dictation
# latency depend on whatever else happens to be running.
#
# Two user units:
#   - `ai-throttle.service` (scripts/ai-throttle.py) governs the background
#     units' duty cycle: every period it freezes them (SIGSTOP) for part of the
#     time and lets them run for the rest, and every control step it moves the
#     run fraction so the CPU package holds one setpoint temperature —
#     `quietAtC` while someone is at the desk, `idleQuietAtC` once the desk has
#     been idle. The setpoints are the inputs; the duty is the outcome, logged
#     and carried into the telemetry. It pauses the units outright while the
#     package is very hot (the band above the governor), on battery, or while
#     speech-to-text was used in the last minute. Pausing never kills, so the
#     embed worker resumes mid-row and no row is condemned as poison the way a
#     kill would condemn it. Not the cgroup freezer: systemd refuses to stop a
#     frozen unit, which would break offline-ai's eviction and Home Manager
#     restarts; a SIGSTOPped unit still stops cleanly, because systemd follows
#     SIGTERM with SIGCONT.
#   - `host-telemetry.service` (scripts/host-telemetry.py) writes one JSON line
#     a minute to ~/.local/state/host-telemetry/: temperatures, package power,
#     iGPU busy, AC, memory, the top units by CPU and by iGPU time, and the
#     throttle's state. That is the record the setpoints below are judged by.
#
# Why a governor and not the earlier 70/60 C band: the backfill's heat answers
# in seconds, so on 2026-10-03 Tctl swung 80 -> <60 -> 80 inside one tick, the
# band paused 234 times in three hours, the backfill ran 23-44 % of the time
# and the fans surged with every swing. 70 C is still where this laptop's fans
# were audible on 2026-10-02; it is now the setpoint the duty is found for.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.aiThrottle;
  units = lib.concatStringsSep " " cfg.units;
in
{
  options.services.aiThrottle = {
    units = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "aggregator-embed.service" "aggregator-embed-server.service" ];
      description = "Background user units whose duty cycle is governed (SIGSTOP/SIGCONT).";
    };
    foreground = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "local-stt.service" "local-stt-general.service" "local-stt-swedish.service" ];
      description = "Interactive user units whose recent CPU use pauses the background units outright.";
    };
    quietAtC = lib.mkOption {
      type = lib.types.int;
      default = 70;
      description = "CPU package temperature (Tctl) the governor holds while someone is at the desk.";
    };
    idleQuietAtC = lib.mkOption {
      type = lib.types.int;
      default = 78;
      description = "Setpoint once the desk has been idle for idleAfterSec (nobody hears the fans).";
    };
    idleAfterSec = lib.mkOption {
      type = lib.types.int;
      default = 900;
      description = "Seconds without input (xprintidle), on mains, before the idle setpoint applies.";
    };
    periodSec = lib.mkOption {
      type = lib.types.float;
      default = 2.0;
      description = "Length of one pause-then-run period.";
    };
    controlSec = lib.mkOption {
      type = lib.types.int;
      default = 30;
      description = "Seconds between governor steps; the step uses the mean Tctl since the last one.";
    };
    gain = lib.mkOption {
      type = lib.types.float;
      default = 0.02;
      description = "Duty change per degree of error per governor step.";
    };
    dutyMin = lib.mkOption {
      type = lib.types.float;
      default = 0.1;
      description = "Lowest duty the governor goes to; below that only the outright pauses stop the units.";
    };
    pauseAtC = lib.mkOption {
      type = lib.types.int;
      default = 90;
      description = "Pause outright at or above this Tctl: the safety net above the governor.";
    };
    resumeBelowC = lib.mkOption {
      type = lib.types.int;
      default = 80;
      description = "Once paused outright for heat, hand back to the governor only below this temperature.";
    };
    foregroundHoldSec = lib.mkOption {
      type = lib.types.int;
      default = 60;
      description = "Stay paused this long after the last foreground activity.";
    };
    requireAC = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Pause while running on battery.";
    };
  };

  config = {
    systemd.user.services.ai-throttle = {
      description = "Govern background AI units' duty cycle to a quiet temperature";
      wantedBy = [ "default.target" ];
      path = [ pkgs.systemd pkgs.xprintidle ];
      environment = {
        AI_THROTTLE_UNITS = units;
        AI_THROTTLE_FOREGROUND = lib.concatStringsSep " " cfg.foreground;
        AI_THROTTLE_QUIET_AT_C = toString cfg.quietAtC;
        AI_THROTTLE_IDLE_QUIET_AT_C = toString cfg.idleQuietAtC;
        AI_THROTTLE_IDLE_AFTER_S = toString cfg.idleAfterSec;
        AI_THROTTLE_PERIOD_S = toString cfg.periodSec;
        AI_THROTTLE_CONTROL_S = toString cfg.controlSec;
        AI_THROTTLE_GAIN = toString cfg.gain;
        AI_THROTTLE_DUTY_MIN = toString cfg.dutyMin;
        AI_THROTTLE_PAUSE_AT_C = toString cfg.pauseAtC;
        AI_THROTTLE_RESUME_BELOW_C = toString cfg.resumeBelowC;
        AI_THROTTLE_FOREGROUND_HOLD_S = toString cfg.foregroundHoldSec;
        AI_THROTTLE_REQUIRE_AC = if cfg.requireAC then "1" else "0";
        # xprintidle asks the X server; without a display it fails and the
        # script treats the desk as occupied (the quiet setpoint).
        DISPLAY = ":0";
      };
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 ${../../scripts/ai-throttle.py}";
        # The script resumes the units on SIGTERM; this covers a crash, so a
        # dead throttle can never leave the backfill paused.
        ExecStopPost = "-${pkgs.systemd}/bin/systemctl --user kill --signal=SIGCONT ${units}";
        Restart = "always";
        RestartSec = 10;
        Nice = 10;
      };
    };

    systemd.user.services.host-telemetry = {
      description = "Log temperatures, power and per-unit CPU/iGPU use once a minute";
      wantedBy = [ "default.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 ${../../scripts/host-telemetry.py}";
        Restart = "always";
        RestartSec = 30;
        Nice = 10;
      };
    };
  };
}
