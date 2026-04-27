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
      CPU_SCALING_GOVERNOR_ON_AC = "performance";
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
    noto-fonts-emoji
    noto-fonts-cjk-sans
    liberation_ttf
    dejavu_fonts
  ];
}
