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

  # Test-only MCP driver — drives the claude-rebuild-mcp server over stdio
  # from inside the VM. Defined here (rather than inline as a heredoc) so
  # Nix's `''` indented-string stripping doesn't get confused by Python
  # code at column 0.
  mcpDriverScript = pkgs.writeText "mcp-drive.py" ''
    import json
    import os
    import subprocess
    import sys

    env = dict(os.environ)

    reqs = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize",
         "params": {"protocolVersion": "2025-06-18",
                    "capabilities": {},
                    "clientInfo": {"name": "vm-e2e", "version": "0"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
         "params": {"name": "classify_dellan", "arguments": {}}},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
         "params": {"name": "rebuild_dellan", "arguments": {}}},
    ]
    inp = "\n".join(json.dumps(r) for r in reqs) + "\n"

    proc = subprocess.run(
        ["claude-rebuild-mcp"],
        input=inp, capture_output=True, text=True, timeout=30, env=env,
    )

    results = {}
    for line in proc.stdout.splitlines():
        try:
            msg = json.loads(line)
        except Exception:
            continue
        if isinstance(msg, dict) and "id" in msg:
            results[msg["id"]] = msg

    sys.stderr.write("MCP STDERR:\n" + proc.stderr[-1500:] + "\n")
    print(json.dumps(results))
    sys.exit(0 if 2 in results and 3 in results else 1)
  '';
