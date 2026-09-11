# One model-owning aggregator MCP server for every local Claude/Codex pane.
{ pkgs, ... }:
let
  prepareToken = pkgs.writeShellApplication {
    name = "aggregator-mcp-prepare-token";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      set -euo pipefail
      token_file="$RUNTIME_DIRECTORY/token"
      if [ -s "$token_file" ]; then
        chmod 0600 "$token_file"
        exit 0
      fi

      umask 077
      token_tmp=$(mktemp "$RUNTIME_DIRECTORY/.token.XXXXXX")
      trap 'rm -f "$token_tmp"' EXIT
      head -c 32 /dev/urandom | base64 > "$token_tmp"
      chmod 0600 "$token_tmp"
      mv -f "$token_tmp" "$token_file"
      trap - EXIT
    '';
  };
in
{
  systemd.user.tmpfiles.rules = [
    "d %h/.local/share/aggregator 0700 - - -"
  ];

  systemd.user.services.aggregator-mcp-backend = {
    Unit = {
      Description = "Shared aggregator MCP backend";
      Documentation = [ "https://github.com/jonathanmoregard/aggregator" ];
      After = [ "network.target" ];
    };

    Service = {
      Type = "simple";
      RuntimeDirectory = "aggregator-mcp";
      RuntimeDirectoryMode = "0700";
      RuntimeDirectoryPreserve = "restart";
      ExecStartPre = "${prepareToken}/bin/aggregator-mcp-prepare-token";
      ExecStart = "${pkgs.aggregator}/bin/aggregator-mcp-backend";
      Restart = "on-failure";
      RestartSec = "5s";

      # Query backend is restartable and owns no ingest/embed claim. Bound its
      # model state; unlike the embed worker, a hard kill cannot poison a row.
      MemoryAccounting = true;
      MemoryHigh = "6G";
      MemoryMax = "8G";

      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = "read-only";
      ReadWritePaths = "%h/.local/share/aggregator";
      RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" ];
      IPAddressDeny = "any";
      IPAddressAllow = "localhost";
    };

    Install.WantedBy = [ "default.target" ];
  };
}
