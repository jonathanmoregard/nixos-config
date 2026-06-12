{ pkgs, ... }:
{
  imports = [
    # Camera relay dies without write-buffer headroom on the loopback
    # device — see the module for the full post-mortem.
    ./v4l2loopback-buffers.nix
  ];

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
    # Route Intel HAL (CamHAL[...]) logs through syslog(3) instead of
    # stdout. With the default stdout sink, glibc full-buffers the pipe to
    # journald and the low-volume CamHAL[WAR] lines arrive in multi-minute
    # bursts (measured on dellan: journal receive timestamps lag the
    # embedded HAL timestamps by 2-4 min). The camera watchdog below greps
    # these lines; syslog delivery makes detection near-realtime. The env
    # contract (logSink=STDOUT|SYSLOG|FILELOG) comes from the HAL's
    # CameraLog.cpp — undocumented upstream, so the watchdog's state
    # machine below is also built to stay correct with bursty delivery.
    environment.logSink = "SYSLOG";
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
  # build — exactly what opening Cheese does. Restarting the relay does
  # the same: the new relayd reads the loopback's client-usage count on
  # subscribe (V4L2_EVENT_PRI_CLIENT_USAGE) and rebuilds the producer
  # against the still-attached consumer, whose starving capture stream
  # then unblacks in place. This watchdog automates that: detect the
  # wedge in the relay journal, restart the relay. Detection is passive
  # journal-grep, so demand-driven is preserved (camera LED stays off
  # when idle, zero idle CPU). Two wedge signals are matched:
  #   - the HAL waitFrame line (frame-starved producer), and
  #   - a run of systemd "Scheduled restart job" lines (relay
  #     crash-looping, e.g. icamerasrc dying at pipeline build — observed
  #     on dellan at 5s cadence for hours, silently).
  #
  # Deliberate non-choices, verified the hard way:
  #   - NO active frame probe (v4l2-ctl/gst grab) as a detection signal
  #     or recovery prime: a second reader's REQBUFS against the loopback
  #     gets EBUSY while a consumer (Chrome) holds the capture stream
  #     token on current v4l2loopback, and on older versions it can
  #     destroy the consumer's live stream outright. A probe would
  #     false-fail during every healthy call.
  #   - NEVER touch the PCI bus: rebinding the IPU6 device corrupts
  #     IVSC/CSE state and turns a soft wedge into a reboot-only hard
  #     wedge.
  #
  # Bounded like research-agent-microvm-healthcheck.nix (cooldown, burst
  # counter, give-up latch + desktop notification, auto re-arm), with one
  # deviation: latches clear only after a sustained quiet streak
  # (CLEAR_AFTER_S), not on a single quiet tick. CamHAL stdout reaches
  # journald in delayed multi-minute bursts when the logSink=SYSLOG knob
  # above is ineffective; clearing on one quiet tick would reset the
  # burst counter between bursts and the give-up latch could never fire
  # on a hard wedge (infinite restart loop, no notification). The streak
  # must exceed the worst observed flush interval (~4 min).
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
      # Recovery uses `restart --no-block`, so a tick is journalctl + a
      # queued job — seconds. 30s is generous headroom; a SIGTERM'd tick
      # mid-recovery would strand an incremented burst counter, so the
      # script is kept short rather than the timeout long.
      TimeoutStartSec = "30s";
    };
    path = [ pkgs.systemd pkgs.coreutils pkgs.gnugrep ];
    # NB: NixOS makeJobScript runs this under `bash -e`; every command
    # that may legitimately fail is guarded. Script-body comments must
    # not contain the strings the vm-base PCI-guard greps reject.
    script = ''
      set -u

      STATE_DIR=/run/ipu6-camera-watchdog
      LAST_RESTART_FILE="$STATE_DIR/last-restart-epoch"
      WEDGE_SEEN_FILE="$STATE_DIR/last-wedge-epoch"
      BURST_FILE="$STATE_DIR/restart-burst-count"
      GAVEUP_FILE="$STATE_DIR/gave-up"
      NOTIFY_FILE=/run/ipu6-camera-notify/wedged
      RELAY=v4l2-relayd-ipu6.service
      WEDGE_RE='waitFrame, time out happens'
      THRASH_RE='Scheduled restart job'
      # The HAL emits waitFrame every ~5s early in a wedge, backing off to
      # ~60s after the first minute (measured). 2 lines in a 150s window
      # catches both cadences while a benign single timeout at stream
      # start stays below threshold.
      WEDGE_THRESHOLD=2
      # Relay auto-restarts run at RestartSec=5s when icamerasrc dies at
      # pipeline build; 5 scheduled restarts in the window means a crash
      # loop, not a one-off blip (boot settling produces a handful at
      # most, and OnBootSec delays the first tick past it).
      THRASH_THRESHOLD=5
      LOOKBACK_S=150
      # Never count journal lines received before (last restart +
      # margin): the dying relay's buffered stdout flushes at kill time,
      # landing right at the restart timestamp, and must not be mistaken
      # for a fresh wedge.
      ANCHOR_MARGIN_S=5
      # 2 = "a restart didn't fix it, and neither did the next" — past
      # that the wedge is in kernel/firmware and only a reboot escapes.
      GIVEUP_AFTER=2
      RENOTIFY_S=3600
      # A real recovery takes one restart (~5-20s incl. the relay's own
      # prime). Rapid icamerasrc start/stop is itself a documented wedge
      # trigger, so give each rebuild room to settle. State in /run
      # (tmpfs) is wiped on reboot — correct, a reboot clears any wedge.
      COOLDOWN_S=60
      # Quiet streak required before burst/give-up state clears. MUST
      # exceed the worst CamHAL stdout flush interval (~4 min measured):
      # clearing on a single quiet tick would reset the burst counter
      # between delayed log bursts and the give-up latch could never
      # fire on a hard wedge.
      CLEAR_AFTER_S=600

      mkdir -p "$STATE_DIR"

      # Read a non-negative integer from a state file. Strips non-digits
      # and clamps to 12 chars. Empty/missing/corrupt -> 0. Without this,
      # arithmetic on a garbage byte would abort the script under -e/-u
      # and brick the watchdog forever (see healthcheck rationale).
      read_int() {
        local v
        v=$(cat "$1" 2>/dev/null | tr -cd '0-9' | head -c 12)
        [ -z "$v" ] && v=0
        printf '%s' "$v"
      }

      now=$(date +%s)

      window_start=$((now - LOOKBACK_S))
      anchor=$(( $(read_int "$LAST_RESTART_FILE") + ANCHOR_MARGIN_S ))
      if [ "$anchor" -gt "$window_start" ]; then
        window_start=$anchor
      fi
      since_ts=$(date -d "@$window_start" "+%Y-%m-%d %H:%M:%S" 2>/dev/null) || since_ts="$LOOKBACK_S sec ago"

      journal=$(journalctl -u "$RELAY" --since "$since_ts" --no-pager 2>/dev/null) || journal=""
      # grep -c exits 1 on zero matches; `|| true` keeps that from
      # aborting the assignment under -e.
      wedge_lines=$(printf '%s' "$journal" | grep -c "$WEDGE_RE") || true
      thrash_lines=$(printf '%s' "$journal" | grep -c "$THRASH_RE") || true
      wedge_lines=$(printf '%s' "$wedge_lines" | tr -cd '0-9'); [ -n "$wedge_lines" ] || wedge_lines=0
      thrash_lines=$(printf '%s' "$thrash_lines" | tr -cd '0-9'); [ -n "$thrash_lines" ] || thrash_lines=0

      wedged=0
      if [ "$wedge_lines" -ge "$WEDGE_THRESHOLD" ] || [ "$thrash_lines" -ge "$THRASH_THRESHOLD" ]; then
        wedged=1
      fi

      if [ "$wedged" -eq 0 ]; then
        # Quiet tick. Clear latches only after a sustained quiet streak —
        # absence of lines is NOT proof of health while CamHAL stdout may
        # still be buffering (see CLEAR_AFTER_S rationale).
        if [ -e "$GAVEUP_FILE" ] || [ "$(read_int "$BURST_FILE")" -gt 0 ]; then
          last_wedge=$(read_int "$WEDGE_SEEN_FILE")
          if [ $((now - last_wedge)) -ge "$CLEAR_AFTER_S" ]; then
            echo "watchdog: quiet for ''${CLEAR_AFTER_S}s+; clearing restart-burst/give-up state"
            rm -f "$GAVEUP_FILE"
            echo 0 > "$BURST_FILE"
          fi
        fi
        exit 0
      fi

      echo "watchdog: wedge signal (waitFrame=$wedge_lines, relay-restarts=$thrash_lines in window)"
      echo "$now" > "$WEDGE_SEEN_FILE"

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
        echo "watchdog: wedge but cooldown active (''${since_last}s < ''${COOLDOWN_S}s); not restarting"
        exit 0
      fi

      # Recover: restart the relay. The new relayd reads the loopback's
      # client-usage count on subscribe and rebuilds the icamerasrc
      # producer against the still-attached consumer; its ExecStartPost
      # prime covers the no-consumer case. No frame-grab here — a second
      # reader's REQBUFS gets EBUSY (or worse) while a consumer streams.
      # --no-block keeps this oneshot short; the next ticks verify.
      echo "$now" > "$LAST_RESTART_FILE"
      echo $((burst + 1)) > "$BURST_FILE"
      echo "watchdog: recovering — restarting $RELAY (rebuilds the icamerasrc producer)"
      systemctl restart --no-block "$RELAY" || true
      exit 0
    '';
  };

  systemd.timers.ipu6-camera-watchdog = {
    description = "Periodic IPU6 camera waitFrame-wedge probe";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Boot delay past the relay's cold-boot settling (a few auto-
      # restarts are normal there and must not trip the thrash signal).
      OnBootSec = "90s";
      # 15s cadence: with syslog-delivered HAL lines (5s cadence early in
      # a wedge), detection + restart lands within ~15-30s of wedge
      # onset. With bursty stdout fallback it degrades to the flush
      # interval (2-4 min) but stays correct.
      OnUnitActiveSec = "15s";
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
