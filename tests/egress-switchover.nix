# vm-egress-switchover: the egress-broker switchover, end to end
# (research-agent docs/egress-broker.md §12.5, research-agent#41).
#
# Four nodes, no external network:
#   host      plays dellan: the real research-agent-microvm.nix, scraper-microvm.nix,
#             research-broker.nix and research-vm-roll.nix in specialisations
#             base (pre-nixos-A) / expand / contract, the real microvm@ units
#             (only their ExecStart/ExecStop replaced), the research-agent
#             checkout as a git repo with a bare origin, and two load generators
#             that call the real mcp_server.server _run_agent inside _vm_lock.
#   agent     plays the research VM: the guest's own egress module per phase,
#             sshd, user agent, bubblewrap, the real run-agent.sh and shims from
#             the checkout; `claude` is research-agent's tests/e2e/fake_agent.py.
#   scraper   plays the scraper VM: the real scraper/server.py from the checkout
#             with Playwright + chromium and the real scraper-egress.nix.
#   upstream  plays the internet: dnsmasq + one HTTPS stub (test CA) for Exa,
#             Tavily, eBay, Tradera, IKEA, shop.test and canary.test.
#
# SLIRP is emulated on the test vlan: host owns 10.0.2.2 (nft DNAT of :8123/:8124
# to its loopback, as SLIRP maps the gateway), upstream owns 10.0.2.3 (SLIRP's
# DNS), the hostfwds are socat on host loopback (2223 agent ssh, 2225 scraper ssh,
# 8123 scraper API). The QEMU user NIC (eth0) is removed from every node.
#
# A microVM restart is emulated: microvm@<vm>'s ExecStop/ExecStart (vmctl.py)
# ask the matching node (nodectl.py) to power off (sshd down, agent processes
# killed) or to come up in the specialisation matching the host's own. Every
# other line of those units is microvm.nix's, so T1 tests the real
# restartTriggers / X-RestartIfChanged.
#
# Shared state between nodes uses virtiofs directories under the driver's
# $SHARED_DIR/lane (one virtiofsd per VM over the same build-host directory): the checkout (host rw, agent /workspace ro and /out rw,
# scraper /workspace/scraper ro), the scraper bearer, and the two control dirs.
#
# The research-agent-new pin carries tests/e2e/fake_agent.py (since
# 1975ae0), so the lane builds from the pins alone. Only a local run
# against an unpushed research-agent tree needs:
#   --override-input research-agent-new path:<research-agent tree>
{ pkgs, inputs }:

