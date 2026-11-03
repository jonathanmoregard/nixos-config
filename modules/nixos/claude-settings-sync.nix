# modules/nixos/claude-settings-sync.nix
#
# Delivers the claude-config settings.json into ~/.claude/settings.json.
#
# Every other projected entry under ~/.claude is a symlink into the deploy
# clone, so a merged PR reaches it on the next deploy tick. settings.json
# cannot be one: Claude Code writes it at runtime (`/model`, rules saved from
# a permission prompt, `/config`), and through a symlink into the read-only
# projection those writes fail with EROFS. So it stays a real file that
# jonathan — and therefore the harness — can write, and this unit merges the
# repository's copy into it.
#
# The merge is three-way (scripts/claude-settings-merge.py): a value only the
# repository changed arrives, a value only the live file changed is kept, and
# list entries either side added are kept. That last part is why this is not a
# copy. The live file carries entries nothing in the repository knows about —
# today a PreToolUse group that dcg wrote into it — and a copy, or jq's `*`
# (which replaces arrays), deletes them without a word. The script refuses any
# merge that would drop such an entry and leaves the file alone.
#
# The merge base — the served copy as of the last successful run — lives in
# ~/.local/state/claude-settings-sync/base.json. Without it the script refuses
# to merge a live file that differs from the served one, because nothing can
# then tell "added live" from "removed upstream".
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
  base = "${home}/.local/state/claude-settings-sync/base.json";

  failuresDir = "/var/lib/unit-failures";
  record = "${failuresDir}/claude-settings-sync.json";

  # The suite runs against the installed file, so the store path the unit
  # executes is the one that passed it, and a red suite fails the host build.
  merge = pkgs.runCommand "claude-settings-merge" {
    nativeBuildInputs = [ pkgs.python3 pkgs.jq ];
  } ''
    install -Dm755 ${../../scripts/claude-settings-merge.py} $out/bin/claude-settings-merge
    substituteInPlace $out/bin/claude-settings-merge \
      --replace-fail '#!/usr/bin/env python3' '#!${pkgs.python3}/bin/python3'
    PYTHONDONTWRITEBYTECODE=1 CLAUDE_SETTINGS_MERGE_SRC=$out/bin/claude-settings-merge \
      python3 -W error::ResourceWarning ${../../tests/claude-settings-sync/test_merge.py} -v
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
    description = "Merge the served claude-config settings.json into ~/.claude/settings.json";
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
        "${merge}/bin/claude-settings-merge"
        "--served" served
        "--live" live
        "--base" base
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
