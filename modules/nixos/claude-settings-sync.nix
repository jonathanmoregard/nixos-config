# Overwrites ~/.claude/settings.json with the claude-config copy on each
# deploy tick. The repository wins; a live-only edit does not survive. See
# nixos-config#402 for why, and what it costs.
#
# settings.json is the one projected entry that is not a symlink into the
# deploy clone, because Claude Code REPLACES this file on `/model` — a link
# would be swapped back for a regular file on the first write.
#
# Triggered by claude-runtime-deploy.service succeeding, not by a path unit on
# the file: git unlinks and recreates, so a watch fires on a file that is
# momentarily absent or half-written.
#
# Delivers configuration, does not enforce it: the live file stays writable by
# the account the agents run as, by necessity.
{ config, lib, pkgs, ... }:
let
  user = "jonathan";
  group = "users";
  home = "/home/${user}";

  served = "/var/lib/claude-runtime/checkout/runtime/settings.json";
  live = "${home}/.claude/settings.json";
  marker = "${home}/.claude/.projection-enabled";

  failuresDir = "/var/lib/unit-failures";
  record = "${failuresDir}/claude-settings-sync.json";

  # The suite runs against the installed file, so the store path the unit
  # executes is the one that passed it, and a red suite fails the host build.
  project = pkgs.runCommand "claude-settings-project" {
    nativeBuildInputs = [ pkgs.python3 pkgs.jq ];
  } ''
    install -Dm755 ${../../scripts/claude-settings-project.py} $out/bin/claude-settings-project
    substituteInPlace $out/bin/claude-settings-project \
      --replace-fail '#!/usr/bin/env python3' '#!${pkgs.python3}/bin/python3'
    PYTHONDONTWRITEBYTECODE=1 CLAUDE_SETTINGS_PROJECT_SRC=$out/bin/claude-settings-project \
      python3 -W error::ResourceWarning ${../../tests/claude-settings-sync/test_project.py} -v
  '';

  failureNotify = pkgs.writeShellApplication {
    name = "claude-settings-sync-failure-notify";
    runtimeInputs = [ pkgs.jq pkgs.coreutils ];
    text = ''
      result="''${MONITOR_SERVICE_RESULT:-unknown}"
      status="''${MONITOR_EXIT_STATUS:-unknown}"
      echo "claude-settings-sync FAILED (result=$result status=$status): merged claude-config settings are not reaching ${live}; inspect: journalctl -u claude-settings-sync.service -n 50"
      mkdir -p -- ${failuresDir}
      chmod 0755 -- ${failuresDir}
      tmp=$(mktemp ${failuresDir}/.claude-settings-sync.XXXXXX)
      jq -n \
        --arg unit claude-settings-sync.service \
        --arg result "$result" \
        --arg status "$status" \
        --arg invocation "''${MONITOR_INVOCATION_ID:-}" \
        --arg failed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg summary "Merged claude-config settings.json changes are not reaching ~/.claude/settings.json; the live file was left unchanged." \
        --arg inspect "journalctl -u claude-settings-sync.service -n 50" \
        '{unit: $unit, result: $result, exit_status: $status, invocation_id: $invocation, failed_at: $failed_at, summary: $summary, inspect: $inspect}' \
        > "$tmp"
      chmod 0644 -- "$tmp"
      mv -f -- "$tmp" ${record}
      echo "claude-settings-sync-failure-notify: recorded ${record}"
    '';
  };

  # Runs as root (the `+` below): the record directory is root's.
  clearRecord = pkgs.writeShellScript "claude-settings-sync-clear" ''
    if [ "''${SERVICE_RESULT:-}" = success ]; then
      ${pkgs.coreutils}/bin/rm -f -- ${record}
    fi
  '';
in
{
  systemd.services.claude-settings-sync = {
    description = "Project the served claude-config settings.json onto ~/.claude/settings.json";
    after = [ "claude-runtime-deploy.service" ];
    unitConfig = {
      OnFailure = "claude-settings-sync-failure-notify.service";
      # Started once per deploy tick; a start limit would turn a burst of
      # ticks into a unit that silently stops running.
      StartLimitIntervalSec = 0;
    };
    serviceConfig = {
      Type = "oneshot";
      User = user;
      Group = group;
      ExecStart = lib.escapeShellArgs [
        "${project}/bin/claude-settings-project"
        "--served" served
        "--live" live
        "--marker" marker
      ];
      ExecStopPost = "+${clearRecord}";
      Nice = 10;
      TimeoutStartSec = 60;
      NoNewPrivileges = true;
      PrivateNetwork = true;
      PrivateTmp = true;
      ProtectSystem = "full";
    };
  };

  systemd.services.claude-runtime-deploy.unitConfig.OnSuccess = [ "claude-settings-sync.service" ];

  systemd.services.claude-settings-sync-failure-notify = {
    description = "Record a failed claude-settings-sync run for the SessionStart report";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe failureNotify;
    };
  };
}
