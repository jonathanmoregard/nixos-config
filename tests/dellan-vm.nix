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
    # collapses both panes onto whichever .jsonl is newest, yielding a
    # duplicate session on restore instead of the user's two distinct
    # ones.
    #
    # Faking real claude processes inside the test VM (argv[0]="claude"
    # AND an open jsonl fd visible via /proc/<pid>/fd) proved fragile —
    # coreutils-multicall trips up `exec -a`, and
    # systemd-run/su/setsid backgrounding interacts unpredictably with
    # dellan.succeed's wait-for-EOF semantics. Instead, the enricher
    # supports a KITTY_ENRICH_PROC_ROOT env var (test-only seam,
    # production always uses /proc) so we can point it at a fake tree
    # of symlinks. This isolates the enricher's lookup logic, which is
    # the only thing the bug fix changed.

    proj_dir = "/home/jonathan/.claude/projects/-tmp-fake"
    sid_a = "aaaa1111-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    sid_b = "bbbb2222-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    dellan.succeed(
        f"su - jonathan -c 'mkdir -p {proj_dir} && "
        f"touch {proj_dir}/{sid_a}.jsonl {proj_dir}/{sid_b}.jsonl'"
    )

    # Fake /proc tree: two arbitrary pids, each with an /fd/9 symlink
    # to a distinct .jsonl. Pids don't need to map to real processes —
    # the enricher only does os.listdir / os.readlink under
    # PROC_ROOT/<pid>/fd.
    fake_proc = "/tmp/fake-proc"
    pid_a, pid_b = 12345, 67890
    dellan.succeed(
        f"rm -rf {fake_proc} && "
        f"mkdir -p {fake_proc}/{pid_a}/fd {fake_proc}/{pid_b}/fd && "
        f"ln -s {proj_dir}/{sid_a}.jsonl {fake_proc}/{pid_a}/fd/9 && "
        f"ln -s {proj_dir}/{sid_b}.jsonl {fake_proc}/{pid_b}/fd/9 && "
        f"chown -R jonathan {fake_proc}"
    )
    print(
        "[diag phase6] fake-proc tree:\n"
        + dellan.succeed(f"ls -laR {fake_proc}")
    )

    # Synthetic `kitty @ ls` JSON with two same-cwd claude windows
    # whose foreground_processes point at the fake pids.
    fake_ls = json.dumps([{
        "tabs": [{
            "windows": [
                {"cwd": "/tmp/fake", "title": "pane-a",
                 "foreground_processes": [
                     {"pid": pid_a, "cmdline": ["/usr/bin/claude"]}
                 ]},
                {"cwd": "/tmp/fake", "title": "pane-b",
                 "foreground_processes": [
                     {"pid": pid_b, "cmdline": ["/usr/bin/claude"]}
                 ]},
            ],
        }],
    }])
    dellan.succeed(
        "cat > /tmp/fake-ls.json <<'EOF'\n" + fake_ls + "\nEOF"
    )
    dellan.succeed("chown jonathan /tmp/fake-ls.json")
    print(
        "[diag phase6] fake-ls.json:\n"
        + dellan.succeed("cat /tmp/fake-ls.json")
    )

    dellan.succeed(
        f"su - jonathan -c 'KITTY_ENRICH_TEST=1 KITTY_ENRICH_PROC_ROOT={fake_proc} "
        "kitty-session-enrich < /tmp/fake-ls.json > /tmp/enriched.json'"
    )
    print(
        "[diag phase6] enriched.json:\n"
        + dellan.succeed("cat /tmp/enriched.json")
    )

    id_a = dellan.succeed(
        "jq -r '.[0].tabs[0].windows[0].claude_session_id // empty' "
        "/tmp/enriched.json"
    ).strip()
    id_b = dellan.succeed(
        "jq -r '.[0].tabs[0].windows[1].claude_session_id // empty' "
        "/tmp/enriched.json"
    ).strip()
    assert id_a == sid_a, (
        f"window 0 expected sid {sid_a!r}, got {id_a!r} — "
        "enricher dropped or mis-attached id"
    )
    assert id_b == sid_b, (
        f"window 1 expected sid {sid_b!r}, got {id_b!r} — "
        "enricher dropped or mis-attached id"
    )
    assert id_a != id_b, (
        "same-cwd panes collapsed to a single claude_session_id — "
        "enricher failed to disambiguate"
    )

    # Negative path: a non-claude foreground process must NOT get a
    # claude_session_id attached even when its pid would have a
    # matching jsonl fd in the fake /proc tree.
    fake_ls_noclaude = json.dumps([{
        "tabs": [{
            "windows": [
                {"cwd": "/tmp/fake", "title": "shell",
                 "foreground_processes": [
                     {"pid": pid_a, "cmdline": ["/usr/bin/zsh"]}
                 ]},
            ],
        }],
    }])
    dellan.succeed(
        "cat > /tmp/fake-ls-noclaude.json <<'EOF'\n"
        + fake_ls_noclaude + "\nEOF"
    )
    dellan.succeed(
        f"su - jonathan -c 'KITTY_ENRICH_TEST=1 KITTY_ENRICH_PROC_ROOT={fake_proc} "
        "kitty-session-enrich < /tmp/fake-ls-noclaude.json "
        "> /tmp/enriched-noclaude.json'"
    )
    has_field = dellan.succeed(
        "jq -r '.[0].tabs[0].windows[0] | has(\"claude_session_id\")' "
        "/tmp/enriched-noclaude.json"
    ).strip()
    assert has_field == "false", (
        f"non-claude window got tagged with claude_session_id "
        f"(has_field={has_field!r})"
    )

    # Production safety: KITTY_ENRICH_PROC_ROOT must be ignored without
    # the explicit KITTY_ENRICH_TEST=1 marker, or a stray export in a
    # user's shell rc could silently re-route /proc lookups to an
    # attacker-controllable tree.
    dellan.succeed(
        f"su - jonathan -c 'KITTY_ENRICH_PROC_ROOT={fake_proc} "
        "kitty-session-enrich < /tmp/fake-ls.json > /tmp/enriched-noflag.json'"
    )
    has_field_noflag = dellan.succeed(
        "jq -r '.[0].tabs[0].windows[0] | has(\"claude_session_id\")' "
        "/tmp/enriched-noflag.json"
    ).strip()
    assert has_field_noflag == "false", (
        "PROC_ROOT was honored without KITTY_ENRICH_TEST=1 — "
        f"production env-var leak risk (has_field={has_field_noflag!r})"
    )

    # Regex tightness: only canonical UUID-shaped session ids
    # (8-4-4-4-12 lowercase hex) must be matched. A non-UUID jsonl in
    # the project dir must NOT be picked up.
    bad_name = "abcdef0123456789abcdef0123456789ab"
    dellan.succeed(
        f"su - jonathan -c 'touch {proj_dir}/{bad_name}.jsonl'"
    )
    pid_c = 33333
    dellan.succeed(
        f"mkdir -p {fake_proc}/{pid_c}/fd && "
        f"ln -s {proj_dir}/{bad_name}.jsonl {fake_proc}/{pid_c}/fd/9 && "
        f"chown -R jonathan {fake_proc}/{pid_c}"
    )
    fake_ls_badname = json.dumps([{
        "tabs": [{
            "windows": [
                {"cwd": "/tmp/fake", "title": "pane-c",
                 "foreground_processes": [
                     {"pid": pid_c, "cmdline": ["/usr/bin/claude"]}
                 ]},
            ],
        }],
    }])
    dellan.succeed(
        "cat > /tmp/fake-ls-badname.json <<'EOF'\n"
        + fake_ls_badname + "\nEOF"
    )
    dellan.succeed(
        f"su - jonathan -c 'KITTY_ENRICH_TEST=1 "
        f"KITTY_ENRICH_PROC_ROOT={fake_proc} kitty-session-enrich "
        "< /tmp/fake-ls-badname.json > /tmp/enriched-badname.json'"
    )
    has_field_badname = dellan.succeed(
        "jq -r '.[0].tabs[0].windows[0] | has(\"claude_session_id\")' "
        "/tmp/enriched-badname.json"
    ).strip()
    assert has_field_badname == "false", (
        f"non-UUID jsonl matched the regex — would attribute the "
        f"wrong id (has_field={has_field_badname!r})"
    )

    # Break-placement: a window with two claude foreground_processes
    # where the first has no attributable session id (process gone /
    # no jsonl fd) must fall through to the second. An unconditional
    # `break` after the first match attempt would skip the second,
    # leaving the window untagged.
    pid_no_sid = 44444
    dellan.succeed(
        f"mkdir -p {fake_proc}/{pid_no_sid}/fd && "
        f"chown -R jonathan {fake_proc}/{pid_no_sid}"
    )
    fake_ls_two_fps = json.dumps([{
        "tabs": [{
            "windows": [
                {"cwd": "/tmp/fake", "title": "pane-multi",
                 "foreground_processes": [
                     {"pid": pid_no_sid, "cmdline": ["/usr/bin/claude"]},
                     {"pid": pid_a, "cmdline": ["/usr/bin/claude"]},
                 ]},
            ],
        }],
    }])
    dellan.succeed(
        "cat > /tmp/fake-ls-twofp.json <<'EOF'\n"
        + fake_ls_two_fps + "\nEOF"
    )
    dellan.succeed(
        f"su - jonathan -c 'KITTY_ENRICH_TEST=1 "
        f"KITTY_ENRICH_PROC_ROOT={fake_proc} kitty-session-enrich "
        "< /tmp/fake-ls-twofp.json > /tmp/enriched-twofp.json'"
    )
    id_multi = dellan.succeed(
        "jq -r '.[0].tabs[0].windows[0].claude_session_id // empty' "
        "/tmp/enriched-twofp.json"
    ).strip()
    assert id_multi == sid_a, (
        f"two-claude-fp window: expected fallthrough to second fp "
        f"with sid {sid_a!r}, got {id_multi!r} — break is firing "
        "before all claude fps are tried"
    )
  '';
}
