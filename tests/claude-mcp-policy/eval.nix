# Pure evaluation of modules/nixos/claude-mcp-policy.nix: the generated policy
# parses, names no server by serverName, allows every registered server's exact
# argv, and the module refuses a command outside the prefixes the agent cannot write.
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
      pkg = { command = "/nix/store/00000000000000000000000000000000-x/bin/x"; args = [ "--flag" "value" ]; literalArgs = [ "--flag" "value" ]; env.A = "1"; };
      web = { type = "http"; url = "https://example.invalid/mcp"; };
    };
    extraAllowedCommands = [ [ "/run/current-system/sw/bin/python3" "/var/lib/claude-runtime/checkout/runtime/scripts/agent-e2e/mcp-stub-dispatch.py" ] ];
    connectorUrls = [ "https://mcp.example.invalid" ];
  }).config;
  policy = builtins.fromJSON good.claude.mcp.policyJSON;
  servers = builtins.fromJSON good.claude.mcp.serversJSON;
  commands = map (e: e.serverCommand) (lib.filter (e: e ? serverCommand) policy.allowedMcpServers);
  urls = map (e: e.serverUrl) (lib.filter (e: e ? serverUrl) policy.allowedMcpServers);

  rejectsWith = fragment: mcp: lib.any (a: lib.hasInfix fragment a.message) (failing (eval ({ enable = true; } // mcp)).config);
  rejectsCommand = rejectsWith "every command must be";
  rejectsArg = rejectsWith "every argument must be";
  rejectsUrl = rejectsWith "every URL must be";
  py = "/run/current-system/sw/bin/python3";
  x = "/nix/store/0-x/bin/x";
  withArgs = command: args: { servers.x = { inherit command args; }; };

  checks = {
    noAssertionFails = failing good == [ ];
    onlyManagedAllowlist = policy.allowManagedMcpServersOnly == true;
    noServerName = lib.all (e: lib.attrNames e == [ "serverCommand" ] || lib.attrNames e == [ "serverUrl" ]) policy.allowedMcpServers;
    everyStdioArgvAllowed = lib.all (s: lib.elem ([ s.command ] ++ s.args) commands)
      (lib.filter (s: s.type == "stdio") (lib.attrValues servers));
    dispatcherAllowedNotRegistered = lib.elem [ py "/var/lib/claude-runtime/checkout/runtime/scripts/agent-e2e/mcp-stub-dispatch.py" ] commands
      && lib.length (lib.attrNames servers) == 3;
    urlsAllowed = lib.elem "https://example.invalid/mcp" urls && lib.elem "https://mcp.example.invalid" urls;
    envKeptInServerList = servers.pkg.env == { A = "1"; } && !(lib.hasInfix "\"env\"" good.claude.mcp.policyJSON);
    literalArgsNotInServerList = !(servers.pkg ? literalArgs);
    etcFilesWorldReadable = lib.all (f: good.environment.etc.${f}.mode == "0644")
      [ "claude-code/managed-settings.d/50-mcp.json" "claude-code/mcp-servers.json" ];
    rejectsBareCommand = rejectsCommand { servers.x.command = "ha-mcp"; };
    rejectsDotDotCommand = rejectsCommand { servers.x.command = "/nix/store/../home/jonathan/x"; };
    rejectsUntrustedExtra = rejectsCommand { extraAllowedCommands = [ [ "/tmp/x" ] ]; };
    rejectsHomePath = rejectsArg (withArgs py [ "/home/jonathan/.claude/mcps/x.py" ]);
    rejectsTildePath = rejectsArg (withArgs x [ "~/x" ]);
    rejectsEqualsPath = rejectsArg (withArgs x [ "--config=/home/jonathan/x" ]);
    rejectsTrustedEqualsPath = rejectsArg (withArgs x [ "--config=/nix/store/0-c/config.json" ]);
    rejectsDotDotArg = rejectsArg (withArgs py [ "/nix/store/../home/jonathan/x.py" ]);
    rejectsDotDotAfterEquals = rejectsArg (withArgs x [ "--config=../x" ]);
    rejectsRelativeScriptPath = rejectsArg (withArgs py [ "mcps/x/server.py" ]);
    rejectsBareScriptName = rejectsArg (withArgs py [ "x.py" ]);
    rejectsBareScriptAfterEquals = rejectsArg (withArgs x [ "--script=x.sh" ]);
    rejectsAttachedFlagPath = rejectsArg (withArgs py [ "-I/home/jonathan/x" ]);
    rejectsDotDotValue = rejectsArg (withArgs x [ "--dir=.." ]);
    rejectsModuleFlag = rejectsArg (withArgs py [ "-m" "pkg" ]);
    rejectsBareServer = rejectsArg (withArgs x [ "server" ]);
    rejectsBareConfigFile = rejectsArg (withArgs x [ "config.json" ]);
    rejectsConfigEqualsToml = rejectsArg (withArgs x [ "--config=c.toml" ]);
    rejectsUntrustedExtraArg = rejectsArg { extraAllowedCommands = [ [ py "-m" ] ]; };
    allowsListedLiteralArgs = !(rejectsArg { servers.x = { command = py; args = [ "-m" "pkg" ]; literalArgs = [ "-m" "pkg" ]; }; });
    rejectsPartlyListedLiteralArgs = rejectsArg { servers.x = { command = py; args = [ "-m" "pkg" ]; literalArgs = [ "-m" ]; }; };
    literalArgsArePerEntry = rejectsArg { servers.x = { command = py; args = [ "-m" ]; }; servers.y = { command = py; literalArgs = [ "-m" ]; }; };
    allowsTrustedPathArgs = !(rejectsArg (withArgs x [ "/nix/store/0-c/config.json" "/var/lib/claude-runtime/checkout/runtime/x" ]));
    rejectsVarExpansion = rejectsWith "no \${VAR}" { servers.x = { command = x; args = [ "\${HOME}" ]; literalArgs = [ "\${HOME}" ]; }; };
    rejectsPlainHttp = rejectsUrl { servers.x = { type = "http"; url = "http://example.invalid"; }; };
    rejectsPlainHttpConnector = rejectsUrl { connectorUrls = [ "http://x" ]; };
    rejectsWildcardConnector = rejectsUrl { connectorUrls = [ "https://*" ]; };
    rejectsWildcardServerUrl = rejectsUrl { servers.x = { type = "http"; url = "https://*.example.com/mcp"; }; };
  };
  failed = lib.attrNames (lib.filterAttrs (_: v: !v) checks);
in
if failed == [ ] then "ok: ${toString (lib.length (lib.attrNames checks))} checks"
else throw "claude-mcp-policy eval checks failed: ${toString failed}"
