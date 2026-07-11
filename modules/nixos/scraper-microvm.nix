{ config, lib, pkgs, ... }:
# scraper microvm — JS-rendering crawler sibling to research-agent.
#
# Why separate from research-agent: chromium executes attacker-controlled
# JS on every render. Hosting it in research-agent would (a) put exa/tavily
# keys in the same process tree as a chromium sandbox escape, and (b) force
# the research-agent egress allowlist open to '*' since chromium needs to
# reach any URL. Splitting keeps the research-agent allowlist narrow
# (anthropic/exa/tavily only) and confines chromium's wide egress to a VM
# that holds nothing worth exfiltrating: no API keys, no operator data,
# nothing persisted across calls.
#
# Trust model:
#   host
#    └─ scraper-bearer-init.service: generates per-boot random token at
#       /var/lib/scraper-bearer/token (0444). Virtiofs RO-shared into both
#       VMs at /etc/scraper/token.
#    └─ scraper microvm (this module)
#         - chromium + playwright via headless HTTP server on guest :8000
#         - SLIRP forwarded to host 127.0.0.1:8123
#         - stock NixOS firewall: ssh + scraper port inbound, * outbound
#         - holds NO secrets; the bearer token gates incoming requests only
#    └─ research-agent microvm (sibling module)
#         - reaches scraper via 10.0.2.2:8123 (SLIRP host gateway)
#         - single nftables rule added there opens 10.0.2.2:8123 only
#         - render_shim.py reads /etc/scraper/token, attaches Bearer
#
# Compromise of chromium yields:
#   - no API keys (none present)
#   - no operator files (tmpfs $HOME, per-request browser context)
#   - wide egress (intended cost — that's the security boundary the VM
#     itself defends)
{
  # Per-boot bearer token. Random, never persisted across reboots. The
  # only consumers that need it (scraper-http inside the scraper VM,
  # render_shim inside the research-agent VM) both read on demand via
  # virtiofs, so a rotation is just `systemctl restart scraper-bearer-init`
  # followed by restarts of the two consumers.
  systemd.tmpfiles.rules = [
    "d /var/lib/scraper-bearer 0755 root root -"
    "d /var/lib/scraper 0700 root root -"
    "d /var/lib/scraper/vm-ssh 0700 root root -"
  ];

  systemd.services.scraper-bearer-init = {
    description = "Generate per-boot bearer token for the scraper microvm HTTP API";
    wantedBy = [ "multi-user.target" ];
    # Must run before either microvm starts so the token file is present
    # when scraper-http.service inside the scraper VM reads it at startup
    # and when render_shim inside research-agent first reads it on call.
    before = [
      "microvm@scraper.service"
      "microvm@research-agent.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [ pkgs.coreutils ];
    script = ''
      set -euo pipefail
      umask 0022
      tmp=$(mktemp /var/lib/scraper-bearer/.token.XXXXXX)
      # 32 bytes urandom → base64url (no '=' padding). ~43 ASCII chars,
      # unambiguous in HTTP headers, no escape concerns.
      head -c 32 /dev/urandom | base64 -w0 | tr -d '=' | tr '+/' '-_' > "$tmp"
      chmod 0444 "$tmp"
      mv "$tmp" /var/lib/scraper-bearer/token
      echo "[scraper-bearer-init] token rotated"
    '';
  };

  microvm.vms.scraper = {
    config = { config, pkgs, ... }: {

      microvm = {
        hypervisor = "qemu";
        vcpu = 2;
        # Chromium with one page open holds ~600-900 MB resident; leave
        # comfortable headroom for OS + virtiofs + a second concurrent
        # render. 3 GiB is the floor that avoided OOM-kills in early
        # smoke; bump if a real workload trips it.
        mem = 3072;

        shares = [
          {
            # Workspace share — same pattern as research-agent. The
            # scraper HTTP server (scraper/server.py) lives in the
            # research-agent repo so both microvms get their code from
            # one place. readOnly=true so a chromium sandbox escape
            # inside the VM cannot rewrite scraper/server.py and
            # persist an implant on the host. microvm.nix's `shares`
            # default is readOnly=false — the flag MUST be set
            # explicitly. (Verified via:
            # `nix eval .#nixosConfigurations.dellan.config.microvm.vms.scraper.config.config.microvm.shares`.)
            source = "/home/jonathan/Repos/research-agent";
            mountPoint = "/workspace";
            tag = "workspace";
            proto = "virtiofs";
            readOnly = true;
          }
          {
            # Bearer token. readOnly=true so a chromium escape inside
            # the VM cannot rotate the operator's view-of-truth out
            # from under the agent. The host owns the file and rotates
            # it via scraper-bearer-init.service. scraper-http
            # re-reads on every request (not cached at import).
            source = "/var/lib/scraper-bearer";
            mountPoint = "/etc/scraper";
            tag = "scraper-token";
            proto = "virtiofs";
            readOnly = true;
          }
          {
            # Persisted SSH host keys (same rationale as the
            # research-agent module: known_hosts pin survives reboots).
            # RW because sshd writes first-boot generated keys back
            # here; a chromium-escape rotation of these would surface
            # as REMOTE HOST IDENTIFICATION HAS CHANGED on the next
            # operator ssh — fail-loud, not silent persistence.
            source = "/var/lib/scraper/vm-ssh";
            mountPoint = "/etc/ssh/keys";
            tag = "ssh-keys";
            proto = "virtiofs";
          }
        ];

        interfaces = [
          {
            type = "user";
            id = "qemu0";
            # Distinct MAC from research-agent (02:00:00:00:00:01) so the
            # host bridge / arp tables don't collide if anything ever
            # bridges instead of SLIRP.
            mac = "02:00:00:00:00:02";
          }
        ];

        forwardPorts = [
          # ssh on host 2225 (research-agent uses 2223; pick a stable
          # next-free port). Useful for interactive debug; the agent →
          # scraper transport is HTTP, not ssh.
          { from = "host"; host.port = 2225; guest.port = 22; proto = "tcp"; }
          # HTTP scraper API. Bind to host loopback only (forwardPorts
          # default with no bind addr → 127.0.0.1, which is what we want
          # — the API must NOT be reachable from off-host or from the
          # LAN; it speaks bearer-auth but defense-in-depth).
          { from = "host"; host.port = 8123; guest.port = 8000; proto = "tcp"; }
        ];
      };

      environment.systemPackages = with pkgs; [
        bubblewrap
        (python3.withPackages (ps: with ps; [ playwright ]))
        # Headless chromium + ffmpeg + node bundled at the version
        # playwright-python expects. Pinned via nixpkgs; matches the
        # playwright Python package version so it can find the browser
        # at $PLAYWRIGHT_BROWSERS_PATH.
        playwright-driver.browsers
      ];

      # Pin scraper uid to 1000 so any virtiofs writeback (none today,
      # but consistent with research-agent's pattern) maps to a stable
      # owner on the host. The user does not need login; restrict shell
      # to nologin would be cleaner once the openssh authorized_keys
      # below is removed in a follow-up (kept for now to allow manual
      # debug ssh into the VM).
      users.users.scraper = {
        isNormalUser = true;
        uid = 1000;
        shell = pkgs.bashInteractive;
        openssh.authorizedKeys.keys = [
          # Reuses the research-agent host key — same operator key,
          # different VM. The host-side mcp_server doesn't ssh into the
          # scraper VM (HTTP transport instead); this entry exists only
          # for manual debug ssh from the operator.
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJTpnxCppc/riWtTthEqc6FDX3tHoJvPkVjiKACOYZUl research-agent-host-key"
          # jonathan@dellan operator key — same role as the
          # research-agent-host-key above (debug ssh access only;
          # the data path is HTTP, not ssh). Listed explicitly so the
          # feature-vm interactive smoke can reach the scraper VM
          # without needing the agenix-decrypted host-key.
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINT9HeHhu82OoNsAHe/QAh116pSEANuZUr1h5m8R8kpp jonathan@dellan"
        ];
      };

      services.openssh = {
        enable = true;
        hostKeys = [
          { path = "/etc/ssh/keys/ssh_host_ed25519_key"; type = "ed25519"; }
        ];
        settings = {
          PasswordAuthentication = false;
          PermitRootLogin = "no";
        };
      };

      # The scraper HTTP server. Listens on 0.0.0.0:8000 inside the VM
      # (only the SLIRP host-loopback forward exposes it — the world
      # never sees 0.0.0.0). Each render spawns a fresh chromium
      # process via Playwright, then tears it down — no shared browser
      # state across requests.
      systemd.services.scraper-http = {
        description = "Scraper HTTP API: POST /render -> rendered HTML";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        environment = {
          # Tell playwright-python where the nix-built browsers live.
          # Without this it falls back to ~/.cache/ms-playwright and
          # fails because the user has no writable cache (tmpfs $HOME).
          PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";
          # Skip Playwright's per-launch host requirements probe; it
          # fails on the headless guest because it shells out to apt.
          PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS = "1";
          SCRAPER_TOKEN_FILE = "/etc/scraper/token";
          SCRAPER_PORT = "8000";
        };
        serviceConfig = {
          User = "scraper";
          ExecStart = "${pkgs.python3.withPackages (ps: with ps; [ playwright ])}/bin/python3 /workspace/scraper/server.py";
          # Crash-loop tolerant — chromium occasionally hangs and the
          # supervisor is the recovery path.
          Restart = "always";
          RestartSec = "5s";
          # Bound memory: a chromium runaway shouldn't be able to OOM
          # the whole VM. ~2 GiB ceiling leaves room for OS + virtiofs.
          MemoryMax = "2G";
        };
      };

      # Inbound: ssh (opened by services.openssh.openFirewall) + the
      # scraper API. Outbound unrestricted on purpose — the scraper's
      # job is to fetch arbitrary URLs. That widened egress is contained
      # by the VM boundary; no API keys or operator data live here, so
      # the exfil ceiling for a chromium compromise is "the HTML the
      # operator asked it to fetch anyway".
      #
      # Stock NixOS firewall ONLY. A custom nftables ruleset used to
      # coexist here — but every base chain hooked at input must accept
      # a packet for it to pass, and the default nixos-fw chain (on by
      # default, fed only by openssh's port 22) silently dropped :8000
      # SYNs. Result: the host→scraper hostfwd (127.0.0.1:8123) hung on
      # every connect while ssh worked, diagnosed 2026-07-11. One
      # firewall layer, stock options, nothing to fall out of sync.
      networking.firewall.allowedTCPPorts = [ 8000 ];

      # Guardrail: any host-forwarded guest port must actually be
      # admitted by the guest firewall, or the forward dies the same
      # silent death. Fails the build, not the runtime.
      assertions = [{
        assertion = lib.all (p:
          p.from or "host" != "host"
          || p.proto or "tcp" != "tcp"
          || builtins.elem p.guest.port config.networking.firewall.allowedTCPPorts
        ) config.microvm.forwardPorts;
        message = "scraper microvm: a TCP forwardPorts guest port is not in networking.firewall.allowedTCPPorts — the hostfwd would stall (see 2026-07-11 incident)";
      }];

      networking.hostName = "scraper";
      # IPv4-only — mirrors research-agent for the same SLIRP-resolver
      # latency reason (AAAA preference would burn 5-10s per first
      # connect against a v6 default-drop).
      networking.enableIPv6 = false;

      system.stateVersion = "25.11";
    };
  };
}
