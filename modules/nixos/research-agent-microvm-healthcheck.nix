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
# Give-up latch: restarting can only fix transient wedges. If two
# consecutive watchdog restarts both fail to bring sshd back, the
# breakage is persistent (bad deploy, qemu bug, corrupted state) and
# further restarts just burn a host core per boot attempt — exactly
# what happened 2026-06-04..05, when the microvm-nix#171 DSDT bug
# wedged every boot pre-init and the watchdog restart-looped a
# CPU-pinning guest 62×/6h in silence. After GIVEUP_AFTER fruitless
# restarts the watchdog stops restarting, latches gave-up state in
# /run, and fires a critical desktop notification (flag file +
# PathChanged user unit — same pattern as nixos-auto-deploy.nix). A
# later successful probe (e.g. operator restart or fixed deploy)
# clears the latch and re-arms everything automatically.
#
# Offline gate: a probe failure while the HOST has no DNS is not
# counted at all — the guest is just waiting for the network (see the
# retry-forever egress-init) and heals itself on reconnect; restarting
# or latching would manufacture a false outage out of a missing WiFi.
#
# Defense-in-depth: this is the safety net. The microvm config remains
# the primary path; if it boots and stays healthy, this script is a
# no-op forever (just one journal line per minute saying "ok").
{
  systemd.tmpfiles.rules = [
    "d /run/research-agent-healthcheck 0700 root root -"
    # Notify flag files live in a world-readable dir (separate from the
    # 0700 state dir) so the user-session path unit can inotify-watch
    # them. Shared by both microvm watchdogs; created by whichever
    # module lands first (tmpfiles dedupes identical rules).
    "d /run/microvm-healthcheck-notify 0755 root root -"
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
    path = [ pkgs.openssh pkgs.systemd pkgs.coreutils pkgs.getent pkgs.bash ];
    script = ''
      set -u

      STATE_DIR=/run/research-agent-healthcheck
      COUNT_FILE="$STATE_DIR/fail-count"
      LAST_RESTART_FILE="$STATE_DIR/last-restart-epoch"
      BURST_FILE="$STATE_DIR/restart-burst-count"
      GAVEUP_FILE="$STATE_DIR/gave-up"
      NOTIFY_FILE=/run/microvm-healthcheck-notify/research-agent
      THRESHOLD=3
      # Consecutive watchdog restarts with no healthy probe in between
      # before giving up. 2 = "a restart didn't fix it, and neither did
      # the restart after that" — at that point the failure is
      # persistent and restart #3 won't differ.
      GIVEUP_AFTER=2
      # Re-touch the notify flag this often while given up. PathChanged
      # only sees writes that happen while a user session is watching —
      # a give-up latched on an unattended boot would otherwise notify
      # into the void once and never again. Hourly = at most one
      # notification per hour of ongoing outage, no per-minute spam.
      RENOTIFY_S=3600
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

      # Restart the VM unless the burst budget is exhausted. $1 is the
      # journal line explaining why. Burst counts consecutive watchdog
      # restarts with no healthy probe in between; a successful probe
      # resets it. Past GIVEUP_AFTER, latch gave-up, fire the desktop
      # notification once (flag-file write; PathChanged user unit sends
      # the actual notify-send), and stop restarting until an operator
      # or a fixed deploy brings sshd back.
      restart_or_give_up() {
        local why="$1" now burst
        now=$(date +%s)
        burst=$(read_int "$BURST_FILE")
        if [ "$burst" -ge "$GIVEUP_AFTER" ]; then
          # tmpfiles creates this dir, but don't depend on ordering on a
          # fresh boot — a lost mkdir here means a lost notification.
          mkdir -p "''${NOTIFY_FILE%/*}" 2>/dev/null || true
          if [ ! -e "$GAVEUP_FILE" ]; then
            : > "$GAVEUP_FILE"
            date +%s > "$NOTIFY_FILE" || true
            echo "healthcheck: GIVING UP after $burst restarts without recovery; not restarting again. Inspect: journalctl -u microvm@research-agent.service; recover: systemctl restart microvm@research-agent.service"
          else
            # NOTIFY_FILE holds the epoch of the last notification —
            # re-touch when stale so a session that appears after the
            # latch still hears about the outage.
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
        systemctl restart --no-block microvm@research-agent.service
        exit 0
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
          restart_or_give_up "healthcheck: unit is failed; restarting (cooldown elapsed)"
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
      # -T 10 (was 5): the scraper twin's probe showed intermittent
      # false negatives on a healthy-but-busy VM at -T 5, each costing
      # a spurious restart of a warm guest. Banner exchange is cheap;
      # the bigger budget only delays detection of a truly dead VM by
      # seconds. Still well inside the unit's TimeoutStartSec=30s.
      if ssh-keyscan -p 2223 -T 10 127.0.0.1 2>/dev/null | grep -q '^[^#]'; then
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

      # Probe failed. If the HOST itself can't resolve, we're offline —
      # the guest's egress-init (retry-forever; research-agent-microvm.nix)
      # is deliberately holding sshd back until connectivity returns and
      # will self-heal on its own. A VM restart cannot help and would
      # burn the give-up budget on a false alarm (2026-07-07 incident:
      # offline boot → 26 failed probes → 2 futile restarts → give-up
      # latch + CRITICAL "VM DOWN" while the only real problem was no
      # WiFi). Don't count, don't restart; reset the streak so
      # post-reconnect failures need three fresh strikes.
      # Two-stage beacon: DNS alone lies behind captive portals (the
      # portal resolves every name to itself), which would re-arm the
      # restart/give-up path in exactly the offline situation this gate
      # exists for. Demand a real TCP handshake to :443 as well.
      # --kill-after: glibc NSS lookups can shrug off SIGTERM while
      # blocked in the resolver; force SIGKILL so a hung resolver can't
      # eat the oneshot's 30s budget.
      host_online() {
        timeout --kill-after=2 5 getent ahostsv4 api.anthropic.com >/dev/null 2>&1 \
          || return 1
        timeout --kill-after=2 5 bash -c 'exec 3<>/dev/tcp/api.anthropic.com/443' 2>/dev/null \
          || return 1
        return 0
      }
      if ! host_online; then
        echo "healthcheck: probe failed but host is offline; guest egress-init is waiting for network — not counting"
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
      restart_or_give_up "healthcheck: restarting microvm@research-agent.service after $count consecutive failures"
    '';
  };

  # Desktop notification chain for the give-up latch. Same flag-file +
  # PathChanged pattern as nixos-auto-deploy.nix: the root watchdog
  # touches the flag, the user-session path unit fires notify-send on
  # the session bus. PathChanged (not PathExists) so the flag can
  # persist without retrigger-looping.
  systemd.user.paths.research-agent-healthcheck-notify = {
    wantedBy = [ "default.target" ];
    pathConfig.PathChanged = "/run/microvm-healthcheck-notify/research-agent";
  };
  systemd.user.services.research-agent-healthcheck-notify = {
    description = "Desktop notification: research-agent microvm watchdog gave up";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "research-agent-healthcheck-notify" ''
        ${pkgs.libnotify}/bin/notify-send -u critical "research-agent VM DOWN" \
          "Watchdog gave up after repeated fruitless restarts. Inspect: journalctl -u microvm@research-agent.service — recover: sudo systemctl restart microvm@research-agent.service (watchdog re-arms on recovery)."
      '';
    };
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
