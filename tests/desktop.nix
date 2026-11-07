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
#   - cinnamon-rescue: a wedged main loop reads as hung and is recovered
#     after three consecutive failures; an unowned bus name never is; the
#     cooldown both holds and expires; the failure count does not outlive
#     the boot; `now` recovers on demand.
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

  # Stands in for gdbus so cinnamon-rescue's branching can be driven without
  # wedging a real Cinnamon. $FAKE_GDBUS_MODE picks the shape:
  #   alive   — name owned, the property read answers
  #   hung    — name owned, the property read times out
  #   unowned — org.Cinnamon has no owner at all (Cinnamon not running)
  #
  # It rejects anything other than the exact call cinnamon-rescue is supposed
  # to make, so aiming the probe at the wrong name or path fails the lane
  # rather than passing it. Peer.Ping and Introspect are rejected outright:
  # GDBus answers both from its worker thread, so a Cinnamon whose main loop
  # has stopped dispatching still replies to them, and a probe built on them
  # can never detect the hang this exists to recover from.
  fakeGdbus = pkgs.writeScriptBin "fake-gdbus" ''
    #!${pkgs.bash}/bin/bash
    mode="''${FAKE_GDBUS_MODE:-alive}"
    args="$*"
    case "$args" in
      *"org.freedesktop.DBus.GetNameOwner org.Cinnamon"*)
        if [ "$mode" = unowned ]; then
          echo "Error: org.Cinnamon has no owner" >&2
          exit 1
        fi
        echo "(':1.42',)" ;;
      *"org.freedesktop.DBus.GetConnectionUnixProcessID org.Cinnamon"*)
        if [ "$mode" = unowned ]; then
          echo "Error: org.Cinnamon has no owner" >&2
          exit 1
        fi
        # PID 1 always exists, so the /proc capture has a real target.
        echo "(uint32 ''${FAKE_PID:-1},)" ;;
      *"org.freedesktop.DBus.Properties.Get org.Cinnamon CinnamonVersion"*)
        case "$args" in
          *"--dest org.Cinnamon "*) : ;;
          *) echo "FAKE: property read not aimed at org.Cinnamon: $args" >&2; exit 64 ;;
        esac
        case "$args" in
          *"--object-path /org/Cinnamon "*) : ;;
          *) echo "FAKE: property read on wrong object path: $args" >&2; exit 64 ;;
        esac
        if [ "$mode" = alive ]; then
          echo "(<'6.6.9'>,)"
        else
          echo "Error: Timeout was reached" >&2
          exit 1
        fi ;;
      *Peer.Ping*|*Introspect*)
        echo "FAKE: probed with a call GDBus answers off the main loop: $args" >&2
        exit 64 ;;
      *)
        echo "FAKE: unexpected call: $args" >&2
        exit 64 ;;
    esac
  '';

  # Records that a restart was attempted, instead of replacing the window
  # manager out from under the test session.
  fakeRestart = pkgs.writeScriptBin "fake-cinnamon-restart" ''
    #!${pkgs.bash}/bin/bash
    echo restarted >> "$CINNAMON_RESCUE_RESTART_LOG"
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
    workstation.wait_for_unit("multi-user.target")
    workstation.wait_for_unit("home-manager-jonathan.service")
    workstation.wait_for_unit("default.target", "jonathan")

    # Voquill must NOT have a cinnamon autostart entry — it is launched by
    # systemd.user.services.voquill (home/router-services.nix); a duplicate
    # autostart entry raced with the systemd unit on every login
    # (proposals/2026-05-05-voquill-autostart-race.md).
    workstation.succeed(
        "test ! -e /home/jonathan/.config/autostart/voquill.desktop"
    )

    # Default media-keys screenshot bindings cleared, so PrtSc does not
    # double-fire into both "save to ~/Pictures" and the clipboard binding.
    media_keys = workstation.succeed(
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
    magnet_default = workstation.succeed(
        "su - jonathan -c 'xdg-mime query default x-scheme-handler/magnet'"
    ).strip()
    assert magnet_default == "org.qbittorrent.qBittorrent.desktop", \
        f"xdg-mime resolves magnet to {magnet_default!r}, expected qbittorrent"
    torrent_default = workstation.succeed(
        "su - jonathan -c 'xdg-mime query default application/x-bittorrent'"
    ).strip()
    assert torrent_default == "org.qbittorrent.qBittorrent.desktop", \
        f"xdg-mime resolves .torrent to {torrent_default!r}, expected qbittorrent"

    for mime in ("video/mp4", "video/x-matroska", "video/webm"):
        video_default = workstation.succeed(
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
    workstation.wait_for_x()
    workstation.wait_for_file("/run/x11-bell-silenced")
    bell_q = workstation.succeed(
        "env DISPLAY=:0 XAUTHORITY=/var/run/lightdm/root/:0 "
        "xset q | grep -i 'bell percent'"
    )
    print("[diag] xset bell state: " + bell_q)
    assert "bell percent:  0" in bell_q, \
        f"X server bell not silenced after display-setup-script:\n{bell_q}"

    # libXcursor apps (kitty's I-beam, Chrome) only get the cursor theme
    # through Xcursor.theme; without it they draw X's tiny core glyphs.
    # home.pointerCursor writes ~/.Xresources and the session start must
    # merge it into the server's RESOURCE_MANAGER.
    workstation.wait_until_succeeds(
        "env DISPLAY=:0 XAUTHORITY=/var/run/lightdm/root/:0 "
        "xrdb -query | grep -qx 'Xcursor.theme:\tBibata-Modern-Classic'",
        timeout=120,
    )

    # cinnamon-rescue (home/cinnamon-watchdog.nix): recover a wedged Cinnamon
    # main loop without a reboot.
    #
    # The probe reads a property off Cinnamon's own interface instead of
    # calling Peer.Ping, because GDBus answers Peer.Ping from its worker
    # thread — a Cinnamon that has stopped dispatching still replies to it.
    # fake-gdbus rejects Peer.Ping outright so that regression fails here.
    rstate = "/tmp/rescue-reports"
    rcount = "/tmp/rescue-counters"
    rlog = "/tmp/rescue-restarts"
    fake_pid = 1

    def rescue_run(cmd, mode="alive", threshold=3, cooldown=300):
        return workstation.execute(
            "su - jonathan -c 'export XDG_RUNTIME_DIR=/run/user/$(id -u) "
            "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus "
            f"FAKE_GDBUS_MODE={mode} FAKE_PID={fake_pid} "
            f"CINNAMON_RESCUE_GDBUS=${fakeGdbus}/bin/fake-gdbus "
            f"CINNAMON_RESCUE_STATE_DIR={rstate} "
            f"CINNAMON_RESCUE_COUNTER_DIR={rcount} "
            f"CINNAMON_RESCUE_RESTART_LOG={rlog} "
            f"CINNAMON_RESCUE_RESTART_CMD=${fakeRestart}/bin/fake-cinnamon-restart "
            f"CINNAMON_RESCUE_THRESHOLD={threshold} "
            f"CINNAMON_RESCUE_COOLDOWN_SECS={cooldown}; "
            f"cinnamon-rescue {cmd}'"
        )

    def rescue(cmd, mode="alive", **kw):
        return rescue_run(cmd, mode, **kw)[0]

    # Asserts the exit code too: a traceback in a branch that happens not to
    # restart would otherwise read as correct "did not restart" behaviour.
    def rescue_ok(cmd, mode="alive", **kw):
        rc, out = rescue_run(cmd, mode, **kw)
        assert rc == 0, f"cinnamon-rescue {cmd} (mode={mode}) exited {rc}:\n{out}"
        return out

    def restarts():
        return int(
            workstation.succeed(f"wc -l < {rlog} 2>/dev/null || echo 0").strip()
        )

    def reset_rescue():
        workstation.succeed(
            f"rm -rf {rstate} {rcount} {rlog}; "
            f"install -o jonathan -m 644 /dev/null {rlog}"
        )

    # The real probe, against the live Cinnamon in this session. The fakes
    # below prove the branching; this proves the probe itself is pointed at
    # something that answers.
    workstation.succeed(
        "su - jonathan -c 'export XDG_RUNTIME_DIR=/run/user/$(id -u); "
        "systemctl --user is-active cinnamon-watchdog.timer'"
    )
    # Cinnamon's shell may take a while to claim org.Cinnamon here, so wait
    # for it, then assert the discriminating property: a session that is NOT
    # wedged must never read as hung, which is the misreport that would make
    # the watchdog replace a healthy window manager.
    def live_probe():
        return workstation.execute(
            "su - jonathan -c 'export XDG_RUNTIME_DIR=/run/user/$(id -u) "
            "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus; "
            "cinnamon-rescue probe'"
        )[0]

    live = live_probe()
    for _ in range(12):
        if live == 0:
            break
        workstation.sleep(5)
        live = live_probe()
    print(f"[diag] live cinnamon-rescue probe: {live} (0 alive, 1 hung, 2 absent)")
    assert live in (0, 2), \
        f"probe reported hung (rc={live}) in a session that is not wedged"

    # Fail-safe: an unowned org.Cinnamon means Cinnamon is not running at all
    # (greeter, non-Cinnamon session). Never "recover" it there.
    reset_rescue()
    assert rescue("probe", mode="unowned") == 2, \
        "an unowned bus name must read as absent, not hung"
    for _ in range(5):
        rescue_ok("check", mode="unowned")
    assert restarts() == 0, \
        "watchdog restarted Cinnamon while its bus name was unowned"

    # Hung: name owned, main loop silent. Must not fire below the threshold.
    reset_rescue()
    assert rescue("probe", mode="hung") == 1, \
        "a silent main loop must read as hung"
    rescue_ok("check", mode="hung")
    rescue_ok("check", mode="hung")
    assert restarts() == 0, "watchdog fired before 3 consecutive failed probes"

    # Threshold reached: recover, and leave a report carrying the real pid,
    # the probe actually used, and a real thread state — so a capture that
    # quietly stopped reading /proc fails here instead of passing on labels.
    rescue_ok("check", mode="hung")
    assert restarts() == 1, "watchdog did not restart Cinnamon at the threshold"
    diag = workstation.succeed(f"cat {rstate}/hang-*.txt")
    assert f"pid={fake_pid}" in diag, f"report does not name the pid:\n{diag}"
    assert "Properties.Get" in diag, \
        f"report does not name the probe actually used:\n{diag}"
    assert f"tid={fake_pid} state=S" in diag, \
        f"report carries no real thread state for pid {fake_pid}:\n{diag}"

    # Cooldown holds inside the window...
    for _ in range(3):
        rescue_ok("check", mode="hung")
    assert restarts() == 1, "cooldown did not suppress a second restart"

    # ...and expires. Backdating last-restart is what makes the assertion
    # above falsifiable: a cooldown that never ended would satisfy it too.
    workstation.succeed(
        f"echo 1 > {rcount}/last-restart; chown jonathan {rcount}/last-restart"
    )
    for _ in range(3):
        rescue_ok("check", mode="hung")
    assert restarts() == 2, \
        "an expired cooldown still refused to restart, so it never ends"

    # A reply resets the count, so isolated blips never add up to a restart.
    reset_rescue()
    rescue_ok("check", mode="hung")
    rescue_ok("check", mode="hung")
    rescue_ok("check", mode="alive")
    rescue_ok("check", mode="hung")
    rescue_ok("check", mode="hung")
    assert restarts() == 0, "a successful probe did not reset the failure counter"

    # The count belongs to the boot. Clearing the counter dir is what a reboot
    # does to XDG_RUNTIME_DIR; a count that survived it would let the next
    # session's first failure skip the threshold entirely.
    reset_rescue()
    rescue_ok("check", mode="hung")
    rescue_ok("check", mode="hung")
    workstation.succeed(f"rm -rf {rcount}")
    rescue_ok("check", mode="hung")
    assert restarts() == 0, \
        "a failure count outlived the boot and skipped the threshold"

    # `now` is the manual escape hatch over SSH or Ctrl+Alt+F2: it recovers on
    # demand, with no accumulated failures and no regard for the cooldown.
    reset_rescue()
    rescue_ok("now", mode="hung")
    assert restarts() == 1, "`cinnamon-rescue now` did not recover on demand"
    status = rescue_ok("status", mode="alive")
    assert "failures=0/3" in status, f"status does not report the counter:\n{status}"

    # Runs last: it takes ~40 s, and the X-bell check above samples server
    # state at one instant, so running this first shifted that sample past
    # the Cinnamon session's own bell setup.
    # lid-guard (home/lid-guard.nix): the lid suspends unless a Claude/Codex
    # pane has work in flight. A fake `claude` (comm == "claude", so it is
    # the agent ancestor agent-activity looks for) pipes real hook JSON into
    # `agent-activity mark` the way the settings.json hook does, then stays
    # alive for $2 seconds. Asserted on the dconf keys csd-power reads.
    def as_j(cmd):
        return workstation.succeed(
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
            workstation.sleep(0.5)
        assert got == want, f"{why}: lid actions {got}, want {want}\n" + as_j("agent-activity status || true")

    hook_n = [0]

    def payload_file(event, session, extra=""):
        hook_n[0] += 1
        path = f"/tmp/hook-{hook_n[0]}.json"
        workstation.succeed(
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
    workstation.sleep(6)
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
    workstation.sleep(6)
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
    workstation.sleep(2)
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
