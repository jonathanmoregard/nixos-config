{ config, pkgs, ... }:
{
  hardware.cpu.amd.updateMicrocode = true;
  hardware.enableRedistributableFirmware = true;

  # Radeon 890M uses upstream amdgpu + Mesa. Do not force other kernel parameters
  # before suspend and GPU stress have been measured on the real machine.
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  # amdgpu's custom brightness curve (Linux 6.15+, still present in 7.1.6)
  # overflows on this panel: measured 2026-09-29 on 6.18.42, requesting
  # brightness ≥ ~64500/65535 made actual_brightness wrap to 0, so the top
  # of the slider — and the boot default, 65535 — is a black screen.
  # 0x40000 = DC_DISABLE_CUSTOM_BRIGHTNESS_CURVE (linear mapping). Drop it
  # once the upstream curve fix is in the pinned kernel and max brightness
  # reads back non-zero without it.
  boot.kernelParams = [ "amdgpu.dcdebugmask=0x40000" ];

  # Motorcomm YT6801 Ethernet (eno1): no in-tree driver bound on 6.18.42 or
  # the 7.2.6 installer kernel (measured 2026-09-29). nixpkgs packages
  # Motorcomm's out-of-tree driver.
  boot.extraModulePackages = [ config.boot.kernelPackages.yt6801 ];

  # Upstream driver provides Fn keys, keyboard controls, and charging policy.
  # Tailor stays disabled until its Gen10 support is hardware-tested.
  hardware.tuxedo-drivers = {
    enable = true;
    settings.charging-profile = "stationary";
  };

  # AMD platform/EPP integration is the conservative baseline. Dellan's
  # Intel-specific TLP policy lives in dell-latitude-7440.nix.
  services.power-profiles-daemon.enable = true;
  services.tlp.enable = false;
  services.thermald.enable = false;

  # Arrival diagnostics plus first local dictation candidate.
  environment.systemPackages = with pkgs; [
    libva-utils
    lm_sensors
    vulkan-tools
    whisper-cpp-vulkan
  ];
}
