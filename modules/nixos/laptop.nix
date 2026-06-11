{ pkgs, ... }:
{
  # Intel CPU microcode updates
  hardware.cpu.intel.updateMicrocode = true;

  # Iris Xe graphics + VA-API video acceleration (Raptor Lake → iHD driver)
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
    extraPackages = with pkgs; [
      intel-media-driver
      vpl-gpu-rt
    ];
  };
  environment.sessionVariables.LIBVA_DRIVER_NAME = "iHD";

  # Firmware updates (LVFS) — `fwupdmgr refresh && fwupdmgr update`
  services.fwupd.enable = true;

  # Battery / power management. TLP > power-profiles-daemon for aggressive saving.
  services.power-profiles-daemon.enable = false;
  services.tlp = {
    enable = true;
    settings = {
      # i7-1365U uses intel_pstate, which only exposes "performance" and
      # "powersave" governors — `performance` pins cores at 5.2 GHz at idle
      # (95°C, fans full). On modern Intel, "powersave" governor + EPP
      # ("balance_performance" on AC, "power" on battery) is the correct
      # idiom — clocks ramp on demand via EPP hints, not the governor.
      CPU_SCALING_GOVERNOR_ON_AC = "powersave";
      CPU_SCALING_GOVERNOR_ON_BAT = "powersave";
      CPU_ENERGY_PERF_POLICY_ON_AC = "balance_performance";
      CPU_ENERGY_PERF_POLICY_ON_BAT = "power";
      START_CHARGE_THRESH_BAT0 = 75;
      STOP_CHARGE_THRESH_BAT0 = 85;
    };
  };

  # Thermal daemon — Intel-specific throttling control
  services.thermald.enable = true;

  # Touchpad
  services.libinput = {
    enable = true;
    touchpad = {
      tapping = true;
      naturalScrolling = true;
      disableWhileTyping = true;
    };
  };

  # Bluetooth
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };

  # Intel IPU6 MIPI webcam (Latitude 7440, 13th-gen Raptor Lake → `ipu6ep`).
  # Without this, the OV02C10 sensor enumerates kernel-side (modules load,
  # /dev/video* nodes appear) but no userspace pipeline produces frames, so
  # apps see "no camera". The module pulls in:
  #   - intel-ipu6 firmware + ivsc-firmware (unfree-redistributable)
  #   - ipu6-drivers out-of-tree kernel modules
  #   - v4l2-relayd → exposes a v4l2loopback device at /dev/video50 (the
  #     fixed `videoDeviceNumber`) so apps using plain v4l2 (Cheese, OBS,
  #     Chromium without PipeWire portal) still find the camera.
  #   - WirePlumber rule that hides the raw IPU6 nodes so PipeWire-aware
  #     apps don't try to open them directly.
  hardware.ipu6 = {
    enable = true;
    platform = "ipu6ep";
  };

  # v4l2-relayd-ipu6 resilience + first-consumer warmup.
  #
  # Two failure modes are mitigated here, both rooted in the same
  # upstream gap (`nixos/modules/hardware/video/webcam/ipu6.nix` does
  # not wait for the IPU6 sensor stack — ivsc_csi / intel_ipu6_isys /
  # sensor probe — to be ready before launching v4l2-relayd):
  #
  # 1. StartLimitBurst lockout. Upstream ships StartLimitBurst=5 +
  #    default RestartSec=100ms; if the cold-boot race against the
  #    sensor stack ever takes more than 5 restart attempts the unit
  #    lands in start-limit-hit and the camera is dead until manual
  #    `systemctl reset-failed`. Infinite retries + 5s backoff turns
  #    that into a brief blank that recovers on its own and gives the
  #    sensor time to settle.
  #
  # 2. First-consumer warmup. v4l2-relayd's gst pipeline (icamerasrc
  #    → v4l2sink /dev/video50) defers full caps negotiation until
  #    something opens the device. Chrome's V4L2 path opens "softly"
  #    and gets an unnegotiated device → no frames → camera shows
  #    blank in the page. Cheese / any GStreamer-backed client opens
  #    "fully", triggers negotiation, and from that point everyone
  #    (including Chrome) works. The ExecStartPost script below grabs
  #    one frame from /dev/video50 so negotiation is forced before
  #    any user app touches the device. It retries because the relay
  #    may still be coming up when ExecStartPost first fires; it is
  #    prefixed with `-` so a prolonged failure to prime never marks
  #    the relay itself as failed (the relay is up regardless).
  systemd.services.v4l2-relayd-ipu6 = {
    unitConfig.StartLimitBurst = 0;
    serviceConfig.RestartSec = "5s";
    serviceConfig.ExecStartPost = [
      "-${pkgs.writeShellApplication {
        name = "v4l2-relayd-ipu6-prime";
        runtimeInputs = [ pkgs.v4l-utils pkgs.coreutils ];
        text = ''
          # Force gst caps negotiation by pulling one frame from
          # /dev/video50. Retry up to ~15s in case the relay is still
          # starting; exit 0 unconditionally so we never poison the
          # main unit (prefix `-` in ExecStartPost already ignores
          # exit codes, this is belt-and-braces).
          for _ in $(seq 1 15); do
            if timeout 1 v4l2-ctl -d /dev/video50 \
                --stream-mmap --stream-count=1 \
                --stream-to=/dev/null >/dev/null 2>&1; then
              exit 0
            fi
            sleep 1
          done
          exit 0
        '';
      }}/bin/v4l2-relayd-ipu6-prime"
    ];
  };

  # ── IPU6 camera self-heal watchdog ──────────────────────────────────
  # The OV02C10 sensor intermittently stops delivering frames mid-stream.
  # Intel's userspace HAL logs `CamHAL[WAR] <id0>@waitFrame, time out
  # happens, wait recovery` every ~5s and NEVER recovers on its own — the
  # "recovery" text is misleading; `RequestThread::waitFrame` is an
  # infinite retry with no teardown (verified in intel/ipu6-camera-hal).
  # So a single waitFrame line means the producer is wedged until the
  # icamerasrc pipeline is torn down + rebuilt. getUserMedia still
  # succeeds, so Chrome/Zoom just sit on a black frame ("works in Cheese,
  # black in Chrome").
  #
  # The ONLY reliable userspace recovery is to force a fresh icamerasrc
  # build — exactly what opening Cheese does: a real consumer's OPEN +
  # STREAMON makes v4l2-relayd tear down and recreate the producer. A bare
  # `systemctl restart v4l2-relayd` with NO consumer attached does NOT
  # help (demand-driven: the producer is never rebuilt, so the sensor is
  # never re-initialised). This watchdog automates the Cheese trick:
  # detect the waitFrame signal in the relay journal, then restart the
  # relay (rebuilds the producer against the still-attached, wedged
  # consumer) and prime one frame. Detection is passive journal-grep, so
  # it only fires when a consumer is actually attached and starved —
  # demand-driven is preserved (camera LED stays off when idle, zero idle
  # CPU). It NEVER touches the PCI bus: unbind/rebind of intel-ipu6
  # corrupts IVSC/CSE state and turns a soft wedge into a reboot-only hard
  # wedge (learned the hard way).
  #
  # Bounded exactly like research-agent-microvm-healthcheck.nix: after
  # GIVEUP_AFTER restarts with no healthy tick in between, it latches
  # gave-up, fires a critical desktop notification (a hard wedge lives in
  # kernel/firmware/IVSC and only a reboot escapes it), and stops
  # restarting until the camera recovers. Same flag-file + PathChanged
  # user-unit notification chain as nixos-auto-deploy.nix.
  systemd.tmpfiles.rules = [
    "d /run/ipu6-camera-watchdog 0700 root root -"
    # Notify flag lives in a world-readable dir so the user-session path
    # unit can inotify-watch it (the 0700 state dir above is root-only).
    "d /run/ipu6-camera-notify 0755 root root -"
  ];

  systemd.services.ipu6-camera-watchdog = {
    description = "Detect IPU6 waitFrame wedge and self-heal (mimics opening Cheese)";
    # oneshot + timer, not a journalctl -f follower: matches the repo's
    # healthcheck idiom and keeps the restart/give-up state machine simple
    # (no pipe-buffer drain races). Restart=no so a probe-script bug can't
    # become a restart loop on top of the guard inside.
    serviceConfig = {
      Type = "oneshot";
      User = "root"; # `systemctl restart` of the relay needs root
      # 60s (not 30s): a recovery does a *blocking* `systemctl restart` of
      # the relay, whose own ExecStartPost prime can take up to ~15s, plus
      # this script's sleep 5 + timeout 8 prime (~28s worst case). A 30s
      # cap could SIGTERM the oneshot mid-recovery — after the burst
      # counter was already incremented — biasing toward premature give-up.
      TimeoutStartSec = "60s";
    };
    path = [ pkgs.systemd pkgs.v4l-utils pkgs.coreutils pkgs.gnugrep ];
    script = ''
      set -u

      STATE_DIR=/run/ipu6-camera-watchdog
      LAST_RESTART_FILE="$STATE_DIR/last-restart-epoch"
      BURST_FILE="$STATE_DIR/restart-burst-count"
      GAVEUP_FILE="$STATE_DIR/gave-up"
      NOTIFY_FILE=/run/ipu6-camera-notify/wedged
      RELAY=v4l2-relayd-ipu6.service
      DEV=/dev/video50
      WEDGE_RE='waitFrame, time out happens'
      # waitFrame lines in the look-back window before we call it wedged.
      # The HAL logs one per ~5s and never self-heals, so >=2 means the
      # wedge has persisted >~5s — past any benign single timeout at
      # stream start, while still detecting within one or two ticks.
      WEDGE_THRESHOLD=2
      LOOKBACK_S=18
      # Consecutive restarts with no healthy tick in between before giving
      # up. 2 = "a restart didn't fix it, and neither did the next" — past
      # that the wedge is in kernel/firmware and only a reboot escapes.
      GIVEUP_AFTER=2
      RENOTIFY_S=3600
      # 60s cooldown: a real recovery takes one restart (~5s rebuild). If
      # a restart didn't clear the waitFrame loop, restarting 12s later
      # won't either, and rapid icamerasrc start/stop is itself a
      # documented wedge trigger — so give the rebuild room to settle.
      # State in /run (tmpfs) is wiped on reboot, which is correct: a
      # reboot is a far longer cooldown and clears any hard wedge anyway.
      COOLDOWN_S=60

      mkdir -p "$STATE_DIR"

      # Read a non-negative integer from a state file. Strips non-digits
      # and clamps to 12 chars. Empty/missing/corrupt -> 0. Without this,
      # `set -u` + arithmetic on a garbage byte would abort the script and
      # brick the watchdog forever (see healthcheck rationale).
      read_int() {
        local v
        v=$(cat "$1" 2>/dev/null | tr -cd '0-9' | head -c 12)
        [ -z "$v" ] && v=0
        printf '%s' "$v"
      }

      now=$(date +%s)

      # Passive detection: count waitFrame lines in the recent relay
      # journal. Anchor the window so we never re-count lines emitted
      # *before* our last restart — otherwise the pre-recovery waitFrame
      # spam still inside the lookback window could be mistaken for a
      # fresh wedge right after a successful heal. The window is the last
      # LOOKBACK_S seconds, clamped to start no earlier than 1s past the
      # last restart. (This makes correctness independent of the
      # cooldown-vs-lookback timing relationship.)
      window_start=$((now - LOOKBACK_S))
      last_restart=$(read_int "$LAST_RESTART_FILE")
      [ "$last_restart" -gt "$window_start" ] && window_start=$((last_restart + 1))
      since_ts=$(date -d "@$window_start" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$LOOKBACK_S sec ago")
      # grep -c exits 1 on zero matches; `|| true` keeps that from
      # aborting under the assignment.
      wedge_lines=$(journalctl -u "$RELAY" --since "$since_ts" --no-pager 2>/dev/null | grep -c "$WEDGE_RE") || true
      wedge_lines=$(printf '%s' "$wedge_lines" | tr -cd '0-9')
      [ -z "$wedge_lines" ] && wedge_lines=0

      if [ "$wedge_lines" -lt "$WEDGE_THRESHOLD" ]; then
        # Not wedged (healthy-in-use, or idle). Clear any latch so a
        # future wedge starts from a clean slate and re-notifies.
        if [ -e "$GAVEUP_FILE" ] || [ "$(read_int "$BURST_FILE")" -gt 0 ]; then
          echo "watchdog: camera healthy; clearing restart-burst/give-up state"
          rm -f "$GAVEUP_FILE"
          echo 0 > "$BURST_FILE"
        fi
        exit 0
      fi

      echo "watchdog: waitFrame wedge detected ($wedge_lines lines in window)"

      # Give-up gate: stop restarting once the burst budget is spent.
      burst=$(read_int "$BURST_FILE")
      if [ "$burst" -ge "$GIVEUP_AFTER" ]; then
        mkdir -p "''${NOTIFY_FILE%/*}" 2>/dev/null || true
        if [ ! -e "$GAVEUP_FILE" ]; then
          : > "$GAVEUP_FILE"
          echo "$now" > "$NOTIFY_FILE" || true
          echo "watchdog: GIVING UP after $burst restarts without recovery; reboot needed. Inspect: journalctl -u $RELAY"
        else
          last_notify=$(read_int "$NOTIFY_FILE")
          if [ $((now - last_notify)) -ge "$RENOTIFY_S" ]; then
            echo "$now" > "$NOTIFY_FILE" || true
          fi
          echo "watchdog: given up ($burst restarts without recovery); awaiting reboot"
        fi
        exit 0
      fi

      # Cooldown gate.
      last=$(read_int "$LAST_RESTART_FILE")
      since_last=$((now - last))
      if [ "$since_last" -lt "$COOLDOWN_S" ]; then
        echo "watchdog: wedge seen but cooldown active (''${since_last}s < ''${COOLDOWN_S}s); not restarting"
        exit 0
      fi

      # Recover — mimic opening Cheese. Restart the relay (tears the
      # wedged icamerasrc to NULL and rebuilds the producer against the
      # still-attached consumer), then prime one frame to force a fresh
      # STREAMON in case the consumer detached. The NEXT tick verifies: no
      # waitFrame -> healthy -> burst/give-up latch cleared above.
      echo "$now" > "$LAST_RESTART_FILE"
      echo $((burst + 1)) > "$BURST_FILE"
      echo "watchdog: recovering — restart $RELAY + prime (mimics opening Cheese)"
      systemctl restart "$RELAY" || true
      sleep 5
      # The prime is a transient consumer: it opens the loopback, grabs
      # one frame, and exits, so it does not keep the sensor powered —
      # the demand-driven / LED-off-when-idle invariant is preserved.
      timeout 8 v4l2-ctl -d "$DEV" --stream-mmap --stream-count=1 --stream-to=/dev/null >/dev/null 2>&1 || true
      exit 0
    '';
  };

  systemd.timers.ipu6-camera-watchdog = {
    description = "Periodic IPU6 camera waitFrame-wedge probe";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Short boot delay so the sensor stack + relay settle first.
      OnBootSec = "90s";
      # 12s cadence: with an 18s look-back and a 2-line threshold, a wedge
      # is caught within ~one to two ticks (~12-24s of black) then healed.
      OnUnitActiveSec = "12s";
      # Don't replay missed ticks all at once after suspend/resume.
      Persistent = false;
      Unit = "ipu6-camera-watchdog.service";
    };
  };

  # Desktop-notification chain for the give-up latch — same flag-file +
  # PathChanged pattern as nixos-auto-deploy.nix and the microvm
  # healthchecks. The root watchdog writes the flag; this user-session
  # unit fires notify-send on the session bus. PathChanged (not
  # PathExists) so the flag can persist without retrigger-looping.
  systemd.user.paths.ipu6-camera-watchdog-notify = {
    wantedBy = [ "default.target" ];
    pathConfig.PathChanged = "/run/ipu6-camera-notify/wedged";
  };
  systemd.user.services.ipu6-camera-watchdog-notify = {
    description = "Desktop notification: IPU6 camera could not self-heal";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "ipu6-camera-watchdog-notify" ''
        ${pkgs.libnotify}/bin/notify-send -u critical "Camera wedged" \
          "The webcam stopped delivering frames and could not self-heal after repeated tries. A reboot will fix it. (Inspect: journalctl -u v4l2-relayd-ipu6.service)"
      '';
    };
  };

  # nix-ld — runs pre-built dynamically-linked Linux binaries (e.g. the
  # Claude Code native installer at ~/.local/share/claude/versions/<v>)
  # that expect /lib64/ld-linux-x86-64.so.2 + standard glibc layout.
  programs.nix-ld.enable = true;

  # Lid close behavior — suspend on battery, ignore on AC (laptop docked)
  services.logind.settings.Login = {
    HandleLidSwitch = "suspend";
    HandleLidSwitchExternalPower = "ignore";
    HandleLidSwitchDocked = "ignore";
  };

  # Audio — PipeWire (Cinnamon does not pull this in by default)
  services.pulseaudio.enable = false;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };
  security.rtkit.enable = true;

  # Printing + mDNS network printer discovery
  services.printing.enable = true;
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };

  # Fonts — sane defaults for desktop use
  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-color-emoji
    noto-fonts-cjk-sans
    liberation_ttf
    dejavu_fonts
  ];
}
