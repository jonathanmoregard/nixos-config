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

  # v4l2-relayd-ipu6 self-heal. Upstream `hardware.ipu6` ships
  # StartLimitBurst=5 + default RestartSec=100ms; the gst pipeline
  # tears down ~1s after preroll (v4l2loopback 0.15.3 buffer-queue
  # regression, upstream PR #656 still open) and the sensor itself
  # occasionally wedges on stop/start. The default settings burn
  # through the burst in <1s and the unit lands in start-limit-hit
  # → camera dead until manual `systemctl reset-failed`. Infinite
  # retries + 5s backoff turns that into a brief blank that
  # recovers on its own and gives the sensor time to settle.
  systemd.services.v4l2-relayd-ipu6 = {
    unitConfig.StartLimitBurst = 0;
    serviceConfig.RestartSec = "5s";
  };

  # nix-ld — runs pre-built dynamically-linked Linux binaries (e.g. the
  # Claude Code native installer at ~/.local/share/claude/versions/<v>)
  # that expect /lib64/ld-linux-x86-64.so.2 + standard glibc layout.
  programs.nix-ld.enable = true;

  # Lid close behavior — suspend on battery, ignore on AC (laptop docked)
  services.logind.lidSwitch = "suspend";
  services.logind.lidSwitchExternalPower = "ignore";
  services.logind.lidSwitchDocked = "ignore";

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
