# vm-base: boot + HM activation smoke test.
#
# Asserts the absolute minimum every other lane inherits:
#   - multi-user.target reached
#   - home-manager activation completed for jonathan
#   - systemd --user (via linger) reached default.target for jonathan
#   - X server up (autoLogin path; catches LightDM regressions in
#     the lightest lane before they trip the heavier ones)
#
# Run: nix build .#checks.x86_64-linux.vm-base -L
{ pkgs, inputs }:
(import ./lib/common.nix { inherit pkgs inputs; }).mkTest {
  name = "vm-base";
  testScript = ''
    dellan.wait_for_unit("multi-user.target")
    dellan.wait_for_unit("home-manager-jonathan.service")
    # systemd --user for jonathan comes up via linger
    dellan.wait_for_unit("default.target", "jonathan")
    # X session must come up too — every lane inherits autoLogin from
    # tests/lib/common.nix, so a LightDM regression should fail here
    # rather than masquerade as a kitty/desktop-lane failure later.
    dellan.wait_for_x()

    # Crontab source includes the bare-repo main-fetch line so worktrees
    # branched off ~/Repos/nixos-config/main don't start behind origin/main.
    # Assert on the home.file source rather than `crontab -l`: the live
    # crontab is installed by an activation hook whose timing relative to
    # /run/wrappers/bin/crontab in this VM image isn't load-bearing for
    # production (real hardware activates after setuid-wrappers).
    crontab_src = dellan.succeed(
        "cat /home/jonathan/.config/crontab"
    )
    assert (
        "git -C /home/jonathan/Repos/nixos-config fetch origin main:main"
        in crontab_src
    ), f"nixos-config bare-repo fetch line missing from crontab source:\n{crontab_src}"

    # modules/nixos/kindle.nix installs a udev rule that stops
    # gvfs-mtp-volume-monitor from claiming the kindle USB interface
    # (calibre needs libusb). Two prior attempts failed because either
    # the rule loaded too late or only blocked the libmtp probe path
    # while leaving libmtp's hwdb-set ID_MTP_DEVICE=1 intact. The
    # current rule unsets both ID_MTP_DEVICE and ID_MEDIA_PLAYER so
    # 69-libmtp.rules' early-exit symlink branch can't fire. The VM
    # can't model real USB so we only assert the rule file is on disk
    # with the right unset clauses — runtime behaviour is verified on
    # dellan by replugging the kindle.
    kindle_rule = dellan.succeed("cat /etc/udev/rules.d/60-kindle.rules")
    assert 'ATTR{idVendor}=="1949"' in kindle_rule, \
        f"kindle rule missing vendor match:\n{kindle_rule}"
    assert 'ATTR{idProduct}=="9981"' in kindle_rule, \
        f"kindle rule missing product (paperwhite) match:\n{kindle_rule}"
    assert 'ENV{ID_MTP_DEVICE}=""' in kindle_rule, \
        f"kindle rule missing ID_MTP_DEVICE unset:\n{kindle_rule}"
    assert 'ENV{ID_MEDIA_PLAYER}=""' in kindle_rule, \
        f"kindle rule missing ID_MEDIA_PLAYER unset:\n{kindle_rule}"
  '';
}
