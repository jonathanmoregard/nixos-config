# GitHub App key broker: the App's private key is readable by the
# `github-app` system user only, and every use of it happens in a process
# running as that user.
#
# Agents run as jonathan. They get what the key is FOR — installation tokens
# and the GitHub MCP server — over two unix sockets that only jonathan may
# connect to, and never the key itself, an App JWT, or a way to mint off
# this host:
#
#   token.sock  one request line `<app_id> <installation_id> [<repo_id>]`;
#               answers GitHub's installation-token JSON (a whole-installation
#               token, or one scoped to that repository). The App JWT is
#               signed here and sent only to `apiUrl`.
#   mcp.sock    one header line `<app_id> <installation_id> <args...>`, then
#               the MCP stdio stream: github-mcp-server runs here in App mode,
#               refreshing its own tokens for the whole session. Only the
#               tool-policy flags cross (which tools, read-only, lockdown);
#               anything that could point the server elsewhere or make it
#               write files is refused.
#
# The ids come from the client (jonathan's ~/.config/github-app/config), so
# the broker checks them against GitHub before signing for them: the
# installation must belong to one of `allowedOwners`. A wrong app id fails at
# GitHub (the JWT does not verify), and a repository id outside the
# installation is refused by GitHub, so neither widens what jonathan reaches.
# Request handling lives in ./programs.nix (harness: tests/github-app-broker.nix).
#
# Invariants: no secret ever appears on a command line (/proc/*/cmdline is
# world-readable); nothing derived from the key or a token is logged.
#
# ── Where the key lives ───────────────────────────────────────────────
#
# secrets/github-app-key.age, encrypted straight to the host's SSH host key
# (recipients in secrets/secrets.nix) and declared with `file`, not
# `rekeyFile` — the klaffat-infra pattern, for the reason its header gives:
# agenix-rekey sources are encrypted to jonathan's user key, i.e. to the
# principal agents run as, so a rekey-managed copy of this key would be one
# `age -d` away from every agent. Until that file exists the module refuses
# to evaluate (the assertion names the owner step); the broker and the
# token cache switch over together, so there is no window in which agents
# lose their tokens.
#
# Token files under ~/.cache/gh-tokens are written by jonathan's
# gh-token.service (home/claude-services.nix) through token.sock.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.githubAppBroker;
  sockets = import ./sockets.nix;
  repoCiphertext = ../../../secrets/github-app-key.age;
  enabled = cfg.keyCiphertext != null;

  programs = import ./programs.nix {
    inherit pkgs;
    inherit (cfg) apiUrl allowedOwners;
  };
  keyPath = config.age.secrets.github-app-key.path;

  # Per-connection instances, as github-app, confined to what signing and
  # talking to GitHub need. stdin/stdout are the accepted connection.
  sessionService = { description, execStart, extra ? { } }: {
    inherit description;
    serviceConfig = {
      ExecStart = execStart;
      User = "github-app";
      Group = "github-app";
      StandardInput = "socket";
      StandardOutput = "socket";
      StandardError = "journal";
      UMask = "0077";
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectProc = "invisible";
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectClock = true;
      ProtectHostname = true;
      RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      CapabilityBoundingSet = "";
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" ];
      SystemCallErrorNumber = "EPERM";
    } // extra;
  };

  # Only github-app-clients (jonathan) and root may connect. root owns the
  # inode: an owner may chmod a socket, so a jonathan-owned one could be
  # opened to every local uid.
  brokerSocket = { description, path }: {
    inherit description;
    wantedBy = [ "sockets.target" ];
    socketConfig = {
      ListenStream = path;
      Accept = true;
      SocketUser = "root";
      SocketGroup = "github-app-clients";
      SocketMode = "0660";
    };
  };
in
{
  options.services.githubAppBroker = {
    keyCiphertext = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = if builtins.pathExists repoCiphertext then repoCiphertext else null;
      defaultText = lib.literalExpression
        "../../../secrets/github-app-key.age if it exists, else null";
      description = ''
        The App private key, age-encrypted to the host key only. Test and
        feature VMs point this at tests/lib/github-app-key-fixture.nix.
      '';
    };
    allowedOwners = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        GitHub account logins (case-insensitive) whose installations of the
        App the broker serves. An installation on any other account is
        refused before the key signs for it.
      '';
    };
    apiUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://api.github.com";
      description = "GitHub REST API base the broker calls; tests point it at a fake.";
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = enabled;
          message = ''
            github-app-broker: secrets/github-app-key.age does not exist. It holds
            the GitHub App private key, encrypted to the host key ONLY (never with
            add-secret: agenix-rekey encrypts to jonathan's user key). On tuxedo,
            from a nixos-config worktree root, with a freshly generated App key:
              nix shell nixpkgs#age -c age -R /etc/ssh/ssh_host_ed25519_key.pub \
                -o secrets/github-app-key.age < /path/to/new-app-key.pem
            then commit it on the branch; the build goes green with it.
          '';
        }
        {
          assertion = cfg.allowedOwners != [ ]
            && lib.all (o: builtins.match "[A-Za-z0-9][A-Za-z0-9-]{0,38}" o != null) cfg.allowedOwners;
          message = "services.githubAppBroker.allowedOwners must list the GitHub logins whose App installations agents may use.";
        }
      ];

      users.users.github-app = {
        isSystemUser = true;
        group = "github-app";
        description = "Holder of the GitHub App private key";
      };
      users.groups.github-app = { };
      users.groups.github-app-clients.members = [ "jonathan" ];
    }

    (lib.mkIf enabled {
      age.secrets.github-app-key = {
        file = cfg.keyCiphertext;
        owner = "github-app";
        group = "github-app";
        mode = "0400";
      };

      systemd.sockets.github-app-token = brokerSocket {
        description = "GitHub App installation-token broker";
        path = sockets.token;
      };
      systemd.services."github-app-token@" = sessionService {
        description = "Mint one GitHub App installation token";
        execStart = "${programs.mintToken}/bin/github-app-mint-token ${keyPath}";
        extra = {
          RuntimeMaxSec = 60;
          MemoryMax = "128M";
        };
      };

      systemd.sockets.github-app-mcp = brokerSocket {
        description = "GitHub MCP server, authenticated as the GitHub App";
        path = sockets.mcp;
      };
      systemd.services."github-app-mcp@" = sessionService {
        description = "GitHub MCP server session (GitHub App)";
        execStart = "${programs.mcpSession}/bin/github-app-mcp-session ${keyPath}";
      };
    })
  ];
}
