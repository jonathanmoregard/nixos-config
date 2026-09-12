{ pkgs, ... }:
{
  hardware.cpu.amd.updateMicrocode = true;
  hardware.enableRedistributableFirmware = true;

  # Radeon 890M uses upstream amdgpu + Mesa. Do not force kernel parameters
  # before suspend and GPU stress have been measured on the real machine.
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

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
