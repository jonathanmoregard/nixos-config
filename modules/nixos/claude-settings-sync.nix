# modules/nixos/claude-settings-sync.nix
#
# Delivers the claude-config settings.json into ~/.claude/settings.json.
#
# Every other projected entry under ~/.claude is a symlink into the deploy
# clone, so a merged PR reaches it on the next deploy tick. settings.json
# cannot be one: Claude Code writes it at runtime (`/model`, rules saved from
# a permission prompt, `/config`), and through a symlink into the read-only
# projection those writes fail with EROFS. Worse, Claude Code REPLACES the
# file rather than writing through it, so a link would be swapped back for a
# regular file on the first write — silently restoring the problem this unit
# exists to fix. So it stays a real file, and this unit projects the
# repository's copy onto it.
#
# The repository wins (scripts/claude-settings-project.py): after a run the
# live file IS the served file, byte for byte, and a live-only edit does not
# survive. That is the point. Every live-only entry measured on tuxedo on
# 2026-11-03 was drift nobody wanted — a PreToolUse group dcg's own
# `self_heal_hook` wrote into the file pinned to a /nix/store path that stops
# resolving after the next dcg upgrade and GC, an allow rule a merged PR had
# deliberately removed, and a `model` value `/model` wrote over the
# checked-in one. There is no merge base and nothing to reconcile.
#
# The cost is the other side of the same coin: a `/model` or `/config` change
# made in a session is reverted at the next tick. Values meant to persist
# belong in the repository, which is where this unit reads them from.
#
# Triggered by claude-runtime-deploy.service succeeding rather than by a watch
# on the file: git replaces a file by unlinking and recreating it, so a path
# unit can fire on a file that is momentarily absent or half-written. After
# the deploy tick, the checkout is settled.
#
# Runs as jonathan from a root-owned unit with a store-pinned script: no path
# jonathan can write is in its exec chain, and it can write nothing jonathan
# could not. This delivers configuration; it does not enforce it. The live
# file stays writable by the user the agents run as, by necessity.
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
