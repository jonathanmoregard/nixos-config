# Pure evaluation of modules/nixos/claude-mcp-policy.nix: the generated policy
# parses, names no server by serverName, allows every registered server's exact
# argv, and the module refuses a command outside the root-owned prefixes.
{ lib }:
let
  stubOptions = {
    options.assertions = lib.mkOption { type = lib.types.listOf lib.types.unspecified; default = [ ]; };
    options.environment.etc = lib.mkOption { type = lib.types.attrsOf lib.types.unspecified; default = { }; };
  };
  eval = mcp: lib.evalModules {
    modules = [ ../../modules/nixos/claude-mcp-policy.nix stubOptions { claude.mcp = mcp; } ];
  };
  failing = cfg: lib.filter (a: !a.assertion) cfg.assertions;

  good = (eval {
    enable = true;
    servers = {
      broker = { command = "/run/current-system/sw/bin/python3"; args = [ "/var/lib/claude-runtime/checkout/runtime/mcps/git-broker/server.py" ]; timeout = 5; };
      pkg = { command = "/nix/store/00000000000000000000000000000000-x/bin/x"; args = [ "--flag" "value" ]; env.A = "1"; };
      web = { type = "http"; url = "https://example.invalid/mcp"; };
    };
    extraAllowedCommands = [ [ "/run/current-system/sw/bin/python3" "/var/lib/claude-runtime/checkout/runtime/scripts/agent-e2e/mcp-stub-dispatch.py" ] ];
    connectorUrls = [ "https://mcp.example.invalid" ];
  }).config;
  policy = builtins.fromJSON good.claude.mcp.policyJSON;
  servers = (builtins.fromJSON good.claude.mcp.serversJSON).mcpServers;
  commands = map (e: e.serverCommand) (lib.filter (e: e ? serverCommand) policy.allowedMcpServers);
  urls = map (e: e.serverUrl) (lib.filter (e: e ? serverUrl) policy.allowedMcpServers);

  rejects = mcp: failing (eval ({ enable = true; } // mcp)).config != [ ];

  checks = {
    noAssertionFails = failing good == [ ];
    onlyManagedAllowlist = policy.allowManagedMcpServersOnly == true;
    noServerName = lib.all (e: lib.attrNames e == [ "serverCommand" ] || lib.attrNames e == [ "serverUrl" ]) policy.allowedMcpServers;
    everyStdioArgvAllowed = lib.all (s: lib.elem ([ s.command ] ++ s.args) commands)
      (lib.filter (s: s.type == "stdio") (lib.attrValues servers));
    dispatcherAllowedNotRegistered = lib.elem [ "/run/current-system/sw/bin/python3" "/var/lib/claude-runtime/checkout/runtime/scripts/agent-e2e/mcp-stub-dispatch.py" ] commands
      && lib.length (lib.attrNames servers) == 3;
    urlsAllowed = lib.elem "https://example.invalid/mcp" urls && lib.elem "https://mcp.example.invalid" urls;
    envKeptInServerList = servers.pkg.env == { A = "1"; } && !(lib.hasInfix "\"env\"" good.claude.mcp.policyJSON);
    etcFilesWorldReadable = good.environment.etc."claude-code/managed-settings.d/50-mcp.json".mode == "0644";
    rejectsBareCommand = rejects { servers.x.command = "ha-mcp"; };
    rejectsHomePath = rejects { servers.x = { command = "/run/current-system/sw/bin/python3"; args = [ "/home/jonathan/.claude/mcps/x.py" ]; }; };
    rejectsTildePath = rejects { servers.x = { command = "/nix/store/0-x/bin/x"; args = [ "~/x" ]; }; };
    rejectsUntrustedExtra = rejects { extraAllowedCommands = [ [ "/tmp/x" ] ]; };
    rejectsVarExpansion = rejects { servers.x = { command = "/nix/store/0-x/bin/x"; args = [ "\${HOME}" ]; }; };
    rejectsPlainHttp = rejects { servers.x = { type = "http"; url = "http://example.invalid"; }; };
  };
  failed = lib.attrNames (lib.filterAttrs (_: v: !v) checks);
in
if failed == [ ] then "ok: ${toString (lib.length (lib.attrNames checks))} checks"
else throw "claude-mcp-policy eval checks failed: ${toString failed}"
