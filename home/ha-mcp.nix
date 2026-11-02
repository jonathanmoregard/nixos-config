{ pkgs, ... }:
# ha-mcp wrapper: Home Assistant MCP server for Claude Code.
#
# Claude Code spawns `ha-mcp` as a stdio MCP subprocess (registered in
# ~/.claude.json). It configures the Home Assistant instance on
# home-server (smarthome repo) over its tailnet-only HTTPS URL:
# automations, helpers, scenes, backups.
#
# Upstream: github.com/homeassistant-ai/ha-mcp (PyPI `ha-mcp`, MIT).
# Not in nixpkgs, so it runs through uvx, pinned two ways:
#   - the package itself to an exact version;
#   - every transitive dependency by `--exclude-newer`, so a dependency
#     released after the pin date can never be resolved in.
# That is determinism, not integrity: there are no artifact hashes, so
# it trusts PyPI over TLS, and a yank can still shift the resolved set.
# Bump both together, after reading the upstream changelog.
#
# Credential: a long-lived access token of a dedicated HA admin user
# (`claude`), so it can be revoked in HA without touching anyone's
# login. HA only lets admins edit automations and helpers.
#
# Rollback: ha-mcp backs up each automation/helper/scene before it
# writes it (on by default); those per-edit backups live under
# HAMCP_BACKUP_DIR and restore without an HA restart. Full HA snapshot
# backups go through its `ha_manage_backup` tool; deleting one is off
# by default and an agent cannot switch that on.
let
  version = "8.6.0";
  excludeNewer = "2026-10-01T00:00:00Z";
  tokenFile = "/run/agenix/home-assistant-mcp-token";
in
{
  home.packages = [
    (pkgs.writeShellApplication {
      name = "ha-mcp";
      runtimeInputs = [ pkgs.uv ];
      text = ''
        if [[ ! -r ${tokenFile} || ! -s ${tokenFile} ]]; then
          echo "ha-mcp: ${tokenFile} is missing or empty; create the agenix secret home-assistant-mcp-token" >&2
          exit 1
        fi
        HOMEASSISTANT_TOKEN=$(< ${tokenFile})
        export HOMEASSISTANT_TOKEN
        export HOMEASSISTANT_URL=https://home-server.tailbebb40.ts.net
        state="''${XDG_STATE_HOME:-$HOME/.local/state}/ha-mcp"
        export HA_MCP_CONFIG_DIR="$state" HAMCP_BACKUP_DIR="$state/backups"
        # Pinned off here because an env var outranks ha-mcp's own
        # override files, which any process of this user could write.
        export ENABLE_BETA_FEATURES=false ENABLE_CODE_MODE=false \
          HAMCP_ENABLE_FILESYSTEM_TOOLS=false ENABLE_SNAPSHOT_DELETE=false
        # Stdio mode otherwise spawns a localhost settings web server
        # that outlives the session. Tools are configured here instead.
        export HA_MCP_DISABLE_SETTINGS_UI=1
        # The version is pinned above; no PyPI polling.
        export HA_MCP_DISABLE_UPDATE_CHECK=1 FASTMCP_CHECK_FOR_UPDATES=off
        # HA is upgraded through the smarthome repo, never from HA itself.
        export DISABLED_TOOLS=ha_manage_updates
        # Use the Nix interpreter; never let uv download a CPython.
        export UV_PYTHON_DOWNLOADS=never
        exec uvx --python ${pkgs.python313}/bin/python3.13 \
          --exclude-newer ${excludeNewer} \
          ha-mcp==${version} "$@"
      '';
    })
  ];
}
