# vm-desktop: Cinnamon screenshot / clipboard plumbing.
#
# Covers:
#   - no duplicate voquill autostart entry (login race regression)
#   - Cinnamon dconf: default media-keys screenshot binding cleared (so
#     PrtSc doesn't double-fire into both "save to ~/Pictures" and "to
#     clipboard")
#   - xdg-mime resolves magnet/.torrent/video types to their handlers
#   - the X11 bell is actually silent after display-setup-script runs
#   - lid-guard: lid-close action is suspend by default, "nothing" while
#     agent hooks report work in flight (turn, subagent, young background
#     Bash), back to suspend on Stop / dead agent / SessionEnd.
#
# Uses mkFeatureTest with home/_test-desktop.nix — HM closure is
# jonathan.nix + cinnamon.nix + desktop-apps.nix (no kitty / claude
# /autodoro / router-services / etc). extraModules pull in the system
# Cinnamon module + lightdm + autoLogin so dconf is populated when the
# Cinnamon session comes up, plus jq for the testScript's grep paths.
#
# Run: nix build .#checks.x86_64-linux.vm-desktop -L
{ pkgs, inputs }:
let
  # Stands in for a Claude Code process: comm is "claude" (the basename
  # execve saw), it feeds a hook payload file to `agent-activity mark` the
  # way the settings.json hook does, then stays alive for $2 seconds. The
  # trailing `true` keeps bash from exec-ing sleep, which would rename the
  # process and orphan the marker's pid.
  fakeClaude = pkgs.writeScriptBin "claude" ''
    #!${pkgs.bash}/bin/bash
    agent-activity mark < "$1"
    sleep "$2"
    true
  '';
