{ config, lib, pkgs, ... }:
# research-broker: the host-side, credential-injecting egress broker for
# the research agent.
#
# Design: research-agent docs/egress-broker.md §2.2 (process model), §2.4
# (run registration), §5 (this module). In one line: the research VM holds
# no third-party API key any more; every keyed API call (Exa, Tavily, eBay,
# Tradera, EUIPO) and every scraper call goes through this host process,
# which injects the key / scraper bearer itself and gates model-authored
# URLs against a per-run ledger.
#
#   research VM ──10.0.2.2:8124 (SLIRP = host 127.0.0.1)──▶ research-broker.socket
#   host MCP server (jonathan) ──/run/research-broker/admin.sock──▶ research-broker-admin.socket
#   research-broker.service ──▶ api.exa.ai, api.tavily.com, api.ebay.com, …
#                           ──▶ 127.0.0.1:8123 (scraper microvm hostfwd)
#
# Interface contract with the research-agent repo (broker/server.py):
#   - two inherited sockets, told apart by $LISTEN_FDNAMES: `vm` (TCP
#     127.0.0.1:8124, every route needs a per-run bearer token) and `admin`
#     (unix socket, 0600 jonathan: only the host MCP server and root can
#     register runs);
#   - keys arrive as files in $CREDENTIALS_DIRECTORY, one per agenix secret
#     below, under the secret's own name. Never env, never argv, never the
#     store: PID 1 reads /run/agenix/* as root at start;
#   - code is the live checkout (same deploy path as the MCP server and the
#     scraper: the 30-min `git pull --ff-only`), bind-mounted read-only at
#     /run/rb/{broker,scraper}. Only those two dirs; never reports/, the one
#     dir the research VM can write into the checkout;
#   - the scraper bearer is re-read from /var/lib/scraper-bearer/token per
#     request (readable under ProtectSystem=strict).
#
# Inert until the code exists: every unit carries ConditionPathExists on
# broker/server.py, so a switch that lands before the research-agent PR
# leaves the sockets unstarted instead of trigger-looping a service that
# is skipped on every connection. (A socket whose service is skipped by a
# condition re-triggers on the still-queued connection until it hits
# TriggerLimitBurst and the socket itself fails.)
let
  checkout = "/home/jonathan/Repos/research-agent";
  entry = "${checkout}/broker/server.py";

  # Stdlib server + curl_cffi for upstream HTTPS (Exa's WAF rejects stdlib
  # TLS fingerprints). Same package the research VM already ships.
  python = pkgs.python3.withPackages (ps: [ ps.curl-cffi ]);

  # The keyed APIs the broker owns. Reused agenix secrets; no new ones.
  # exa-api-key stays jonathan-owned for the MCP fast path (_direct_exa);
  # LoadCredential reads every file as root regardless of owner.
  credentials = [
    "exa-api-key"
    "tavily-api-key"
    "euipo-client-id"
    "euipo-client-secret"
    "ebay-client-id"
    "ebay-client-secret"
    "tradera-app-id"
    "tradera-app-key"
  ];

  inertWithoutCode = { ConditionPathExists = entry; };
in
{
  systemd.sockets.research-broker = {
    description = "research-broker VM listener (research VM reaches it as 10.0.2.2:8124)";
    wantedBy = [ "sockets.target" ];
    unitConfig = inertWithoutCode;
    # Host loopback only. SLIRP turns the research VM's 10.0.2.2:8124 into
    # a connection to host 127.0.0.1:8124; nothing off-host can reach it.
    listenStreams = [ "127.0.0.1:8124" ];
    socketConfig = {
      FileDescriptorName = "vm";
      Service = "research-broker.service";
    };
  };

  systemd.sockets.research-broker-admin = {
    description = "research-broker admin socket (run registration; host MCP server only)";
    wantedBy = [ "sockets.target" ];
    unitConfig = inertWithoutCode;
    listenStreams = [ "/run/research-broker/admin.sock" ];
    socketConfig = {
      FileDescriptorName = "admin";
      Service = "research-broker.service";
      SocketUser = "jonathan";
      SocketGroup = "root";
      SocketMode = "0600";
      DirectoryMode = "0755";
    };
  };

  systemd.services.research-broker = {
    description = "research-agent egress broker (keyed APIs + scraper proxy, per-run URL ledger)";
    unitConfig = inertWithoutCode;
    # Inherit both listeners. Without Sockets=, a service only gets the fds
    # of the socket that shares its name.
    requires = [ "research-broker.socket" "research-broker-admin.socket" ];
    after = [ "research-broker.socket" "research-broker-admin.socket" ];
    serviceConfig = {
      Sockets = [ "research-broker.socket" "research-broker-admin.socket" ];
      # -I: isolated (no PYTHON* env, no user site, no script dir on
      # sys.path); the broker sets sys.path to exactly /run/rb/{broker,scraper}.
      # -B: no bytecode written (the code dirs are read-only anyway).
      ExecStart = "${python}/bin/python3 -I -B /run/rb/broker/server.py";
      # Code reload is the broker exiting 0 when idle and stale (§2.2);
      # socket activation starts it again on the next connection.
      Restart = "on-failure";
      RestartSec = "2s";

      DynamicUser = true;
      LoadCredential = map
        (name: "${name}:${config.age.secrets.${name}.path}")
        credentials;

      ProtectHome = "tmpfs";
      BindReadOnlyPaths = [
        "${checkout}/broker:/run/rb/broker"
        "${checkout}/scraper:/run/rb/scraper"
      ];

      # Hardening (doc §2.2, plus what systemd-analyze still flagged).
      # No PrivateNetwork / IPAddressDeny: the broker needs the internet
      # and 127.0.0.1:8123.
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      PrivateTmp = true;
      PrivateDevices = true;
      PrivateIPC = true;
      PrivateUsers = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectClock = true;
      ProtectHostname = true;
      ProtectProc = "invisible";
      ProcSubset = "pid";
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
      SystemCallErrorNumber = "EPERM";
      SystemCallArchitectures = "native";
      CapabilityBoundingSet = "";
      AmbientCapabilities = "";
      KeyringMode = "private";
      DevicePolicy = "closed";
      UMask = "0077";

      # Sized for the per-run ledger cap (≈40 MB/run) across both VM slots
      # with headroom (§2.5).
      MemoryMax = "1G";
      TasksMax = 64;
    };
  };
}
