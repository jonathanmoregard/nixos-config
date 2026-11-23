# Makes the mcpServers of ~/.claude.json exactly the list in
# /etc/claude-code/mcp-servers.json, the one the managed policy enforces — see
# scripts/claude-mcp-import.py. The list changes on rebuild, so a rebuild reruns it.
{ config, lib, pkgs, ... }:
let
  user = "jonathan";
  group = "users";
  home = "/home/${user}";

  served = "/etc/claude-code/mcp-servers.json";
  live = "${home}/.claude.json";
  marker = "${home}/.claude/.projection-enabled";

  hasList = config.environment.etc ? "claude-code/mcp-servers.json";

  failuresDir = "/var/lib/unit-failures";
  record = "${failuresDir}/claude-mcp-import.json";

  import' = pkgs.runCommand "claude-mcp-import" {
    nativeBuildInputs = [ pkgs.python3 ];
  } ''
    install -Dm755 ${../../scripts/claude-mcp-import.py} $out/bin/claude-mcp-import
    substituteInPlace $out/bin/claude-mcp-import \
      --replace-fail '#!/usr/bin/env python3' '#!${pkgs.python3}/bin/python3'
    PYTHONDONTWRITEBYTECODE=1 CLAUDE_MCP_IMPORT_SRC=$out/bin/claude-mcp-import \
      python3 -W error::ResourceWarning ${../../tests/claude-mcp-import/test_import.py} -v
  '';

  failureNotify = pkgs.writeShellApplication {
    name = "claude-mcp-import-failure-notify";
    runtimeInputs = [ pkgs.jq pkgs.coreutils ];
    text = ''
      result="''${MONITOR_SERVICE_RESULT:-unknown}"
      status="''${MONITOR_EXIT_STATUS:-unknown}"
      echo "claude-mcp-import FAILED (result=$result status=$status): the managed MCP server list is not reaching ${live}; inspect: journalctl -u claude-mcp-import.service -n 50"
      mkdir -p -- ${failuresDir}
      chmod 0755 -- ${failuresDir}
      tmp=$(mktemp ${failuresDir}/.claude-mcp-import.XXXXXX)
      trap 'rm -f -- "$tmp"' EXIT
      jq -n \
        --arg unit claude-mcp-import.service \
        --arg result "$result" \
        --arg status "$status" \
        --arg invocation "''${MONITOR_INVOCATION_ID:-}" \
        --arg failed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg summary "Managed mcp-servers.json changes are not reaching ~/.claude.json; the live MCP server list is stale." \
        --arg inspect "journalctl -u claude-mcp-import.service -n 50" \
        '{unit: $unit, result: $result, exit_status: $status, invocation_id: $invocation, failed_at: $failed_at, summary: $summary, inspect: $inspect}' \
        > "$tmp"
      chmod 0644 -- "$tmp"
      mv -f -- "$tmp" ${record}
      echo "claude-mcp-import-failure-notify: recorded ${record}"
    '';
  };

  clearRecord = pkgs.writeShellScript "claude-mcp-import-clear" ''
    if [ "''${SERVICE_RESULT:-}" = success ]; then
      ${pkgs.coreutils}/bin/rm -f -- ${record}
    fi
  '';
in
{
  systemd.services.claude-mcp-import = {
    description = "Mirror the managed mcp-servers.json into ~/.claude.json";
    after = [ "claude-runtime-deploy.service" ];
    wantedBy = lib.optional hasList "multi-user.target";
    restartTriggers = lib.optional hasList config.environment.etc."claude-code/mcp-servers.json".source;
    unitConfig = {
      OnFailure = "claude-mcp-import-failure-notify.service";
      StartLimitIntervalSec = 0;
    };
    serviceConfig = {
      Type = "oneshot";
      User = user;
      Group = group;
      ExecStart = lib.escapeShellArgs [
        "${import'}/bin/claude-mcp-import"
        "--served" served
        "--live" live
        "--marker" marker
      ];
      ExecStopPost = "+${clearRecord}";
      Nice = 10;
      TimeoutStartSec = 90;
      NoNewPrivileges = true;
      PrivateNetwork = true;
      PrivateTmp = true;
      ProtectSystem = "full";
    };
  };

  systemd.services.claude-runtime-deploy.unitConfig.OnSuccess = [ "claude-mcp-import.service" ];

  systemd.services.claude-mcp-import-failure-notify = {
    description = "Record a failed claude-mcp-import run for the SessionStart report";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe failureNotify;
    };
  };
}
