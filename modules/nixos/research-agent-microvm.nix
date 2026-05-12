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
          }
          {
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
            }
          }
        '';
      };

      systemd.services.research-agent-egress-init = {
        description = "Resolve allowlist FQDNs and populate nftables set";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" "nftables.service" ];
        wants = [ "network-online.target" ];
        requires = [ "nftables.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        path = [ pkgs.nftables pkgs.glibc pkgs.coreutils pkgs.gawk ];
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
