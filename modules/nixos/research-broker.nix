{ config, lib, pkgs, ... }:
# research-broker: the host-side, credential-injecting egress broker for
# the research agent.
#
# Design: research-agent docs/egress-broker.md §2.2 (process model), §2.4
# (run registration), §5 (this module), §12 (switchover). In one line: once
# the switchover's contract step lands, the research VM holds no
# third-party API key; every keyed API call (Exa, Tavily, eBay, Tradera,
# EUIPO) and every scraper call goes through this host process, which
# injects the key / scraper bearer itself and gates model-authored URLs
# against a per-run ledger. Until then (researchAgent.legacyPaths, the
# expand step) the old direct paths stay open next to it.
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
#
# Code lifecycle (§12.2), driven by research-broker-code.{path,service}:
#   - first arrival: the pull creates broker/; the code-watch starts both
#     sockets (ConditionPathExists alone would never re-evaluate);
#   - change: the code-watch sends `systemctl reload` on every (debounced)
#     change event and never judges the code itself. The broker's SIGHUP
#     handler compares the digest of the code it loaded with the code on
#     disk — one implementation, the broker's own (research-agent
#     broker/digest.py) — and if they match keeps serving (a spurious
#     event costs nothing). If they differ it persists its run registry to
#     $STATE_DIRECTORY, stops accepting (new connections queue in the
#     systemd-owned backlog), finishes in-flight requests and exits 0; the
#     next connection starts the new code, which loads the registry.
#     Root never executes or hashes checkout content here: the checkout is
#     updated by an unattended pull, so anything root ran from it would be
#     repo content running as root;
#   - removal (a revert): the code-watch STOPS the sockets and the service.
#     ConditionPathExists is evaluated only on start, so nothing else
#     would take down sockets that are already listening with no code
#     behind them.
let
  checkout = "/home/jonathan/Repos/research-agent";
  entry = "${checkout}/broker/server.py";

  # The code-watch (§12.2). Debounce first: a pull lands many files, and
  # events that arrive while this runs are dropped, so it must look at
  # the tree only once the pull has settled.
  codeWatch = pkgs.writeShellApplication {
    name = "research-broker-code";
    runtimeInputs = with pkgs; [ coreutils systemd ];
    text = ''
      sleep 5
      state() { systemctl show -P ActiveState "$1"; }
      sockets=(research-broker.socket research-broker-admin.socket)

      if [ ! -f ${entry} ]; then
        for u in "''${sockets[@]}" research-broker.service; do
          if [ "$(state "$u")" != inactive ]; then
            echo "research-broker-code: ${entry} is gone; stopping the sockets and draining the service"
            systemctl stop "''${sockets[@]}" research-broker.service
            break
          fi
        done
        exit 0
      fi

      for s in "''${sockets[@]}"; do
        if [ "$(state "$s")" != active ]; then
          echo "research-broker-code: code present; starting $s"
          systemctl start "$s"
        fi
      done

      # Only a running broker can be stale; an idle one starts on the new
      # code at its next connection. Whether this change is a code change
      # is the broker's call (its SIGHUP handler), not ours.
      if [ "$(state research-broker.service)" = active ]; then
        echo "research-broker-code: change under the code dirs; asking the broker to reload"
        systemctl reload research-broker.service
      fi
    '';
  };

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
      # Graceful reload (§12.2): the broker drains and exits 0, socket
      # activation starts the new code on the next connection. Restart
      # covers crashes only.
      ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
      Restart = "on-failure";
      RestartSec = "2s";
      # The drain's bound: the longest upstream route (session/act, 165 s
      # broker-side) plus margin. SIGTERM drains the same way.
      TimeoutStopSec = 210;
      # runs.json, the run registry handed from the old process to the new
      # one across a reload (private to the dynamic user).
      StateDirectory = "research-broker";
      StateDirectoryMode = "0700";

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

  # Watch the two code dirs the broker loads from (broker/ and, for
  # urlpolicy.py, scraper/). PathChanged on a directory also fires when it
  # is created or renamed away. No PathExists=: with a oneshot it would
  # re-trigger every time the oneshot exits, for as long as the file
  # exists.
  systemd.paths.research-broker-code = {
    wantedBy = [ "paths.target" ];
    pathConfig = {
      PathChanged = [ "${checkout}/broker" "${checkout}/scraper" ];
      Unit = "research-broker-code.service";
    };
  };

  systemd.services.research-broker-code = {
    description = "research-broker code-watch: start on first code, reload on change, stop on removal";
    unitConfig.StartLimitIntervalSec = 0;
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      ExecStart = "${codeWatch}/bin/research-broker-code";
      # The stop branch waits for the service's own drain.
      TimeoutStartSec = 300;
    };
  };
}
