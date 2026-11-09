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
#   - tooltip markup: the string CopyQ publishes for an empty clipboard
#     renders without Pango rejecting it, while real markup still renders.
#   - cinnamon-rescue: a wedged main loop reads as hung and is recovered
#     after three consecutive failures; an unowned bus name never is; the
#     cooldown both holds and expires; the failure count does not outlive
#     the boot; `now` recovers on demand.
#   - cinnamon-rescue escalation: a replacement that never takes over is
#     reported as a failed recovery rather than a success; the wedged
#     process is ended SIGTERM-then-SIGKILL to unblock it; a pid that is
#     not Cinnamon is never signalled; the blocked replacement is stopped.
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
    # A started replacement owns the name, so "unowned" has to be able to
    # become owned -- otherwise a started window manager could never be
    # observed to take over and that assertion could not pass honestly.
    took_over() {
      [ -n "''${FAKE_TAKEOVER_MARKER:-}" ] && [ -e "$FAKE_TAKEOVER_MARKER" ]
    }
    case "$args" in
      *"org.freedesktop.DBus.GetNameOwner org.Cinnamon"*)
        if [ "$mode" = unowned ] && ! took_over; then
          echo "Error: org.Cinnamon has no owner" >&2
          exit 1
        fi
        echo "(':1.42',)" ;;
      *"org.freedesktop.DBus.GetConnectionUnixProcessID org.Cinnamon"*)
        if [ "$mode" = unowned ] && ! took_over; then
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
        # A replacement that has taken over makes the property read answer
        # again, which is how a verified recovery is distinguished from a
        # launch that blocked in XWindowEvent and never managed anything.
        if [ "$mode" = alive ] || took_over; then
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
  # manager out from under the test session. FAKE_RESTART_TAKES_OVER=1 models
  # the replacement actually becoming the window manager; left unset it
  # models the launch blocking in XWindowEvent, which is what a wedged
  # Cinnamon does to it.
  fakeRestart = pkgs.writeScriptBin "fake-cinnamon-restart" ''
    #!${pkgs.bash}/bin/bash
    echo restarted >> "$CINNAMON_RESCUE_RESTART_LOG"
    if [ "''${FAKE_RESTART_TAKES_OVER:-0}" = 1 ]; then
      : > "$FAKE_TAKEOVER_MARKER"
    fi
  '';

  # argv[0] has to end in systemd-run for the transient-unit path (the
  # --setenv insertion and the unit name the cleanup stops) to be taken.
  fakeSystemdRun = pkgs.writeScriptBin "fake-systemd-run" ''
    #!${pkgs.bash}/bin/bash
    echo "$*" >> "$CINNAMON_RESCUE_RESTART_LOG"
  '';

  fakeSystemctl = pkgs.writeScriptBin "fake-systemctl" ''
    #!${pkgs.bash}/bin/bash
    echo "$*" >> "$CINNAMON_RESCUE_SYSTEMCTL_LOG"
  '';

  # Stands in for a wedged Cinnamon so the escalation has a real process to
  # end. execv sets argv[0] to the given name, which is what the guard
  # matches on; mode "trap" ignores SIGTERM, so only SIGKILL can end it.
  # Prints the victim's pid.
  fakeVictim = pkgs.writers.writePython3Bin "start-fake-cinnamon"
    { flakeIgnore = [ "E501" ]; }
    ''
      import os
      import sys

      name, mode = sys.argv[1], sys.argv[2]
      ignore = "import signal; signal.signal(signal.SIGTERM, signal.SIG_IGN); " if mode == "trap" else ""
      body = ignore + "import time; time.sleep(600)"

      pid = os.fork()
      if pid:
          print(pid)
          sys.exit(0)
      os.setsid()
      os.closerange(0, 3)
      os.execv(sys.executable, [name, "-c", body])
    '';

  # Drives the real Tooltip.set_markup path inside the running Cinnamon,
  # first with the string CopyQ actually publishes when the clipboard is
  # empty, then with valid markup. Kept in a file because the JS needs
  # double quotes and the testScript already nests two levels of shell
  # quoting; the newline is built at runtime because a literal one inside
  # the JS string would be an uncatchable syntax error.
  tooltipMarkupProbe = pkgs.writeText "tooltip-markup-probe.js" ''
    var log = [];
    try {
        var NL = String.fromCharCode(10);
        var button = new imports.gi.St.Button();
        var tip = new imports.ui.tooltips.Tooltip(button, "");
        tip.set_markup("CopyQ" + NL + "<EMPTY>");
        log.push("hostile_text=" +
                 tip._tooltip.clutter_text.get_text().split(NL).join("~"));
        tip.set_markup("<b>bold</b>");
        log.push("valid_text=" + tip._tooltip.clutter_text.get_text());
        // Positive control, and it runs LAST on purpose. These two lines are
        // the unpatched set_markup body verbatim, so they reach Pango without
        // the validation and must produce exactly one warning. Without it,
        // "no new warnings" would also pass when the warning never reaches
        // the journal at all -- and the rendered text cannot tell the two
        // apart, because Clutter keeps the literal string either way.
        // Being last means journald has necessarily flushed the lines above
        // it by the time this one is visible.
        tip._tooltip.set_text("CopyQ" + NL + "<EMPTY>");
        tip._tooltip.clutter_text.set_use_markup(true);
        log.push("control=fired");
        tip._tooltip.destroy();
        button.destroy();
    } catch (e) {
        log.push("ERR: " + e);
    }
    log.join(" | ");
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
    rsctl = "/tmp/rescue-systemctl"
    rmark = "/tmp/rescue-took-over"
    fake_pid = 1

    def rescue_run(
        cmd,
        mode="alive",
        threshold=3,
        cooldown=300,
        pid=None,
        takes_over=False,
        restart_cmd="${fakeRestart}/bin/fake-cinnamon-restart",
    ):
        return workstation.execute(
            "su - jonathan -c 'export XDG_RUNTIME_DIR=/run/user/$(id -u) "
            "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus "
            f"FAKE_GDBUS_MODE={mode} FAKE_PID={fake_pid if pid is None else pid} "
            f"FAKE_TAKEOVER_MARKER={rmark} "
            f"FAKE_RESTART_TAKES_OVER={1 if takes_over else 0} "
            f"CINNAMON_RESCUE_GDBUS=${fakeGdbus}/bin/fake-gdbus "
            f"CINNAMON_RESCUE_STATE_DIR={rstate} "
            f"CINNAMON_RESCUE_COUNTER_DIR={rcount} "
            f"CINNAMON_RESCUE_RESTART_LOG={rlog} "
            f"CINNAMON_RESCUE_SYSTEMCTL_LOG={rsctl} "
            f"CINNAMON_RESCUE_SYSTEMCTL=${fakeSystemctl}/bin/fake-systemctl "
            f'CINNAMON_RESCUE_RESTART_CMD="{restart_cmd}" '
            f"CINNAMON_RESCUE_THRESHOLD={threshold} "
            f"CINNAMON_RESCUE_COOLDOWN_SECS={cooldown} "
            # Escalation deadlines shrunk so the lane does not spend a minute
            # per stalled recovery; the production values are in the module.
            "CINNAMON_RESCUE_TAKEOVER_DEADLINE_SECS=2 "
            "CINNAMON_RESCUE_COLD_START_DEADLINE_SECS=2 "
            "CINNAMON_RESCUE_TERM_GRACE_SECS=2 "
            "CINNAMON_RESCUE_KILL_GRACE_SECS=2; "
            # 2>&1 because the driver's backdoor shell sends only stdout to
            # the capture socket, and the failure paths report on stderr --
            # which is where the journal reads them from for the real unit.
            f"cinnamon-rescue {cmd} 2>&1'"
        )

    def rescue(cmd, mode="alive", **kw):
        return rescue_run(cmd, mode, **kw)[0]

    # Asserts the exit code too: a traceback in a branch that happens not to
    # restart would otherwise read as correct "did not restart" behaviour.
    def rescue_ok(cmd, mode="alive", **kw):
        rc, out = rescue_run(cmd, mode, **kw)
        assert rc == 0, f"cinnamon-rescue {cmd} (mode={mode}) exited {rc}:\n{out}"
        return out

    def rescue_fails(cmd, mode="alive", **kw):
        rc, out = rescue_run(cmd, mode, **kw)
        assert rc != 0, \
            f"cinnamon-rescue {cmd} (mode={mode}) reported success:\n{out}"
        return out

    def restarts():
        return int(
            workstation.succeed(f"wc -l < {rlog} 2>/dev/null || echo 0").strip()
        )

    def reset_rescue():
        workstation.succeed(
            f"rm -rf {rstate} {rcount} {rlog} {rsctl} {rmark}; "
            f"install -o jonathan -m 644 /dev/null {rlog}; "
            f"install -o jonathan -m 644 /dev/null {rsctl}"
        )

    # Starts a process that stands in for a wedged Cinnamon, so os.kill has a
    # real target whose death the test can observe. Waits for argv[0] to carry
    # the name, which is both what the guard matches on and proof the exec
    # landed before the escalation reads /proc.
    def start_victim(name, trapped):
        pid = int(workstation.succeed(
            "su - jonathan -c "
            f"'${fakeVictim}/bin/start-fake-cinnamon {name} "
            f"{'trap' if trapped else 'plain'}'"
        ).strip())
        workstation.wait_until_succeeds(
            f"tr '\\0' ' ' < /proc/{pid}/cmdline | grep -q '^{name} '",
            timeout=20,
        )
        return pid

    def alive_pid(pid):
        return workstation.execute(f"test -d /proc/{pid}")[0] == 0

    # A killed orphan can sit as a zombie until init reaps it, and
    # /proc/<pid> still exists for a zombie, so "gone" has to accept Z.
    # Times out loudly if the escalation never ended the process.
    def wait_until_gone(pid):
        workstation.wait_until_succeeds(
            f"! test -e /proc/{pid}/status "
            f"|| grep -qE '^State:[[:space:]]+Z' /proc/{pid}/status",
            timeout=30,
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
    # == 0, not "in (0, 2)": accepting "absent" let this pass in a session
    # where Cinnamon never claimed the bus name, which is the one state that
    # makes every real-probe assertion below vacuous.
    assert live == 0, \
        f"the real probe did not read a healthy session as alive (rc={live})"

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
    out = rescue_ok("check", mode="hung", takes_over=True)
    assert restarts() == 1, "watchdog did not restart Cinnamon at the threshold"
    assert "took over" in out, f"recovery was not verified, only launched:\n{out}"
    diag = workstation.succeed(f"cat {rstate}/hang-*.txt")
    assert f"pid={fake_pid}" in diag, f"report does not name the pid:\n{diag}"
    assert "Properties.Get" in diag, \
        f"report does not name the probe actually used:\n{diag}"
    assert f"tid={fake_pid} state=S" in diag, \
        f"report carries no real thread state for pid {fake_pid}:\n{diag}"

    # Cooldown holds inside the window...
    workstation.succeed(f"rm -f {rmark}")
    for _ in range(3):
        rescue_ok("check", mode="hung")
    assert restarts() == 1, "cooldown did not suppress a second restart"

    # ...and expires. Backdating last-restart is what makes the assertion
    # above falsifiable: a cooldown that never ended would satisfy it too.
    workstation.succeed(
        f"echo 1 > {rcount}/last-restart; chown jonathan {rcount}/last-restart"
    )
    for _ in range(3):
        rescue_ok("check", mode="hung", takes_over=True)
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
    rescue_ok("now", mode="hung", takes_over=True)
    assert restarts() == 1, "`cinnamon-rescue now` did not recover on demand"
    status = rescue_ok("status", mode="alive")
    assert "failures=0/3" in status, f"status does not report the counter:\n{status}"

    # `cinnamon --replace` blocks in XWindowEvent until the outgoing window
    # manager destroys its selection window (muffin 6.6.3
    # take_manager_selection: "We sort of block infinitely here"). A wedged
    # main loop never gets there, so a launch that is merely queued must not
    # be reported as a recovery, and the hung process has to be ended for the
    # waiting replacement to proceed. takes_over stays False throughout:
    # that is what models the blocked replacement.
    #
    # A process that ignores SIGTERM proves both rungs of the ladder are
    # real — it can only die of SIGKILL.
    reset_rescue()
    victim = start_victim("cinnamon-kill-victim", trapped=True)
    out = rescue_fails("now", mode="hung", pid=victim)
    wait_until_gone(victim)
    assert "SIGTERM" in out and "SIGKILL" in out, \
        f"escalation did not climb from SIGTERM to SIGKILL:\n{out}"
    assert "recovery FAILED" in out, \
        f"a recovery that never took over was not reported as failed:\n{out}"

    # SIGTERM first, and only as far as it needs to go: a process that honours
    # it must never be SIGKILLed.
    reset_rescue()
    polite = start_victim("cinnamon-term-victim", trapped=False)
    out = rescue_fails("now", mode="hung", pid=polite)
    wait_until_gone(polite)
    assert "has exited" in out, \
        f"escalation did not notice the process had gone:\n{out}"
    assert "SIGKILL" not in out, \
        f"escalated to SIGKILL against a process that honoured SIGTERM:\n{out}"

    # The guard that makes escalation safe. The pid comes from the broker, so
    # a stale or recycled one must never be signalled — here it is PID 1, and
    # the VM surviving this assertion is itself the evidence.
    reset_rescue()
    out = rescue_fails("now", mode="hung", pid=1)
    assert "not Cinnamon; not signalling" in out, \
        f"escalation did not refuse a pid that is not Cinnamon:\n{out}"
    assert alive_pid(1), "escalation signalled PID 1"

    # A pid whose process has gone is reported as exited and the ladder stops
    # there, rather than escalating at a number the kernel is free to hand to
    # somebody else.
    #
    # The start-time half of the identity guard is NOT covered here. It only
    # bites when a pid is reaped and reissued between the diagnosis and a
    # signal, and staging that needs CAP_SYS_ADMIN to write ns_last_pid from
    # inside the rescue's own timing window. It is defence in depth whose
    # removal this lane would not catch.
    reset_rescue()
    ghost = start_victim("cinnamon-ghost-victim", trapped=False)
    workstation.succeed(f"kill -9 {ghost}")
    wait_until_gone(ghost)
    out = rescue_fails("now", mode="hung", pid=ghost)
    assert "has exited" in out, f"a dead pid was not reported as exited:\n{out}"
    assert "sent SIG" not in out, \
        f"signalled a pid whose process had already gone:\n{out}"

    # No pid at all from the broker: escalation has nothing to act on and
    # says so, instead of signalling something it guessed at.
    reset_rescue()
    out = rescue_fails("now", mode="unowned")
    assert "no pid to escalate against" in out, \
        f"escalation did not refuse an absent pid:\n{out}"

    # Ending Cinnamon and then dropping its replacement leaves nothing owning
    # the bus name. Read as "no Cinnamon here" that would strand the session
    # with no window manager and never retry, so it has to start one.
    reset_rescue()
    stranded = start_victim("cinnamon-stranded-victim", trapped=True)
    rescue_fails("now", mode="hung", pid=stranded)
    wait_until_gone(stranded)
    # The cooldown the failed attempt opened would otherwise mask this; the
    # block below proves it is the cooldown and not indifference.
    out = rescue_ok("check", mode="unowned", takes_over=True)
    assert "cooldown is still open" in out, \
        f"a stranded session ignored the cooldown:\n{out}"
    workstation.succeed(
        f"echo 1 > {rcount}/last-restart; chown jonathan {rcount}/last-restart"
    )
    out = rescue_ok("check", mode="unowned", takes_over=True)
    assert "starting one" in out, \
        f"an unowned bus name after our own kill was read as healthy:\n{out}"
    assert restarts() >= 2, \
        f"no window manager was started for the stranded session:\n{out}"

    # ...but an unowned name on its own is still a greeter, not a fault.
    reset_rescue()
    for _ in range(3):
        rescue_ok("check", mode="unowned")
    assert restarts() == 0, \
        "watchdog started a window manager in a session that has no Cinnamon"

    # And the stranded-session retries are bounded. Linger keeps this timer
    # and its runtime dir alive after a logout, so an unbounded retry would
    # start a Cinnamon with no display every cooldown for as long as the
    # machine stays up. After the limit it concludes the session is gone.
    reset_rescue()
    doomed = start_victim("cinnamon-doomed-victim", trapped=True)
    rescue_fails("now", mode="hung", pid=doomed)
    wait_until_gone(doomed)
    # Each of the first three attempts legitimately exits non-zero: it starts
    # a Cinnamon that cannot take over in this fake session.
    for _ in range(4):
        workstation.succeed(
            f"echo 1 > {rcount}/last-restart; chown jonathan {rcount}/last-restart"
        )
        rc, out = rescue_run("check", mode="unowned")
    assert "treating the session as ended" in out, \
        f"stranded-session starts are unbounded:\n{out}"
    assert rc == 0, f"giving the session up was reported as a failure:\n{out}"
    before = restarts()
    workstation.succeed(
        f"echo 1 > {rcount}/last-restart; chown jonathan {rcount}/last-restart"
    )
    rescue_ok("check", mode="unowned")
    assert restarts() == before, \
        "watchdog kept starting Cinnamon after giving the session up"

    # A rescued Cinnamon has nothing supervising it. cinnamon-launcher reads
    # our kill as a crash, and both answers to the dialog it then puts up end
    # the launcher, so when that Cinnamon later crashes outright no fallback
    # is left -- and reading the unowned name as "no Cinnamon here" would
    # leave the session without a window manager for the rest of it.
    reset_rescue()
    rescue_ok("check", mode="hung", threshold=1, takes_over=True)
    # The healthy tick is the whole point of this block: it clears the record
    # of our own kill, which is what made a crash afterwards read as a session
    # that never had a Cinnamon at all.
    rescue_ok("check", mode="alive")
    assert workstation.succeed(f"cat {rcount}/ended-cinnamon").strip() == "0", (
        "the healthy tick left the record of our own kill in place, so the "
        "crash below would be covered by that record and prove nothing"
    )
    # The crash: the Cinnamon we started stops owning the name.
    workstation.succeed(f"rm -f {rmark}")
    before = restarts()
    workstation.succeed(
        f"echo 1 > {rcount}/last-restart; chown jonathan {rcount}/last-restart"
    )
    out = rescue_ok("check", mode="unowned", takes_over=True)
    assert restarts() > before, \
        f"a crash after a rescue left the session with no window manager:\n{out}"

    # A replacement left blocked holds the window manager selection without
    # managing anything, so it is stopped rather than left for the next
    # --replace to aim at.
    reset_rescue()
    stale = start_victim("cinnamon-stale-victim", trapped=True)
    stale_exe = workstation.succeed(f"readlink /proc/{stale}/exe").strip()
    rescue_fails(
        "now", mode="hung", pid=stale,
        restart_cmd="${fakeSystemdRun}/bin/fake-systemd-run --user --unit=@unit@ @cinnamon@ --replace",
    )
    stops = workstation.succeed(f"cat {rsctl}")
    assert "stop" in stops and "cinnamon-rescue-replace-" in stops, \
        f"the blocked replacement was not stopped:\n{stops}"
    launched = workstation.succeed(f"cat {rlog}")
    assert "--setenv=DISPLAY=" in launched, \
        f"the transient unit was launched without DISPLAY:\n{launched}"
    unit = [w for w in launched.split() if w.startswith("--unit=")][0].split("=", 1)[1]
    assert unit in stops, \
        f"stopped a different unit than the one launched ({unit}):\n{stops}"
    # A replacement stuck in XWindowEvent does not answer SIGTERM, so a
    # blocking stop would spend the unit's whole start timeout waiting.
    assert "--no-block" in stops, \
        f"the stop would block on the stuck replacement:\n{stops}"
    # Every launch has to name the binary the wedged session was running,
    # including the stranded start -- which runs after escalation ended that
    # pid, so reading /proc for it there falls back to the newest system
    # Cinnamon, or, once the kernel has reissued the number, hands --replace
    # some unrelated process's binary.
    launches = [ln for ln in launched.splitlines() if ln.strip()]
    assert len(launches) == 2, \
        f"expected a replacement and a stranded start, got {len(launches)}:\n{launched}"
    for line in launches:
        assert stale_exe in line, \
            f"a launch did not name the wedged session's binary {stale_exe}:\n{line}"

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

    # Tooltip text is untrusted: CopyQ publishes the clipboard on line 2 of
    # its tray tooltip, so an empty clipboard ("<EMPTY>") or a copied '&'
    # reaches Pango as invalid markup. Clutter keeps the literal text either
    # way, so what it renders cannot tell a fixed Cinnamon from a broken one
    # — the absence of the warning is the only observable difference, and it
    # is also the damage (92 of them in the host journal over five weeks).
    # The valid-markup case is asserted alongside so that a "fix" which
    # escapes unconditionally, throwing away real formatting, fails too.
    def markup_failures():
        return int(workstation.succeed(
            "journalctl -b 0 --no-pager | "
            "grep -c 'Failed to set the markup' || true"
        ).strip() or "0")

    workstation.wait_until_succeeds(
        "su - jonathan -c 'export XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus; "
        "gdbus call --session --dest org.freedesktop.DBus "
        "--object-path /org/freedesktop/DBus "
        "--method org.freedesktop.DBus.GetNameOwner org.Cinnamon'",
        timeout=180,
    )
    before = markup_failures()
    rendered = as_j(
        "gdbus call --session --dest org.Cinnamon "
        "--object-path /org/Cinnamon --method org.Cinnamon.Eval "
        "\"$(cat ${tooltipMarkupProbe})\""
    )
    print("[diag] tooltip markup probe: " + rendered.strip())
    assert "ERR:" not in rendered, \
        f"tooltip probe threw inside Cinnamon:\n{rendered}"
    assert "hostile_text=CopyQ~<EMPTY>" in rendered, \
        f"CopyQ's tooltip text was not preserved verbatim:\n{rendered}"
    assert "valid_text=bold" in rendered, \
        f"valid markup no longer renders (over-escaped?):\n{rendered}"
    assert "control=fired" in rendered, \
        f"the positive control did not run, so the count below proves nothing:\n{rendered}"

    # Wait for the control's warning rather than reading the count straight
    # away: this is what distinguishes "the fix worked" from "the warning had
    # not been flushed yet", and it waits out the flush in the same step.
    workstation.wait_until_succeeds(
        f"test $(journalctl -b 0 --no-pager | grep -c 'Failed to set the markup') "
        f"-ge {before + 1}",
        timeout=60,
    )
    after = markup_failures()
    # Exactly one: the control's. The two set_markup calls above it must have
    # added none.
    assert after == before + 1, (
        "Pango rejected CopyQ's tooltip text through the patched path: "
        f"{after - before - 1} warning(s) beyond the positive control's "
        f"(before={before} after={after}, expected {before + 1})"
    )

    # The live fault, end to end, with no fakes anywhere in the path: wedge
    # the real Cinnamon's main loop the way the 2026-11-07 hang did, then
    # recover it with the real `cinnamon --replace`.
    #
    # This is the assertion the fakes cannot make. muffin blocks in
    # XWindowEvent until the outgoing window manager destroys its selection
    # window, and a main loop spinning in JS never will -- it will not even
    # act on SIGTERM, because GLib's handler defers to that same loop. So
    # the handover completes only because the escalation reaches SIGKILL.
    #
    # Runs last: it ends the session's window manager, which nothing after
    # it could rely on.
    rescue_env = (
        "export XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus"
    )

    def cinnamon_owner_pid():
        raw = workstation.succeed(
            f"su - jonathan -c '{rescue_env}; "
            "gdbus call --session --dest org.freedesktop.DBus "
            "--object-path /org/freedesktop/DBus --method "
            "org.freedesktop.DBus.GetConnectionUnixProcessID org.Cinnamon' "
            "| sed -n 's/.*uint32 \\([0-9]*\\).*/\\1/p'"
        ).strip()
        assert raw, "nothing owns org.Cinnamon, so there is no live session to wedge"
        return int(raw)

    # cinnamon-session owns org.gnome.SessionManager. Its presence as a process
    # is not checkable here: comm is capped at 15 characters, so `pgrep -x
    # cinnamon-session` never matches, and `pgrep -f` matches the su shell
    # carrying the pattern, which would pass with the session already dead.
    def session_manager_pid():
        return workstation.succeed(
            f"su - jonathan -c '{rescue_env}; "
            "gdbus call --session --dest org.freedesktop.DBus "
            "--object-path /org/freedesktop/DBus --method "
            "org.freedesktop.DBus.GetConnectionUnixProcessID "
            "org.gnome.SessionManager' "
            "| sed -n 's/.*uint32 \\([0-9]*\\).*/\\1/p'"
        ).strip()

    # The diagnostic probe above tolerates "absent" (Cinnamon may not have
    # claimed the name yet). This block cannot: without a live Cinnamon there
    # is nothing to wedge and every assertion below would pass vacuously.
    workstation.wait_until_succeeds(
        f"su - jonathan -c '{rescue_env}; cinnamon-rescue probe'", timeout=120
    )
    wedged_pid = cinnamon_owner_pid()
    session_pid = session_manager_pid()
    assert session_pid, "nothing owns org.gnome.SessionManager"
    print(
        f"[diag] live Cinnamon before the wedge: pid {wedged_pid}, "
        f"cinnamon-session pid {session_pid}"
    )

    # Eval runs the script on Cinnamon's main loop, so an endless loop there
    # is the real fault rather than a simulation of it. The reply never
    # comes, so the client is given a short --timeout and abandoned; the loop
    # it started keeps spinning inside Cinnamon regardless.
    rc_eval, eval_out = workstation.execute(
        f"su - jonathan -c '{rescue_env}; "
        "timeout 30 gdbus call --session --timeout 3 --dest org.Cinnamon "
        "--object-path /org/Cinnamon --method org.Cinnamon.Eval "
        "\"while(true){}\" 2>&1'",
        timeout=120,
    )
    print(f"[diag] Eval rc={rc_eval} out={eval_out.strip()!r}")

    # The probe must see the real wedge, not just the fake one.
    probes = []
    for _ in range(10):
        probes.append(workstation.execute(
            f"su - jonathan -c '{rescue_env}; cinnamon-rescue probe'"
        )[0])
        if probes[-1] == 1:
            break
    print(f"[diag] probe after the wedge: {probes}")
    assert 1 in probes, (
        "Eval did not wedge the live main loop, so the recovery below would "
        f"prove nothing: Eval rc={rc_eval} out={eval_out.strip()!r}, "
        f"probes={probes}"
    )

    # No deadline overrides: this runs the production takeover deadline and
    # both escalation graces, so the shipped numbers are the ones proven to
    # fit a real handover rather than numbers no test ever exercised.
    rc, out = workstation.execute(
        f"su - jonathan -c '{rescue_env} "
        f"CINNAMON_RESCUE_STATE_DIR={rstate} CINNAMON_RESCUE_COUNTER_DIR={rcount}; "
        "cinnamon-rescue now 2>&1'",
        timeout=600,
    )
    print(f"[diag] live recovery rc={rc}:\n{out}")
    assert rc == 0, f"live recovery of a genuinely wedged Cinnamon failed:\n{out}"
    assert "SIGKILL" in out, \
        f"the handover completed without the escalation, so --replace did not block:\n{out}"
    assert "took over" in out, f"recovery was not verified:\n{out}"

    recovered_pid = cinnamon_owner_pid()
    assert recovered_pid != wedged_pid, \
        f"org.Cinnamon is still owned by the wedged pid {wedged_pid}"

    # The session itself has to survive the rescue. cinnamon-launcher declares
    # X-GNOME-Provides=panel;windowmanager; with X-GNOME-AutoRestart=false, so
    # if ending Cinnamon took cinnamon-session down with it the rescue would
    # have cost the whole session rather than saved it.
    session_after = session_manager_pid()
    assert session_after == session_pid, (
        "cinnamon-session did not survive the rescue: org.gnome.SessionManager "
        f"was owned by pid {session_pid} before it, now "
        f"{session_after or 'nothing'}"
    )
    assert "true" in workstation.succeed(
        f"su - jonathan -c '{rescue_env}; "
        "gdbus call --session --timeout 5 --dest org.gnome.SessionManager "
        "--object-path /org/gnome/SessionManager --method "
        "org.gnome.SessionManager.IsSessionRunning'"
    ), "cinnamon-session kept the bus name but stopped answering"

    # The launcher reads a signal death as a crash and takes its fallback
    # branch unconditionally: fork, metacity --replace, then confirm_restart()
    # puts up a keep-above "Cinnamon just crashed" dialog. Recorded rather than
    # asserted absent: the dialog cannot be avoided by a kill-based rescue on
    # 6.6.9, because the launcher only treats a signal death as its own when
    # self.killed is set, and that happens only in its memory monitor.
    #
    # Counted from the forked child's traceback rather than the launcher's own
    # prints: the launcher block-buffers stdout and flushes it only when it
    # exits, so its "Launching for fallback session: nm-applet" reaches the
    # journal minutes late. That buffering, not a missing helper, is why an
    # earlier version of this diagnostic read 0 with the branch taken.
    print("[diag] launcher took its crash-fallback branch: " + workstation.succeed(
        "journalctl -b 0 --no-pager | grep -c 'os.execvp(FALLBACK_COMMAND' || true"
    ).strip())
    # rc 1 with no ids is a real absence; any other failure is the instrument,
    # which must not be able to read as "no dialog".
    rc_dialog, dialog = workstation.execute(
        "su jonathan -c 'DISPLAY=:0 "
        "${pkgs.xdotool}/bin/xdotool search --name Cinnamon.just.crashed' 2>&1"
    )
    print(f"[diag] crash dialog search rc={rc_dialog} windows={dialog.split()!r}")
    print("[diag] metacity on PATH in this closure: " + workstation.succeed(
        "command -v metacity >/dev/null && echo yes || echo no"
    ).strip())
    assert workstation.execute(
        f"su - jonathan -c '{rescue_env}; cinnamon-rescue probe'"
    )[0] == 0, "the replacement does not answer its own main loop"
    print(f"[diag] live Cinnamon recovered: pid {wedged_pid} -> {recovered_pid}")

    # Answering that dialog. Its No button and its window close reach the same
    # branch -- Gtk.main_quit(), launcher line 199, the only alternative to
    # YES -- so WM_DELETE_WINDOW is the No click without depending on focus or
    # on button coordinates GTK does not expose to X. The launcher provides
    # panel;windowmanager with X-GNOME-AutoRestart=false, so what happens to
    # the session when it quits decides whether the rescue saved the session
    # or only postponed losing it to the user's next click.
    def launcher_pids():
        rc, out = workstation.execute("pgrep -f 'cinnamon-launche[r]' 2>&1")
        return sorted(out.split()) if rc == 0 else []

    launcher_before = launcher_pids()
    assert launcher_before, \
        "no cinnamon-launcher is running, so nothing here would answer the dialog"
    assert rc_dialog == 0 and dialog.split(), \
        "no dialog window to answer, so everything below would pass vacuously"
    workstation.succeed(
        "su jonathan -c 'DISPLAY=:0 "
        "${pkgs.xdotool}/bin/xdotool search --name Cinnamon.just.crashed "
        "windowquit' 2>&1"
    )
    for _ in range(40):
        if not launcher_pids():
            break
        workstation.sleep(0.5)
    launcher_after = launcher_pids()
    print(f"[diag] launcher pids after answering No: {launcher_before} -> {launcher_after}")
    assert not launcher_after, (
        "answering the dialog did not end the launcher, so the checks below "
        f"prove nothing about that click: {launcher_before} -> {launcher_after}"
    )
    session_final = session_manager_pid()
    assert session_final == session_pid, (
        "the session died when the launcher quit, so the rescue only postpones "
        f"the loss: org.gnome.SessionManager was pid {session_pid}, now "
        f"{session_final or 'nothing'}"
    )
    assert "true" in workstation.succeed(
        f"su - jonathan -c '{rescue_env}; "
        "gdbus call --session --timeout 5 --dest org.gnome.SessionManager "
        "--object-path /org/gnome/SessionManager --method "
        "org.gnome.SessionManager.IsSessionRunning'"
    ), "the session kept the bus name but stopped answering once the launcher quit"
    assert cinnamon_owner_pid() == recovered_pid, \
        "the rescued Cinnamon did not survive the launcher quitting"

    # The gap the rescue itself opens, live. With the launcher gone, nothing
    # supervises the Cinnamon the rescue left running: a crash from here on is
    # the watchdog's to catch or nobody's. The healthy tick first, because it
    # is what makes the next part a crash rather than the aftermath of our own
    # kill -- it clears the record escalation wrote.
    rescue_counters = (
        f"CINNAMON_RESCUE_STATE_DIR={rstate} CINNAMON_RESCUE_COUNTER_DIR={rcount}"
    )
    workstation.succeed(
        f"su - jonathan -c '{rescue_env} {rescue_counters}; cinnamon-rescue check 2>&1'"
    )
    assert workstation.succeed(f"cat {rcount}/ended-cinnamon").strip() == "0", (
        "the healthy tick left the record of our own kill in place, so the "
        "crash below would be covered by that record and prove nothing"
    )
    workstation.succeed(f"kill -KILL {recovered_pid}")

    # 2 is ABSENT: the session now has no window manager at all, which is the
    # state the launcher used to cover. Polled by exit code rather than with
    # wait_until_succeeds, because the driver runs each command under `set -e`,
    # where a probe exiting non-zero ends the shell before any test of $?.
    def probe_state():
        return workstation.execute(
            f"su - jonathan -c '{rescue_env}; cinnamon-rescue probe'"
        )[0]

    state = probe_state()
    for _ in range(30):
        if state == 2:
            break
        workstation.sleep(1)
        state = probe_state()
    assert state == 2, (
        "the killed Cinnamon still owns org.Cinnamon, so what follows would "
        f"not be the absent-name case this covers: probe={state}"
    )
    # Only the cooldown is overridden. The production 300s would idle the lane
    # for five minutes here; the fake-driven block above is where the cooldown
    # behaviour itself is asserted. Everything else, the cold-start deadline
    # included, runs at the shipped numbers.
    t0 = int(workstation.succeed("date +%s").strip())
    rc_crash, crash_out = workstation.execute(
        f"su - jonathan -c '{rescue_env} {rescue_counters} "
        "CINNAMON_RESCUE_COOLDOWN_SECS=0; cinnamon-rescue check 2>&1'",
        timeout=600,
    )
    t1 = int(workstation.succeed("date +%s").strip())
    print(f"[diag] crash after the rescue: rc={rc_crash} in ~{t1 - t0}s\n{crash_out}")
    assert "starting one" in crash_out, (
        "a crash after the rescue was read as a session that has no Cinnamon, "
        f"so nothing started a window manager:\n{crash_out}"
    )
    assert rc_crash == 0, f"the crash after the rescue was not recovered:\n{crash_out}"
    crash_pid = cinnamon_owner_pid()
    assert crash_pid != recovered_pid, \
        f"org.Cinnamon is still owned by the crashed pid {recovered_pid}"
    assert probe_state() == 0, \
        "the Cinnamon started after the crash does not answer its main loop"
    print(f"[diag] crash recovered: pid {recovered_pid} -> {crash_pid}")
  '';
}
