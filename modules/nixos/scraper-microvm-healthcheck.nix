{ config, lib, pkgs, ... }:
# Host-side liveness watchdog for microvm@scraper.service.
#
# Mirrors research-agent-microvm-healthcheck.nix. Probes the scraper VM's
# sshd on host port 2225 once per minute via `ssh-keyscan` (no auth, no
# known_hosts mutation — just protocol banner) and restarts
# microvm@scraper.service after 3 consecutive failures. Cooldown gate
# prevents thrash if a restart fails to fix the issue.
#
# Why a separate watchdog from research-agent's:
#   - Independent failure domains. The scraper VM runs a fresh chromium
#     per request and is the much heavier workload — more likely to wedge
#     under memory pressure (MemoryMax=2G in scraper-microvm.nix) than the
#     agent VM is.
#   - One unit per VM keeps the systemctl-restart action target-precise.
#     A combined watchdog would either restart both VMs on either VM's
#     trouble or skew the timer cadence.
#
# Probe is ssh-keyscan against :2225 not curl against :8123 because the
# scraper HTTP endpoint requires a bearer (which the watchdog must NOT
# read — its job is liveness, not auth-correctness). sshd banner reachable
# == VM userspace alive; the qemu hostfwd that breaks the HTTP API path
# would also break sshd, so this probe catches both failure modes.
#
# Defense-in-depth: this is the safety net. The microvm config remains
# the primary path; if it boots and stays healthy, this script is a no-op
# forever (just one journal line per minute saying "ok").
{
  systemd.tmpfiles.rules = [
    "d /run/scraper-healthcheck 0700 root root -"
  ];

  systemd.services.scraper-healthcheck = {
    description = "Probe scraper microvm sshd and restart on persistent failure";
    serviceConfig = {
      Type = "oneshot";
      # systemctl restart of the microvm unit requires root.
      User = "root";
      # Bound the oneshot's wall time. Stuck script != stuck watchdog —
      # fail fast, next timer tick retries.
      TimeoutStartSec = "30s";
    };
    path = [ pkgs.openssh pkgs.systemd pkgs.coreutils ];
    script = ''
      set -u

      STATE_DIR=/run/scraper-healthcheck
      COUNT_FILE="$STATE_DIR/fail-count"
      LAST_RESTART_FILE="$STATE_DIR/last-restart-epoch"
      THRESHOLD=3
      # 5-min cooldown — same rationale as research-agent watchdog:
      # tight-looping restarts on a deeply broken VM burns disk and
      # clutters the journal; operator gets visible breathing room.
      COOLDOWN_S=300

      mkdir -p "$STATE_DIR"

      # Read a non-negative integer from a state file. Strips everything
      # except digits and clamps to 12 chars. Empty / non-existent /
      # corrupted input → 0. Under `set -u`, unsanitized arithmetic on
      # non-numeric input aborts the script and bricks the watchdog —
      # one bad byte on disk = no more restarts. This guard makes that
      # impossible. Mirrors the read_int in research-agent-microvm-healthcheck.nix.
      read_int() {
        local v
        v=$(cat "$1" 2>/dev/null | tr -cd '0-9' | head -c 12)
        [ -z "$v" ] && v=0
        printf '%s' "$v"
      }

      # State machine — same shape as research-agent watchdog. Only
      # 'active' / 'failed' warrant attention; 'inactive' is operator
      # action (silently exit), 'activating' / 'deactivating' are
      # transient and systemd's own timeouts handle them.
      state=$(systemctl is-active microvm@scraper.service 2>/dev/null || true)
      case "$state" in
        active) ;;
        failed)
          now=$(date +%s)
          last=$(read_int "$LAST_RESTART_FILE")
          since_last=$((now - last))
          if [ "$since_last" -lt "$COOLDOWN_S" ]; then
            echo "healthcheck: unit failed but cooldown active (''${since_last}s < ''${COOLDOWN_S}s); not restarting"
            exit 0
          fi
          echo "healthcheck: unit is failed; restarting (cooldown elapsed)"
          echo "$now" > "$LAST_RESTART_FILE"
          echo 0 > "$COUNT_FILE"
          systemctl restart --no-block microvm@scraper.service
          exit 0
          ;;
        *)
          exit 0
          ;;
      esac

      count=$(read_int "$COUNT_FILE")

      # ssh-keyscan does the protocol banner exchange only — no auth,
      # no known_hosts mutation. -T sets the connect timeout. Piping to
      # grep ensures we got a real key line, not just an empty response.
      if ssh-keyscan -p 2225 -T 5 127.0.0.1 2>/dev/null | grep -q '^[^#]'; then
        if [ "$count" -gt 0 ]; then
          echo "healthcheck: recovered after $count consecutive failures"
        fi
        echo 0 > "$COUNT_FILE"
        exit 0
      fi

      count=$((count + 1))
      echo "$count" > "$COUNT_FILE"
      echo "healthcheck: probe failed ($count/$THRESHOLD)"

      if [ "$count" -lt "$THRESHOLD" ]; then
        exit 0
      fi

      now=$(date +%s)
      last=$(read_int "$LAST_RESTART_FILE")
      since_last=$((now - last))
      if [ "$since_last" -lt "$COOLDOWN_S" ]; then
        echo "healthcheck: threshold hit but cooldown active (''${since_last}s < ''${COOLDOWN_S}s); not restarting"
        exit 0
      fi

      echo "healthcheck: restarting microvm@scraper.service after $count consecutive failures"
      echo "$now" > "$LAST_RESTART_FILE"
      echo 0 > "$COUNT_FILE"
      systemctl restart --no-block microvm@scraper.service
    '';
  };

  systemd.timers.scraper-healthcheck = {
    description = "Periodic liveness probe for scraper microvm sshd";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # 5-min boot delay so the VM has a fair chance to come up on a
      # cold start before the first probe fires.
      OnBootSec = "5min";
      OnUnitActiveSec = "1min";
      Persistent = false;
      Unit = "scraper-healthcheck.service";
    };
  };
}
