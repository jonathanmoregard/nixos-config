# services.securityBatch.<name> — scheduled, sandboxed security scans whose
# verdict reaches Claude sessions.
#
# ── Adding a runner (one file per runner, imported from the host/profile) ──
#
#   # modules/nixos/security-batch/<name>.nix   (+ <name>.accepted.txt beside it)
#   { config, pkgs, ... }: {
#     imports = [ ../security-batch.nix ];
#     services.securityBatch.<name> = {
#       schedule = "Sun 03:00";            # OnCalendar
#       timeout = "2h";                    # required: a wedged fetch must not hold the unit forever
#       acceptedFindings = ./<name>.accepted.txt;
#       credentials.gh-token = config.age.secrets.foo.path;   # optional → $CREDENTIALS_DIRECTORY/gh-token
#       script = pkgs.writeShellApplication {
#         name = "security-batch-<name>";
#         runtimeInputs = [ pkgs.jq pkgs.some-scanner ];
#         text = ''
#           some-scanner --json > "$RUN_DIR/scan.json"            # results of THIS run
#           # diff against "$PREVIOUS_DIR" (empty on the first run = seed),
#           # minus the IDs listed in "$ACCEPTED_FINDINGS"
#           echo "new=0 errors=0" > "$RUN_DIR/summary.txt"         # counts + IDs only
#           exit 0   # 0 = clean, 1 = new findings, 3 = a tool failed (run all steps first)
#         '';
#       };
#     };
#   }
#
# Contract for the script: cwd = $RUN_DIR (fresh runs/<utc>-<rand>/); $PREVIOUS_DIR =
# the last run that exited 0 (the baseline; "" on the first run); $CACHE_DIRECTORY
# for tool databases. Exit 75 is reserved (offline skip). summary.txt is the only
# text that leaves the run dir: [A-Za-z0-9 =:;,.@_>-] survive, 200 chars max.
#
# ── What the module guarantees ──
#
# Units: security-batch-<name>.service + .timer (Persistent, 1h jitter, AC power
# only), OnFailure → security-batch-notify@<name>.service, a root oneshot that
# writes /var/lib/unit-failures/security-batch-<name>.json — the record
# ~/.claude/hooks/unit-failure-health.py shows at every SessionStart (2026-08-31
# constraint: failures must reach Claude) — plus a critical desktop toast. Only a
# run that exits 0 deletes the record; an offline skip leaves it in place.
#
# Verdict = exit status. A failing run never becomes `previous`, so a finding
# keeps failing every week until it is fixed or listed in accepted.txt — it does
# not age into the baseline.
#
# State: /var/lib/security-batch/<name>/{runs/,latest,previous,last-skip},
# owned by a per-runner static system user secbatch-<name> with group `users`,
# 0750, so jonathan (and Claude) read results. Not DynamicUser: systemd keeps
# DynamicUser state under /var/lib/private (0700 root), unreadable to anyone
# else. Runs older than 90 days are pruned (never latest/previous); files over
# 64 MiB in a run are truncated.
#
# System units, not user timers: a user timer runs as jonathan with his whole
# home and credentials in reach of a scanner parsing untrusted feeds; a system
# unit gets its own uid, LoadCredential and the sandbox below.
#
# Sandbox: no capabilities, read-only system, no /home, no devices. The scanners
# that need more say so in their own serviceConfig with a comment.
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption types;
  runners = config.services.securityBatch;

  stateRoot = "/var/lib/security-batch";
  failuresDir = "/var/lib/unit-failures";
  userOf = name: "secbatch-${name}";
  recordOf = name: "${failuresDir}/security-batch-${name}.json";

  # Exit code reserved for "offline, nothing ran"; listed in SuccessExitStatus
  # so it is not a failure, and distinguished from 0 so it clears nothing.
  skipCode = 75;

  networkOnline = import ../../home/network-online-script.nix { inherit pkgs; };

  # ExecStart: gate, run dir, the runner, then rotate links and prune.
  wrapper = name: r: pkgs.writeShellApplication {
    name = "security-batch-${name}-run";
    runtimeInputs = [ pkgs.coreutils pkgs.findutils networkOnline ];
    text = ''
      state=${stateRoot}/${name}
      if ! network-online; then
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) offline" > "$state/last-skip"
        echo "security-batch ${name}: SKIP offline; previous verdict and failure record left as they were"
        exit ${toString skipCode}
      fi

      mkdir -p "$state/runs"
      run=$(mktemp -d "$state/runs/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
      chmod 0750 "$run"
      prev=""
      [ -d "$state/previous" ] && prev=$(readlink -f "$state/previous")
      echo "security-batch ${name}: run $run, previous ''${prev:-<none: seeding>}"

      rc=0
      ( cd "$run" && RUN_DIR="$run" PREVIOUS_DIR="$prev" \
          ACCEPTED_FINDINGS=${r.acceptedFindings} exec ${lib.getExe r.script} ) || rc=$?
      [ "$rc" -ne ${toString skipCode} ] || rc=3   # 75 is the module's, not the runner's
      echo "$rc" > "$run/exit-status"

      # Cap what a run keeps on disk.
      find "$run" -type f -size +64M -print -exec truncate -s 64M {} + \
        | sed 's/^/security-batch ${name}: truncated to 64 MiB: /'

      link() { ln -sfn "runs/$(basename "$run")" "$state/.$1" && mv -T "$state/.$1" "$state/$1"; }
      link latest
      [ "$rc" -ne 0 ] || link previous

      # Retention: 90 days, never the dirs the links point at.
      keep_latest=$(readlink -f "$state/latest")
      keep_prev=$(readlink -f "$state/previous" || true)
      find "$state/runs" -mindepth 1 -maxdepth 1 -type d -mtime +90 -print0 \
        | while IFS= read -r -d "" d; do
            [ "$d" = "$keep_latest" ] || [ "$d" = "$keep_prev" ] || rm -r -- "$d"
          done

      echo "security-batch ${name}: exit $rc"
      exit "$rc"
    '';
  };

  # OnFailure target, one template for every runner. Root (the record dir is
  # root-owned and trusted as such by the hook), but the runner-written summary
  # is read with the runner's own uid so a planted symlink cannot make root
  # disclose a file, and only a fixed character set survives.
  notify = pkgs.writeShellApplication {
    name = "security-batch-notify";
    runtimeInputs = [ pkgs.coreutils pkgs.jq pkgs.util-linux ];
    text = ''
      name="$1"
      [[ "$name" =~ ^[a-z][a-z0-9-]{0,22}$ ]] || { echo "bad runner name" >&2; exit 1; }
      unit="security-batch-$name.service"
      result="''${MONITOR_SERVICE_RESULT:-unknown}"
      status="''${MONITOR_EXIT_STATUS:-unknown}"
      echo "$unit FAILED (result=$result status=$status)"

      if [ "$result" = exit-code ]; then
        found=$(runuser -u "secbatch-$name" -- head -c 2000 "${stateRoot}/$name/latest/summary.txt" 2>/dev/null \
          | tr '\n' ' ' | tr -cd 'A-Za-z0-9 =:;,.@_>-' | head -c 200 || true)
        what="exit $status: ''${found:-no summary.txt}"
      else
        what="run did not finish ($result), no verdict"
      fi
      # The hook shows 300 chars of summary and 120 of inspect.
      summary="security-batch $name: $what; accept in security-batch/$name.accepted.txt"

      mkdir -p -- ${failuresDir}
      chmod 0755 -- ${failuresDir}
      tmp=$(mktemp ${failuresDir}/.security-batch-"$name".XXXXXX)
      jq -n --arg unit "$unit" --arg result "$result" --arg status "$status" \
        --arg invocation "''${MONITOR_INVOCATION_ID:-}" \
        --arg failed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg summary "$summary" \
        --arg inspect "ls ${stateRoot}/$name/latest/; journalctl -u $unit -n 200" \
        '{unit: $unit, result: $result, exit_status: $status, invocation_id: $invocation, failed_at: $failed_at, summary: $summary, inspect: $inspect}' \
        > "$tmp"
      chmod 0644 -- "$tmp"
      mv -f -- "$tmp" "${failuresDir}/security-batch-$name.json"
      echo "security-batch-notify: recorded ${failuresDir}/security-batch-$name.json"
    '';
  };

  runnerOpts = { name, ... }: {
    options = {
      schedule = mkOption {
        type = types.str;
        example = "Sun 03:00";
        description = "systemd OnCalendar expression.";
      };
      timeout = mkOption {
        type = types.str;
        example = "2h";
        description = "TimeoutStartSec. Required: a oneshot's default is infinity.";
      };
      script = mkOption {
        type = types.package;
        description = "Runner executable (lib.getExe), e.g. writeShellApplication.";
      };
      acceptedFindings = mkOption {
        type = types.path;
        default = pkgs.writeText "security-batch-${name}-accepted.txt" "";
        description = "Passed as $ACCEPTED_FINDINGS; the runner subtracts it.";
      };
      credentials = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = "LoadCredential= name → host path; read $CREDENTIALS_DIRECTORY/<name>.";
      };
      serviceConfig = mkOption {
        type = types.attrsOf types.anything;
        default = { };
        description = "Merged over the module's serviceConfig (relax with a comment).";
      };
    };
  };
