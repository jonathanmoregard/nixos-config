{ config, lib, pkgs, ... }:
# research-agent microvm — replaces the docker-based
# research-agent-container.service.
#
# Lifecycle: microvm.nix synthesizes microvm@research-agent.service
# from this declaration. Boot order inside the guest:
#   network-online.target → nftables.service →
#   research-agent-egress-init.service → sshd.service
#
# sshd is gated on egress-init via Requires=/After=. egress-init never
# hard-fails on DNS: it retries forever with capped backoff, so a host
# that is offline at guest boot surfaces as `Connection refused` (sshd
# not up YET) and self-heals the moment connectivity returns — no
# operator, no watchdog restart needed. (2026-07-07 incident: the old
# 5-retry/exit-1 design turned an offline laptop into a failed sshd,
# a give-up-latched watchdog, and a false "VM DOWN" alert.)
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
        # NOT 2048: qemu's microvm machine type serves a corrupt DSDT
        # when guest RAM ends exactly at the 2 GiB split boundary
        # (microvm-nix/microvm.nix#171, open since 2023). The guest
        # kernel busy-spins in acpi_tb_checksum before init — sshd
        # never starts, one host core pins at 100%, and the sshd
        # watchdog restart-loops forever. Latent until PR #111 added
        # the 4th virtiofs share (scraper-token), which grew the DSDT
        # enough to shift table placement into the bad region.
        # Empirically bounded 2026-06-05: 2047/2049/2560/3072/4096 all
        # emit a clean DSDT and boot; only exactly 2048 corrupts.
        # 3072 matches the scraper VM. acpi=off is NOT a workaround
        # (drops the PCIe bridge; all virtio-*-pci devices fail).
        mem = 3072;

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
            # (systemd.tmpfiles.rules in hosts/dellan/default.nix).
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
        # Requires= propagates explicit restarts (verified empirically
        # with toy units 2026-07-07: restarting the dependency restarts
        # the dependent), so an nftables reload can never leave sshd
        # serving against a flushed allowlist. bindsTo additionally
        # covers non-job deactivations of egress-init — belt and braces.
        bindsTo = [ "research-agent-egress-init.service" ];
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
          # The retry-forever loop in the script may legitimately run
          # for hours (laptop offline). The 90s default would kill the
          # unit and re-create the dead-sshd incident this design
          # exists to prevent.
          TimeoutStartSec = "infinity";
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
          # -e deliberately absent: a failing getent inside the retry
          # loop IS the expected offline case, not an error. -u and
          # pipefail stay.
          set -uo pipefail

          ALLOWED=(
            api.anthropic.com
            api.exa.ai
            mcp.exa.ai
            api.tavily.com
            mcp.tavily.com
            # Trademark-clearance shims (agent/shims/{trademark,bolagsverket}
            # _shim.py in the research-agent repo). Added to the agent in
            # 2026-06 but never to this allowlist — every call dialled out,
            # hit dropped packets, and hung to its client timeout (EUIPO
            # curl-28 after 30s, bolagsverket urllib after 120s), burning
            # whole research budgets on dead waits.
            # EUIPO sandbox (in use until the production subscription is
            # approved):
            auth-sandbox.euipo.europa.eu
            api-sandbox.euipo.europa.eu
            # EUIPO production (pre-added so the sandbox->prod flip is a
            # shim-env change, not another firewall PR):
            euipo.europa.eu
            api.euipo.europa.eu
            # Bolagsverket open-data bulk file (CC-BY, weekly refresh):
            vardefulla-datamangder.bolagsverket.se
            # PRV open-data FTP (Swedish national trademark register;
            # sanctioned bulk channel used by prv_shim). NOTE: FTP —
            # control on :21 plus PASV data connections to the same
            # host on ephemeral ports; the allowlist is IP-based so
            # PASV lands on the same allowed IPs, and outbound
            # ESTABLISHED/RELATED handles the rest.
            opendata.prv.se
          )

          # Never hard-fail on DNS. This unit gates sshd (Requires=),
          # so exiting non-zero turns a flaky uplink into a VM that
          # needs an operator. Instead: insert what resolves
          # incrementally (partial connectivity opens what it can) and
          # retry the rest forever with capped backoff. sshd starts
          # only once the FULL allowlist is populated — the security
          # posture is unchanged, just patient. Pairs with
          # TimeoutStartSec=infinity above and the host watchdog's
          # offline gate (research-agent-microvm-healthcheck.nix).
          # Contract enforced by checks.egress-init-retry.

          # Idempotent: flush the set so re-runs don't accumulate.
          nft flush set inet filter research_allowed || true

          declare -A RESOLVED=()
          attempt=0
          while :; do
            missing=0
            for d in "''${ALLOWED[@]}"; do
              [ -n "''${RESOLVED[$d]:-}" ] && continue
              # /STREAM/ filter: getent ahostsv4 emits STREAM/DGRAM/RAW
              # triplets per IP; unfiltered $1 would also swallow any
              # oddball non-address lines.
              if ips=$(getent ahostsv4 "$d" | awk '/STREAM/{print $1}' | sort -u) \
                 && [ -n "$ips" ]; then
                while IFS= read -r ip; do
                  [ -z "$ip" ] && continue
                  # Log nft failures instead of swallowing them — a set
                  # that's missing mid-reload is worth seeing in the
                  # journal even though the retry architecture and
                  # sshd's BindsTo make it non-fatal.
                  nft add element inet filter research_allowed { $ip } \
                    || echo "[egress-init] WARN: nft add $ip ($d) failed" >&2
                  echo "[egress-init] allow $d -> $ip"
                done <<< "$ips"
                RESOLVED[$d]=1
              else
                missing=$((missing + 1))
              fi
            done
            [ "$missing" -eq 0 ] && break
            attempt=$((attempt + 1))
            if [ "$attempt" -lt 12 ]; then
              sleep_s=$((attempt * 5))
            else
              sleep_s=60
            fi
            echo "[egress-init] $missing domain(s) unresolved (attempt $attempt) — host offline? retrying in ''${sleep_s}s" >&2
            sleep "$sleep_s"
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
