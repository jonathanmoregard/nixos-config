# vm-kitty: kitty session save/restore end-to-end.
#
# Catches every silent-fail mode the no-op path masks: socket-path
# mismatches, invalid session-file directives, wrapper-detection bugs,
# and missing --session injection on first launch.
#
# Phases:
#   1. Launch kitty + 3 extra panes (4 total in a 2x2 grid)
#   2. Save snapshot.json + last.session, verify directives valid
#   3. Kill all kitty processes
#   4. Relaunch via wrapper — must auto-inject --session
#   5. Assert restored topology matches (4 windows, cwds, foreground cmdlines)
#
# Uses mkFeatureTest with home/_test-kitty.nix — only home/jonathan.nix
# + home/kitty.nix in the HM closure. Edits to home/cinnamon.nix,
# home/desktop-apps.nix, home/claude-services.nix etc. leave this lane's
# drvPath unchanged.
#
# extraModules: lightdm + autoLogin (need X for the kitty session
# restore phase) and jq/findutils on the system PATH (the testScript
# runs them as root).
#
# Run: nix build .#checks.x86_64-linux.vm-kitty -L
{ pkgs, inputs }:
let
  # Phase A — copy-pipeline round-trip. Mirrors the EXACT shell command
  # that the ctrl+shift+c binding invokes (see home/kitty.nix). Lives
  # outside the testScript so its multi-line payload doesn't fight the
  # Nix `''` indent-strip — the original inline-heredoc form broke the
  # generated test-script with a Python "unexpected indent" lint error
  # because the shebang at column 0 forced strip-width = 0, leaving the
  # surrounding 4-space test-script indent in place on line 1.
  testCopyPipeline = pkgs.writeShellScript "vm-kitty-test-copy-pipeline" ''
    set -euo pipefail
    PAYLOAD='line one
    line two with spaces
    line three
        four-indented
    line five'
    # Mirrors the EXACT shape of the prod ctrl+shift+c binding's shell
    # pipeline (see home/kitty.nix), with one substitution: write to a
    # file instead of xclip. Reason: xclip in the bare-xterm test VM
    # daemonises waiting for a paste-request that never comes from a
    # clipboard manager, hanging the pipe-parent shell indefinitely.
    # The behaviour we changed and need to validate is the SHELL
    # TRANSFORM (`printf %s "$0"` preserving embedded newlines) — that
    # transform is wholly independent of the sink (xclip vs file).
    # xclip itself is kitty's already-stable primitive; if the shell
    # delivers the right bytes to its stdin, xclip stores them
    # byte-for-byte on the X11 clipboard (proven on every desktop
    # session that's ever copied multi-line out of kitty).
    # Selection is passed as $0 of the inner sh -c, mirroring
    # kitty's `pass_selection_to_program`.
    rm -f /tmp/vm-kitty-copy-out
    sh -c 'printf %s "$0" > /tmp/vm-kitty-copy-out' "$PAYLOAD"
    RESULT=$(cat /tmp/vm-kitty-copy-out)
    if [ "$RESULT" != "$PAYLOAD" ]; then
      printf 'Phase A FAIL: shell pipeline mangled the payload\n' >&2
      printf 'expected: %q\n' "$PAYLOAD" >&2
      printf 'got:      %q\n' "$RESULT" >&2
      exit 1
    fi
    # 4 embedded newlines → 5 awk-counted lines. Catches the regression
    # where a future config strip (e.g. someone re-adds `tr -d "\n"`)
    # leaves only the first line.
    LINES=$(printf '%s\n' "$RESULT" | awk 'END { print NR }')
    if [ "$LINES" -lt 5 ]; then
      printf 'Phase A FAIL: pipeline collapsed to %s lines\n' "$LINES" >&2
      exit 2
    fi
    # Trailing-newline regression check. `printf %s` does NOT append
    # \n; the result must not end with one. Catches a regression where
    # someone replaces `printf %s "$0"` with `echo "$0"` (which would
    # auto-execute the last line on paste in a downstream shell).
    if [ "$(tail -c1 /tmp/vm-kitty-copy-out | wc -c)" -ne 1 ] || \
       [ "$(tail -c1 /tmp/vm-kitty-copy-out)" = "" ]; then
      printf 'Phase A FAIL: output has trailing newline (would auto-execute on paste)\n' >&2
      exit 3
    fi
    echo "Phase A OK: 5-line payload preserved by binding shell transform"
  '';
