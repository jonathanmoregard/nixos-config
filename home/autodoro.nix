{ pkgs, lib, ... }:
# Autodoro pomodoro timer.
#
# The script lives in ~/Repos/autodoro and is iterated on outside this
# flake. The Nix side here owns:
#
#   1. the launch *environment* — a wrapper that injects every binary
#      and GI/pixbuf path the script's bash + python3+gi code needs at
#      runtime. NixOS has no /bin/bash and no global GI typelib, so
#      without this wrapper the service either exits 203/EXEC or
#      crashes inside python with "Namespace Gtk not available" /
#      "Couldn't recognize the image file format".
#
#   2. the *reload trigger* — a `pre-push` git hook installed into
#      the user's global `~/.config/git/hooks/` dir. Fires only on
#      `git push` from the autodoro repo and restarts the service.
#      Replaces the older `.githooks/post-push` flow, which silently
#      no-op'd: (a) `post-push` is not a real git hook (git only
#      defines `pre-push`), and (b) the user's global
#      `core.hooksPath=~/.config/git/hooks` overrode the per-repo
#      `.githooks/` dir anyway. The hook lives in the global dir
#      (matching that override) and guards by repo toplevel so it's
#      a cheap no-op for pushes from any other repo.
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
  # loader, then point GDK_PIXBUF_MODULE_FILE at the regenerated
  # cache. blocker.py loads a .webp screen image; without this the
  # base loader cache (built without webp) would crash with
  # "Couldn't recognize the image file format".
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

  # The actual systemd ExecStart. Sources the env, then execs the
  # repo script — the script body itself stays in ~/Repos/autodoro
  # and is reloaded via the pre-push git hook below on `git push`.
  launcher = pkgs.writeShellApplication {
    name = "autodoro";
    inherit runtimeInputs;
    text = ''
      ${envExports}
      exec "$HOME/Repos/autodoro/autodoro.sh" "$@"
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
      # Cap restarts so a script that segfaults right after a bad
      # push doesn't wedge the user's session in a tight restart
      # loop. Next push of a fixed script re-triggers the hook.
      StartLimitIntervalSec = 30;
      StartLimitBurst = 5;
    };
    Service = {
      ExecStart = "${launcher}/bin/autodoro";
      ExecCondition = "/bin/sh -c 'test -f %h/Repos/autodoro/autodoro.sh'";
      Restart = "on-failure";
      RestartSec = "2s";
      Environment = [
        "DISPLAY=:0"
        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
      ];
    };
    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
  };

  # Global pre-push hook → restart autodoro.service after a push from
  # ~/Repos/autodoro. Lives in the global hooks dir because that's
  # where the user's `core.hooksPath` (set in home/jonathan.nix)
  # points; any per-repo `.githooks/` would be silently shadowed.
  # Guard by `git rev-parse --show-toplevel` so pushes from every
  # other repo are a cheap no-op.
  #
  # Fires synchronously inside `git push` and exits 0 unconditionally
  # so a systemd error does not block the push itself. The restart
  # is fire-and-forget — by the time the network push completes the
  # service is already on the new code.
  home.file.".config/git/hooks/pre-push" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      # Run from any git push; this dispatches on the current repo.
      if [ "$(${pkgs.git}/bin/git rev-parse --show-toplevel 2>/dev/null)" = "$HOME/Repos/autodoro" ]; then
        ${pkgs.systemd}/bin/systemctl --user restart autodoro.service || true
      fi
      exit 0
    '';
  };
}
