# Scheduled Nix garbage collection, and keeping recently built store
# paths alive across it.
#
# Daily GC reclaims old profile generations and unreachable store paths
# before they can fill the root filesystem again; Nix's min-free/max-free
# guard (modules/common.nix) also reacts during build spikes.
#
# `nix-collect-garbage --delete-older-than 14d` only ages out *profile
# generations*; every store path no root reaches is deleted on the next
# run, however fresh. Dev shells entered with `nix develop --command …`
# and crane `cargoArtifacts` built by `nix build` / `nix flake check` are
# never rooted, so the daily timer evicted them every night and the next
# agent session rebuilt or re-fetched them cold (RSI proposal
# 2026-09-19-nix-auto-gc-evicts-build-cache-mid-session; journal on
# tuxedo 2026-10-01/02: ~3.6k paths per run, incl. the rustc/rustfmt
# wrappers klaffat's dev shell uses).
#
# Upstream has no age gate for unrooted paths yet (NixOS/nix#7572, PR
# #14725). Until it does, the nix-gc unit roots every path registered in
# the last `days` days for the duration of the run only:
#
#   preStart  — symlink each recent path into gcroots/keep-recent
#   script    — the stock nix-collect-garbage, unchanged
#   postStop  — remove the roots again (runs on success AND failure)
#
# The roots exist only while nix-gc.service runs, so the in-build
# min-free/max-free emergency collector and manual `nix-collect-garbage`
# still see that garbage as reclaimable: disk pressure wins over cache.
# A failure while pinning fails the unit before collection starts, so
# the cache is never deleted unprotected.
#
# ── Failure reporting ──
#
# Fail-closed pinning has a cost: if `nix path-info` output ever breaks
# (a Nix bump changing the JSON), nix-gc fails every night and no
# scheduled GC runs at all. That must not be silent, and a desktop toast
# alone is not enough — it reaches Jonathan, never the Claude session
# that could fix it (2026-08-31 constraint). So:
#
#   OnFailure=nix-gc-failure-notify.service (system, root) logs a journal
#     marker and writes /var/lib/unit-failures/nix-gc.json, the durable
#     world-readable record that ~/.claude's SessionStart hook
#     (hooks/unit-failure-health.py) puts into every session's context.
#   A user path unit watches that record and raises a critical toast —
#     the nixos-deploy pattern (system writes a file, the user manager
#     owns the session bus).
#   postStop deletes the record after a successful run, so it always
#     means "the last run failed", never "a run once failed".
#
# Known limit: age is registration time, not last use. A closure that
# stays unchanged and unrooted for longer than `days` is still collected
# once per `days`+1 nights (weekly instead of nightly at the default).
# Closures that must never go cold want a real root (`nix develop
# --profile`, nix-direnv).
{ config, lib, pkgs, ... }:
let
  cfg = config.services.nixGcKeepRecent;
  rootsDir = "/nix/var/nix/gcroots/keep-recent";

  # One JSON record per failed system unit, <unit>.json. Read by
  # ~/.claude/hooks/unit-failure-health.py at SessionStart; another
  # system unit opts in by writing the same shape here.
  failuresDir = "/var/lib/unit-failures";
  record = "${failuresDir}/nix-gc.json";

  # Activated only via OnFailure (no wantedBy). Journal first, then the
  # record, written atomically so the hook never reads half a file.
  failureNotify = pkgs.writeShellApplication {
    name = "nix-gc-failure-notify";
    runtimeInputs = [ pkgs.jq pkgs.coreutils ];
    text = ''
      result="''${MONITOR_SERVICE_RESULT:-unknown}"
      status="''${MONITOR_EXIT_STATUS:-unknown}"
      echo "nix-gc FAILED (result=$result status=$status): scheduled GC did not run; inspect: journalctl -u nix-gc.service -n 100"

      mkdir -p -- ${failuresDir}
      chmod 0755 -- ${failuresDir}
      tmp=$(mktemp ${failuresDir}/.nix-gc.XXXXXX)
      jq -n \
        --arg unit nix-gc.service \
        --arg result "$result" \
        --arg status "$status" \
        --arg invocation "''${MONITOR_INVOCATION_ID:-}" \
        --arg failed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg summary "Scheduled Nix garbage collection failed; no scheduled GC runs until this is fixed (the keep-recent pin step fails closed)." \
        --arg inspect "journalctl -u nix-gc.service -n 100" \
        '{unit: $unit, result: $result, exit_status: $status, invocation_id: $invocation, failed_at: $failed_at, summary: $summary, inspect: $inspect}' \
        > "$tmp"
      chmod 0644 -- "$tmp"
      mv -f -- "$tmp" ${record}
      echo "nix-gc-failure-notify: recorded ${record}"
    '';
  };

  # Runs on success and failure alike; only a successful run clears the
  # failure record.
  postStop = pkgs.writeShellScript "nix-gc-post-stop" ''
    ${pkgs.coreutils}/bin/rm -rf -- ${rootsDir}
    if [ "''${SERVICE_RESULT:-}" = success ]; then
      ${pkgs.coreutils}/bin/rm -f -- ${record}
    fi
  '';

  pinRecent = pkgs.writeShellApplication {
    name = "nix-gc-pin-recent";
    runtimeInputs = [ config.nix.package pkgs.jq pkgs.coreutils pkgs.findutils ];
    text = ''
      days=${toString cfg.days}
      cutoff=$(( $(date +%s) - days * 86400 ))

      rm -rf -- ${rootsDir}
      mkdir -p -- ${rootsDir}

      # registrationTime is when the path became valid in this store
      # (built or substituted). `nix path-info --all` is the supported
      # read of it; no direct db.sqlite access.
      nix --extra-experimental-features nix-command \
        path-info --all --json --json-format 1 \
        | jq -r --argjson cutoff "$cutoff" \
            'to_entries[] | select(.value.registrationTime >= $cutoff) | .key' \
        | xargs -r ln -s -t ${rootsDir} --

      pinned=$(find ${rootsDir} -mindepth 1 -maxdepth 1 | wc -l)
      echo "nix-gc-pin-recent: rooted $pinned paths registered in the last $days days"
    '';
  };