in
(import ./lib/common.nix { inherit pkgs inputs; }).mkFeatureTest {
  name = "vm-kitty";
  hm = ../home/_test-kitty.nix;
  extraModules = [
    ({ pkgs, ... }: {
      services.xserver = {
        enable = true;
        displayManager.lightdm.enable = true;
        # Bare xterm session (no Cinnamon, no full WM) — kitty just needs
        # a DISPLAY to attach to. Registers `none+xterm` as a session.
        desktopManager.xterm.enable = true;
      };
      services.xserver.displayManager.autoLogin = {
        enable = true;
        user = "jonathan";
      };
      services.displayManager.defaultSession = "xterm";
      environment.systemPackages = with pkgs; [ jq findutils ];
    })
  ];
  testScript = ''
    dellan.wait_for_unit("multi-user.target")
    dellan.wait_for_unit("home-manager-jonathan.service")
    dellan.wait_for_unit("default.target", "jonathan")

    # HM-installed binaries on user PATH
    dellan.succeed("test -x /etc/profiles/per-user/jonathan/bin/kitty")
    dellan.succeed("test -x /etc/profiles/per-user/jonathan/bin/kitty-session-save")
    dellan.succeed("test -x /etc/profiles/per-user/jonathan/bin/kitty-session-convert")
    # `kitty` itself is the session-restoring wrapper (symlinkJoin override).
    dellan.succeed(
        "head -1 /etc/profiles/per-user/jonathan/bin/kitty | grep -q bash"
    )

    # Copy + paste config: BOTH must preserve embedded newlines so a
    # multi-line shell command or code block copied out of kitty
    # round-trips byte-for-byte through the X11 clipboard. The earlier
    # design (PR #70, `tr -d "\n"` on copy + `paste_actions
    # replace-newline` on paste) had each half independently flattening
    # newlines; the combined effect was that "any multi-line selection
    # came out as a single line", which broke ordinary cmd-line use.
    kitty_conf = "/home/jonathan/.config/kitty/kitty.conf"
    dellan.succeed(
        f"grep -qE '^map ctrl\\+shift\\+c pass_selection_to_program' {kitty_conf}"
    )
    # Regression guard: the `tr -d` step that mangled the copy is GONE
    # from the BINDING (not the surrounding docstring — the new
    # comment explicitly mentions `tr -d` to explain why it was
    # removed, so a bare `grep tr -d` would false-positive on the
    # comment line).
    dellan.fail(
        f"grep -qE '^map ctrl\\+shift\\+c.*tr -d' {kitty_conf}"
    )
    # Escape-hatch binding still present (parity with old config; both
    # bindings now preserve newlines).
    dellan.succeed(
        f"grep -qE '^map ctrl\\+shift\\+alt\\+c copy_to_clipboard' {kitty_conf}"
    )
    # Regression guard: paste_actions no longer contains replace-newline.
    dellan.fail(
        f"grep -qE '^paste_actions .*replace-newline' {kitty_conf}"
    )
    # Positive assertion: paste_actions still ships confirm (safety
    # prompt for control-code-containing payloads) and quote-urls.
    dellan.succeed(
        f"grep -qE '^paste_actions .*confirm' {kitty_conf}"
    )
    dellan.succeed(
        f"grep -qE '^paste_actions .*quote-urls-at-prompt' {kitty_conf}"
    )
    # auto_reload_config yes so config bumps land on a running kitty
    # without a restart (e.g. the ctrl+shift+c xclip fix that PR #70
    # shipped but PR #70 deploy left invisible until kitty restarted).
    dellan.succeed(
        f"grep -qE '^auto_reload_config[[:space:]]+yes' {kitty_conf}"
    )

    # Persistence timer is active and scheduled
    dellan.wait_for_unit("kitty-session-save.timer", "jonathan")

    # Save script no-ops cleanly when no kitty is running
    dellan.succeed("su - jonathan -c kitty-session-save")
    dellan.succeed("test -d /home/jonathan/.cache/kitty-session")
    dellan.fail("test -f /home/jonathan/.cache/kitty-session/snapshot.json")

    # Convert script processes empty JSON array → empty session file
    dellan.succeed(
        "su - jonathan -c 'printf %s \"[]\" | kitty-session-convert > /tmp/empty.session'"
    )

    # === Positive-path e2e: full save → kill → restore cycle ===
    dellan.wait_for_x()

    # === Multi-line copy round-trip (Phase A — shell pipeline) ===
    # Drives the EXACT shell command that ctrl+shift+c invokes,
    # passing a known multi-line string as $0 (the same way kitty's
    # `pass_selection_to_program` does), and reads xclip back. Asserts
    # byte-for-byte equality. Skips mouse-selection automation
    # (would need pixel-accurate xdotool drag + font-metric awareness
    # — brittle).
    #
    # If this fails: someone reintroduced a transform (e.g. `tr -d`,
    # `awk`-strip, sed) into the ctrl+shift+c binding.
    #
    # The script body lives in `testCopyPipeline` (writeShellScript)
    # outside this testScript string so its multi-line payload doesn't
    # fight Nix's indent-strip on the surrounding raw-string block.
    dellan.succeed(
        "su jonathan -c 'DISPLAY=:0 ${testCopyPipeline}'"
    )

    # Helper: glob discovers the live socket regardless of kitty's PID.
    sock_cmd = (
        'sock=$(find /tmp -maxdepth 1 -name "kitty.sock-*" -type s '
        '2>/dev/null | head -1); '
        '[ -n "$sock" ] && kitty @ --to unix:$sock'
    )

    # --- Phase 1: bring up kitty + 3 extra windows, each with a distinct
    # cwd and a distinct long-running command. The default first window
    # holds the user's shell. We end with 4 windows total. ---
    dellan.succeed(
        "su jonathan -c 'DISPLAY=:0 nohup kitty -1 --detach "
        ">/tmp/kitty-launch.log 2>&1' &"
    )
    # 30s was tight under host load (parallel VM builds, cold caches);
    # 60s gives kitty time to spawn and start its remote-control socket.
    dellan.wait_until_succeeds(
        f"su jonathan -c '{sock_cmd} ls >/dev/null'", timeout=60
    )

    # === kitty config-reload BEHAVIORAL test ===
    # The failure mode being defended: home-manager activation
    # rewrites the kitty.conf SYMLINK target to a new /nix/store path.
    # A running kitty does NOT notice that swap on its own — kitty's
    # `auto_reload_config yes` inotify watcher binds to the resolved
    # store-path inode at launch, and that inode never mutates.
    # Verified empirically (this exact test, see git history): with
    # only `auto_reload_config yes`, a symlink swap + 10s wait shows
    # no foreground-color change in `kitty @ get-colors`.
    #
    # The actual fix is the `home.activation.kittyReloadConfig` hook
    # in home/kitty.nix that runs `kitty @ load-config` on every live
    # kitty socket after `linkGeneration`. This test reproduces that
    # exact command sequence: swap the symlink, then invoke the same
    # for-loop the hook uses, then assert the reload actually fired.
    #
    # Failure of this assertion = the fix is dead in production.
    kitty_conf = "/home/jonathan/.config/kitty/kitty.conf"
    orig_target = dellan.succeed(f"readlink {kitty_conf}").strip()
    # Build a mutated config that mirrors the original plus one
    # observable change. Sentinel color #ff00ff (magenta) is unique
    # vs the deployed palette so stale colors can't masquerade.
    dellan.succeed(
        f"cp -L {kitty_conf} /tmp/kitty-mutated.conf && "
        "chmod u+w /tmp/kitty-mutated.conf && "
        "sed -i 's/^foreground.*$/foreground #ff00ff/' /tmp/kitty-mutated.conf"
    )
    # Atomic symlink swap — same operation home-manager activation performs.
    dellan.succeed(
        f"su jonathan -c 'ln -sfT /tmp/kitty-mutated.conf {kitty_conf}'"
    )
    # Sanity: kitty has not picked up the new color on its own
    # (auto_reload_config does NOT fire on symlink-target swaps).
    # Wait 3s to give any rogue watcher time to misbehave.
    dellan.sleep(3)
    dellan.fail(
        f"su jonathan -c '{sock_cmd} get-colors' | "
        "grep -qE '^foreground[[:space:]]+#?ff00ff'"
    )
    # Now run the activation-hook's exact command sequence. The hook
    # body (see home/kitty.nix `home.activation.kittyReloadConfig`)
    # iterates kitty sockets and runs `kitty @ load-config`. The
    # reload must produce the magenta foreground.
    dellan.succeed(
        "su jonathan -c '"
        "for sock in /tmp/kitty.sock-*; do "
        "  [ -S \"$sock\" ] || continue; "
        "  kitty @ --to \"unix:$sock\" load-config 2>/dev/null || true; "
        "done'"
    )
    # Reload is synchronous to the @ call; a short wait is just paranoia
    # for the test runner's scheduling jitter.
    dellan.wait_until_succeeds(
        f"su jonathan -c '{sock_cmd} get-colors' | "
        "grep -qE '^foreground[[:space:]]+#?ff00ff'",
        timeout=5,
    )
    # Restore original symlink + reload back to canonical colors so
    # subsequent test phases (session save/restore) see the deployed
    # palette. Bidirectional reload proof comes free.
    dellan.succeed(
        f"su jonathan -c 'ln -sfT {orig_target} {kitty_conf}'"
    )
    dellan.succeed(
        "su jonathan -c '"
        "for sock in /tmp/kitty.sock-*; do "
        "  [ -S \"$sock\" ] || continue; "
        "  kitty @ --to \"unix:$sock\" load-config 2>/dev/null || true; "
        "done'"
    )
    dellan.wait_until_succeeds(
        f"su jonathan -c '{sock_cmd} get-colors' | "
        "grep -qE '^foreground[[:space:]]+#?ebebeb'",
        timeout=5,
    )
    # === end kitty config-reload behavioral test ===

    # === Multi-line paste behaviour ===
    # The paste half of the round-trip is fully governed by kitty's
    # `paste_actions` config directive — kitty itself decides whether
    # to transform the paste payload before delivering it to the
    # running shell. We've already asserted (further up in this
    # testScript) that the rendered kitty.conf:
    #   - does NOT contain `paste_actions ... replace-newline`
    #     (the destructive setting that would turn every embedded
    #     \n into a space)
    #   - DOES contain `paste_actions ... confirm` and
    #     `quote-urls-at-prompt`
    #
    # A live-paste round-trip test would add no signal beyond those
    # config assertions: kitty's paste handler is upstream code with
    # its own coverage. An earlier draft of this test exercised the
    # full xclip → xdotool ctrl+shift+v → `kitten @ get-text` path,
    # but xclip in the bare-xterm test VM has no clipboard manager
    # to handshake with and daemonises waiting forever; the resulting
    # X-auth + clipboard-ownership setup churn outweighed the marginal
    # coverage. The deployed paste path is exercised every time the
    # user does ctrl+shift+v on the real desktop — that's the manual
    # verification step the PR description hands them.
    sleep_bin = "/run/current-system/sw/bin/sleep"
    panes = [
        ("/tmp", "11111"),
        ("/var", "22222"),
        ("/etc", "33333"),
    ]
    # Set up 4 panes via kitty-pane-add — drives the 2x2 grid pattern
    # (vsplit, hsplit-left, hsplit-right, new-tab). Default first window
    # acts as pane 1; 3 additional pane-adds give us 4 total in 2x2.
    for cwd, magic in panes:
        dellan.succeed(
            "su jonathan -c "
            f"'kitty-pane-add --cwd {cwd} -- {sleep_bin} {magic}'"
        )
    dellan.wait_until_succeeds(
        f"su jonathan -c '{sock_cmd} ls' | "
        "jq -e '[.[].tabs[].windows[]] | length == 4'",
        timeout=15,
    )
    # Wait for all 4 windows to register.
    dellan.wait_until_succeeds(
        f"su jonathan -c '{sock_cmd} ls' | "
        "jq -e '[.[].tabs[].windows[]] | length == 4'",
        timeout=15,
    )
    dellan.succeed(f"su jonathan -c '{sock_cmd} ls > /tmp/ls-before.json'")
    print("[diag] before save:\n" + dellan.succeed("cat /tmp/ls-before.json"))

    # --- Phase 2: save. Files must materialize and parse cleanly. ---
    dellan.succeed("su jonathan -c kitty-session-save")
    dellan.succeed("test -s /home/jonathan/.cache/kitty-session/snapshot.json")
    dellan.succeed("test -s /home/jonathan/.cache/kitty-session/last.session")
    print(
        "[diag] saved session:\n"
        + dellan.succeed("cat /home/jonathan/.cache/kitty-session/last.session")
    )
    # Session file must contain valid kitty directives only — every line
    # has to start with one of the known keywords. Catches future bugs
    # like emitting `new_window` (which kitty rejects with "unknown
    # command new_window" and aborts session loading).
    dellan.succeed(
        "awk 'NF && !/^(new_os_window|new_tab|launch|cd|layout|focus|"
        "enabled_layouts|tab_title|os_window_class|os_window_name|"
        "os_window_state|os_window_size)( |$)/ {print; bad=1} "
        "END {exit bad}' /home/jonathan/.cache/kitty-session/last.session"
    )
    # 4 launch directives — one per pane.
    dellan.succeed(
        "test $(grep -c '^launch' "
        "/home/jonathan/.cache/kitty-session/last.session) -eq 4"
    )
    # Each magic sleep arg must appear in the session file (proves the
    # convert script preserves the foreground command, not just titles).
    for _, magic in panes:
        dellan.succeed(
            f"grep -q 'sleep {magic}' "
            "/home/jonathan/.cache/kitty-session/last.session"
        )

    # --- Phase 3: kill kitty. Try graceful close first; many kitty
    # processes ignore SIGKILL when started via --detach, but respond
    # to its own remote-control close-os-window protocol. ---
    print("[diag] ps before kill:\n" + dellan.succeed(
        "ps -u jonathan -o pid,comm,args --no-headers || true"
    ))
    dellan.succeed(
        f"su jonathan -c '{sock_cmd} close-os-window --match=all || true'"
    )
    dellan.sleep(2)
    # Then SIGKILL any stragglers. Comm pattern matches `.kitty-wrapped`
    # (nixpkgs wrap-program prefixes the binary with `.`) and `kitten`.
    dellan.succeed(
        "for _ in 1 2 3 4 5; do "
        "  pids=$(ps -u jonathan -o pid,comm --no-headers | "
        "    awk '$2 ~ /kit/ {print $1}'); "
        "  [ -z \"$pids\" ] && break; "
        "  echo $pids | xargs kill -KILL 2>/dev/null || true; "
        "  sleep 1; "
        "done; true"
    )
    print("[diag] ps after kill:\n" + dellan.succeed(
        "ps -u jonathan -o pid,comm,args --no-headers || true"
    ))
    dellan.succeed("rm -f /tmp/kitty.sock-*")

    # --- Phase 4: relaunch via wrapper — must auto-inject --session.
    # Use shell backgrounding (& + setsid) instead of kitty's --detach,
    # which can spawn an extra default OS window alongside the session. ---
    dellan.succeed(
        "su jonathan -c 'DISPLAY=:0 setsid kitty </dev/null "
        ">/tmp/kitty-relaunch.log 2>&1 &'"
    )
    # Diagnostic dump before the wait — failures at the wait give us
    # nothing to inspect otherwise.
    dellan.sleep(3)
    print("[diag pre-wait] restore.log:\n" + dellan.succeed(
        "cat /tmp/kitty-restore.log 2>&1 || true"
    ))
    print("[diag pre-wait] sockets:\n" + dellan.succeed(
        "find /tmp -maxdepth 1 -name 'kitty.sock-*' 2>&1 || true"
    ))
    dellan.wait_until_succeeds(
        f"su jonathan -c '{sock_cmd} ls >/dev/null'", timeout=30
    )

    # --- Phase 5: capture restored state and assert the full topology
    # (4 windows, expected cwds, expected sleep cmdlines). ---
    # First make sure the socket answers; then capture state; then assert.
    dellan.wait_until_succeeds(
        f"su jonathan -c '{sock_cmd} ls > /tmp/ls-after.json'", timeout=20
    )
    # Give kitty a moment to finish spawning all session-restored windows.
    dellan.sleep(3)
    dellan.succeed(f"su jonathan -c '{sock_cmd} ls > /tmp/ls-after.json'")
    print("[diag] kitty-wrapper.log:\n" + dellan.succeed(
        "cat /tmp/kitty-wrapper.log 2>&1 || true"
    ))
    print("[diag] kitty-restore.log:\n" + dellan.succeed(
        "cat /tmp/kitty-restore.log 2>&1 || true"
    ))
    print("[diag] kitty-relaunch.log:\n" + dellan.succeed(
        "cat /tmp/kitty-relaunch.log 2>&1 || true"
    ))
    print("[diag] ls-after.json:\n" + dellan.succeed("cat /tmp/ls-after.json"))

    # Wait for restore-session to finish injecting all panes (async).
    dellan.wait_until_succeeds(
        f"su jonathan -c '{sock_cmd} ls > /tmp/ls-after.json' && "
        "jq -e '[.[].tabs[].windows[]] | length == 4' /tmp/ls-after.json",
        timeout=30,
    )
    print("[diag] ls-after final:\n" + dellan.succeed("cat /tmp/ls-after.json"))

    # All 3 magic sleep cmds must be back, with their cwds.
    for cwd, magic in panes:
        dellan.succeed(
            f"jq -e '[.[].tabs[].windows[].cwd] | any(. == \"{cwd}\")' "
            "/tmp/ls-after.json"
        )
        dellan.succeed(
            "jq -e '[.[].tabs[].windows[].foreground_processes[]?.cmdline | "
            f"join(\" \")] | any(. | endswith(\"sleep {magic}\"))' "
            "/tmp/ls-after.json"
        )

    # 2x2 grid: tab uses splits layout with 4 distinct window groups.
    # (kitty's `ls` JSON doesn't expose at_x/at_y; the layout pattern is
    # encoded in `tabs[].groups[]` — 4 groups means 4 separate splits.)
    dellan.succeed(
        "jq -e '.[0].tabs[0].layout == \"splits\"' /tmp/ls-after.json"
    )
    dellan.succeed(
        "jq -e '.[0].tabs[0].groups | length == 4' /tmp/ls-after.json"
    )
  '';
}
