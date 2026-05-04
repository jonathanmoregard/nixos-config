{ pkgs, lib, autodoroSrc, ... }:
# Autodoro pomodoro timer.
#
# Fully declarative: scripts ship from /nix/store via the `autodoro`
# flake input (github:jonathanmoregard/autodoro). The wrapper sets up
# PATH + GI_TYPELIB_PATH + GDK_PIXBUF_MODULE_FILE for the bash +
# python3+gi code, then exec's bash on the script (bypassing its
# shebang so /bin/bash absence on NixOS does not matter).
#
# Iteration loop: edit autodoro repo → push → `nix flake update
# autodoro` in /etc/nixos → `nixos-rebuild switch --flake
# /etc/nixos#dellan`. The VM gate runs against the same source so
# regressions surface before switch.
let
  pythonEnv = pkgs.python3.withPackages (ps: with ps; [ pygobject3 ]);

  # Typelibs the script's gi imports actually touch (Gtk 3, Gdk,
  # GdkPixbuf, GLib via blocker.py + popup.py). Pango/Atk/HarfBuzz
  # come along because Gtk's typelib references them.
  # NOTE: must reference `.out` explicitly — several of these pkgs
  # default to `.bin` and ship typelibs in `.out`.
  giTypelibPath = lib.makeSearchPath "lib/girepository-1.0" [
    pkgs.gtk3.out
    pkgs.gdk-pixbuf.out
    pkgs.pango.out
    pkgs.atk.out
    pkgs.harfbuzz.out
    pkgs.glib.out
    pkgs.gobject-introspection.out
  ];

  # Re-query gdk-pixbuf loaders against the base set + the webp
  # loader. blocker.py loads a .webp screen image; the base loader
  # cache (built without webp) would crash with "Couldn't recognize
  # the image file format".
  # gdk-pixbuf-query-loaders takes loader .so paths as args — its
  # GDK_PIXBUF_MODULEDIR env honors only a single directory, so
  # passing two dirs separated by `:` quietly drops one.
  pixbufModuleFile = pkgs.runCommand "autodoro-gdk-pixbuf-loaders.cache" {
    nativeBuildInputs = [ pkgs.gdk-pixbuf ];
  } ''
    gdk-pixbuf-query-loaders \
      ${pkgs.gdk-pixbuf.out}/lib/gdk-pixbuf-2.0/2.10.0/loaders/*.so \
      ${pkgs.webp-pixbuf-loader}/lib/gdk-pixbuf-2.0/2.10.0/loaders/*.so \
      > $out
  '';

  runtimeInputs = [
    pkgs.bash
    pkgs.coreutils
    pkgs.gnugrep                # autodoro.sh uses grep -q (NixOS coreutils does not include grep)
    pkgs.procps                 # ps
    pkgs.pulseaudio             # pactl, paplay
    pkgs.xprintidle
    pkgs.cinnamon-screensaver   # cinnamon-screensaver-command
    pythonEnv
  ];

  envExports = ''
    export GI_TYPELIB_PATH="${giTypelibPath}''${GI_TYPELIB_PATH:+:$GI_TYPELIB_PATH}"
    export GDK_PIXBUF_MODULE_FILE="${pixbufModuleFile}"
  '';

  # systemd ExecStart. exec's bash on the store path so the script's
  # shebang is irrelevant — wrapper PATH always points at our pinned
  # bash, regardless of what shebang upstream changes the script to.
  launcher = pkgs.writeShellApplication {
    name = "autodoro";
    inherit runtimeInputs;
    text = ''
      ${envExports}
      exec bash ${autodoroSrc}/autodoro.sh "$@"
    '';
  };

  # Same env+PATH as the launcher, but execs an arbitrary command.
  # Used by the VM test to run smoke checks (e.g. python3 importing
  # gi + listing pixbuf loaders) under the exact runtime profile the
  # service sees.
  envWrapper = pkgs.writeShellApplication {
    name = "autodoro-env";
    inherit runtimeInputs;
    text = ''
      ${envExports}
      exec "$@"
    '';
  };
in
{
  home.packages = [ launcher envWrapper ];

  systemd.user.services.autodoro = {
    Unit = {
      Description = "Autodoro pomodoro timer";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      ExecStart = "${launcher}/bin/autodoro";
      Restart = "on-failure";
      Environment = [
        "DISPLAY=:0"
        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
      ];
    };
    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
  };
}
