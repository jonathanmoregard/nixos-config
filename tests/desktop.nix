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
      services.xserver.displayManager.autoLogin = {
        enable = true;
        user = "jonathan";
      };
      services.displayManager.defaultSession = "cinnamon";
      environment.systemPackages = with pkgs; [ jq ];
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
  '';
}
