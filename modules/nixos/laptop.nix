{ pkgs, ... }:
{
  # Firmware updates (LVFS) — `fwupdmgr refresh && fwupdmgr update`
  services.fwupd.enable = true;

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

  # nix-ld — runs pre-built dynamically-linked Linux binaries (e.g. the
  # Claude Code native installer at ~/.local/share/claude/versions/<v>)
  # that expect /lib64/ld-linux-x86-64.so.2 + standard glibc layout.
  programs.nix-ld.enable = true;

  # tiny_power_button turns every ACPI power-button notify into a raw
  # SIGRTMIN+4 (poweroff) to PID 1, bypassing logind. On 6.18.5x this
  # InfinityBook's firmware fires such a notify at s2idle entry and on lid
  # open, so every suspend ended in a poweroff on resume (journal: "Received
  # SIGRTMIN+4" amid "Freezing user space processes"). The regular `button`
  # driver still exposes the key as an input device, so logind keeps
  # handling it per HandlePowerKey.
  boot.blacklistedKernelModules = [ "tiny_power_button" ];

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
    # "Echo-cancelled mic": the default mic minus what the speakers play
    # (WebRTC AEC), so a recorder such as Meetily does not capture a call's
    # far side twice when it plays on speakers. monitor.mode takes the echo
    # reference from the default sink's monitor, so playback needs no routing
    # through a virtual sink. Passive capture: the real mic only opens while
    # something records from this source. Not made the default source.
    extraConfig.pipewire."60-echo-cancel" = {
      "context.modules" = [
        {
          name = "libpipewire-module-echo-cancel";
          args = {
            "library.name" = "aec/libspa-aec-webrtc";
            "monitor.mode" = true;
            "capture.props" = {
              "node.name" = "echo-cancel-capture";
              "node.passive" = true;
            };
            "source.props" = {
              "node.name" = "echo-cancel-source";
              "node.description" = "Echo-cancelled mic";
            };
          };
        }
      ];
    };
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