let
  lib = pkgs.lib;
  inherit (inputs) microvm researchAgentOld researchAgentNew;

  # jonathan on the lane host; the agent and scraper guests take theirs from it.
  uid = 1000;

  keyNames = [
    "exa-api-key"
    "tavily-api-key"
    "euipo-client-id"
    "euipo-client-secret"
    "ebay-client-id"
    "ebay-client-secret"
    "tradera-app-id"
    "tradera-app-key"
  ];
  keyEnv = {
    "exa-api-key" = "EXA_API_KEY";
    "tavily-api-key" = "TAVILY_API_KEY";
    "euipo-client-id" = "EUIPO_CLIENT_ID";
    "euipo-client-secret" = "EUIPO_CLIENT_SECRET";
    "ebay-client-id" = "EBAY_CLIENT_ID";
    "ebay-client-secret" = "EBAY_CLIENT_SECRET";
    "tradera-app-id" = "TRADERA_APP_ID";
    "tradera-app-key" = "TRADERA_APP_KEY";
  };
  # Test values. Every one carries LANEKEY-, the marker the jail's own
  # envcheck looks for; the testScript greps for the exact values
  # (LANE.keyValues).
  keyValue = n: "LANEKEY-${n}-5b1d";

  upstreamNames = [
    "api.exa.ai"
    "mcp.exa.ai"
    "api.tavily.com"
    "api.ebay.com"
    "www.ebay.com"
    "api.tradera.com"
    "www.ikea.com"
    "shop.test"
    "canary.test"
    "api.anthropic.com"
  ];
  keyedHosts = [ "api.exa.ai" "mcp.exa.ai" "api.tavily.com" "api.ebay.com" "api.tradera.com" ];

  # Addresses. 11.0.0.0/24 is global (the scraper's netguard and egress refuse
  # private and TEST-NET ranges); 10.0.2.0/24 is the emulated SLIRP net.
  ip = {
    upstream = "11.0.0.10";
    hostSlirp = "10.0.2.2";
    dns = "10.0.2.3";
    agentSlirp = "10.0.2.15";
    agentGlobal = "11.0.0.15";
    scraperSlirp = "10.0.2.16";
    scraperGlobal = "11.0.0.20";
  };

  # Test PKI and ssh keys, world-readable in the store, authenticating nowhere.
  fixtures = pkgs.runCommand "egress-switchover-fixtures"
    { nativeBuildInputs = [ pkgs.openssl pkgs.openssh ]; } ''
      mkdir -p "$out"
      openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
        -subj /CN=lane-test-ca -keyout "$out/ca.key" -out "$out/ca.pem" \
        -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign
      openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj /CN=lane-upstream \
        -keyout "$out/leaf.key" -out leaf.csr
      printf 'subjectAltName=%s\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\nkeyUsage=digitalSignature\n' \
        "${lib.concatMapStringsSep "," (n: "DNS:${n}") upstreamNames}" > ext
      openssl x509 -req -in leaf.csr -CA "$out/ca.pem" -CAkey "$out/ca.key" -CAcreateserial \
        -days 3650 -extfile ext -out "$out/leaf.pem"
      ssh-keygen -q -t ed25519 -N "" -C lane-research-vm-host -f "$out/agent_host"
      ssh-keygen -q -t ed25519 -N "" -C lane-scraper-vm-host -f "$out/scraper_host"
      ssh-keygen -q -t ed25519 -N "" -C research-agent-host-key -f "$out/client"
    '';

  # The test CA plays a public root, so it goes wherever public roots are:
  # /etc/ssl (security.pki), chromium's NSS DB, and the nixpkgs cacert bundle
  # that python certifi (hence curl_cffi) reads when NIX_SSL_CERT_FILE is
  # unset — bind-mounted over that store file on every node.
  caBundle = pkgs.runCommand "lane-ca-bundle.crt" { } ''
    cat ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt ${fixtures}/ca.pem > "$out"
  '';
  caBundleModule = {
    security.pki.certificateFiles = [ "${fixtures}/ca.pem" ];
    systemd.services.lane-ca-bundle = {
      wantedBy = [ "multi-user.target" ];
      before = [ "multi-user.target" "network.target" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = "${pkgs.util-linux}/bin/mount --bind ${caBundle} ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    };
  };

  # Pre-nixos-A guest egress: nixos-A's module minus exactly its :8124 rule.
  realEgress = ../modules/nixos/research-agent-egress.nix;
  rule8124 = "ip daddr 10.0.2.2 tcp dport 8124 accept\n";
  egressSrc = builtins.readFile realEgress;
  preAEgress =
    assert lib.assertMsg (lib.hasInfix rule8124 egressSrc)
      "vm-egress-switchover: research-agent-egress.nix no longer has the :8124 rule the base phase removes";
    builtins.toFile "research-agent-egress-pre-a.nix"
      (builtins.replaceStrings [ rule8124 ] [ "" ] egressSrc);

  # agenix, replaced: same option shape the modules read, test files behind it.
  ageStub = { lib, ... }: {
    options.age.secrets = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options.path = lib.mkOption {
          type = lib.types.str;
          default = "/run/lane-secrets/${name}";
        };
      }));
      default = { };
    };
    config.age.secrets = lib.genAttrs (keyNames ++ [ "research-agent-host-key" ]) (_: { });
  };

  # Pre-nixos-A hosts have no researchAgent.legacyPaths; research-agent-microvm.nix
  # (nixos-A's) reads it, and true is exactly the pre-A guest.
  preALegacyOption = { lib, ... }: {
    options.researchAgent.legacyPaths = lib.mkOption { type = lib.types.bool; default = true; };
  };

  vmctl = pkgs.writeScript "lane-vmctl" ''
    #!${pkgs.python3}/bin/python3
    ${builtins.readFile ./egress-switchover/vmctl.py}
  '';
  nodectl = pkgs.writeScript "lane-nodectl" ''
    #!${pkgs.python3}/bin/python3
    ${builtins.readFile ./egress-switchover/nodectl.py}
  '';

  # The ONLY change to microvm.nix's units: ExecStart and ExecStop of
  # microvm@<vm> (vmctl), plus virtiofsd made inert (nothing to share: the
  # nodes mount the host dirs over virtiofs). Identical in every phase, so a phase
  # switch changes those units exactly when microvm.nix's own lines change.
  laneVmUnits = {
    systemd.services = lib.genAttrs [ "microvm@research-agent" "microvm@scraper" ] (n:
      let vm = lib.removePrefix "microvm@" n; in {
        serviceConfig.ExecStart = lib.mkForce [ "" "+${vmctl} ${vm} start" ];
        serviceConfig.ExecStop = lib.mkForce [ "" "+${vmctl} ${vm} stop" ];
      }) // lib.genAttrs [ "microvm-virtiofsd@research-agent" "microvm-virtiofsd@scraper" ] (_: {
        serviceConfig.ExecStart = lib.mkForce [ "" "${pkgs.coreutils}/bin/sleep infinity" ];
        serviceConfig.Type = lib.mkForce "simple";
      });
  };

  phaseModule = phase: {
    environment.etc."lane/phase".text = phase;
  };

  rollTimings = {
    researchAgent.roll.scraperQuietSeconds = 20;
    researchAgent.roll.readyTimeoutSeconds = 120;
  };

  hostSpecs = {
    base = {
      imports = [
        ../modules/nixos/research-agent-microvm.nix
        ../modules/nixos/scraper-microvm.nix
        preALegacyOption
        laneVmUnits
        (phaseModule "base")
      ];
      microvm.vms.research-agent.config = {
        disabledModules = [ realEgress ];
        imports = [ preAEgress ];
      };
    };
    expand = {
      imports = [
        ../modules/nixos/research-agent-microvm.nix
        ../modules/nixos/scraper-microvm.nix
        ../modules/nixos/research-broker.nix
        ../modules/nixos/research-vm-roll.nix
        laneVmUnits
        rollTimings
        (phaseModule "expand")
      ];
      researchAgent.legacyPaths = true;
    };
    contract = {
      imports = [
        ../modules/nixos/research-agent-microvm.nix
        ../modules/nixos/scraper-microvm.nix
        ../modules/nixos/research-broker.nix
        ../modules/nixos/research-vm-roll.nix
        laneVmUnits
        rollTimings
        (phaseModule "contract")
      ];
      researchAgent.legacyPaths = false;
    };
  };

  # The load generator, under the file name protocheck recognises.
  bootstrap = pkgs.writeText "research-agent-mcp-bootstrap.py"
    (builtins.readFile ./egress-switchover/loadgen.py);
  harnessPython = pkgs.python3.withPackages (ps: [ ps.curl-cffi ]);
  # server.py imports FastMCP at module level only to register its tools;
  # the load generator calls _run_agent directly, so the MCP transport is
  # never used. nixpkgs ships mcp 2.x (FastMCP renamed), research-agent pins
  # mcp 1.x through uv: a stand-in that registers nothing and cannot run.
  mcpStub = pkgs.writeTextDir "mcp/server/fastmcp.py" ''
    class FastMCP:
        def __init__(self, *args, **kwargs):
            pass

        def tool(self, *args, **kwargs):
            return lambda fn: fn

        def run(self, *args, **kwargs):
            raise RuntimeError("vm-egress-switchover: no MCP transport in the load generator")
  '';
  laneMcp = pkgs.writeShellScriptBin "lane-mcp" ''
    set -eu
    name=$1 root=$2
    # `keyless`: an MCP spawned while nixos-B's wrapper exports no keys
    # (the lane has no wrapper; this is its stand-in for that spawn).
    keys=(${lib.concatMapStringsSep " " (n: "--setenv=${keyEnv.${n}}=${keyValue n}") keyNames})
    if [ "''${3:-}" = keyless ]; then keys=(); fi
    install -d -m 0755 /run/lane-ctl "/run/lane-ctl/$name.req"
    exec systemd-run --unit="lane-$name" --uid=jonathan --gid=users \
      -p WorkingDirectory=/home/jonathan \
      --setenv=HOME=/home/jonathan --setenv=USER=jonathan \
      --setenv=XDG_RUNTIME_DIR=/run/user/${toString uid} \
      --setenv=PATH=${lib.makeBinPath [ pkgs.openssh pkgs.coreutils pkgs.util-linux ]} \
      "''${keys[@]}" \
      --setenv=CLAUDE_CODE_OAUTH_TOKEN=lane-oauth-token \
      --setenv=RESEARCH_SSH_KEY=/home/jonathan/.ssh/lane_key \
      --setenv=RESEARCH_ACTIVITY_FILE=/run/research-agent/active \
      --setenv=RESEARCH_SLOTS=2 \
      --setenv=RESEARCH_REPORTS_DIR=/home/jonathan/Repos/research-agent/reports \
      --setenv=SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
      --setenv=PYTHONPATH=${mcpStub} \
      ${harnessPython}/bin/python3 ${bootstrap} --name "$name" --root "$root"
  '';

  # The checkout as a git repo: commit 1 = research-agent-old pushed and
  # cloned; commit 2 = research-agent-new pushed to origin, pulled at T2.
  laneGit = pkgs.writeShellApplication {
    name = "lane-git";
    runtimeInputs = [ pkgs.git pkgs.coreutils pkgs.findutils ];
    text = ''
      export HOME=/home/jonathan
      CO=/home/jonathan/Repos/research-agent
      WORK=/var/lib/lane-git/work
      ORIGIN=/var/lib/lane-git/origin.git
      commit_tree() {  # replace the work tree's content with $1, commit as $2
        (cd "$WORK" && git rm -rq --ignore-unmatch . && find . -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +)
        cp -r "$1"/. "$WORK"/
        chmod -R u+w "$WORK"
        (cd "$WORK" && git add -A && git commit -qm "$2" && git push -q origin HEAD:main)
      }
      case "$1" in
        setup)
          git config --global user.name lane
          git config --global user.email lane@lane.test
          git config --global init.defaultBranch main
          git init -q --bare "$ORIGIN"
          git clone -q "$ORIGIN" "$WORK"
          commit_tree ${researchAgentOld} "commit 1 (research-agent-old)"
          git clone -q "$ORIGIN" "$CO"
          commit_tree ${researchAgentNew} "commit 2 (research-agent-new)"
          ;;
        noop)
          (cd "$WORK" && printf '\n# lane no-op change\n' >> broker/server.py \
            && git commit -qam "no-op under broker/" && git push -q origin HEAD:main)
          ;;
        revert)
          (cd "$WORK" && git revert --no-edit HEAD~2..HEAD >/dev/null && git push -q origin HEAD:main)
          ;;
        reapply)
          (cd "$WORK" && git revert --no-edit HEAD~2..HEAD >/dev/null && git push -q origin HEAD:main)
          ;;
        pull)
          git -C "$CO" pull -q --ff-only
          ;;
      esac
    '';
  };

  # The fake LLM: research-agent's own e2e stand-in, on PATH as `claude`.
  fakeClaude = pkgs.writeShellScriptBin "claude" ''
    exec /run/current-system/sw/bin/python3 ${researchAgentNew}/tests/e2e/fake_agent.py "$@"
  '';

  # virtiofs on a Linux build host (qemu-vm.nix). virtiofsd runs as the
  # sandbox build user, so every node sees the shared files as owned by uid
  # 1000 — jonathan on host, agent and scraper alike, as on dellan.
  # cache=never: each node runs its own virtiofsd over the same directory, so
  # any attribute or page cache lets one node read a file another node has
  # already rewritten as it was before (seen: the host read a 0-byte report
  # the agent had written 131 bytes into).
  share = writable: source: target: { inherit source target writable; cache = "never"; };
  noUserNic = {
    virtualisation.qemu.networkingOptions = lib.mkForce [ ];
    # Not the checkout: the built-in `shared` share would expose all of
    # $SHARED_DIR/lane (bearer included) at /tmp/shared on every node.
    virtualisation.sharedDirectories.shared.source = lib.mkForce ''"$TMPDIR"/xchg'';
    networking.enableIPv6 = false;
  };
  nodectlService = role: {
    systemd.services.lane-nodectl = {
      wantedBy = [ "multi-user.target" ];
      restartIfChanged = false;
      path = [ pkgs.procps pkgs.systemd pkgs.util-linux ];
      serviceConfig.ExecStart = "${nodectl} ${role}";
    };
  };