in
{
  options.services.securityBatch = mkOption {
    type = types.attrsOf (types.submodule runnerOpts);
    default = { };
    description = "Scheduled security batch runners; see the header of this file.";
  };

  config = lib.mkIf (runners != { }) {
    assertions = lib.mapAttrsToList (name: _: {
      assertion = builtins.match "[a-z][a-z0-9-]{0,22}" name != null;
      message = "services.securityBatch.${name}: name must match [a-z][a-z0-9-]{0,22} (system user secbatch-<name> ≤ 32 chars).";
    }) runners;

    users.users = lib.mapAttrs' (name: _: lib.nameValuePair (userOf name) {
      isSystemUser = true;
      group = "users";
      description = "security-batch runner ${name}";
    }) runners;

    systemd.services = {
      "security-batch-notify@" = {
        description = "Record a failed security batch run (%i) for Claude sessions";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${lib.getExe notify} %i";
        };
      };
    } // lib.mapAttrs' (name: r: lib.nameValuePair "security-batch-${name}" {
      description = "Security batch runner ${name}";
      unitConfig = {
        OnFailure = "security-batch-notify@${name}.service";
        ConditionACPower = true;
      };
      # A deploy must not kill a sweep halfway.
      restartIfChanged = false;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe (wrapper name r);
        # Root, only to delete the record after a clean run (exit 0; a skip is 75).
        ExecStopPost = "+${pkgs.writeShellScript "security-batch-${name}-clear" ''
          if [ "$SERVICE_RESULT" = success ] && [ "$EXIT_STATUS" = 0 ]; then
            ${pkgs.coreutils}/bin/rm -f -- ${recordOf name}
          fi
        ''}";
        SuccessExitStatus = [ skipCode ];
        TimeoutStartSec = r.timeout;
        User = userOf name;
        Group = "users";
        UMask = "0027";
        StateDirectory = "security-batch/${name}";
        StateDirectoryMode = "0750";
        CacheDirectory = "security-batch/${name}";
        CacheDirectoryMode = "0700";
        LoadCredential = lib.mapAttrsToList (k: v: "${k}:${v}") r.credentials;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        CapabilityBoundingSet = "";
        MemoryMax = "4G";
        TasksMax = 512;
        Nice = 19;
        IOSchedulingClass = "idle";
        CPUSchedulingPolicy = "idle";
      } // r.serviceConfig;
    }) runners;

    systemd.timers = lib.mapAttrs' (name: r: lib.nameValuePair "security-batch-${name}" {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = r.schedule;
        Persistent = true;
        RandomizedDelaySec = "1h";
      };
    }) runners;

    # Toast beside the record (the nix-gc pattern: root writes the file, the
    # user manager owns the session bus).
    systemd.user.paths = lib.mapAttrs' (name: _: lib.nameValuePair "security-batch-${name}-toast" {
      wantedBy = [ "default.target" ];
      pathConfig.PathChanged = recordOf name;
    }) runners;
    systemd.user.services = lib.mapAttrs' (name: _: lib.nameValuePair "security-batch-${name}-toast" {
      description = "Desktop notification: security batch ${name} failed";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "security-batch-${name}-toast" ''
          [ -e ${recordOf name} ] || exit 0
          ${pkgs.libnotify}/bin/notify-send -u critical "security-batch ${name} FAILED" \
            "$(${pkgs.jq}/bin/jq -r .summary ${recordOf name} | ${pkgs.coreutils}/bin/head -c 300)" \
            || echo "notify-send failed; ${recordOf name} still reaches Claude"
        '';
      };
    }) runners;
  };
}
