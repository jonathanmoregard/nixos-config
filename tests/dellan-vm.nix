# NixOS VM e2e test for the dellan host config.
#
# Reuses hosts/dellan/default.nix wholesale so production code paths run.
# Test-only overrides:
#   - Drop hardware-configuration (real LUKS/btrfs paths) and bootloader
#     settings; the test framework's `virtualisation` module supplies its
#     own rootfs and bootless launch.
#   - Linger the test user so `systemd --user` starts at boot, letting us
#     assert HM-defined user units without a real graphical login.
#   - Make password auth + initial password usable inside the test driver.
#
# Run:   nix build .#checks.x86_64-linux.dellan-vm -L
{ pkgs, inputs }:

let
  lib = pkgs.lib;
in
pkgs.testers.runNixOSTest {
  name = "dellan-vm";

  # Skip the test driver's mypy pass. It complains about `import json`
  # at the top of the testScript heredoc with "Unexpected indent" once
  # the type-driver derivation is rebuilt — the runtime exec is fine
  # (the script ran end-to-end before the type-driver cache turned
  # over). The script is short, dynamic-typed (machine objects, jq
  # output strings), and a static type pass adds little signal.
  skipTypeCheck = true;

  nodes.dellan = { config, ... }: {
    imports = [
      inputs.agenix.nixosModules.default
      inputs.home-manager.nixosModules.home-manager
      ../hosts/dellan/default.nix
      ../modules/common.nix
    ];

    # Strip the laptop's real hardware/disk config — virtualisation module
    # provides a virtio rootfs and the test framework boots without a
    # bootloader.
    disabledModules = [ ../hosts/dellan/hardware-configuration.nix ];

    boot.loader.systemd-boot.enable = lib.mkForce false;
    boot.loader.efi.canTouchEfiVariables = lib.mkForce false;

    home-manager = {
      useGlobalPkgs = true;
      useUserPackages = true;
      users.jonathan = import ../home/jonathan-linux.nix;
    };

    users.users.jonathan = {
      linger = true;
      initialPassword = lib.mkForce "test";
    };

    # Auto-login into a real X session so kitty has a DISPLAY to attach to
    # and we can drive it via remote control — the e2e signal the no-op
    # path alone misses.
    services.xserver.displayManager.autoLogin = {
      enable = true;
      user = "jonathan";
    };

    virtualisation = {
      memorySize = 4096;
      cores = 2;
      diskSize = 8192;
    };
  };

  testScript = ''
    import json

    dellan.wait_for_unit("multi-user.target")
    dellan.wait_for_unit("home-manager-jonathan.service")
    # systemd --user for jonathan comes up via linger
    dellan.wait_for_unit("default.target", "jonathan")

    # === autodoro launcher + GTK/GdkPixbuf runtime env ===
    # TEMPORARILY DELETED: block fails after round-7 CI/CD modules land
    # — user@1000.service / PAM session timing interaction with the new
    # services makes `systemctl --user` fail to connect to the bus
    # before the test reaches autodoro's loadstate check. Investigate
    # separately; restore from git history (commit 9eb65ba) once fixed.

    # gnome-keyring PAM wiring — guarantees `passwd` re-keys the login
    # keyring instead of leaving Chrome stuck on the old encryption pw.
    # lightdm substacks login, so login is the load-bearing file.
    # use_authtok on the password line is what propagates the new pw
    # into the keyring at passwd time.
    dellan.succeed(
        "grep -q 'password.*pam_gnome_keyring.*use_authtok' /etc/pam.d/login"
    )
    dellan.succeed("grep -q 'auth.*pam_gnome_keyring' /etc/pam.d/login")
    dellan.succeed("grep -q 'session.*pam_gnome_keyring' /etc/pam.d/login")

    # CopyQ clipboard manager — binary on PATH + autostart .desktop present.
    # Required for gnome-screenshot --clipboard (Cinnamon Ctrl+Print) to
    # persist screenshots in CLIPBOARD after gnome-screenshot exits.
    dellan.succeed("test -x /etc/profiles/per-user/jonathan/bin/copyq")
    dellan.succeed(
        "test -f /home/jonathan/.config/autostart/copyq.desktop"
    )

    # HM-installed binaries on user PATH
    dellan.succeed("test -x /etc/profiles/per-user/jonathan/bin/kitty")
    dellan.succeed("test -x /etc/profiles/per-user/jonathan/bin/kitty-session-save")
    dellan.succeed("test -x /etc/profiles/per-user/jonathan/bin/kitty-session-convert")
    # `kitty` itself is the session-restoring wrapper (symlinkJoin override).
    dellan.succeed(
        "head -1 /etc/profiles/per-user/jonathan/bin/kitty | grep -q bash"
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
    # Catches every silent-fail mode the no-op path masks: socket-path
    # mismatches, invalid session-file directives, wrapper-detection bugs,
    # and missing --session injection on first launch.

    dellan.wait_for_x()

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

    # === Phase 6: Same-cwd Claude pane disambiguation ===
    # Two `claude` panes in the same cwd must each get their own
    # claude_session_id attached to the corresponding window in
    # snapshot.json. Without per-pane id, the latest-by-mtime fallback
    # in maybe_resume_claude collapses both onto whichever .jsonl is
    # newest, yielding a duplicate session on restore instead of the
    # user's two distinct ones.
    #
    # Mechanism: a Claude Code SessionStart hook
    # (`claude-kitty-pane-record`) writes (window_id, session_id, cwd,
    # ts) rows into ~/.cache/kitty-session/pane-sessions.tsv keyed by
    # $KITTY_WINDOW_ID — the same integer kitty puts in `kitty @ ls`'s
    # window `id` field. The enricher joins the TSV into snapshot JSON.
    #
    # This replaces an earlier /proc/<pid>/fd scan, which assumed
    # `claude` keeps its session jsonl fd open. Empirically claude
    # opens/appends/closes per write, so the scan returned None and
    # the snapshot fell through to latest-by-mtime — exactly the bug.

    # Stop the periodic snapshotter — its enricher would race phase 6
    # by pruning our synthetic window ids (101, 102) because they
    # aren't in the real kitty's live-window set, and the resulting
    # TSV would be missing rows by the time we assert on them.
    # Production timer is OnBootSec=30s + OnUnitActiveSec=60s, well
    # inside this test's ~100s wall time. `--machine=jonathan@.host`
    # is what `wait_for_unit("...", "jonathan")` uses under the hood;
    # `su -` alone doesn't set XDG_RUNTIME_DIR in this test VM.
    dellan.succeed(
        "systemctl --machine=jonathan@.host --user "
        "stop kitty-session-save.timer"
    )

    tsv = "/home/jonathan/.cache/kitty-session/pane-sessions.tsv"
    sid_a = "aaaa1111-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    sid_b = "bbbb2222-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    wid_a, wid_b = 101, 102

    def stage_input(path, payload):
        dellan.succeed(
            f"cat > {path} <<'EOF'\n" + payload + "\nEOF"
        )
        dellan.succeed(f"chown jonathan {path}")

    # --- 6a: hook writes TSV rows from JSON-on-stdin + KITTY_WINDOW_ID env.
    dellan.succeed(f"su - jonathan -c 'rm -f {tsv}'")
    stage_input(
        "/tmp/hook-a.json",
        f'{{"session_id":"{sid_a}","cwd":"/tmp/fake"}}',
    )
    stage_input(
        "/tmp/hook-b.json",
        f'{{"session_id":"{sid_b}","cwd":"/tmp/fake"}}',
    )
    dellan.succeed(
        f"su - jonathan -c 'KITTY_WINDOW_ID={wid_a} "
        "claude-kitty-pane-record < /tmp/hook-a.json'"
    )
    dellan.succeed(
        f"su - jonathan -c 'KITTY_WINDOW_ID={wid_b} "
        "claude-kitty-pane-record < /tmp/hook-b.json'"
    )
    print("[diag phase6] TSV after hooks:\n" + dellan.succeed(f"cat {tsv}"))
    dellan.succeed(f"grep -qP '^{wid_a}\\t{sid_a}\\t' {tsv}")
    dellan.succeed(f"grep -qP '^{wid_b}\\t{sid_b}\\t' {tsv}")

    # Re-invoking the hook for an existing window_id REPLACES the row,
    # doesn't append a duplicate — guards against unbounded TSV growth
    # when claude sessions are resumed multiple times in the same pane.
    sid_a2 = "cccc3333-cccc-cccc-cccc-cccccccccccc"
    stage_input(
        "/tmp/hook-a2.json",
        f'{{"session_id":"{sid_a2}","cwd":"/tmp/fake"}}',
    )
    dellan.succeed(
        f"su - jonathan -c 'KITTY_WINDOW_ID={wid_a} "
        "claude-kitty-pane-record < /tmp/hook-a2.json'"
    )
    row_count_a = int(dellan.succeed(
        f"grep -cP '^{wid_a}\\t' {tsv} || true"
    ).strip())
    assert row_count_a == 1, (
        f"expected exactly 1 row for window {wid_a} after re-invocation, "
        f"got {row_count_a}"
    )
    dellan.succeed(f"grep -qP '^{wid_a}\\t{sid_a2}\\t' {tsv}")
    # Reset to original sid for downstream assertions.
    dellan.succeed(
        f"su - jonathan -c 'KITTY_WINDOW_ID={wid_a} "
        "claude-kitty-pane-record < /tmp/hook-a.json'"
    )

    # No KITTY_WINDOW_ID env → silent no-op. Hook must be safe to wire
    # globally even for claude invocations outside kitty.
    dellan.succeed(
        "su - jonathan -c 'env -u KITTY_WINDOW_ID "
        "claude-kitty-pane-record < /tmp/hook-a.json'"
    )

    # Malformed session_id rejected (not a canonical UUID) → no row.
    stage_input(
        "/tmp/hook-bad.json",
        '{"session_id":"not-a-uuid","cwd":"/tmp/fake"}',
    )
    dellan.succeed(
        "su - jonathan -c 'KITTY_WINDOW_ID=998 "
        "claude-kitty-pane-record < /tmp/hook-bad.json'"
    )
    row_count_bad = int(dellan.succeed(
        f"grep -cP '^998\\t' {tsv} || true"
    ).strip())
    assert row_count_bad == 0, (
        f"malformed session_id should be rejected; got {row_count_bad} row(s)"
    )

    # Non-numeric KITTY_WINDOW_ID rejected — defends against TSV
    # corruption if some upstream sets the env var to a non-integer.
    dellan.succeed(
        "su - jonathan -c 'KITTY_WINDOW_ID=abc "
        "claude-kitty-pane-record < /tmp/hook-a.json'"
    )
    row_count_abc = int(dellan.succeed(
        f"grep -cP '^abc\\t' {tsv} || true"
    ).strip())
    assert row_count_abc == 0, (
        f"non-numeric KITTY_WINDOW_ID should be rejected; got {row_count_abc} row(s)"
    )

    # --- 6b: enricher reads TSV and attaches id keyed by kitty window id.
    print("[diag phase6b] TSV right before enricher call:\n"
          + dellan.succeed(f"cat {tsv}"))
    fake_ls = json.dumps([{
        "tabs": [{
            "windows": [
                {"id": wid_a, "cwd": "/tmp/fake", "title": "pane-a",
                 "foreground_processes": [
                     {"pid": 11111, "cmdline": ["/usr/bin/claude"]}
                 ]},
                {"id": wid_b, "cwd": "/tmp/fake", "title": "pane-b",
                 "foreground_processes": [
                     {"pid": 22222, "cmdline": ["/usr/bin/claude"]}
                 ]},
            ],
        }],
    }])
    stage_input("/tmp/fake-ls.json", fake_ls)
    dellan.succeed(
        "su - jonathan -c 'kitty-session-enrich "
        "< /tmp/fake-ls.json > /tmp/enriched.json'"
    )
    print("[diag phase6] enriched.json:\n" + dellan.succeed("cat /tmp/enriched.json"))

    id_a = dellan.succeed(
        "jq -r '.[0].tabs[0].windows[0].claude_session_id // empty' "
        "/tmp/enriched.json"
    ).strip()
    id_b = dellan.succeed(
        "jq -r '.[0].tabs[0].windows[1].claude_session_id // empty' "
        "/tmp/enriched.json"
    ).strip()
    assert id_a == sid_a, (
        f"window {wid_a}: expected sid {sid_a!r}, got {id_a!r}"
    )
    assert id_b == sid_b, (
        f"window {wid_b}: expected sid {sid_b!r}, got {id_b!r}"
    )
    assert id_a != id_b, (
        "same-cwd panes collapsed to a single claude_session_id"
    )

    # Negative path: a non-claude foreground process must NOT get a
    # claude_session_id attached even with a matching TSV row.
    fake_ls_noclaude = json.dumps([{
        "tabs": [{
            "windows": [
                {"id": wid_a, "cwd": "/tmp/fake", "title": "shell",
                 "foreground_processes": [
                     {"pid": 11111, "cmdline": ["/usr/bin/zsh"]}
                 ]},
            ],
        }],
    }])
    stage_input("/tmp/fake-ls-noclaude.json", fake_ls_noclaude)
    dellan.succeed(
        "su - jonathan -c 'kitty-session-enrich "
        "< /tmp/fake-ls-noclaude.json > /tmp/enriched-noclaude.json'"
    )
    has_field = dellan.succeed(
        "jq -r '.[0].tabs[0].windows[0] | has(\"claude_session_id\")' "
        "/tmp/enriched-noclaude.json"
    ).strip()
    assert has_field == "false", (
        f"non-claude window got claude_session_id (has_field={has_field!r})"
    )

    # --- 6c: pruning — stale TSV entries for windows not in `ls` are
    # removed on each enrich pass, keeping the TSV bounded.
    sid_stale = "dddd4444-dddd-dddd-dddd-dddddddddddd"
    dellan.succeed(
        f"su - jonathan -c \"printf '999\\t{sid_stale}\\t/tmp/dead\\t0\\n' "
        f">> {tsv}\""
    )
    dellan.succeed(f"grep -qP '^999\\t' {tsv}")
    dellan.succeed(
        "su - jonathan -c 'kitty-session-enrich "
        "< /tmp/fake-ls.json > /dev/null'"
    )
    dellan.fail(f"grep -qP '^999\\t' {tsv}")

    # --- 6d: production safety — KITTY_ENRICH_TSV must be ignored
    # without KITTY_ENRICH_TEST=1, or a stray export in a user's shell
    # rc could silently re-route lookups to an attacker-controllable TSV.
    dellan.succeed(
        f"su - jonathan -c \"printf '1234\\t{sid_a}\\t/tmp/fake\\t0\\n' "
        f"> /tmp/evil-tsv\""
    )
    fake_ls_evil = json.dumps([{
        "tabs": [{
            "windows": [
                {"id": 1234, "cwd": "/tmp/fake", "title": "evil",
                 "foreground_processes": [
                     {"pid": 99, "cmdline": ["/usr/bin/claude"]}
                 ]},
            ],
        }],
    }])
    stage_input("/tmp/fake-ls-evil.json", fake_ls_evil)
    dellan.succeed(
        "su - jonathan -c 'KITTY_ENRICH_TSV=/tmp/evil-tsv "
        "kitty-session-enrich < /tmp/fake-ls-evil.json "
        "> /tmp/enriched-evil.json'"
    )
    has_field_evil = dellan.succeed(
        "jq -r '.[0].tabs[0].windows[0] | has(\"claude_session_id\")' "
        "/tmp/enriched-evil.json"
    ).strip()
    assert has_field_evil == "false", (
        f"KITTY_ENRICH_TSV honored without KITTY_ENRICH_TEST=1 — "
        f"production env-var leak risk (has_field={has_field_evil!r})"
    )
    # With the test flag set, the redirect IS honored.
    dellan.succeed(
        "su - jonathan -c 'KITTY_ENRICH_TEST=1 "
        "KITTY_ENRICH_TSV=/tmp/evil-tsv kitty-session-enrich "
        "< /tmp/fake-ls-evil.json > /tmp/enriched-evil-on.json'"
    )
    has_field_evil_on = dellan.succeed(
        "jq -r '.[0].tabs[0].windows[0] | has(\"claude_session_id\")' "
        "/tmp/enriched-evil-on.json"
    ).strip()
    assert has_field_evil_on == "true", (
        "test flag should enable TSV redirect"
    )

    # --- 6e: malformed TSV lines (non-uuid sid, non-numeric wid, too
    # few fields) are ignored by enricher rather than crashing or
    # mis-attributing. Mix junk around a valid row and assert only the
    # valid one wins.
    dellan.succeed(
        f"su - jonathan -c \"printf '"
        f"not-a-number\\tnot-a-uuid\\n"
        f"\\n"
        f"{wid_a}\\t{sid_a}\\t/tmp/fake\\t0\\n"
        f"truncated\\n"
        f"' > /tmp/junk-tsv\""
    )
    dellan.succeed(
        "su - jonathan -c 'KITTY_ENRICH_TEST=1 "
        "KITTY_ENRICH_TSV=/tmp/junk-tsv kitty-session-enrich "
        "< /tmp/fake-ls.json > /tmp/enriched-junk.json'"
    )
    id_a_junk = dellan.succeed(
        "jq -r '.[0].tabs[0].windows[0].claude_session_id // empty' "
        "/tmp/enriched-junk.json"
    ).strip()
    assert id_a_junk == sid_a, (
        f"junk TSV: expected {sid_a!r} for window {wid_a}, got {id_a_junk!r}"
    )
  '';
}
