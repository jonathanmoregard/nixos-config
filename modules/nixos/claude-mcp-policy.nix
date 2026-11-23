# The one owner of Claude Code's MCP server list. It writes the machine-wide
# managed policy (only these exact commands and URLs may start, whatever
# ~/.claude.json, a repo's .mcp.json or --mcp-config says) and the list the
# importer copies into ~/.claude.json. Drift and review control, not an agent
# boundary: an unsandboxed agent running as the user can still run a binary
# itself or start claude without this policy (design: Fable, 2026-11-21).
# Rule: every argv element after the command is an absolute trusted-prefix path
# without "..", or appears verbatim in that entry's literalArgs. Env is not
# compared by the managed allowlist, so it is out of scope.
# Reviewers: don't report new argv forms; report only a concrete input that
# satisfies this rule and still loads untrusted code (e.g. a trusted-prefix path
# the agent can write).
# Argv equality proves the configured command, not the code it loads;
# interpreter search paths in $HOME are same-uid writable and out of scope.
# A server that is missing must be added to claude.mcp (servers or
# extraAllowedCommands); unlisted servers are skipped silently.
{ config, lib, ... }:
let
  cfg = config.claude.mcp;

  trustedPrefixes = [
    "/nix/store/"
    "/run/current-system/sw/bin/"
    "/var/lib/claude-runtime/checkout/"
  ];
  hasDotDot = s: lib.elem ".." (lib.splitString "/" s);
  trusted = s: lib.any (p: lib.hasPrefix p s) trustedPrefixes && !hasDotDot s;

  stdio = lib.filterAttrs (_: s: s.type == "stdio") cfg.servers;
  remote = lib.filterAttrs (_: s: s.type != "stdio") cfg.servers;
  storeLiterals =
    lib.filter (e: lib.hasPrefix "/nix/store/" e && !builtins.hasContext e)
      (lib.concatMap argvOf (lib.attrValues stdio) ++ lib.concatLists cfg.extraAllowedCommands);
  allUrls = map (s: s.url) (lib.attrValues remote) ++ cfg.connectorUrls;
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

  badArgs = lib.concatLists (lib.mapAttrsToList
    (name: s: map (e: "${name}: ${e}") (lib.filter (e: !(trusted e || lib.elem e s.literalArgs)) s.args))
    stdio
    ++ map (c: map (e: "extraAllowedCommands: ${e}") (lib.filter (e: !trusted e) (lib.drop 1 c)))
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
      literalArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Arguments allowed verbatim although they are not trusted-prefix paths, e.g. a flag or subcommand.";
      };
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
    claude.mcp.serversJSON = builtins.toJSON (lib.mapAttrs (_: entry) cfg.servers);

    assertions = [
      {
        assertion = untrustedCommands == [ ];
        message = "claude.mcp: every command must be absolute under ${toString trustedPrefixes}; offending: ${toString untrustedCommands}";
      }
      {
        assertion = badArgs == [ ];
        message = "claude.mcp: every argument must be an absolute path under ${toString trustedPrefixes} or listed in literalArgs; offending: ${toString badArgs}";
      }
      {
        assertion = storeLiterals == [ ];
        message = "claude.mcp: an argv element or command under /nix/store/ must come from Nix interpolation (hasContext); offending: ${toString storeLiterals}";
      }
      {
        assertion = lib.all (u: lib.hasPrefix "https://" u && !(lib.hasInfix "*" u)) allUrls;
        message = "claude.mcp: every URL must be https:// without \"*\" (serverUrl treats it as a wildcard); offending: ${toString (lib.filter (u: !(lib.hasPrefix "https://" u && !(lib.hasInfix "*" u))) allUrls)}";
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
