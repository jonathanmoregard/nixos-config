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
# Give-up latch + desktop notification: mirrors
# research-agent-microvm-healthcheck.nix — after GIVEUP_AFTER
# consecutive fruitless restarts the watchdog stops restarting,
# latches gave-up in /run, and fires a critical notification via the
# flag-file + PathChanged user-unit chain. A later healthy probe
# clears the latch and re-arms.
#
# Defense-in-depth: this is the safety net. The microvm config remains
# the primary path; if it boots and stays healthy, this script is a no-op
# forever (just one journal line per minute saying "ok").
{
  systemd.tmpfiles.rules = [
    "d /run/scraper-healthcheck 0700 root root -"
    # Shared world-readable flag dir for watchdog notifications; same
    # rule as in research-agent-microvm-healthcheck.nix.
    "d /run/microvm-healthcheck-notify 0755 root root -"
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
      BURST_FILE="$STATE_DIR/restart-burst-count"
      GAVEUP_FILE="$STATE_DIR/gave-up"
      NOTIFY_FILE=/run/microvm-healthcheck-notify/scraper
      THRESHOLD=3
      # Consecutive watchdog restarts with no healthy probe in between
      # before giving up — see research-agent twin for rationale.
      GIVEUP_AFTER=2
      # Hourly notify re-touch while given up — see research-agent twin.
      RENOTIFY_S=3600
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

      # Restart the VM unless the burst budget is exhausted — mirrors
      # the research-agent twin; see that file for full rationale.
      restart_or_give_up() {
        local why="$1" now burst
        now=$(date +%s)
        burst=$(read_int "$BURST_FILE")
        if [ "$burst" -ge "$GIVEUP_AFTER" ]; then
          mkdir -p "''${NOTIFY_FILE%/*}" 2>/dev/null || true
          if [ ! -e "$GAVEUP_FILE" ]; then
            : > "$GAVEUP_FILE"
            date +%s > "$NOTIFY_FILE" || true
            echo "healthcheck: GIVING UP after $burst restarts without recovery; not restarting again. Inspect: journalctl -u microvm@scraper.service; recover: systemctl restart microvm@scraper.service"
          else
            last_notify=$(read_int "$NOTIFY_FILE")
            if [ $((now - last_notify)) -ge "$RENOTIFY_S" ]; then
              date +%s > "$NOTIFY_FILE" || true
            fi
            echo "healthcheck: given up ($burst restarts without recovery); awaiting operator"
          fi
          exit 0
        fi
        echo "$why"
        echo "$now" > "$LAST_RESTART_FILE"
        echo 0 > "$COUNT_FILE"
        echo $((burst + 1)) > "$BURST_FILE"
        systemctl restart --no-block microvm@scraper.service
        exit 0
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
          restart_or_give_up "healthcheck: unit is failed; restarting (cooldown elapsed)"
          ;;
        *)
          exit 0
          ;;
      esac

      count=$(read_int "$COUNT_FILE")

      # ssh-keyscan does the protocol banner exchange only — no auth,
      # no known_hosts mutation. -T sets the connect timeout. Piping to
      # grep ensures we got a real key line, not just an empty response.
      # -T 10 (was 5): journal 2026-06-05 shows this probe flapping on a
      # healthy-but-busy VM (probe failed 1/3 → recovered, repeatedly),
      # killing a warm guest every ~15min once 3 misses lined up. The
      # scraper renders JS with chromium on 2 vcpus — banner latency
      # spikes past 5s under load are routine, not a liveness signal.
      if ssh-keyscan -p 2225 -T 10 127.0.0.1 2>/dev/null | grep -q '^[^#]'; then
        if [ "$count" -gt 0 ]; then
          echo "healthcheck: recovered after $count consecutive failures"
        fi
        if [ -e "$GAVEUP_FILE" ] || [ "$(read_int "$BURST_FILE")" -gt 0 ]; then
          echo "healthcheck: VM healthy; clearing restart-burst/give-up state"
          rm -f "$GAVEUP_FILE"
          echo 0 > "$BURST_FILE"
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

      restart_or_give_up "healthcheck: restarting microvm@scraper.service after $count consecutive failures"
    '';
  };

  # Desktop notification chain for the give-up latch — flag-file +
  # PathChanged user-unit pattern, mirroring the research-agent twin.
  systemd.user.paths.scraper-healthcheck-notify = {
    wantedBy = [ "default.target" ];
    pathConfig.PathChanged = "/run/microvm-healthcheck-notify/scraper";
  };
  systemd.user.services.scraper-healthcheck-notify = {
    description = "Desktop notification: scraper microvm watchdog gave up";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "scraper-healthcheck-notify" ''
        ${pkgs.libnotify}/bin/notify-send -u critical "scraper VM DOWN" \
          "Watchdog gave up after repeated fruitless restarts. Inspect: journalctl -u microvm@scraper.service — recover: sudo systemctl restart microvm@scraper.service (watchdog re-arms on recovery)."
      '';
    };
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
