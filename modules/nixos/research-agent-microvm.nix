{ config, lib, pkgs, ... }:
# research-agent microvm — replaces the docker-based
# research-agent-container.service.
#
# Lifecycle: microvm.nix synthesizes microvm@research-agent.service
# from this declaration. Boot order inside the guest:
#   network-online.target → nftables.service →
#   research-agent-egress-init.service → sshd.service
#
# sshd is gated on egress-init via Requires=, so a DNS-resolution
# failure surfaces as `Connection refused` from the host MCP server's
# SSH call rather than a 10-minute silent timeout.
#
# Host MCP server reaches the VM via ssh on 127.0.0.1:2223 (port
# forward from SLIRP user-mode networking). Per-call isolation is
# enforced by bwrap inside the VM, exactly as in the docker era.
{
  microvm.vms.research-agent = {
    # Fully-declarative VM (`config` set inline below). The host's
    # `microvm.nixosModules.host` already injects the guest microvm
    # module for declarative VMs — importing it explicitly here would
    # define `microvm.runner.qemu` twice. `flake = ...` is mutually
    # exclusive with `config` and would fail assertion
    # `Fully-declarative VMs cannot also set a flake!`.
    config = { config, pkgs, ... }: {

      microvm = {
        hypervisor = "qemu";
        vcpu = 2;
        mem = 2048;

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
            # (systemd.tmpfiles.rules in hosts/dellan/default.nix).
            source = "/var/lib/research-agent/vm-ssh";
            mountPoint = "/etc/ssh/keys";
            tag = "ssh-keys";
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
        (python3.withPackages (ps: with ps; [ curl-cffi ]))
      ];

      # Pin agent uid to 1000 so virtiofs passthrough lines up with
      # host jonathan. Without this, files written to /out by the
      # guest agent land on the host with the wrong owner and the
      # host MCP server can't unlink them.
      users.users.agent = {
        isNormalUser = true;
        uid = 1000;
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

      # SSH only listens after the egress allowlist is populated.
      # Requires= (not Wants=) means a failed egress-init transitions
      # sshd to `failed`, surfacing as `Connection refused` at the host
      # MCP server rather than a silent 10-minute timeout.
      systemd.services.sshd = {
        after = [ "research-agent-egress-init.service" ];
        requires = [ "research-agent-egress-init.service" ];
      };

      # Egress allowlist — declarative nftables, populated at boot.
      networking.nftables = {
        enable = true;
        ruleset = ''
          table inet filter {
            set research_allowed {
              type ipv4_addr
              flags interval
            }

            chain input {
              type filter hook input priority 0; policy drop;
              iif lo accept
              ct state established,related accept
              tcp dport 22 accept
            }

            chain output {
              type filter hook output priority 0; policy drop;
              oif lo accept
              ct state established,related accept
              udp dport 53 accept
              tcp dport 53 accept
              ip daddr @research_allowed tcp dport 443 accept
              # Scraper microvm HTTP API. 10.0.2.2 is the SLIRP host
              # gateway from inside this VM (qemu user-mode default).
              # The host's forwardPorts rule on the scraper VM exposes
              # the scraper's guest port 8000 at host loopback :8123,
              # so this rule lets the agent's render_shim reach the
              # scraper without widening the broader egress allowlist.
              ip daddr 10.0.2.2 tcp dport 8123 accept
            }
          }
        '';
      };

      systemd.services.research-agent-egress-init = {
        description = "Resolve allowlist FQDNs and populate nftables set";
        wantedBy = [ "multi-user.target" "nftables.service" ];
        after = [ "network-online.target" "nftables.service" ];
        wants = [ "network-online.target" ];
        requires = [ "nftables.service" ];
        # PartOf=nftables.service so when nftables reloads (every
        # nixos-rebuild switch atomically re-applies the ruleset and
        # recreates the `research_allowed` set empty), egress-init is
        # restarted in the same transaction and repopulates the set
        # before the new ruleset goes live. Without this, a switch
        # mid-flight on the host wipes the allowlist; ESTABLISHED
        # flows survive via conntrack, but new outbound connections
        # hit policy=drop until the operator manually restarts
        # egress-init.
        partOf = [ "nftables.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        # pkgs.getent (a separate small derivation) provides the
        # `getent` binary. `glibc.bin` on current nixpkgs does NOT
        # ship getent — it has gencat/getconf/iconv/locale/etc. but
        # the resolver tool lives in its own attr. Verified by
        # `ls $(nix eval --raw .#pkgs.glibc.bin)/bin`.
        # Without this, the script fails on every domain with
        # `getent: command not found`, exhausts retries, exits 1, and
        # cascades sshd into `failed` via the Requires= above.
        path = [ pkgs.nftables pkgs.getent pkgs.coreutils pkgs.gawk ];
        script = ''
          set -euo pipefail

          ALLOWED=(
            api.anthropic.com
            api.exa.ai
            mcp.exa.ai
            api.tavily.com
            mcp.tavily.com
          )

          DNS_RETRIES=5
          DNS_RETRY_SLEEP=2

          resolve_or_die() {
            local domain="$1" attempt ips
            for ((attempt=1; attempt<=DNS_RETRIES; attempt++)); do
              ips=$(getent ahostsv4 "$domain" | awk '{print $1}' | sort -u)
              if [ -n "$ips" ]; then
                printf '%s\n' "$ips"
                return 0
              fi
              if [ $attempt -lt $DNS_RETRIES ]; then
                echo "[egress-init] DNS miss for $domain ($attempt/$DNS_RETRIES), retrying in $DNS_RETRY_SLEEP s" >&2
                sleep $DNS_RETRY_SLEEP
              fi
            done
            echo "[egress-init] ERROR: failed to resolve $domain after $DNS_RETRIES attempts" >&2
            return 1
          }

          # Idempotent: flush the set so re-runs don't accumulate.
          nft flush set inet filter research_allowed || true

          for d in "''${ALLOWED[@]}"; do
            ips=$(resolve_or_die "$d") || exit 1
            while IFS= read -r ip; do
              [ -z "$ip" ] && continue
              nft add element inet filter research_allowed { $ip } || true
              echo "[egress-init] allow $d -> $ip"
            done <<< "$ips"
          done

          echo "[egress-init] firewall active"
        '';
      };

      networking.hostName = "research-agent";

      # Disable IPv6 inside the guest. The egress allowlist set
      # (research_allowed, type ipv4_addr) only covers v4, and
      # egress-init resolves with `getent ahostsv4`. If SLIRP ever
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
