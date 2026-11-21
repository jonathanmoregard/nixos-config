# The one owner of Claude Code's MCP server list. It writes the machine-wide
# managed policy (only these exact commands and URLs may start, whatever
# ~/.claude.json, a repo's .mcp.json or --mcp-config says) and the list the
# importer copies into ~/.claude.json. Drift and review control, not an agent
# boundary: an unsandboxed agent running as the user can still run a binary
# itself or start claude without this policy (design: Fable, 2026-11-21).
# A server that is missing must be added to claude.mcp (servers or
# extraAllowedCommands); unlisted servers are skipped silently.
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
  trusted = s: lib.any (p: lib.hasPrefix p s) trustedPrefixes && !hasDotDot s;
  hasDotDot = s: lib.elem ".." (lib.splitString "/" s);
  # A flag such as --config=/home/x carries its path after the first "=".
  afterEquals = s: lib.concatStringsSep "=" (lib.drop 1 (lib.splitString "=" s));
  badElement = e:
    (looksLikePath e && !trusted e)
    || hasDotDot e
    || (lib.hasInfix "=" e && (let v = afterEquals e; in (looksLikePath v && !trusted v) || hasDotDot v));

  stdio = lib.filterAttrs (_: s: s.type == "stdio") cfg.servers;
  remote = lib.filterAttrs (_: s: s.type != "stdio") cfg.servers;
  argvOf = s: [ s.command ] ++ s.args;

  policy = {
    allowManagedMcpServersOnly = true;
    allowedMcpServers =
      lib.mapAttrsToList (_: s: { serverCommand = argvOf s; }) stdio
      ++ map (c: { serverCommand = c; }) cfg.extraAllowedCommands
      ++ lib.mapAttrsToList (_: u: { serverCommand = u.argv; }) cfg.unreviewedAllowedCommands
      ++ lib.mapAttrsToList (_: s: { serverUrl = s.url; }) remote
      ++ map (u: { serverUrl = u; }) cfg.connectorUrls;
  };

  entry = s:
    if s.type == "stdio" then
      { type = "stdio"; inherit (s) command args env; } // lib.optionalAttrs (s.timeout != null) { inherit (s) timeout; }
    else
      { inherit (s) type url; };

  badElements = lib.concatLists (lib.mapAttrsToList
    (name: s: map (e: "${name}: ${e}") (lib.filter badElement (argvOf s)))
    stdio
    ++ map (c: map (e: "extraAllowedCommands: ${e}") (lib.filter badElement c))
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
    # The visible escape hatch from the trusted-prefix rule; every entry must carry an issue.
    unreviewedAllowedCommands = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          argv = lib.mkOption { type = lib.types.listOf lib.types.str; };
          reason = lib.mkOption { type = lib.types.str; };
          issue = lib.mkOption { type = lib.types.str; };
        };
      });
      default = { };
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
    claude.mcp.serversJSON = builtins.toJSON (lib.mapAttrs (_: entry) cfg.servers);

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
    ] ++ lib.mapAttrsToList (name: u: {
      assertion = lib.trim u.reason != ""
        && builtins.match "https://github\\.com/[^/]+/[^/]+/issues/[0-9]+" u.issue != null
        && u.argv != [ ]
        && !(lib.any (lib.hasInfix "\${") u.argv);
      message = "claude.mcp.unreviewedAllowedCommands.${name}: needs a non-empty argv without \${, a reason, and a https://github.com/<owner>/<repo>/issues/<n> issue";
    }) cfg.unreviewedAllowedCommands;

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
