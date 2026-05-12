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
# Run: nix build .#checks.x86_64-linux.vm-desktop -L
{ pkgs, inputs }:
(import ./lib/common.nix { inherit pkgs inputs; }).mkTest {
  name = "vm-desktop";
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

    # LightDM greeter-setup-script — silences the X11 bell so arrow keys
    # at the password field don't "twoink". Greeter user is `lightdm`,
    # separate from jonathan's user-session dconf, so the silencing has
    # to happen at the X-server level before the greeter starts.
    lightdm_conf = dellan.succeed("cat /etc/lightdm/lightdm.conf")
    print("[diag] /etc/lightdm/lightdm.conf:\n" + lightdm_conf)
    assert "greeter-setup-script=" in lightdm_conf, \
        f"greeter-setup-script not wired into lightdm.conf:\n{lightdm_conf}"
    # Resolve the script path the greeter-setup-script line points at,
    # then assert the body calls xset to disable the bell.
    setup_script = dellan.succeed(
        "awk -F= '/^greeter-setup-script=/ {print $2; exit}' /etc/lightdm/lightdm.conf"
    ).strip()
    assert setup_script, "greeter-setup-script value empty"
    setup_body = dellan.succeed(f"cat {setup_script}")
    assert "xset b off" in setup_body, \
        f"greeter-setup-script does not silence X11 bell:\n{setup_body}"
  '';
}
