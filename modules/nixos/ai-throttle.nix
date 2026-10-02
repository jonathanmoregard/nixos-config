# ai-throttle + host-telemetry — keep background AI quiet and measurable.
#
# The embedding backfill, speech-to-text and any honeypot run all share one
# iGPU and one memory bus, and the iGPU has no scheduling priority a cgroup can
# set. Left alone the backfill keeps the fans up for days and makes dictation
# latency depend on whatever else happens to be running.
#
# Two user units:
#   - `ai-throttle.service` (scripts/ai-throttle.py) pauses the background
#     units (SIGSTOP) while the CPU is hot, the laptop is on battery, or
#     speech-to-text was used in the last minute, and resumes them (SIGCONT)
#     afterwards. Pausing never kills, so the embed worker resumes mid-row and
#     no row is condemned as poison the way a kill would condemn it. Not the
#     cgroup freezer: systemd refuses to stop a frozen unit, which would break
#     offline-ai's eviction and Home Manager restarts; a SIGSTOPped unit still
#     stops cleanly, because systemd follows SIGTERM with SIGCONT.
#   - `host-telemetry.service` (scripts/host-telemetry.py) writes one JSON line
#     a minute to ~/.local/state/host-telemetry/: temperatures, package power,
#     iGPU busy, AC, memory, the top units by CPU and by iGPU time, and the
#     throttle's state. That is the record the thresholds below are judged by.
#
# The thresholds are inputs, not measured truths: 70/60 C is where this
# laptop's fans were audible on 2026-10-02, and the telemetry is how to move
# them.
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
      description = "Background user units to pause (SIGSTOP) while the machine should be quiet.";
    };
    foreground = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "local-stt.service" "local-stt-general.service" "local-stt-swedish.service" ];
      description = "Interactive user units whose recent CPU use pauses the background units.";
    };
    pauseAtC = lib.mkOption {
      type = lib.types.int;
      default = 70;
      description = "Pause at or above this CPU package temperature (Tctl).";
    };
    resumeBelowC = lib.mkOption {
      type = lib.types.int;
      default = 60;
      description = "Once paused for heat, resume only below this temperature.";
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
      description = "Pause background AI units while hot, on battery, or dictating";
      wantedBy = [ "default.target" ];
      path = [ pkgs.systemd ];
      environment = {
        AI_THROTTLE_UNITS = units;
        AI_THROTTLE_FOREGROUND = lib.concatStringsSep " " cfg.foreground;
        AI_THROTTLE_PAUSE_AT_C = toString cfg.pauseAtC;
        AI_THROTTLE_RESUME_BELOW_C = toString cfg.resumeBelowC;
        AI_THROTTLE_FOREGROUND_HOLD_S = toString cfg.foregroundHoldSec;
        AI_THROTTLE_REQUIRE_AC = if cfg.requireAC then "1" else "0";
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
