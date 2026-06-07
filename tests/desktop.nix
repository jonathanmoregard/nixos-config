# vm-desktop: Cinnamon screenshot / clipboard plumbing.
#
# Covers the Print / Shift+Print → gnome-screenshot → CopyQ chain:
#   - CopyQ binary on PATH + autostart .desktop present (required for
#     gnome-screenshot --clipboard to persist after gnome-screenshot exits)
#   - gnome-screenshot binary on PATH (fired by the keybindings)
#   - Cinnamon dconf: Print + Shift+Print custom bindings present;
#     default media-keys screenshot binding cleared (so PrtSc doesn't
#     double-fire into both "save to ~/Pictures" and "to clipboard").
#
# Uses mkFeatureTest with home/_test-desktop.nix — HM closure is
# jonathan.nix + cinnamon.nix + desktop-apps.nix (no kitty / claude
# /autodoro / router-services / etc). extraModules pull in the system
# Cinnamon module + lightdm + autoLogin so dconf is populated when the
# Cinnamon session comes up, plus jq for the testScript's grep paths.
#
# Run: nix build .#checks.x86_64-linux.vm-desktop -L
{ pkgs, inputs }:
(import ./lib/common.nix { inherit pkgs inputs; }).mkFeatureTest {
  name = "vm-desktop";
  hm = ../home/_test-desktop.nix;
  extraModules = [
    ../modules/nixos/desktop.nix
    ({ pkgs, ... }: {
      services.displayManager.autoLogin = {
        enable = true;
        user = "jonathan";
      };
      services.displayManager.defaultSession = "cinnamon";
      environment.systemPackages = with pkgs; [ jq xdg-utils ];
    })
  ];
  testScript = ''
    dellan.wait_for_unit("multi-user.target")
    dellan.wait_for_unit("home-manager-jonathan.service")
    dellan.wait_for_unit("default.target", "jonathan")

    # CopyQ clipboard manager — binary on PATH + autostart .desktop present.
    dellan.succeed("test -x /etc/profiles/per-user/jonathan/bin/copyq")
    dellan.succeed(
        "test -f /home/jonathan/.config/autostart/copyq.desktop"
    )

    # Nemo (GTK) sidebar bookmarks — declarative pins for ~/Downloads
    # and ~/Dropbox in the file manager's left menu.
    bookmarks = dellan.succeed(
        "cat /home/jonathan/.config/gtk-3.0/bookmarks"
    )
    assert "file:///home/jonathan/Downloads" in bookmarks, \
        f"Downloads bookmark missing:\n{bookmarks}"
    assert "file:///home/jonathan/Dropbox" in bookmarks, \
        f"Dropbox bookmark missing:\n{bookmarks}"

    # gnome-screenshot — the binary fired by the Print / Shift+Print
    # Cinnamon custom keybindings.
    dellan.succeed("test -x /etc/profiles/per-user/jonathan/bin/gnome-screenshot")

    # Cinnamon dconf — Print / Shift+Print custom keybindings present and
    # the default media-keys screenshot bindings cleared.
    dconf_dump = dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "dconf dump /org/cinnamon/desktop/keybindings/'"
    )
    print("[diag] cinnamon keybindings dconf dump:\n" + dconf_dump)
    assert "[custom-keybindings/custom-screenshot-clipboard]" in dconf_dump, \
        f"missing custom-screenshot-clipboard entry:\n{dconf_dump}"
    assert "[custom-keybindings/custom-screenshot-area-clipboard]" in dconf_dump, \
        f"missing custom-screenshot-area-clipboard entry:\n{dconf_dump}"
    assert "binding=['Print']" in dconf_dump, \
        f"Print not bound to fullscreen-to-clipboard:\n{dconf_dump}"
    assert "binding=['<Shift>Print']" in dconf_dump, \
        f"Shift+Print not bound to area-to-clipboard:\n{dconf_dump}"
    # Command paths include the nix store prefix; assert the gnome-screenshot
    # binary suffix + args. `--clipboard'` (with trailing single-quote) pins
    # the fullscreen-only command since `--area --clipboard'` matches the
    # other entry too.
    assert "gnome-screenshot --clipboard'" in dconf_dump, \
        f"fullscreen binding command missing:\n{dconf_dump}"
    assert "gnome-screenshot --area --clipboard'" in dconf_dump, \
        f"area binding command missing:\n{dconf_dump}"
    # Default media-keys screenshot bindings cleared
    media_keys = dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "dconf read /org/cinnamon/desktop/keybindings/media-keys/screenshot' || echo EMPTY"
    ).strip()
    # dconf prints typed empty arrays as `@as []`; bare `[]` or empty string
    # are also acceptable signals that the binding is unset.
    assert media_keys in ("@as []", "[]", "EMPTY", ""), \
        f"default screenshot media-key not cleared: {media_keys!r}"

    # XDG MIME defaults — magnet links and .torrent files route to qBittorrent.
    # User-realistic check: `xdg-open magnet:?xt=...` resolves via xdg-mime,
    # which reads ~/.config/mimeapps.list (Home Manager writes it from
    # xdg.mimeApps.defaultApplications).
    mimeapps = dellan.succeed("cat /home/jonathan/.config/mimeapps.list")
    print("[diag] mimeapps.list:\n" + mimeapps)
    assert "x-scheme-handler/magnet=org.qbittorrent.qBittorrent.desktop" in mimeapps, \
        f"magnet handler not mapped to qbittorrent:\n{mimeapps}"
    assert "application/x-bittorrent=org.qbittorrent.qBittorrent.desktop" in mimeapps, \
        f".torrent handler not mapped to qbittorrent:\n{mimeapps}"
    magnet_default = dellan.succeed(
        "su - jonathan -c 'xdg-mime query default x-scheme-handler/magnet'"
    ).strip()
    assert magnet_default == "org.qbittorrent.qBittorrent.desktop", \
        f"xdg-mime resolves magnet to {magnet_default!r}, expected qbittorrent"
    torrent_default = dellan.succeed(
        "su - jonathan -c 'xdg-mime query default application/x-bittorrent'"
    ).strip()
    assert torrent_default == "org.qbittorrent.qBittorrent.desktop", \
        f"xdg-mime resolves .torrent to {torrent_default!r}, expected qbittorrent"

    # LightDM display-setup-script — silences the X11 bell so arrow
    # keys at the password field don't "twoink". Greeter user is
    # `lightdm`, separate from jonathan's user-session dconf, so the
    # silencing has to happen at the X-server level. Hook is
    # `display-setup-script` (runs on every X start) rather than
    # `greeter-setup-script` (skipped on autologin path).
    lightdm_conf = dellan.succeed("cat /etc/lightdm/lightdm.conf")
    print("[diag] /etc/lightdm/lightdm.conf:\n" + lightdm_conf)
    assert "display-setup-script=" in lightdm_conf, \
        f"display-setup-script not wired into lightdm.conf:\n{lightdm_conf}"
    setup_script = dellan.succeed(
        "awk -F= '/^display-setup-script=/ {print $2; exit}' /etc/lightdm/lightdm.conf"
    ).strip()
    assert setup_script, "display-setup-script value empty"
    setup_body = dellan.succeed(f"cat {setup_script}")
    assert "xset b off" in setup_body, \
        f"display-setup-script does not silence X11 bell:\n{setup_body}"

    # Empirical: with autologin enabled (test scaffolding mirrors
    # feature-vm), display-setup-script runs and the X server reports
    # bell volume 0. Confirms the hook fires on the autologin path —
    # the failure mode that greeter-setup-script had.
    #
    # Sync barrier: `wait_for_x` only confirms the X socket is up; it
    # does not wait for display-setup-script to finish. The script
    # touches /run/x11-bell-silenced after xset, so this gives a
    # deterministic post-condition to wait on (no retry loop, no race).
    dellan.wait_for_x()
    dellan.wait_for_file("/run/x11-bell-silenced")
    bell_q = dellan.succeed(
        "env DISPLAY=:0 XAUTHORITY=/var/run/lightdm/root/:0 "
        "xset q | grep -i 'bell percent'"
    )
    print("[diag] xset bell state: " + bell_q)
    assert "bell percent:  0" in bell_q, \
        f"X server bell not silenced after display-setup-script:\n{bell_q}"
  '';
}
