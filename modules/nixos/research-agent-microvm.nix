{ config, lib, pkgs, ... }:
# research-agent microvm — replaces the docker-based
# research-agent-container.service.
#
# Lifecycle: microvm.nix synthesizes microvm@research-agent.service
# from this declaration. Boot order inside the guest:
#   nftables.service → dnsmasq.service → sshd.service
#
# Egress is an nftables IP allowlist that the guest's own resolver
# fills in as names are looked up (research-agent-egress.nix). sshd
# waits for the firewall, not for DNS: a host that is offline at guest
# boot gives a reachable VM whose outbound calls fail fast at name
# resolution, and they work again the moment connectivity returns.
# (History: until 2026-10 a retry-forever egress-init resolved the
# allowlist at boot and held sshd back until it could — see the
# 2026-07-07 offline-boot incident — and a 10-min refresh timer chased
# rotating IPs. Neither could keep up with Akamai's sub-minute TTLs.)
#
# Host MCP server reaches the VM via ssh on 127.0.0.1:2223 (port
# forward from SLIRP user-mode networking). Per-call isolation is
# enforced by bwrap inside the VM, exactly as in the docker era.
let
  # Captured here: inside the guest module below, `config` is the guest's.
  hostJonathanUid = config.users.users.jonathan.uid;
