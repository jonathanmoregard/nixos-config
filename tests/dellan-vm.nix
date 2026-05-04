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
    dellan.wait_for_unit("multi-user.target")
    dellan.wait_for_unit("home-manager-jonathan.service")
    # systemd --user for jonathan comes up via linger
    dellan.wait_for_unit("default.target", "jonathan")

    # === autodoro launcher + GTK/GdkPixbuf runtime env ===
    # On NixOS the autodoro pomodoro service must launch via a wrapper
    # that injects a deterministic PATH (bash, pactl, paplay, xprintidle,
    # cinnamon-screensaver-command, python3-with-gi) plus GI_TYPELIB_PATH
    # and GDK_PIXBUF_MODULE_FILE so the GTK popup + webp blocker image
    # render. Without the wrapper, the service exits 203/EXEC (the
    # repo's `#!/bin/bash` shebang has no /bin/bash on NixOS) or
    # crashes inside python with "Namespace Gtk not available" /
    # "Couldn't recognize the image file format for file ...webp".

    dellan.succeed("test -x /etc/profiles/per-user/jonathan/bin/autodoro")
    dellan.succeed("test -x /etc/profiles/per-user/jonathan/bin/autodoro-env")

    # Wrapper is a real shell script (writeShellApplication output).
    dellan.succeed(
        "head -1 /etc/profiles/per-user/jonathan/bin/autodoro | "
        "grep -Eq '^#!.*/(ba)?sh'"
    )

    # All runtime CLI deps reachable from the launcher's PATH.
    # `command -v` is a shell builtin, so we have to invoke it through
    # bash (the wrapper exec's its argv directly, and exec can't run
    # builtins).
    for binname in [
        "bash", "pactl", "paplay", "xprintidle",
        "cinnamon-screensaver-command", "python3",
    ]:
        dellan.succeed(
            f"su jonathan -c \"autodoro-env bash -c 'command -v {binname}'\""
        )

    # systemd unit definition resolves and is loaded. ExecCondition
    # exits non-zero in the test VM because ~/Repos/autodoro is not
    # cloned, so the unit stays inactive — but it must not be
    # not-found / failed at the unit-file layer.
    state = dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/1000 "
        "systemctl --user show -p LoadState autodoro.service'"
    ).strip()
    assert state.endswith("=loaded"), f"autodoro.service LoadState: {state}"

    # GTK 3 + GdkPixbuf importable AND webp pixbuf loader registered.
    # Catches GI_TYPELIB_PATH gaps (Gtk import) and missing
    # GDK_PIXBUF_MODULE_FILE / webp-pixbuf-loader (blocker.py loads
    # /home/jonathan/Repos/intender/.../misty-1280.webp at runtime).
    py_check = "\n".join([
        "import gi",
        "gi.require_version('Gtk', '3.0')",
        "from gi.repository import Gtk, Gdk, GdkPixbuf, GLib  # noqa: F401",
        "fmts = sorted(f.get_name() for f in GdkPixbuf.Pixbuf.get_formats())",
        "assert 'webp' in fmts, f'webp loader missing; have: {fmts}'",
        "print('ok ' + ','.join(fmts))",
        "",
    ])
    dellan.succeed(
        "cat > /tmp/autodoro-check.py <<'PYEOF'\n"
        + py_check + "PYEOF"
    )
    pixbuf_out = dellan.succeed(
        "su jonathan -c 'autodoro-env python3 /tmp/autodoro-check.py'"
    )
    print("[diag autodoro] gi/pixbuf check:\n" + pixbuf_out)
    assert pixbuf_out.startswith("ok "), pixbuf_out

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
    dellan.wait_until_succeeds(
        f"su jonathan -c '{sock_cmd} ls >/dev/null'", timeout=30
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
  '';
}