in
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

    # Voquill must NOT have a cinnamon autostart entry — it is launched by
    # systemd.user.services.voquill (home/router-services.nix); a duplicate
    # autostart entry raced with the systemd unit on every login
    # (proposals/2026-05-05-voquill-autostart-race.md).
    dellan.succeed(
        "test ! -e /home/jonathan/.config/autostart/voquill.desktop"
    )

    # Default media-keys screenshot bindings cleared, so PrtSc does not
    # double-fire into both "save to ~/Pictures" and the clipboard binding.
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
    # which must find both mimeapps.list and the handler's .desktop file.
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

    for mime in ("video/mp4", "video/x-matroska", "video/webm"):
        video_default = dellan.succeed(
            f"su - jonathan -c 'xdg-mime query default {mime}'"
        ).strip()
        assert video_default == "vlc.desktop", \
            f"xdg-mime resolves {mime} to {video_default!r}, expected vlc.desktop"

    # LightDM display-setup-script — silences the X11 bell so arrow
    # keys at the password field don't "twoink". Greeter user is
    # `lightdm`, separate from jonathan's user-session dconf, so the
    # silencing has to happen at the X-server level. Hook is
    # `display-setup-script` (runs on every X start) rather than
    # `greeter-setup-script` (skipped on autologin path).
    #
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

    # Runs last: it takes ~40 s, and the X-bell check above samples server
    # state at one instant, so running this first shifted that sample past
    # the Cinnamon session's own bell setup.
    # lid-guard (home/lid-guard.nix): the lid suspends unless a Claude/Codex
    # pane has work in flight. A fake `claude` (comm == "claude", so it is
    # the agent ancestor agent-activity looks for) pipes real hook JSON into
    # `agent-activity mark` the way the settings.json hook does, then stays
    # alive for $2 seconds. Asserted on the dconf keys csd-power reads.
    def as_j(cmd):
        return dellan.succeed(
            "su - jonathan -c 'export XDG_RUNTIME_DIR=/run/user/$(id -u) "
            "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus; "
            + cmd + "'"
        )

    def lid_actions():
        return tuple(
            as_j(f"dconf read /org/cinnamon/settings-daemon/plugins/power/{k}").strip()
            for k in ("lid-close-ac-action", "lid-close-battery-action")
        )

    def expect_lid(action, why):
        want = (f"'{action}'", f"'{action}'")
        for _ in range(20):
            got = lid_actions()
            if got == want:
                return
            dellan.sleep(0.5)
        assert got == want, f"{why}: lid actions {got}, want {want}\n" + as_j("agent-activity status || true")

    hook_n = [0]

    def payload_file(event, session, extra=""):
        hook_n[0] += 1
        path = f"/tmp/hook-{hook_n[0]}.json"
        dellan.succeed(
            f"echo '{{\"hook_event_name\": \"{event}\", \"session_id\": \"{session}\"{extra}}}' > {path}; chmod 644 {path}"
        )
        return path

    def hook(event, session, extra="", alive=600):
        path = payload_file(event, session, extra)
        as_j(f"(${fakeClaude}/bin/claude {path} {alive} >/dev/null 2>&1 &); sleep 1")

    as_j("systemctl --user is-active lid-guard.timer")
    expect_lid("suspend", "default with no agent activity")

    # Open turn → stays awake; Stop (control back to user) → suspends.
    hook("UserPromptSubmit", "s1")
    expect_lid("nothing", "UserPromptSubmit opens a turn")
    hook("Stop", "s1")
    expect_lid("suspend", "Stop hands control back")

    # A permission prompt is idle: nothing progresses behind a closed lid
    # until it is answered. The next tool result means work resumed.
    hook("UserPromptSubmit", "s1")
    hook("PermissionRequest", "s1")
    expect_lid("suspend", "PermissionRequest waits on the user")
    hook("PostToolUse", "s1")
    expect_lid("nothing", "PostToolUse after approval resumes work")

    # Idle TTL: a turn with no hook activity (an ESC skips Stop) lapses;
    # PostToolUse refreshes it.
    dellan.sleep(6)
    stale = as_j("AGENT_ACTIVITY_IDLE_TTL_SECS=5 agent-activity status").strip()
    assert stale == "idle", f"marker with no hook activity past the TTL still counts:\n{stale}"
    hook("PostToolUse", "s1")
    fresh = as_j("AGENT_ACTIVITY_IDLE_TTL_SECS=5 agent-activity status").strip()
    assert fresh.startswith("active"), f"PostToolUse did not restore the turn:\n{fresh}"
    hook("Stop", "s1")
    expect_lid("suspend", "Stop hands control back")

    # Background subagent keeps it awake after Stop; its own tool hooks
    # (agent_id set) never reopen the main turn.
    hook("SubagentStart", "s1", ', "agent_id": "a1"')
    expect_lid("nothing", "background subagent pending")
    hook("PostToolUse", "s1", ', "agent_id": "a1"')
    subs = as_j("agent-activity status")
    assert "s1: turn" not in subs, f"subagent tool hook reopened the main turn:\n{subs}"
    hook("PermissionRequest", "s1", ', "agent_id": "a1"')
    expect_lid("suspend", "subagent waiting on a permission prompt")
    hook("PostToolUse", "s1", ', "agent_id": "a1"')
    expect_lid("nothing", "subagent resumed after approval")
    hook("SubagentStop", "s1", ', "agent_id": "a1"')
    expect_lid("suspend", "subagent finished, no turn open")

    # Crashed pane: the marker's agent pid dies → reaped on reconcile.
    hook("UserPromptSubmit", "s2", alive=5)
    expect_lid("nothing", "short-lived agent's turn")
    dellan.sleep(6)
    as_j("agent-activity reconcile")
    expect_lid("suspend", "dead agent pid must not pin the lid")

    # SessionEnd clears everything for that session.
    hook("UserPromptSubmit", "s3")
    hook("SubagentStart", "s3", ', "agent_id": "a2"')
    hook("SessionEnd", "s3")
    expect_lid("suspend", "SessionEnd clears the session")

    # Background Bash: a process holding a harness tasks/*.output open
    # counts, but only while younger than the cap (a dev server ages out).
    as_j("mkdir -p /tmp/claude-$(id -u)/proj/s4/tasks; "
         "(sleep 600 > /tmp/claude-$(id -u)/proj/s4/tasks/b1.output 2>&1 &); sleep 1; "
         "agent-activity reconcile")
    expect_lid("nothing", "young background bash")
    dellan.sleep(2)
    aged = as_j("AGENT_ACTIVITY_BASH_CAP_SECS=1 agent-activity status").strip()
    assert aged == "idle", f"background bash past the cap still counts:\n{aged}"
    as_j("pkill -f \"^sleep 600\"; agent-activity reconcile")
    expect_lid("suspend", "background bash exited")

    # The hook must never print into the agent's context or fail it.
    path = payload_file("UserPromptSubmit", "s5")
    out = as_j(f"agent-activity mark < {path}; echo rc=$?")
    assert out.strip() == "rc=0", f"mark printed or failed: {out!r}"
    out = as_j("echo not-json | agent-activity mark; echo rc=$?")
    assert out.strip() == "rc=0", f"mark on garbage printed or failed: {out!r}"
  '';
}