in
pkgs.testers.runNixOSTest {
  name = "dellan-vm";

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

    # Test-only — preserve claude-rebuild env overrides through sudo so the
    # e2e MCP→sudo→apply path can stub nixos-rebuild and redirect repo/state
    # to a fixture. Production sudoers does NOT include this; defaults take
    # over and apply hits real /etc/nixos + real nixos-rebuild.
    security.sudo.extraConfig = ''
      Defaults env_keep += "CLAUDE_REBUILD_REPO CLAUDE_REBUILD_STATE_DIR CLAUDE_REBUILD_AUDIT_LOG CLAUDE_REBUILD_NIXOS_REBUILD_BIN"
    '';

    # Test-only MCP driver script.
    environment.etc."mcp-drive.py".source = mcpDriverScript;

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
        "sock=$(ls /tmp/kitty.sock-* 2>/dev/null | head -1); "
        "[ -n \"$sock\" ] && kitty @ --to unix:$sock"
    )

    # --- Phase 1: bring up kitty + 3 extra windows, each with a distinct
    # cwd and a distinct long-running command. The default first window
    # holds the user's shell. We end with 4 windows total. ---
    dellan.succeed(
        "su jonathan -c 'DISPLAY=:0 nohup kitty -1 --detach "
        ">/tmp/kitty-launch.log 2>&1' &"
    )
    dellan.wait_until_succeeds(
        f"su jonathan -c '{sock_cmd} ls >/dev/null'", timeout=30
    )
    sleep_bin = "/run/current-system/sw/bin/sleep"
    panes = [
        ("/tmp", "11111"),
        ("/var", "22222"),
        ("/etc", "33333"),
    ]
    # Set up 4 panes via kitty's native remote control. The 2x2 grid
    # ordering (vsplit, hsplit-left, hsplit-right, new-tab pattern) is
    # WIP — see kittyPaneAdd / kittyRestoreSession in home/kitty.nix.
    # For now we just verify that the 4 panes' cwds + cmdlines round-trip.
    for cwd, magic in panes:
        dellan.succeed(
            f"su jonathan -c '{sock_cmd} launch --type=window --cwd {cwd} "
            f"{sleep_bin} {magic}'"
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

    # --- Phase 3: kill kitty, confirm process gone. (Stale socket files
    # may persist briefly; the wrapper probes them on next launch and
    # cleans dead ones — see home/kitty.nix.) ---
    dellan.succeed("su jonathan -c 'pkill -x kitty || true'")
    dellan.wait_until_succeeds(
        "! pgrep -x -u jonathan kitty >/dev/null", timeout=15
    )

    # --- Phase 4: relaunch via wrapper — must auto-inject --session.
    # Use shell backgrounding (& + setsid) instead of kitty's --detach,
    # which can spawn an extra default OS window alongside the session. ---
    dellan.succeed(
        "su jonathan -c 'DISPLAY=:0 setsid kitty </dev/null "
        ">/tmp/kitty-restore.log 2>&1 &'"
    )
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
    print("[diag] kitty-restore.log:\n" + dellan.succeed(
        "cat /tmp/kitty-restore.log 2>&1 || true"
    ))
    print("[diag] ls-after.json:\n" + dellan.succeed("cat /tmp/ls-after.json"))

    # All 3 magic sleep cmds must be back, with their cwds. (Layout / 2x2
    # grid restoration is WIP — see kittyPaneAdd in home/kitty.nix.)
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

    # === claude-rebuild — module from modules/nixos/claude-rebuild ===
    # Binaries on system PATH (environment.systemPackages → current-system/sw/bin)
    dellan.succeed("test -x /run/current-system/sw/bin/claude-rebuild-classify")
    dellan.succeed("test -x /run/current-system/sw/bin/claude-rebuild-apply")
    dellan.succeed("test -x /run/current-system/sw/bin/claude-rebuild-mcp")

    # Help output proves the entry-point + python deps resolved
    dellan.succeed("claude-rebuild-classify --help >/dev/null")
    dellan.succeed("claude-rebuild-apply --help >/dev/null")

    # State + audit-log paths declared via systemd.tmpfiles
    dellan.succeed("test -d /var/lib/claude-rebuild")
    dellan.succeed("test -f /var/log/claude-rebuild.log")

    # Sudoers rule: NOPASSWD only for `claude-rebuild-apply low` — high tier
    # MUST flow through pkexec so polkit can prompt the user. The rule is
    # rendered at /etc/sudoers.d/<n>-claude-rebuild_extraRules-cmd-0 (or
    # similar) — grep the merged sudoers for the contract.
    dellan.succeed(
        "sudo -l -U jonathan 2>&1 | "
        "grep -E 'NOPASSWD: .*/claude-rebuild-apply low'"
    )
    # Negative — high must NOT be NOPASSWD-able via sudo
    dellan.fail(
        "sudo -l -U jonathan 2>&1 | "
        "grep -E 'NOPASSWD: .*/claude-rebuild-apply high'"
    )

    # MCP stdio server — initialize handshake should round-trip
    init_req = (
        '{"jsonrpc":"2.0","id":1,"method":"initialize",'
        '"params":{"protocolVersion":"2025-06-18",'
        '"capabilities":{},"clientInfo":{"name":"vm-test","version":"0"}}}'
    )
    dellan.succeed(
        f"echo '{init_req}' | timeout 10 claude-rebuild-mcp 2>/dev/null | "
        "grep -q '\"serverInfo\":{\"name\":\"claude-rebuild\"'"
    )

    # ~/.claude/symlinks — declarative HM derivation, contents fixed
    dellan.succeed(
        "test -L /home/jonathan/.claude/symlinks/claude-rebuild-nix"
    )
    dellan.succeed(
        "test -L /home/jonathan/.claude/symlinks/claude-rebuild-mcp"
    )
    # Targets resolve into /etc/nixos
    dellan.succeed(
        "readlink /home/jonathan/.claude/symlinks/claude-rebuild-nix | "
        "grep -q '^/etc/nixos/modules/nixos/claude-rebuild$'"
    )

    # === claude-rebuild full e2e: classifier → apply → MCP roundtrip ===
    # Stubs nixos-rebuild via env override (CLAUDE_REBUILD_NIXOS_REBUILD_BIN)
    # and redirects repo/state via env so we don't fight the real /etc/nixos
    # or write to live /var/lib. Sudoers env_keep (test-only) lets these
    # vars survive `sudo -n claude-rebuild-apply low` from the MCP server.

    # Allow git to read repos owned by other users — needed because MCP
    # server runs as jonathan but apply runs as root via sudo.
    dellan.succeed("git config --system --add safe.directory '*'")

    # Fixture repo with one low-blast change committed against base.
    dellan.succeed("""
      set -eux
      mkdir -p /tmp/cr-repo
      cd /tmp/cr-repo
      git init -q
      git config user.email a@b
      git config user.name t
      mkdir -p home modules/nixos overlays
      echo '{ }' > home/foo.nix
      git add -A
      git commit -q -m base
      echo '{ environment.systemPackages = [ ]; }' > home/foo.nix
      git add -A
      git commit -q -m low-change
      chmod -R a+rX /tmp/cr-repo
    """)

    cr_env = (
        "CLAUDE_REBUILD_REPO=/tmp/cr-repo "
        "CLAUDE_REBUILD_STATE_DIR=/tmp/cr-state "
        "CLAUDE_REBUILD_AUDIT_LOG=/tmp/cr-audit.log "
        "CLAUDE_REBUILD_NIXOS_REBUILD_BIN=/run/current-system/sw/bin/true "
    )

    # --- Classifier on low-blast diff ---
    out = dellan.succeed(f"{cr_env} claude-rebuild-classify --from HEAD~1 --to HEAD")
    import json as _json
    parsed = _json.loads(out)
    assert parsed["tier"] == "low", f"expected low, got {parsed!r}"

    # --- Direct apply low (root invocation) — stubbed nixos-rebuild ---
    # `--to HEAD` is required (no default) since round 2 — prevents HEAD
    # drift between an agent's classification and apply.
    dellan.succeed(f"{cr_env} claude-rebuild-apply low --to HEAD")
    dellan.succeed("test -s /tmp/cr-state/last-applied-rev")
    dellan.succeed("grep -q rebuild_finish /tmp/cr-audit.log")
    dellan.succeed("grep -q '\"exit_code\": 0' /tmp/cr-audit.log")

    # apply with no --to must fail fast (required arg) — defense against
    # CLI invocations that re-resolve HEAD silently.
    dellan.fail(f"{cr_env} claude-rebuild-apply low")

    # --- Stage a HIGH-blast diff: touch flake.nix ---
    dellan.succeed("""
      set -eux
      cd /tmp/cr-repo
      echo '{ description = "x"; }' > flake.nix
      git add -A
      git -c user.email=a@b -c user.name=t commit -q -m high-change
    """)

    out = dellan.succeed(f"{cr_env} claude-rebuild-classify")
    parsed = _json.loads(out)
    assert parsed["tier"] == "high", f"expected high, got {parsed!r}"

    # --- Defense in depth: apply low when classifier says high → reject ---
    dellan.fail(f"{cr_env} claude-rebuild-apply low --to HEAD")

    # --- High tier without PKEXEC_UID → reject ---
    dellan.fail(f"{cr_env} claude-rebuild-apply high --to HEAD")

    # --- High tier with PKEXEC_UID set (simulating a successful pkexec
    # elevation; in production polkit's prompt is the actual HITL gate) ---
    dellan.succeed(f"PKEXEC_UID=1000 {cr_env} claude-rebuild-apply high --to HEAD")

    # --- B1 fix: --to <sha> pins the apply to the user-approved diff. ---
    # Reset to a clean state, commit C1 (low), capture sha, commit C2 (high).
    # apply with --to=C1 must apply C1 even though HEAD points at C2.
    dellan.succeed("""
      set -eux
      cd /tmp/cr-repo
      git reset --hard HEAD~2  # back to base
      rm -rf /tmp/cr-state /tmp/cr-audit.log
      echo '{ environment.systemPackages = [ ]; }' > home/foo.nix
      git add -A
      git -c user.email=a@b -c user.name=t commit -q -m C1-low
    """)
    c1_sha = dellan.succeed("cd /tmp/cr-repo && git rev-parse HEAD").strip()
    dellan.succeed("""
      set -eux
      cd /tmp/cr-repo
      echo '{ description = "x"; }' > flake.nix
      git add -A
      git -c user.email=a@b -c user.name=t commit -q -m C2-high
    """)
    # apply --to=C1 (low) should classify C1 alone (low) and apply, even
    # though HEAD is C2 (high). If apply silently picked HEAD it would
    # reject as tier mismatch.
    dellan.succeed(
        f"{cr_env} claude-rebuild-apply low --to {c1_sha}"
    )
    applied_rev = dellan.succeed("cat /tmp/cr-state/last-applied-rev").strip()
    assert applied_rev == c1_sha, f"expected --to to pin to {c1_sha}, got {applied_rev}"

    # --- H2 fix: audit records include caller identity (ppid, cmdline,
    # SUDO_*/PKEXEC_* if present). ---
    last_audit = dellan.succeed("tail -1 /tmp/cr-audit.log")
    last = _json.loads(last_audit)
    assert "caller" in last, f"audit missing caller: {last!r}"
    assert last["caller"]["ppid"], f"audit caller missing ppid: {last['caller']!r}"

    # --- H3 fix: secrets/*.age rotation now classified high. ---
    dellan.succeed("""
      set -eux
      cd /tmp/cr-repo
      git reset --hard HEAD~2  # base
      mkdir -p secrets
      echo 'fakeciphertext-v1' > secrets/foo.age
      git add -A
      git -c user.email=a@b -c user.name=t commit -q -m secrets-add
      echo 'fakeciphertext-v2' > secrets/foo.age  # rotation
      git add -A
      git -c user.email=a@b -c user.name=t commit -q -m secrets-rotate
    """)
    out = dellan.succeed(f"{cr_env} claude-rebuild-classify --from HEAD~1 --to HEAD")
    parsed = _json.loads(out)
    assert parsed["tier"] == "high", f"secret rotation should be high, got {parsed!r}"

    # --- M1 fix: deny-key for services.openssh inside an ALWAYS_LOW file ---
    # Even though modules/nixos/desktop.nix is in ALWAYS_LOW_FILES, an
    # added line containing services.openssh must trip the deny-key check.
    dellan.succeed("""
      set -eux
      cd /tmp/cr-repo
      git reset --hard HEAD~2  # base
      mkdir -p modules/nixos
      echo '{ }' > modules/nixos/desktop.nix
      git add -A
      git -c user.email=a@b -c user.name=t commit -q -m desktop-base
      printf '%s\\n' '{ ... }: {' '  services.openssh.passwordAuthentication = true;' '}' > modules/nixos/desktop.nix
      git add -A
      git -c user.email=a@b -c user.name=t commit -q -m sshd-flip
    """)
    out = dellan.succeed(f"{cr_env} claude-rebuild-classify --from HEAD~1 --to HEAD")
    parsed = _json.loads(out)
    assert parsed["tier"] == "high", f"services.openssh in desktop.nix must be high, got {parsed!r}"

    # --- M2 fix: classifier surfaces a useful error on a bogus rev. ---
    # H5's ancestor check now fast-fails on unknown-rev with "not an
    # ancestor"; deeper M2-style git-stderr surfacing is exercised when
    # the rev exists but the repo state is broken (covered indirectly).
    rc, output = dellan.execute(
        f"{cr_env} claude-rebuild-classify --from nonexistent-rev --to HEAD 2>&1"
    )
    assert rc != 0, "classifier should fail on bogus rev"
    assert any(s in output for s in ("ancestor", "fatal:", "unknown revision", "bad revision")), (
        f"classifier should surface a useful error; got: {output[-500:]}"
    )

    # --- H5 fix: classifier refuses if <from> is not an ancestor of <to>. ---
    # Use the existing 3-commit linear history (base → desktop-base →
    # sshd-flip) and reverse the rev range. HEAD is sshd-flip, HEAD~1 is
    # desktop-base. `--from HEAD --to HEAD~1` → from is NOT an ancestor
    # of to (it's a descendant). Refusal expected. No branch state to
    # clean up; subsequent tests still see a 3-commit history.
    rc, output = dellan.execute(
        f"{cr_env} claude-rebuild-classify --from HEAD --to HEAD~1 2>&1"
    )
    assert rc != 0, f"classifier should refuse non-ancestor; got rc={rc}, out={output!r}"
    assert "ancestor" in output, f"expected ancestor refusal message; got: {output[-500:]}"

    # --- L12: production safe.directory works on real /etc/nixos. ---
    # Unlike the test-only `safe.directory '*'` we set above, the module
    # declares a pinned safe.directory = /etc/nixos in NixOS config. This
    # asserts that pin works for `jonathan` reading the root-owned repo.
    # /etc/nixos in the test VM is whatever NixOS materialized — empty by
    # default, so we initialize it as a real git repo first to exercise
    # the safe.directory contract.
    dellan.succeed("""
      set -eux
      mkdir -p /etc/nixos
      cd /etc/nixos
      git init -q 2>/dev/null || true
      git config user.email a@b
      git config user.name t
      [ -f marker ] || ( echo m > marker && git add -A && git -c user.email=a@b -c user.name=t commit -q -m init )
      chown -R root:root /etc/nixos
    """)
    # As jonathan, run git status on root-owned /etc/nixos. With pinned
    # safe.directory in NixOS config (programs.git.config.safe.directory),
    # this must succeed without "dubious ownership" error.
    dellan.succeed(
        "su - jonathan -c 'git -C /etc/nixos status' >/dev/null"
    )

    # === MCP server stdio: full request/response cycle ===
    # Reset state to base + one low-blast change (collapse the high-blast
    # commits into a fresh rev range so MCP's no-arg call sees low-blast).
    dellan.succeed("""
      set -eux
      cd /tmp/cr-repo
      git reset --hard HEAD~1
      rm -rf /tmp/cr-state /tmp/cr-audit.log
    """)

    # MCP driver lives at /etc/mcp-drive.py (installed via environment.etc).
    # Run as jonathan so the MCP→sudo path is exercised exactly as production.
    raw = dellan.succeed(
        f"su - jonathan -c '{cr_env} python3 /etc/mcp-drive.py'"
    )
    mcp_results = _json.loads(raw.strip().splitlines()[-1])

    # tools/call classify_dellan
    classify_msg = mcp_results["2"]
    classify_text = classify_msg["result"]["structuredContent"]
    assert classify_text["tier"] == "low", f"MCP classify wrong tier: {classify_text!r}"

    # tools/call rebuild_dellan — should apply via sudo NOPASSWD path
    rebuild_msg = mcp_results["3"]
    rebuild_struct = rebuild_msg["result"]["structuredContent"]
    assert rebuild_struct["tier"] == "low", f"MCP rebuild wrong tier: {rebuild_struct!r}"
    assert rebuild_struct["applied"] is True, (
        f"MCP rebuild not applied: {rebuild_struct!r}"
    )

    # Audit log written by the apply binary post-sudo elevation.
    dellan.succeed("test -s /tmp/cr-audit.log")
    dellan.succeed("grep -q rebuild_finish /tmp/cr-audit.log")
    dellan.succeed("test -s /tmp/cr-state/last-applied-rev")
  '';
}
