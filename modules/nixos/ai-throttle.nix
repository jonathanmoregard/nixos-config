# host-telemetry — keep background AI measurable, and name the foreground hint.
#
# `host-telemetry.service` (scripts/host-telemetry.py) writes one JSON line a
# minute to ~/.local/state/host-telemetry/: temperatures, package power, iGPU
# busy, AC, memory, and the top units by CPU and by iGPU time. That record is
# what "the fans were loud" is matched against.
#
# There used to be an `ai-throttle.service` here that SIGSTOPped the embedding
# backfill to hold a package temperature. The backfill is gone; the one
# remaining background job, aggregator-ingest, is bounded by its own cgroup
# limits (CPUQuota, idle CPU and IO classes, see aggregator-ingest-timer.nix),
# which hold for the whole run and never pause a process mid-write. A
# governor with nothing to govern was removed rather than re-pointed.
#
# The module keeps `services.aiThrottle.foregroundHint`: the file the
# local-stt router touches when a recording starts (see local-stt.nix).
{ config, lib, pkgs, ... }:
{
  options.services.aiThrottle.foregroundHint = lib.mkOption {
    type = lib.types.str;
    default = "%t/ai-throttle/foreground-hint";
    description = ''
      File the local-stt router touches when a recording starts and when a
      transcription begins. systemd specifiers apply (%t is the runtime dir).
    '';
  };

  config.systemd.user.services.host-telemetry = {
    description = "Log temperatures, power and per-unit CPU/iGPU use once a minute";
    wantedBy = [ "default.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.python3}/bin/python3 ${../../scripts/host-telemetry.py}";
      Restart = "always";
      RestartSec = 30;
      Nice = 10;
    };
  };
}
