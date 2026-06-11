# vm-base: boot + HM activation smoke test.
#
# Asserts the absolute minimum every other lane inherits:
#   - multi-user.target reached
#   - home-manager activation completed for jonathan
#   - systemd --user (via linger) reached default.target for jonathan
#   - X server up (autoLogin path; catches LightDM regressions in
#     the lightest lane before they trip the heavier ones)
#   - kindle udev rule file present with the expected unset clauses
#     (vm-base-only by design: this is the lane that imports the full
#     dellan host config via mkTest, and we only need to verify the
#     payload once per build — mkMinimalTest / mkFeatureTest lanes
#     don't include kindle.nix)
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
    # (calibre needs libusb). Rule clears ID_MTP_DEVICE so
    # 69-libmtp.rules:10's early-exit symlink branch can't fire, but
    # leaves ID_MEDIA_PLAYER alone so 70-uaccess.rules:70 still grants
    # the user ACL on the /dev/bus/usb/N/M node (cleared by PR #108,
    # restored here). The VM can't model real USB so we only assert
    # the rule file is on disk with the right clauses — runtime
    # behaviour is verified on dellan by replugging the kindle.
    kindle_rule = dellan.succeed("cat /etc/udev/rules.d/60-kindle.rules")
    assert 'ATTR{idVendor}=="1949"' in kindle_rule, \
        f"kindle rule missing vendor match:\n{kindle_rule}"
    assert 'ATTR{idProduct}=="9981"' in kindle_rule, \
        f"kindle rule missing product (paperwhite) match:\n{kindle_rule}"
    assert 'ENV{ID_MTP_DEVICE}=""' in kindle_rule, \
        f"kindle rule missing ID_MTP_DEVICE unset:\n{kindle_rule}"
    # Regression guard for PR #108 → PR #109: must NOT clear
    # ID_MEDIA_PLAYER (breaks 70-uaccess.rules:70 user-ACL grant).
    # Substring match is safe here because writeTextFile only writes
    # the `text` field — Nix-source comments don't leak into the
    # deployed rule file. If a future edit adds rule-file comments via
    # writeTextFile body, tighten this to a regex/word-boundary check.
    assert 'ENV{ID_MEDIA_PLAYER}=""' not in kindle_rule, \
        f"kindle rule clears ID_MEDIA_PLAYER — breaks uaccess; see PR #108 regression:\n{kindle_rule}"

    # claude-agent-N users (modules/nixos/claude-agent-users.nix) must be
    # hidden from the LightDM greeter. slick-greeter builds its user list
    # from AccountsService, which drops accounts whose SystemAccount
    # property is true — assert the property the greeter actually filters
    # on, not just the keyfile on disk.
    def system_account(user):
        path = dellan.succeed(
            "busctl call org.freedesktop.Accounts /org/freedesktop/Accounts"
            f" org.freedesktop.Accounts FindUserByName s {user}"
            " | awk '{print $2}'"
        ).strip().strip('"')
        return dellan.succeed(
            f"busctl get-property org.freedesktop.Accounts {path}"
            " org.freedesktop.Accounts.User SystemAccount"
        ).strip()

    # Enumerate agents from /etc/passwd rather than hardcoding the list:
    # the module scales with services.claudeAgentUsers.count, and a
    # hardcoded list would silently skip claude-agent-4+ if count grows.
    agents = dellan.succeed(
        "getent passwd | awk -F: '/^claude-agent-/{print $1}'"
    ).split()
    # Floor assumes dellan keeps services.claudeAgentUsers.count >= 3
    # (testScript can't read cfg.count); lower the floor if count drops.
    assert len(agents) >= 3, \
        f"expected >=3 claude-agent users, found {agents}"
    for agent in agents:
        prop = system_account(agent)
        assert prop == "b true", \
            f"{agent} visible in greeter user list (SystemAccount={prop!r})"
    # jonathan must stay visible — guard against over-hiding.
    jprop = system_account("jonathan")
    assert jprop == "b false", \
        f"jonathan hidden from greeter (SystemAccount={jprop!r})"

    # The drift-warning banner (home/jonathan.nix loginExtra) is gated to
    # interactive shells; it must NOT leak into a non-interactive
    # `su - -c '…'`, or it pollutes scripted output (it previously broke
    # the GEMINI_API_KEY_FILE assertion below, and would break any su -c
    # parse like the camera-watchdog checks).
    drift_leak = dellan.succeed("su - jonathan -c 'true'")
    assert "drift warning" not in drift_leak, (
        f"drift banner leaked into non-interactive login shell:\n{drift_leak}"
    )

    # home.sessionVariables.GEMINI_API_KEY_FILE must reach jonathan's
    # interactive shell — prose-decorate --audio and any future Gemini
    # tool reads this env var to find the agenix-decrypted key. `su -`
    # loads jonathan's login shell, which sources the HM-generated env
    # files; assert the value matches the agenix path the host wires up.
    gemini_var = dellan.succeed(
        "su - jonathan -c 'echo $GEMINI_API_KEY_FILE'"
    ).strip()
    assert gemini_var == "/run/agenix/gemini-api-key", (
        f"GEMINI_API_KEY_FILE in jonathan's login shell = {gemini_var!r}, "
        f"expected '/run/agenix/gemini-api-key'"
    )

    # ── IPU6 camera self-heal watchdog (modules/nixos/laptop.nix) ──
    # The real recovery can't be modelled in a VM (no OV02C10 sensor /
    # IVSC), so — like the kindle udev rule above — this asserts the
    # wiring is installed correctly and that the script's healthy/no-op
    # path runs cleanly under real systemd. The state machine itself is
    # covered exhaustively by the runtime-invocation suite; full sensor
    # recovery is verified on dellan after deploy.
    dellan.succeed(
        "systemctl cat ipu6-camera-watchdog.timer "
        "| grep -q 'OnUnitActiveSec=12s'"
    )
    cam_script = dellan.succeed(
        "systemctl cat ipu6-camera-watchdog.service "
        "| awk -F= '/^ExecStart=/{print $2}' | tr -d '\"'"
    ).strip()
    # Recovery must restart the relay by name and key off the waitFrame
    # signal (a rename of either silently breaks self-heal).
    dellan.succeed(f"grep -q 'systemctl restart' {cam_script}")
    dellan.succeed(f"grep -q 'v4l2-relayd-ipu6.service' {cam_script}")
    dellan.succeed(f"grep -q 'waitFrame, time out happens' {cam_script}")
    # Hard regression guard: the watchdog must NEVER touch the PCI bus.
    # Unbind/rebind of intel-ipu6 corrupts IVSC/CSE state and turns a
    # soft wedge into a reboot-only hard wedge (learned empirically).
    dellan.fail(f"grep -q 'unbind' {cam_script}")
    dellan.fail(f"grep -q 'intel-ipu6' {cam_script}")
    # Give-up latch + notify flag — regression guard against restart-
    # forever (same failure class as the microvm watchdog incident).
    dellan.succeed(f"grep -q 'restart-burst-count' {cam_script}")
    dellan.succeed(f"grep -q 'GIVING UP' {cam_script}")
    dellan.succeed(f"grep -q '/run/ipu6-camera-notify/wedged' {cam_script}")
    dellan.succeed("test -f /etc/systemd/user/ipu6-camera-watchdog-notify.path")
    dellan.succeed(
        "test -f /etc/systemd/user/ipu6-camera-watchdog-notify.service"
    )
    cam_notify_perms = dellan.succeed(
        "stat -c '%a %U' /run/ipu6-camera-notify"
    ).strip()
    assert cam_notify_perms == "755 root", (
        f"camera notify flag dir perms expected '755 root', got {cam_notify_perms!r}"
    )
    # No camera in the VM → relay emits no waitFrame → healthy no-op path.
    # A fresh run must exit 0, not fight a non-existent wedge.
    dellan.succeed("systemctl start ipu6-camera-watchdog.service")
    rc = dellan.succeed(
        "systemctl is-failed ipu6-camera-watchdog.service || true"
    ).strip()
    assert rc != "failed", (
        f"camera watchdog must no-op cleanly with no camera; got is-failed={rc!r}"
    )
    # Corrupt state file MUST NOT brick the watchdog (read_int clamp);
    # mirrors the microvm watchdog's corruption guard.
    dellan.succeed(
        "mkdir -p /run/ipu6-camera-watchdog "
        "&& printf 'abc\\n0\\n5garbage' > /run/ipu6-camera-watchdog/restart-burst-count"
    )
    dellan.succeed("systemctl start ipu6-camera-watchdog.service")
    rc = dellan.succeed(
        "systemctl is-failed ipu6-camera-watchdog.service || true"
    ).strip()
    assert rc != "failed", (
        f"camera watchdog must survive corrupted state; got is-failed={rc!r}"
    )
  '';
}