in
{
  microvm.vms.research-agent = {
    # Fully-declarative VM (`config` set inline below). The host's
    # `microvm.nixosModules.host` already injects the guest microvm
    # module for declarative VMs — importing it explicitly here would
    # define `microvm.runner.qemu` twice. `flake = ...` is mutually
    # exclusive with `config` and would fail assertion
    # `Fully-declarative VMs cannot also set a flake!`.
    config = { config, pkgs, ... }: {

      # Egress allowlist + the resolver that fills it (dnsmasq nftset).
      # The allowlist itself lives there.
      imports = [ ./research-agent-egress.nix ];

      microvm = {
        hypervisor = "qemu";
        vcpu = 2;
        # NOT 2048: qemu's microvm machine type serves a corrupt DSDT
        # when guest RAM ends exactly at the 2 GiB split boundary
        # (microvm-nix/microvm.nix#171, open since 2023). The guest
        # kernel busy-spins in acpi_tb_checksum before init — sshd
        # never starts, one host core pins at 100%, and the sshd
        # watchdog restart-loops forever. Latent until PR #111 added
        # the 4th virtiofs share (scraper-token), which grew the DSDT
        # enough to shift table placement into the bad region.
        # Empirically bounded 2026-06-05: 2047/2049/2560/3072/4096 all
        # emit a clean DSDT and boot; only exactly 2048 corrupts. 6144 is
        # well clear of that boundary. acpi=off is NOT a workaround
        # (drops the PCIe bridge; all virtio-*-pci devices fail).
        #
        # 4096 (was 6144): 6144 was over-sized. The 2026-07-31 4-concurrent
        # Opus/deep load test measured guest peak VmRSS at 1268 MiB (21% of
        # 6144); the earlier 2-concurrent cgroup measurement (in
        # research-agent/mcp_server/server.py comment above _VM_SLOTS_DEFAULT)
        # extrapolates ~0.43 GB per concurrent call, so the companion PR
        # bumping the slot cap to 6 (jonathanmoregard/research-agent#20)
        # projects peak baseline + 6*0.43 ≈ 3.3 GB. 4096 MiB gives ~+20%
        # buffer over that projected peak. Frees 2 GiB back to the host —
        # the OOM incident that motivated the swap+zram PR (#152) was
        # exactly this class of oversubscription. Still well clear of the
        # 2048 DSDT-corruption boundary noted above.
        #
        # 4224 (was 4096), 2026-10-04: research-agent now runs 2 concurrent
        # slots with a 1536 MiB per-call memguard cap, and its sizing
        # invariant `slots * cap + guest_base <= mem` needs
        # 2 * 1536 + ~1100 = 4172 MiB (research-agent scripts/lib/memguard.sh,
        # tests/test_memguard.py). 6 slots x 1536 MiB had broken it, so the
        # per-call cap could not stop VM-wide reclaim. Not near 2048.
        mem = 4224;

        shares = [
          {
            source = "/home/jonathan/Repos/research-agent";
            mountPoint = "/workspace";
            tag = "workspace";
            proto = "virtiofs";
            # RO so a prompt-injected agent cannot rewrite its own
            # CLAUDE.md / shims / scripts on the host. microvm.nix's
            # `shares` default is readOnly=false — the flag MUST be
            # set explicitly. (Verified via:
            # `nix eval .#nixosConfigurations.dellan.config.microvm.vms.research-agent.config.config.microvm.shares`.)
            readOnly = true;
          }
          {
            # /out is RW because the agent writes one report file per
            # call here; the host MCP server reads the file from this
            # virtiofs share after the agent exits.
            source = "/home/jonathan/Repos/research-agent/reports";
            mountPoint = "/out";
            tag = "out";
            proto = "virtiofs";
          }
          {
            # Persisted VM SSH host keys across reboots — required for
            # the host-side known_hosts pin (StrictHostKeyChecking=accept-new
            # in the MCP server's ssh command, pinned on first connect)
            # to remain valid across VM reboots. Without persistence
            # every boot would regenerate keys and the host would hit
            # REMOTE HOST IDENTIFICATION HAS CHANGED on the second call.
            # Backed by /var/lib/research-agent/vm-ssh on the host
            # (systemd.tmpfiles.rules in profiles/workstation/default.nix).
            source = "/var/lib/research-agent/vm-ssh";
            mountPoint = "/etc/ssh/keys";
            tag = "ssh-keys";
            proto = "virtiofs";
          }
          {
            # Persistent tool cache (PRV + Bolagsverket SQLite indexes).
            # RW: run-agent.sh binds this into the bwrap jail and points
            # PRV_CACHE_DIR / BOLAGSVERKET_CACHE_DIR at it, so the
            # ~888 MiB PRV index survives across calls instead of being
            # rebuilt per-jail into a RAM-backed tmpfs (which failed
            # with "database or disk is full"). Threat note: a
            # prompt-injected agent can poison the cached indexes
            # (false-negative trademark hits on later calls) but gains
            # no host code execution — same exposure class as /out.
            # Backed by /var/lib/research-agent/tool-cache on the host
            # (systemd.tmpfiles.rules in profiles/workstation/default.nix).
            source = "/var/lib/research-agent/tool-cache";
            mountPoint = "/tool-cache";
            tag = "tool-cache";
            proto = "virtiofs";
          }
          {
            # Bearer token for the scraper microvm's HTTP API. The file
            # lives on the host at /var/lib/scraper-bearer/token
            # (generated per-boot by scraper-bearer-init.service in
            # modules/nixos/scraper-microvm.nix). render_shim.py reads
            # /etc/scraper/token at call time.
            # readOnly=true: a prompt-injected agent inside the VM
            # cannot rotate the bearer out from under the scraper.
            source = "/var/lib/scraper-bearer";
            mountPoint = "/etc/scraper";
            tag = "scraper-token";
            proto = "virtiofs";
            readOnly = true;
          }
        ];

        interfaces = [
          {
            type = "user";
            id = "qemu0";
            mac = "02:00:00:00:00:01";
          }
        ];

        forwardPorts = [
          { from = "host"; host.port = 2223; guest.port = 22; proto = "tcp"; }
        ];
      };

      # System packages — replaces Dockerfile apt + pip layer.
      # Note: `exa-py` and `tavily-python` from the old Dockerfile are
      # dropped — both shims at agent/shims/{exa,tavily}_shim.py use
      # `curl_cffi` directly (bypasses the SDKs entirely).
      environment.systemPackages = with pkgs; [
        bubblewrap
        claude-code
        codex
        (python3.withPackages (ps: with ps; [ curl-cffi ]))
      ];

      # Agent uid = host jonathan's uid so virtiofs passthrough lines
      # up. Without this, files written to /out by the guest agent land
      # on the host with the wrong owner and the host MCP server can't
      # unlink them.
      users.users.agent = {
        isNormalUser = true;
        uid = hostJonathanUid;
        shell = pkgs.bashInteractive;
        openssh.authorizedKeys.keys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJTpnxCppc/riWtTthEqc6FDX3tHoJvPkVjiKACOYZUl research-agent-host-key"
          # jonathan@dellan operator key — debug ssh access only (the
          # data path is host-MCP-over-ssh-stdin, not human ssh). Listed
          # so feature-vm interactive smoke can reach the agent VM
          # without needing the agenix-decrypted research-agent-host-key
          # (which doesn't decrypt inside feature-vm because the
          # host-ssh 9p mount's identity isn't a secrets.nix recipient).
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINT9HeHhu82OoNsAHe/QAh116pSEANuZUr1h5m8R8kpp jonathan@dellan"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINy+08a1zu6ndn5RQ5TDV2uNrXJ+4lPmlcmmWXI8XH/8 jonathan@tuxedo"
        ];
      };

      services.openssh = {
        enable = true;
        # Persisted across boots via the virtiofs ssh-keys share.
        hostKeys = [
          { path = "/etc/ssh/keys/ssh_host_ed25519_key"; type = "ed25519"; }
        ];
        settings = {
          PasswordAuthentication = false;
          PermitRootLogin = "no";
        };
      };

      # sshd (the host MCP's only way in) never serves without the
      # firewall: Requires=/BindsTo= nftables, so a ruleset that failed
      # to load means no agent runs at all rather than one running with
      # an open output chain. It deliberately does NOT wait for DNS any
      # more: the allowlist is filled per lookup by dnsmasq
      # (research-agent-egress.nix), so there is nothing to pre-resolve,
      # and an offline host now means calls fail fast at name
      # resolution instead of sshd being held back.
      systemd.services.sshd = {
        after = [ "nftables.service" "dnsmasq.service" ];
        requires = [ "nftables.service" ];
        bindsTo = [ "nftables.service" ];
        wants = [ "dnsmasq.service" ];
      };

      # SLIRP uplink. Same DHCP the default 99-ethernet-default-dhcp
      # network would do (this one sorts first, so networkd uses it),
      # minus the DHCP-offered DNS server: resolved must ask dnsmasq
      # and only dnsmasq, or its answers bypass the egress set (see
      # research-agent-egress.nix). IPv4 only, matching enableIPv6 below.
      systemd.network.networks."10-uplink" = {
        matchConfig.Type = "ether";
        networkConfig.DHCP = "ipv4";
        dhcpV4Config.UseDNS = false;
      };

      networking.hostName = "research-agent";

      # Disable IPv6 inside the guest. The egress allowlist set
      # (research_allowed, type ipv4_addr) only covers v4, and
      # dnsmasq only inserts A records into it (nftset `4#`). If SLIRP ever
      # advertised a v6 resolver (some QEMU configs expose fec0::3),
      # the agent's resolver would prefer AAAA per RFC 6724, wait for
      # the v6 connect to time out against the chain's default drop,
      # then fall back to A — adding 5-10 s to every first connect.
      # Matches the docker-era behavior (containers were v4-only).
      networking.enableIPv6 = false;

      system.stateVersion = "25.11";
    };
  };
}
