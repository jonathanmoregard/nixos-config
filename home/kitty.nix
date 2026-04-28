{ pkgs, ... }:
let
  # Convert `kitty @ ls` JSON snapshot → kitty session-file format
  # (https://sw.kovidgoyal.net/kitty/overview/#startup-sessions).
  # Restores OS-window/tab/window topology, layouts, cwds, titles. Does
  # NOT restore foreground commands or scrollback — kitty has no API for
  # those, same gap as tmux-resurrect.
  kittySessionConvert = pkgs.writers.writePython3Bin "kitty-session-convert" {} ''
    import json
    import shlex
    import sys

    data = json.load(sys.stdin)
    out = []
    for i, osw in enumerate(data):
        if i > 0:
            out.append("new_os_window")
        for j, tab in enumerate(osw.get("tabs", [])):
            if j > 0:
                title = tab.get("title", "")
                out.append(f"new_tab {title}".rstrip())
            layout = tab.get("layout", "")
            if layout:
                out.append(f"layout {layout}")
            # Each `launch` creates a new window in the current tab. There
            # is no `new_window` directive in kitty's session file format.
            # cwd goes inline via `--cwd` rather than a separate `cd`
            # directive — `cd` between launches can confuse kitty into
            # opening extra OS windows under `--session`.
            for win in tab.get("windows", []):
                cwd = win.get("cwd")
                wtitle = win.get("title", "")
                fg = win.get("foreground_processes") or []
                cmdline = fg[0].get("cmdline", []) if fg else []
                parts = ["launch"]
                if cwd:
                    parts.append("--cwd")
                    parts.append(shlex.quote(cwd))
                if wtitle:
                    parts.append("--title")
                    parts.append(shlex.quote(wtitle))
                if cmdline:
                    parts.extend(shlex.quote(a) for a in cmdline)
                out.append(" ".join(parts))
    sys.stdout.write("\n".join(out) + "\n")
  '';

  # Add a new pane following a deterministic 2x2-per-tab grid pattern:
  #   pane 1: full
  #   pane 2: vsplit (right half)
  #   pane 3: hsplit on left side  → upper-left / lower-left
  #   pane 4: hsplit on right side → upper-right / lower-right
  #   pane 5+: new tab, repeat
  # Reusable by both session restore and a future kitty MCP server.
  kittyPaneAdd = pkgs.writers.writePython3Bin "kitty-pane-add" {} ''
    """Add a pane following the 2x2-per-tab grid.

    Usage: kitty-pane-add [--cwd DIR] [--title T] [-- CMD ARGS...]
    """
    import glob
    import json
    import subprocess
    import sys


    def find_socket():
        for f in sorted(glob.glob("/tmp/kitty.sock-*")):
            r = subprocess.run(
                ["kitty", "@", "--to", f"unix:{f}", "ls"],
                capture_output=True, timeout=3,
            )
            if r.returncode == 0:
                return f"unix:{f}"
        return None


    def parse_args(argv):
        cwd = None
        title = None
        cmd = []
        i = 1
        while i < len(argv):
            a = argv[i]
            if a == "--cwd":
                cwd = argv[i + 1]
                i += 2
            elif a == "--title":
                title = argv[i + 1]
                i += 2
            elif a == "--":
                cmd = argv[i + 1:]
                break
            else:
                print(f"unknown arg: {a}", file=sys.stderr)
                sys.exit(2)
        return cwd, title, cmd


    def main():
        cwd, title, cmd = parse_args(sys.argv)
        sock = find_socket()
        if not sock:
            print("no live kitty", file=sys.stderr)
            sys.exit(1)

        ls_out = subprocess.check_output(
            ["kitty", "@", "--to", sock, "ls"], text=True,
        )
        data = json.loads(ls_out)
        active_tab = None
        for osw in data:
            for tab in osw.get("tabs", []):
                if tab.get("is_focused"):
                    active_tab = tab
                    break
            if active_tab:
                break
        if not active_tab:
            active_tab = data[0]["tabs"][0] if data else None
        if not active_tab:
            print("no tab", file=sys.stderr)
            sys.exit(1)

        windows = active_tab.get("windows", [])
        count = len(windows)

        common = []
        if cwd:
            common += ["--cwd", cwd]
        if title:
            common += ["--title", title]

        def run(*xs):
            subprocess.run(["kitty", "@", "--to", sock, *xs], check=True)

        if count == 0:
            run("launch", *common, *cmd)
        elif count == 1:
            run("launch", "--location=vsplit", *common, *cmd)
        elif count == 2:
            left = min(windows, key=lambda w: w.get("at_x", 0))
            run("focus-window", f"--match=id:{left['id']}")
            run("launch", "--location=hsplit", *common, *cmd)
        elif count == 3:
            right = max(windows, key=lambda w: w.get("at_x", 0))
            run("focus-window", f"--match=id:{right['id']}")
            run("launch", "--location=hsplit", *common, *cmd)
        else:
            run("launch", "--type=tab", *common, *cmd)


    if __name__ == "__main__":
        main()
  '';

  # Restore kitty topology from snapshot.json using kitty-pane-add. Waits
  # for the freshly-launched kitty's socket to appear, walks the snapshot,
  # then closes whatever default window kitty opened on startup.
  kittyRestoreSession = pkgs.writers.writePython3Bin "kitty-restore-session" {} ''
    """Restore kitty session from snapshot.json via kitty-pane-add."""
    import glob
    import json
    import os
    import re
    import subprocess
    import sys
    import time


    def find_socket(timeout=30):
        deadline = time.time() + timeout
        while time.time() < deadline:
            for f in sorted(glob.glob("/tmp/kitty.sock-*")):
                r = subprocess.run(
                    ["kitty", "@", "--to", f"unix:{f}", "ls"],
                    capture_output=True, timeout=2,
                )
                if r.returncode == 0:
                    return f"unix:{f}"
            time.sleep(0.3)
        return None


    def maybe_resume_claude(cmd, cwd):
        """If cmd is the claude-code CLI, rewrite to resume the latest
        session for this cwd. Returns the (possibly modified) cmd list."""
        if not cmd or not cwd:
            return cmd
        if os.path.basename(cmd[0]) != "claude":
            return cmd
        encoded = re.sub(r"[^a-zA-Z0-9]", "-", cwd)
        proj_dir = os.path.expanduser(f"~/.claude/projects/{encoded}")
        if not os.path.isdir(proj_dir):
            return cmd
        sessions = [
            (f, os.path.getmtime(os.path.join(proj_dir, f)))
            for f in os.listdir(proj_dir)
            if f.endswith(".jsonl")
        ]
        if not sessions:
            return cmd
        sessions.sort(key=lambda t: t[1], reverse=True)
        latest = sessions[0][0].removesuffix(".jsonl")
        return [cmd[0], "--resume", latest]


    def main():
        cache = os.environ.get(
            "XDG_CACHE_HOME",
            os.path.join(os.path.expanduser("~"), ".cache"),
        )
        snap_path = os.path.join(cache, "kitty-session", "snapshot.json")
        if not os.path.exists(snap_path) or os.path.getsize(snap_path) == 0:
            return

        sock = find_socket()
        if not sock:
            print("kitty socket never appeared", file=sys.stderr)
            sys.exit(1)

        # IDs of the default windows kitty opened on startup; close them
        # after we've added all our panes.
        ls_out = subprocess.check_output(
            ["kitty", "@", "--to", sock, "ls"], text=True,
        )
        default_ids = [
            w["id"]
            for osw in json.loads(ls_out)
            for tab in osw.get("tabs", [])
            for w in tab.get("windows", [])
        ]

        with open(snap_path) as fh:
            snap = json.load(fh)

        panes = []
        for osw in snap:
            for tab in osw.get("tabs", []):
                for win in tab.get("windows", []):
                    fg = win.get("foreground_processes") or []
                    cmd = fg[0].get("cmdline", []) if fg else []
                    cwd = win.get("cwd")
                    cmd = maybe_resume_claude(cmd, cwd)
                    panes.append({
                        "cwd": cwd,
                        "title": win.get("title", ""),
                        "cmd": cmd,
                    })

        if not panes:
            return

        # Pane 0: launch directly into current (default-window) tab.
        # We then close the default windows so only this pane remains —
        # giving kitty-pane-add a clean count=1 starting point for the
        # rest, which keeps the 2x2 grid pattern aligned.
        first = panes[0]
        first_argv = ["launch"]
        if first["cwd"]:
            first_argv += ["--cwd", first["cwd"]]
        if first["title"]:
            first_argv += ["--title", first["title"]]
        if first["cmd"]:
            first_argv += first["cmd"]
        subprocess.run(
            ["kitty", "@", "--to", sock, *first_argv], check=False,
        )

        for did in default_ids:
            subprocess.run(
                ["kitty", "@", "--to", sock,
                 "close-window", f"--match=id:{did}"],
                check=False,
            )

        for p in panes[1:]:
            argv = ["kitty-pane-add"]
            if p["cwd"]:
                argv += ["--cwd", p["cwd"]]
            if p["title"]:
                argv += ["--title", p["title"]]
            if p["cmd"]:
                argv += ["--", *p["cmd"]]
            subprocess.run(argv, check=False)

        # Final cleanup: kitty sometimes spawns a stray OS window during
        # restore (race between launch + close-window). Close any OS
        # window that ended up with fewer panes than the largest one —
        # that's our restored topology; the rest are leftovers.
        ls_final = subprocess.check_output(
            ["kitty", "@", "--to", sock, "ls"], text=True,
        )
        os_windows = json.loads(ls_final)
        print(f"[restore] final cleanup; {len(os_windows)} OS window(s)",
              flush=True)
        if len(os_windows) > 1:
            entries = []
            for osw in os_windows:
                total = sum(len(t["windows"]) for t in osw.get("tabs", []))
                sample_wid = None
                for t in osw.get("tabs", []):
                    for w in t.get("windows", []):
                        sample_wid = w["id"]
                        break
                    if sample_wid is not None:
                        break
                entries.append((osw["id"], total, sample_wid))
            max_count = max(c for _, c, _ in entries)
            for osw_id, count, sample_wid in entries:
                if count < max_count and sample_wid is not None:
                    print(
                        f"[restore] closing stray OS#{osw_id} "
                        f"({count} windows)",
                        flush=True,
                    )
                    subprocess.run(
                        ["kitty", "@", "--to", sock,
                         "close-window", f"--match=id:{sample_wid}"],
                        check=False,
                    )


    if __name__ == "__main__":
        main()
  '';

  # Snapshot current kitty state. No-op if no kitty is listening.
  kittySessionSave = pkgs.writeShellApplication {
    name = "kitty-session-save";
    runtimeInputs = [ pkgs.kitty kittySessionConvert pkgs.coreutils ];
    text = ''
      set -euo pipefail

      dir="''${XDG_CACHE_HOME:-$HOME/.cache}/kitty-session"
      mkdir -p "$dir"

      # Discover live kitty socket. Under `kitty -1` the listen_on path has
      # `-{pid}` appended, so glob and pick the first live socket file.
      sock=""
      if [ -n "''${KITTY_LISTEN_ON:-}" ]; then
        sock="$KITTY_LISTEN_ON"
      else
        shopt -s nullglob
        for f in /tmp/kitty.sock-*; do
          [ -S "$f" ] || continue
          sock="unix:$f"
          break
        done
      fi

      # Skip silently if no kitty is running / not listening.
      [ -z "$sock" ] && exit 0
      if ! json="$(kitty @ --to "$sock" ls 2>/dev/null)"; then
        exit 0
      fi
      [ -z "$json" ] && exit 0

      printf '%s\n' "$json" > "$dir/snapshot.json.tmp"
      mv "$dir/snapshot.json.tmp" "$dir/snapshot.json"

      kitty-session-convert < "$dir/snapshot.json" > "$dir/last.session.tmp"
      mv "$dir/last.session.tmp" "$dir/last.session"
    '';
  };

  # Drop-in replacement for `kitty` itself. symlinkJoin mirrors the upstream
  # package (man pages, terminfo, share/applications/kitty.desktop, icons)
  # and replaces just `bin/kitty` with the session-restoring wrapper. Menu
  # launchers and shells that resolve `kitty` via PATH transparently get
  # the wrapper without needing a custom .desktop entry.
  #
  # The wrapper invokes the real kitty by store-path, avoiding self-recursion.
  # It only injects --session on first launch (no other kitty in this user's
  # process tree); subsequent launches reuse the running instance via `-1`.
  kittyWithSession = pkgs.symlinkJoin {
    name = "kitty-with-session";
    paths = [ pkgs.kitty ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      rm $out/bin/kitty
      cat > $out/bin/kitty <<EOF
      #!${pkgs.bash}/bin/bash
      set -euo pipefail
      # Remote-control invocations (\`kitty @ <subcmd>\`) must pass through
      # untouched — injecting '-1' or '--session' here would mangle the
      # argv that kitty's @ parser expects.
      if [ "\''${1:-}" = "@" ]; then
        exec ${pkgs.kitty}/bin/kitty "\$@"
      fi
      session="\''${XDG_CACHE_HOME:-\$HOME/.cache}/kitty-session/last.session"
      # Detect a running kitty by probing each socket — a kitty crash can
      # leave stale /tmp/kitty.sock-PID files behind that would otherwise
      # block restore on next launch. pgrep is unsafe here because the
      # kernel sets comm to argv[0] which is "kitty" for this wrapper too.
      shopt -s nullglob
      live=0
      for f in /tmp/kitty.sock-*; do
        [ -S "\$f" ] || continue
        if ${pkgs.kitty}/bin/kitty @ --to "unix:\$f" ls >/dev/null 2>&1; then
          live=1
          break
        fi
        # Stale socket from a crashed instance — clean it up.
        rm -f "\$f"
      done
      # First-launch restore: spawn kitty-restore-session in the
      # background to inject panes via kitty-pane-add (preserving the
      # 2x2 grid pattern), then exec plain kitty. The restore script
      # waits for kitty's socket to appear before issuing its commands.
      snap="\''${XDG_CACHE_HOME:-\$HOME/.cache}/kitty-session/snapshot.json"
      if [ -s "\$snap" ] && [ "\$live" -eq 0 ]; then
        ( ${kittyRestoreSession}/bin/kitty-restore-session \
            >/tmp/kitty-restore.log 2>&1 & )
      fi
      exec ${pkgs.kitty}/bin/kitty -1 "\$@"
      EOF
      chmod +x $out/bin/kitty
    '';
  };
in
{
  home.packages = [
    kittyWithSession
    kittySessionConvert
    kittySessionSave
    # WIP, not yet wired in (see wrapper above):
    kittyPaneAdd
    kittyRestoreSession
  ];

  home.file.".config/kitty/kitty.conf".text = ''
    # Scrolling — momentum-style kinetic scroll on Linux/X11 touchpad.
    # Reason for switching from Ghostty: Ghostty 1.3.1 doesn't fire kinetic
    # scroll for GDK_SOURCE_TOUCHPAD on X11 (GTK4 limitation, tracked at
    # ghostty#11460). Kitty 0.46+ shipped first-class momentum_scroll.
    momentum_scroll 0.96
    pixel_scroll yes

    # Remote control — JSON-over-Unix-socket for scripts / future MCP server
    # exposing pane management (`kitty @ ls`, launch, send-text, focus, ...).
    # Kitty appends `-{pid}` under `-1` regardless of socket type; the save
    # script globs `/tmp/kitty.sock-*` to find the live one.
    allow_remote_control yes
    listen_on unix:/tmp/kitty.sock

    # Splits layout enables hsplit/vsplit launch locations
    enabled_layouts splits,stack

    # Keybinds — mirror Ghostty config (home/ghostty.nix). These override
    # kitty defaults like ctrl+minus = decrease_font_size.
    map ctrl+minus launch --location=hsplit --cwd=current
    map ctrl+w close_window
    map ctrl+up neighboring_window up
    map ctrl+down neighboring_window down
  '';

  # Periodic snapshot — survives crashes, kernel panics, power loss.
  systemd.user.services.kitty-session-save = {
    Unit.Description = "Snapshot kitty session state";
    Service = {
      Type = "oneshot";
      ExecStart = "${kittySessionSave}/bin/kitty-session-save";
    };
  };

  systemd.user.timers.kitty-session-save = {
    Unit.Description = "Snapshot kitty session every minute";
    Timer = {
      OnBootSec = "30s";
      OnUnitActiveSec = "60s";
      AccuracySec = "10s";
    };
    Install.WantedBy = [ "timers.target" ];
  };

  # Final snapshot at logout. Bound to graphical-session.target so ExecStop
  # fires when the desktop session ends, capturing state newer than the
  # last 60s timer tick.
  systemd.user.services.kitty-session-save-on-logout = {
    Unit = {
      Description = "Snapshot kitty session at logout";
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.coreutils}/bin/true";
      ExecStop = "${kittySessionSave}/bin/kitty-session-save";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
