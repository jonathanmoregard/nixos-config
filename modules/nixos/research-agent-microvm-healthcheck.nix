{ config, lib, pkgs, ... }:
# Host-side liveness watchdog for microvm@research-agent.service.
#
# Why this exists: research-agent's microvm has been observed entering
# emergency mode after a guest warm-reboot. qemu's `-no-reboot` reliably
# catches ACPI-path reboots but not triple-fault reboots (kernel cmdline
# `reboot=t`) on the microvm machine type — the guest CPUs warm-reset
# while the qemu process keeps running, then the second boot's PCI
# enumeration fails on the microvm chassis (no ACPI tables → no host
# bridge re-init) and `/dev/disk/by-label/nix-store` never materializes
# → 1m30s wait → emergency shell. sshd never starts; the host MCP
# server sees `kex_exchange_identification: Connection reset by peer`
# ~75s after every research() call (qemu user-mode SLIRP SYN-retransmit
# window). The systemd unit's `Restart=always` doesn't fire because
# qemu itself is alive.
#
# This watchdog probes sshd inside the guest once per minute via
# `ssh-keyscan` (no auth, no key material, just the protocol banner)
# and restarts microvm@research-agent.service after 3 consecutive
# failures. Cooldown gate prevents thrash if a restart fails to fix
# the issue.
#
# Defense-in-depth: this is the safety net. The microvm config remains
# the primary path; if it boots and stays healthy, this script is a
# no-op forever (just one journal line per minute saying "ok").
{
  systemd.tmpfiles.rules = [
    "d /run/research-agent-healthcheck 0700 root root -"
  ];

  systemd.services.research-agent-healthcheck = {
    description = "Probe research-agent microvm sshd and restart on persistent failure";
    # `simple` would be wrong — the script runs to completion and exits.
    # Timer re-arms it. Restart=no so a single probe-script bug doesn't
    # turn into a restart loop on top of the restart-loop guard inside.
    serviceConfig = {
      Type = "oneshot";
      # systemctl restart of the microvm unit requires root.
      User = "root";
      # Bound the oneshot's wall time. Even with --no-block on the
      # restart call, ssh-keyscan + systemctl probes should finish
      # well under 30s. Stuck script ≠ stuck watchdog — fail fast,
      # next timer tick retries.
      TimeoutStartSec = "30s";
    };
    path = [ pkgs.openssh pkgs.systemd pkgs.coreutils ];
    script = ''
      set -u

      STATE_DIR=/run/research-agent-healthcheck
      COUNT_FILE="$STATE_DIR/fail-count"
      LAST_RESTART_FILE="$STATE_DIR/last-restart-epoch"
      THRESHOLD=3
      # 5-min cooldown: a real fix takes one restart; if a restart
      # didn't help, restarting again 60s later won't either, and
      # tight-looping restarts on a deeply broken VM just burns disk
      # and clutters the journal. Operator gets visible breathing room
      # to look.
      #
      # State lives in /run (tmpfs) — wiped on host reboot. That's
      # intentional: host boot is itself a much longer cooldown than
      # 5min and the new microvm comes up fresh, so any pre-reboot
      # restart history is meaningless. Don't move to /var/lib without
      # also adding a max-age check, or a stale last-restart-epoch from
      # days ago will gate out a legitimate restart.
      COOLDOWN_S=300

      mkdir -p "$STATE_DIR"

      # Read a non-negative integer from a state file. Strips
      # everything except digits and clamps to 12 chars (comfortably
      # covers unix epochs through year 33658 and any plausible
      # fail-count). Empty / non-existent / corrupted input → 0.
      # Under `set -u`, an unsanitized `count=$((count+1))` on
      # non-numeric input aborts the script with "unbound variable"
      # or "syntax error" and bricks the watchdog forever — one bad
      # byte on disk = no more restarts. This guard makes that
      # impossible.
      read_int() {
        local v
        v=$(cat "$1" 2>/dev/null | tr -cd '0-9' | head -c 12)
        [ -z "$v" ] && v=0
        printf '%s' "$v"
      }

      # The microvm unit can be in one of several states; only some
      # warrant attention from the watchdog:
      #   active      → probe sshd; restart if persistently dead
      #   failed      → systemd has given up retrying (Restart=always
      #                 exhausted); we are the recovery path. Treat
      #                 like a probe-failure cycle: restart subject
      #                 to cooldown.
      #   inactive    → operator stopped it (or install-microvm
      #                 hasn't run yet) — not our problem, exit 0
      #                 silently to avoid fighting an admin action.
      #   activating  → boot in progress; systemd's own
      #                 TimeoutStartSec handles a stuck activation.
      #   deactivating→ stop in progress; ditto.
      state=$(systemctl is-active microvm@research-agent.service 2>/dev/null || true)
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
          systemctl restart --no-block microvm@research-agent.service
          exit 0
          ;;
        *)
          exit 0
          ;;
      esac

      count=$(read_int "$COUNT_FILE")

      # ssh-keyscan does the protocol banner exchange only — no auth,
      # no known_hosts mutation (-T sets the connect timeout). Piping
      # to grep ensures we got a real key line, not just an empty
      # response. The exact key value is uninteresting; presence is
      # the signal that sshd is alive.
      if ssh-keyscan -p 2223 -T 5 127.0.0.1 2>/dev/null | grep -q '^[^#]'; then
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

      # --no-block returns immediately after queuing the restart job
      # instead of waiting for activation. Two reasons:
      #   1. The oneshot stays short (a few seconds), which keeps the
      #      1-min timer cadence intact. A blocking restart that takes
      #      90s would suppress the next timer tick and let stuck
      #      activations pile up as queued probe jobs.
      #   2. The next timer tick observes whatever state the unit has
      #      reached — `activating` no-ops silently, `active` probes
      #      sshd, `failed` re-enters the failed-state branch above.
      #      No need to block here just to confirm what the next probe
      #      will see anyway.
      echo "healthcheck: restarting microvm@research-agent.service after $count consecutive failures"
      echo "$now" > "$LAST_RESTART_FILE"
      echo 0 > "$COUNT_FILE"
      systemctl restart --no-block microvm@research-agent.service
    '';
  };

  systemd.timers.research-agent-healthcheck = {
    description = "Periodic liveness probe for research-agent microvm sshd";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # 5-min boot delay so the VM has a fair chance to come up on a
      # cold start before the first probe fires.
      OnBootSec = "5min";
      OnUnitActiveSec = "1min";
      # Persistent=false: missed timers (suspend, host downtime) should
      # not all fire at once on resume — a single probe is enough.
      Persistent = false;
      Unit = "research-agent-healthcheck.service";
    };
  };
}