in
{
  options.services.nixGcKeepRecent.days = lib.mkOption {
    type = lib.types.ints.positive;
    default = 7;
    description = ''
      Store paths registered within this many days survive the scheduled
      nix-gc run even when nothing roots them. Emergency (min-free) and
      manual collections are unaffected.
    '';
  };

  config = {
    nix.gc = {
      automatic = true;
      dates = [ "daily" ];
      options = "--delete-older-than 14d";
    };

    # Power loss mid-run skips postStop; drop leftover roots at boot so
    # they never outlive the run that made them by more than one boot.
    systemd.tmpfiles.rules = [ "R ${rootsDir}" ];

    systemd.services.nix-gc = {
      preStart = "${lib.getExe pinRecent}";
      postStop = "${postStop}";
      unitConfig.OnFailure = "nix-gc-failure-notify.service";
    };

    systemd.services.nix-gc-failure-notify = {
      description = "Record and announce a failed scheduled Nix GC";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe failureNotify;
      };
    };

    # Toast: PathChanged fires on close-after-write or rename into place,
    # once per recorded failure.
    systemd.user.paths.nix-gc-failure-toast = {
      wantedBy = [ "default.target" ];
      pathConfig.PathChanged = record;
    };
    systemd.user.services.nix-gc-failure-toast = {
      description = "Desktop notification: scheduled Nix GC failed";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "nix-gc-failure-toast" ''
          [ -e ${record} ] || exit 0
          ${pkgs.libnotify}/bin/notify-send -u critical "nix-gc FAILED" \
            "Scheduled Nix GC failed; no scheduled GC runs until fixed. Inspect: journalctl -u nix-gc.service -n 100" \
            || echo "notify-send failed (no session bus?); ${record} still reaches Claude"
        '';
      };
    };
  };
}
