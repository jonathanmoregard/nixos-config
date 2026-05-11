{ pkgs, ... }:
# User services ported from ~/.config/systemd/user/ + migrated from autostart.
# - Router services: originals under ~/.local/share/router-agent (uv-managed venv).
# - Voquill: migrated from ~/.config/autostart/ to a proper systemd user service.
let
  # Voquill is built outside Nix (in ~/Repos/voquill via its devShell flake),
  # so the resulting binary links against unqualified SONAMEs (libwebkit2gtk,
  # libxdo, libpulse, etc.). On NixOS those libs aren't in /usr/lib, so we
  # have to inject the Nix-store paths via LD_LIBRARY_PATH at launch time.
  # Keep this list in sync with apps/desktop/flake.nix `runtimeLibs`.
  voquillRuntimeLibs = with pkgs; [
    webkitgtk_4_1
    gtk3
    gtk-layer-shell
    libayatana-appindicator  # tray-icon dlopens libayatana-appindicator3.so.1
    glib
    libsoup_3
    librsvg
    gdk-pixbuf
    cairo
    pango
    atk
    harfbuzz
    openssl
    alsa-lib
    libpulseaudio
    xdotool
    libx11
    libxtst
    libxi
    libxrandr
    libxcursor
    libxcb
    libxkbcommon
    wayland
    vulkan-loader
    libGL
  ];

  # Built with tauri.local.conf.json overlay so the binary uses the
  # `com.voquill.desktop.local` identifier and reads the user's existing
  # data directory at ~/.config/com.voquill.desktop.local.
  voquillBinary = "/home/jonathan/Repos/voquill/apps/desktop/src-tauri/target/release/Voquill (local)";
  voquillWrapper = pkgs.writeShellApplication {
    name = "voquill-launch";
    runtimeInputs = [ pkgs.xdotool ];
    text = ''
      export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath voquillRuntimeLibs}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
      # webkit2gtk DMA-BUF renderer can crash on some drivers; force the
      # legacy compositing renderer for stability inside Tauri.
      export WEBKIT_DISABLE_DMABUF_RENDERER=1
      exec "${voquillBinary}" "$@"
    '';
  };
in
{
  # Router services: ExecStart was hardcoded to /home/jonathan/.local/bin/uv,
  # which existed on the prior Mint host (pip-installed) but not on NixOS.
  # nixpkgs provides uv at ${pkgs.uv}/bin/uv (resolved at activation time).
  # ConditionPathExists guards against the project dir not being present —
  # the router-agent project (uv-managed venv at %h/.local/share/router-agent)
  # is jonathan's personal repo, not part of the flake closure, so it may be
  # absent on fresh installs or rollbacks. Without the guard, systemd
  # auto-restart floods journal with CHDIR failures.
  systemd.user.services.router-ingestor = {
    Unit = {
      Description = "Router personal-assistant ingestor (inlet -> inbox)";
      After = [ "default.target" ];
      ConditionPathExists = "%h/.local/share/router-agent";
    };
    Service = {
      Type = "simple";
      WorkingDirectory = "%h/.local/share/router-agent";
      ExecStart = "${pkgs.uv}/bin/uv run router-ingestor --paths %h/.config/router/paths.yaml watch";
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install.WantedBy = [ "default.target" ];
  };

  systemd.user.services.router-worker = {
    Unit = {
      Description = "Router worker (inbox -> HITL queue)";
      After = [ "router-ingestor.service" ];
      ConditionPathExists = "%h/.local/share/router-agent";
    };
    Service = {
      Type = "simple";
      WorkingDirectory = "%h/.local/share/router-agent";
      ExecStart = "${pkgs.uv}/bin/uv run router-worker --paths %h/.config/router/paths.yaml watch";
      Restart = "on-failure";
      RestartSec = 10;
    };
    Install.WantedBy = [ "default.target" ];
  };

  systemd.user.services.router-ingestor-scan = {
    Unit = {
      Description = "Router ingestor hourly safety-net scan (scan-once)";
      ConditionPathExists = "%h/.local/share/router-agent";
    };
    Service = {
      Type = "oneshot";
      WorkingDirectory = "%h/.local/share/router-agent";
      ExecStart = "/bin/sh -c '${pkgs.uv}/bin/uv run router-ingestor --paths %h/.config/router/paths.yaml scan-once >> %h/.local/state/router/audit/ingestor-cron.log 2>&1'";
    };
  };

  systemd.user.timers.router-ingestor-scan = {
    Unit.Description = "Hourly trigger for router-ingestor-scan.service";
    Timer = {
      OnBootSec = "5min";
      OnUnitActiveSec = "1h";
      Persistent = true;
      Unit = "router-ingestor-scan.service";
    };
    Install.WantedBy = [ "timers.target" ];
  };

  # Voquill voice-typing app. Locally-built release binary at
  # ~/Repos/voquill/apps/desktop/src-tauri/target/release/Voquill, launched
  # through `voquillWrapper` so it gets the Nix-store LD_LIBRARY_PATH it
  # cannot resolve on its own (no /usr/lib on NixOS).
  # Start-menu entry for Voquill. Placed at ~/.local/share/applications by
  # home-manager so Cinnamon's menu picks it up without imperative edits.
  xdg.desktopEntries.voquill = {
    name = "Voquill";
    comment = "AI voice dictation";
    exec = "${voquillWrapper}/bin/voquill-launch";
    icon = "/home/jonathan/Repos/voquill/apps/desktop/src-tauri/icons/128x128.png";
    terminal = false;
    type = "Application";
    categories = [ "Utility" "AudioVideo" ];
  };

  systemd.user.services.voquill = {
    Unit = {
      Description = "Voquill voice-typing";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      Type = "simple";
      ExecStart = "${voquillWrapper}/bin/voquill-launch --voquill-autostart-hidden";
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