in
pkgs.testers.runNixOSTest {
  name = "vm-egress-switchover";
  skipTypeCheck = true;

  nodes.upstream = { pkgs, ... }: {
    imports = [ noUserNic ];
    virtualisation.memorySize = 768;
    networking.firewall.enable = false;
    networking.interfaces.eth1.ipv4.addresses = lib.mkAfter [
      { address = ip.dns; prefixLength = 24; }
      { address = ip.upstream; prefixLength = 24; }
    ];
    services.dnsmasq = {
      enable = true;
      resolveLocalQueries = false;
      settings = {
        no-resolv = true;
        no-hosts = true;
        address = map (n: "/${n}/${ip.upstream}") upstreamNames;
        log-queries = true;
      };
    };
    systemd.tmpfiles.rules = [
      "d /var/log/upstream 0755 root root -"
      "f /var/log/canary 0644 root root -"
    ];
    systemd.services.lane-upstream = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart =
        "${pkgs.python3}/bin/python3 ${./egress-switchover/upstream.py} ${fixtures}/leaf.pem ${fixtures}/leaf.key";
    };
  };

  nodes.host = { config, pkgs, ... }: {
    imports = [ microvm.nixosModules.host ageStub noUserNic caBundleModule ];
    virtualisation.memorySize = 3072;
    virtualisation.cores = 2;
    virtualisation.diskSize = 4096;

    users.users.jonathan = {
      isNormalUser = true;
      inherit uid;
      linger = true;
    };

    virtualisation.sharedDirectories = {
      checkout = share true ''"$SHARED_DIR"/lane/research-agent'' "/home/jonathan/Repos/research-agent";
      bearer = share true ''"$SHARED_DIR"/lane/bearer'' "/var/lib/scraper-bearer";
      ctlagent = share true ''"$SHARED_DIR"/lane/ctl-agent'' "/var/lib/lane-vmctl/research-agent";
      ctlscraper = share true ''"$SHARED_DIR"/lane/ctl-scraper'' "/var/lib/lane-vmctl/scraper";
    };

    # SLIRP, emulated: 10.0.2.2 is this host's loopback for :8123/:8124.
    networking.firewall.enable = false;
    networking.nameservers = [ ip.dns ];
    networking.interfaces.eth1.ipv4.addresses = lib.mkAfter [
      { address = ip.hostSlirp; prefixLength = 24; }
      { address = "11.0.0.2"; prefixLength = 24; }
    ];
    boot.kernel.sysctl."net.ipv4.conf.all.route_localnet" = 1;
    boot.kernel.sysctl."net.ipv4.conf.eth1.route_localnet" = 1;
    networking.nftables.enable = true;
    networking.nftables.tables.lane-slirp = {
      family = "ip";
      content = ''
        chain prerouting {
          type nat hook prerouting priority dstnat; policy accept;
          ip daddr ${ip.hostSlirp} tcp dport { 8123, 8124 } dnat to 127.0.0.1
        }
      '';
    };
    systemd.services = lib.mapAttrs' (name: v: lib.nameValuePair "lane-hostfwd-${name}" {
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig.ExecStart =
        "${pkgs.socat}/bin/socat TCP-LISTEN:${toString v.port},bind=127.0.0.1,reuseaddr,fork TCP:${v.to}";
      serviceConfig.Restart = "always";
    }) {
      agent-ssh = { port = 2223; to = "${ip.agentSlirp}:22"; };
      scraper-ssh = { port = 2225; to = "${ip.scraperSlirp}:22"; };
      scraper-api = { port = 8123; to = "${ip.scraperSlirp}:8000"; };
    } // {
      # Test credentials where agenix would decrypt them; the persisted VM
      # host key where research-agent-microvm.nix's share expects it.
      lane-secrets = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
        script = ''
          install -d -m 0755 /run/lane-secrets
          ${lib.concatMapStringsSep "\n" (n: "printf %s '${keyValue n}' > /run/lane-secrets/${n}") keyNames}
          install -m 0400 ${fixtures}/client /run/lane-secrets/research-agent-host-key
          chmod 0400 /run/lane-secrets/*
          install -d -m 0700 /var/lib/research-agent/vm-ssh
          install -m 0600 ${fixtures}/agent_host /var/lib/research-agent/vm-ssh/ssh_host_ed25519_key
          install -m 0644 ${fixtures}/agent_host.pub /var/lib/research-agent/vm-ssh/ssh_host_ed25519_key.pub
          install -d -o jonathan -g users -m 0700 /home/jonathan/.ssh
          install -o jonathan -g users -m 0600 ${fixtures}/client /home/jonathan/.ssh/lane_key
        '';
      };
    };
    systemd.tmpfiles.rules = [
      "d /home/jonathan/Repos 0755 jonathan users -"
      "d /home/jonathan/.cache 0755 jonathan users -"
      "d /home/jonathan/.cache/research-agent 0700 jonathan users -"
      "d /run/research-agent 0755 jonathan users -"
      "d /var/lib/research-agent/tool-cache 0777 jonathan users -"
      "d /var/lib/lane-git 0755 jonathan users -"
      "d /var/log/switchover 0755 jonathan users -"
      "d /run/lane-ctl 0755 root root -"
    ];
    environment.systemPackages = [
      laneMcp laneGit pkgs.git pkgs.jq pkgs.curl pkgs.openssh harnessPython
    ];
    environment.etc."lane/phase".text = lib.mkDefault "parent";

    specialisation = lib.mapAttrs (_: c: { configuration = c; }) hostSpecs;
  };

  nodes.agent = { nodes, pkgs, ... }:
    let
      guestOf = p: nodes.host.specialisation.${p}.configuration.microvm.vms.research-agent.config.config;
      g = guestOf "base";
      hasTokenShare = p: lib.any (s: s.tag == "scraper-token") (guestOf p).microvm.shares;
      laneSpec = p: {
        imports = [ (if p == "base" then preAEgress else realEgress) ];
        researchAgent.egress.legacyPaths = (guestOf p).researchAgent.egress.legacyPaths;
        systemd.services.sshd = {
          inherit (g.systemd.services.sshd) requires bindsTo wants;
          after = g.systemd.services.sshd.after;
        };
        virtualisation.fileSystems = lib.mkIf (hasTokenShare p) {
          "/etc/scraper" = {
            device = "bearer";
            fsType = "9p";
            options = [ "trans=virtio" "version=9p2000.L" "ro" ];
          };
        };
      };
    in
    {
      imports = [ noUserNic caBundleModule (nodectlService "agent") ];
      virtualisation.memorySize = 2048;
      virtualisation.cores = 2;
      networking.interfaces.eth1.ipv4.addresses = lib.mkAfter [
        { address = ip.agentSlirp; prefixLength = 24; }
        { address = ip.agentGlobal; prefixLength = 24; }
      ];
      # Every phase's egress module runs on nftables; the parent too, so a
      # phase switch never swaps firewall backends at runtime.
      networking.nftables.enable = true;

      # The research VM's shares, over virtiofs from the same host directories.
      virtualisation.sharedDirectories = {
        workspace = share false ''"$SHARED_DIR"/lane/research-agent'' "/workspace";
        out = share true ''"$SHARED_DIR"/lane/research-agent/reports'' "/out";
        nodectl = share true ''"$SHARED_DIR"/lane/ctl-agent'' "/var/lib/lane-nodectl";
      };
      # The bearer share exists on the "hypervisor" in every phase; a phase
      # mounts it only when its guest config has the scraper-token share.
      virtualisation.qemu.options = [
        ''-virtfs local,path="$SHARED_DIR"/lane/bearer,security_model=none,readonly=on,mount_tag=bearer''
      ];
      systemd.tmpfiles.rules = [ "d /tool-cache 0777 root root -" ];

      users.users.agent = {
        isNormalUser = true;
        inherit (g.users.users.agent) uid;
        shell = pkgs.bashInteractive;
        openssh.authorizedKeys.keys = g.users.users.agent.openssh.authorizedKeys.keys;
      };
      services.openssh = {
        enable = true;
        inherit (g.services.openssh) hostKeys;
        settings = { inherit (g.services.openssh.settings) PasswordAuthentication PermitRootLogin; };
      };
      # The persisted host key the share would carry, and the lane's client
      # key (the guest's own authorized key is research-agent-host-key's).
      systemd.services.lane-agent-keys = {
        wantedBy = [ "multi-user.target" ];
        before = [ "sshd.service" ];
        requiredBy = [ "sshd.service" ];
        serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
        script = ''
          install -d -m 0755 /etc/ssh/keys
          install -m 0600 ${fixtures}/agent_host /etc/ssh/keys/ssh_host_ed25519_key
          install -m 0644 ${fixtures}/agent_host.pub /etc/ssh/keys/ssh_host_ed25519_key.pub
          install -d -o agent -g users -m 0700 /home/agent/.ssh
          install -o agent -g users -m 0600 ${fixtures}/client.pub /home/agent/.ssh/authorized_keys
        '';
      };
      # The guest's packages, with the fake agent in the real CLIs' place.
      environment.systemPackages =
        lib.filter (p: !(lib.elem (lib.getName p) [ "claude-code" "codex" ])) g.environment.systemPackages
        ++ [ fakeClaude pkgs.curl pkgs.dig pkgs.procps ];

      specialisation = lib.genAttrs [ "base" "expand" "contract" ] (p: { configuration = laneSpec p; });
    };

  nodes.scraper = { nodes, pkgs, ... }:
    let
      gs = nodes.host.specialisation.base.configuration.microvm.vms.scraper.config.config;
      unit = gs.systemd.services.scraper-http;
    in
    {
      imports = [ noUserNic caBundleModule (nodectlService "scraper") ../modules/nixos/scraper-egress.nix ];
      virtualisation.memorySize = 3072;
      virtualisation.cores = 2;
      networking.nameservers = [ ip.dns ];
      networking.interfaces.eth1.ipv4.addresses = lib.mkAfter [
        { address = ip.scraperSlirp; prefixLength = 24; }
        { address = ip.scraperGlobal; prefixLength = 24; }
      ];
      networking.firewall.allowedTCPPorts = gs.networking.firewall.allowedTCPPorts;

      virtualisation.sharedDirectories = {
        scrapercode = share false ''"$SHARED_DIR"/lane/research-agent/scraper'' "/workspace/scraper";
        bearer = share false ''"$SHARED_DIR"/lane/bearer'' "/etc/scraper";
        nodectl = share true ''"$SHARED_DIR"/lane/ctl-scraper'' "/var/lib/lane-nodectl";
      };

      users.users.scraper = {
        isNormalUser = true;
        inherit (gs.users.users.scraper) uid;
      };
      services.openssh = {
        enable = true;
        inherit (gs.services.openssh) hostKeys;
        settings = { inherit (gs.services.openssh.settings) PasswordAuthentication PermitRootLogin; };
      };
      environment.systemPackages = gs.environment.systemPackages ++ [ pkgs.curl pkgs.nss.tools ];

      # The scraper guest's own unit (fields named, not copied wholesale);
      # started by nodectl when the host starts microvm@scraper.
      systemd.services.scraper-http = {
        inherit (unit) description;
        after = [ "network-online.target" "lane-scraper-trust.service" ];
        wants = [ "network-online.target" ];
        requires = [ "lane-scraper-trust.service" ];
        environment = {
          inherit (unit.environment)
            PLAYWRIGHT_BROWSERS_PATH PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS SCRAPER_TOKEN_FILE SCRAPER_PORT;
        };
        serviceConfig = { inherit (unit.serviceConfig) User ExecStart Restart RestartSec MemoryMax; };
      };
      systemd.services.lane-scraper-trust = {
        serviceConfig = { Type = "oneshot"; RemainAfterExit = true; User = "scraper"; };
        script = ''
          db=sql:$HOME/.pki/nssdb
          mkdir -p "$HOME/.pki/nssdb"
          ${pkgs.nss.tools}/bin/certutil -d "$db" -L >/dev/null 2>&1 \
            || ${pkgs.nss.tools}/bin/certutil -d "$db" -N --empty-password
          ${pkgs.nss.tools}/bin/certutil -d "$db" -A -n lane-test-ca -t C,, -i ${fixtures}/ca.pem
        '';
      };
      systemd.services.lane-scraper-keys = {
        wantedBy = [ "multi-user.target" ];
        before = [ "sshd.service" ];
        requiredBy = [ "sshd.service" ];
        serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
        script = ''
          install -d -m 0755 /etc/ssh/keys
          install -m 0600 ${fixtures}/scraper_host /etc/ssh/keys/ssh_host_ed25519_key
        '';
      };
    };

  testScript = ''
    LANE = ${builtins.toJSON {
      old = "${researchAgentOld}";
      # The 8 exact values: T5/T5b grep for these, never for the bare
      # LANEKEY- prefix, which fake_agent.py itself carries as KEY_MARK
      # and so sits in the checkout the agent mounts as /workspace (b10).
      keyValues = map keyValue keyNames;
      inherit keyedHosts;
      inherit (ip) agentGlobal;
    }}
  '' + builtins.readFile ./egress-switchover/script.py;
}
