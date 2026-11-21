# The one owner of Claude Code's MCP server list. It writes the machine-wide
# managed policy (only these exact commands and URLs may start, whatever
# ~/.claude.json, a repo's .mcp.json or --mcp-config says) and the list the
# importer copies into ~/.claude.json. Drift and review control, not an agent
# boundary: an unsandboxed agent running as the user can still run a binary
# itself or start claude without this policy (design: Fable, 2026-11-21).
{ config, lib, ... }:
let
  cfg = config.claude.mcp;

  # Root-owned prefixes only: every argv element of an allowed command must
  # resolve under one of these, so the policy names code a PR reviewed.
  trustedPrefixes = [
    "/nix/store/"
    "/run/current-system/sw/bin/"
    "/var/lib/claude-runtime/checkout/"
  ];
  looksLikePath = s: lib.hasPrefix "/" s || lib.hasPrefix "~" s || lib.hasPrefix "." s;
  trusted = s: lib.any (p: lib.hasPrefix p s) trustedPrefixes;

  stdio = lib.filterAttrs (_: s: s.type == "stdio") cfg.servers;
  remote = lib.filterAttrs (_: s: s.type != "stdio") cfg.servers;
  argvOf = s: [ s.command ] ++ s.args;

  policy = {
    allowManagedMcpServersOnly = true;
    allowedMcpServers =
      lib.mapAttrsToList (_: s: { serverCommand = argvOf s; }) stdio
      ++ map (c: { serverCommand = c; }) cfg.extraAllowedCommands
      ++ lib.mapAttrsToList (_: s: { serverUrl = s.url; }) remote
      ++ map (u: { serverUrl = u; }) cfg.connectorUrls;
  };

  entry = s:
    if s.type == "stdio" then
      { type = "stdio"; inherit (s) command args env; } // lib.optionalAttrs (s.timeout != null) { inherit (s) timeout; }
    else
      { inherit (s) type url; };

  badElements = lib.concatLists (lib.mapAttrsToList
    (name: s: map (e: "${name}: ${e}") (lib.filter (e: looksLikePath e && !trusted e) (argvOf s)))
    stdio
    ++ map (c: map (e: "extraAllowedCommands: ${e}") (lib.filter (e: looksLikePath e && !trusted e) c))
      cfg.extraAllowedCommands);
  untrustedCommands = lib.concatLists (lib.mapAttrsToList
    (name: s: lib.optional (!trusted s.command) "${name}: ${s.command}") stdio
    ++ map (c: lib.optional (c == [ ] || !trusted (builtins.head c)) "extraAllowedCommands: ${toString c}")
      cfg.extraAllowedCommands);

  serverType = lib.types.submodule {
    options = {
      type = lib.mkOption { type = lib.types.enum [ "stdio" "http" "sse" ]; default = "stdio"; };
      command = lib.mkOption { type = lib.types.str; default = ""; };
      args = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
      # Copied into ~/.claude.json only; the policy does not compare env and
      # the files under /etc are world-readable, so never put a secret here.
      env = lib.mkOption { type = lib.types.attrsOf lib.types.str; default = { }; };
      timeout = lib.mkOption { type = lib.types.nullOr lib.types.int; default = null; };
      url = lib.mkOption { type = lib.types.str; default = ""; };
    };
  };
in
{
  options.claude.mcp = {
    enable = lib.mkEnableOption "the managed Claude Code MCP server list";
    servers = lib.mkOption {
      type = lib.types.attrsOf serverType;
      default = { };
    };
    extraAllowedCommands = lib.mkOption {
      type = lib.types.listOf (lib.types.listOf lib.types.str);
      default = [ ];
      description = "Commands allowed but not registered in ~/.claude.json, e.g. the agent-e2e stub dispatcher.";
    };
    connectorUrls = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "claude.ai connector URLs, allowed by exact serverUrl.";
    };
    policyJSON = lib.mkOption { type = lib.types.str; readOnly = true; internal = true; };
    serversJSON = lib.mkOption { type = lib.types.str; readOnly = true; internal = true; };
  };

  config = lib.mkIf cfg.enable {
    claude.mcp.policyJSON = builtins.toJSON policy;
    claude.mcp.serversJSON = builtins.toJSON { mcpServers = lib.mapAttrs (_: entry) cfg.servers; };

    assertions = [
      {
        assertion = untrustedCommands == [ ] && badElements == [ ];
        message = "claude.mcp: every command and path argument must be absolute under ${toString trustedPrefixes}; offending: ${toString (untrustedCommands ++ badElements)}";
      }
      {
        assertion = lib.all (s: s.url != "" && lib.hasPrefix "https://" s.url) (lib.attrValues remote);
        message = "claude.mcp: remote servers need an https:// url";
      }
      {
        assertion = lib.all (s: !(lib.hasInfix "\${" (toString (argvOf s)))) (lib.attrValues stdio);
        message = "claude.mcp: no \${VAR} in commands; the policy matches literal argv";
      }
    ];

    environment.etc."claude-code/managed-settings.d/50-mcp.json" = {
      text = cfg.policyJSON;
      mode = "0644";
    };
    environment.etc."claude-code/mcp-servers.json" = {
      text = cfg.serversJSON;
      mode = "0644";
    };
  };
}
