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
                # Skip transient kitty internals (e.g. the `kitten ask`
                # confirmation dialog tab that kitty spawns when the user
                # clicks X with running processes — restoring it
                # re-shows the prompt on next launch).
                if any("kitten" in a for a in cmdline) and "ask" in cmdline:
                    continue
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
        focused_win = None
        for osw in data:
            for tab in osw.get("tabs", []):
                if tab.get("is_focused"):
                    active_tab = tab
                    for w in tab.get("windows", []):
                        if w.get("is_focused"):
                            focused_win = w
                            break
                    break
            if active_tab:
                break
        if not active_tab:
            active_tab = data[0]["tabs"][0] if data else None
        if not active_tab:
            print("no tab", file=sys.stderr)
            sys.exit(1)

        # Inherit cwd from the focused window if --cwd wasn't given.
        if cwd is None and focused_win is not None:
            cwd = focused_win.get("cwd")

        windows = active_tab.get("windows", [])
        count = len(windows)

        common = []
        if cwd:
            common += ["--cwd", cwd]
        if title:
            common += ["--title", title]

        def run(*xs):
            subprocess.run(["kitty", "@", "--to", sock, *xs], check=True)

        # Use insertion order via window ID (kitty auto-increments).
        # Smallest id = original full-height "left" pane; second-smallest
        # = result of vsplit, i.e. full-height "right" pane.
        # `kitty @ ls` JSON doesn't expose at_x/at_y so we can't infer
        # geometry directly.
        sorted_ids = sorted(w["id"] for w in windows)
        if count == 0:
            run("launch", *common, *cmd)
        elif count == 1:
            run("launch", "--location=vsplit", *common, *cmd)
        elif count == 2:
            run("focus-window", f"--match=id:{sorted_ids[0]}")
            run("launch", "--location=hsplit", *common, *cmd)
        elif count == 3:
            run("focus-window", f"--match=id:{sorted_ids[1]}")
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
    import shlex
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


    def maybe_resume_claude(cmd, cwd, session_id=None):
        """If cmd is the claude-code CLI, rewrite to resume the correct
        session. Prefers the per-pane session_id captured at snapshot time
        (TSV populated by the SessionStart hook claude-kitty-pane-record,
        keyed by kitty window id and joined in by kitty-session-enrich);
        falls back to latest-by-mtime for the cwd when no per-pane id is
        available, OR when the named session's jsonl no longer exists
        (user pruned it between snapshot and restore)."""
        if not cmd:
            return cmd
        if os.path.basename(cmd[0]) != "claude":
            return cmd
        proj_dir = None
        if cwd:
            encoded = re.sub(r"[^a-zA-Z0-9]", "-", cwd)
            proj_dir = os.path.expanduser(f"~/.claude/projects/{encoded}")
        if session_id and proj_dir and os.path.isfile(
            os.path.join(proj_dir, f"{session_id}.jsonl")
        ):
            return [cmd[0], "--resume", session_id]
        if not proj_dir or not os.path.isdir(proj_dir):
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


    STUB_PATH = "/tmp/kitty-stub-session"


    def load_panes():
        cache = os.environ.get(
            "XDG_CACHE_HOME",
            os.path.join(os.path.expanduser("~"), ".cache"),
        )
        snap_path = os.path.join(cache, "kitty-session", "snapshot.json")
        if not os.path.exists(snap_path) or os.path.getsize(snap_path) == 0:
            return []
        with open(snap_path) as fh:
            snap = json.load(fh)
        panes = []
        for osw in snap:
            for tab in osw.get("tabs", []):
                for win in tab.get("windows", []):
                    fg = win.get("foreground_processes") or []
                    cmd = fg[0].get("cmdline", []) if fg else []
                    # Skip kitty's transient `kitten ask` confirmation
                    # dialogs (saved if a snapshot fires while the
                    # close-confirmation tab is open).
                    if any("kitten" in a for a in cmd) and "ask" in cmd:
                        continue
                    cwd = win.get("cwd")
                    sid = win.get("claude_session_id")
                    cmd = maybe_resume_claude(cmd, cwd, sid)
                    panes.append({
                        "cwd": cwd,
                        "title": win.get("title", ""),
                        "cmd": cmd,
                    })
        return panes


    def emit_stub():
        """Write a kitty session file with only pane 0's launch directive.
        Kitty starts directly into this single window (no default extra),
        avoiding a close-window prompt on the spurious startup shell."""
        panes = load_panes()
        if not panes:
            return
        p = panes[0]
        parts = ["launch"]
        if p["cwd"]:
            parts += ["--cwd", shlex.quote(p["cwd"])]
        if p["title"]:
            parts += ["--title", shlex.quote(p["title"])]
        if p["cmd"]:
            parts += [shlex.quote(a) for a in p["cmd"]]
        with open(STUB_PATH, "w") as fh:
            fh.write(" ".join(parts) + "\n")


    def main():
        if "--emit-stub" in sys.argv:
            emit_stub()
            return

        panes = load_panes()
        if len(panes) <= 1:
            # Pane 0 is already created via kitty's --session stub; if
            # that's all there is, we're done.
            return

        sock = find_socket()
        if not sock:
            print("kitty socket never appeared", file=sys.stderr)
            sys.exit(1)

        # Skip pane[0] — kitty already created it from the --session stub.
        for p in panes[1:]:
            argv = ["kitty-pane-add"]
            if p["cwd"]:
                argv += ["--cwd", p["cwd"]]
            if p["title"]:
                argv += ["--title", p["title"]]
            if p["cmd"]:
                argv += ["--", *p["cmd"]]
            subprocess.run(argv, check=False)


    if __name__ == "__main__":
        main()
  '';

  # Claude Code SessionStart hook: record (kitty_window_id, session_id, cwd)
  # to pane-sessions.tsv. Consumed by kitty-session-enrich at snapshot time
  # to attach a `claude_session_id` to each pane in `kitty @ ls` JSON, so
  # restore can re-resume the *same* session per pane (not just the latest
  # one in the cwd).
  #
  # Mechanism replaces the earlier /proc/<pid>/fd scan, which assumed
  # `claude` keeps its session jsonl fd open — empirically it does not
  # (open/append/close per write), so the scan returned None and same-cwd
  # panes collapsed onto the latest-by-mtime fallback.
  #
  # Hook input: JSON on stdin from Claude Code with { session_id, cwd, ... }.
  # Required env: KITTY_WINDOW_ID (kitty injects this for every launched
  # window). Silent no-op outside kitty so the hook is safe to wire
  # globally.
  claudeKittyPaneRecord = pkgs.writeShellApplication {
    name = "claude-kitty-pane-record";
    runtimeInputs = with pkgs; [ jq coreutils util-linux gawk ];
    text = ''
      set -euo pipefail

      # Only the main interactive Claude Code session may write the
      # TSV. Nested `claude -p` invocations (SDK, agents, the
      # step-back classifier, etc.) inherit KITTY_WINDOW_ID from the
      # parent terminal, so their SessionStart hook fires with the
      # SAME window_id but a fresh subprocess session_id. Without this
      # gate, the nested write overwrites the main session's row and
      # kitty restore resumes the subprocess instead of the user's
      # session (which is exactly the watcher-prompt-on-resume bug
      # this fix was discovered through).
      #
      # CLAUDE_CODE_ENTRYPOINT="cli" = main interactive session.
      # "sdk-cli" / future values = subprocess; skip.
      [ "''${CLAUDE_CODE_ENTRYPOINT:-cli}" = "cli" ] || exit 0

      # Outside kitty → nothing to record.
      [ -n "''${KITTY_WINDOW_ID:-}" ] || exit 0

      input=$(cat)
      session_id=$(printf '%s' "$input" | jq -r '.session_id // empty')
      cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')

      # Reject malformed input — TSV consumers rely on UUID-shaped sids.
      case "$session_id" in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
        *) exit 0 ;;
      esac
      [ -n "$cwd" ] || exit 0
      # Reject window ids that would corrupt the TSV (tab is field sep).
      case "$KITTY_WINDOW_ID" in
        '''|*[!0-9]*) exit 0 ;;
      esac

      dir="''${XDG_CACHE_HOME:-$HOME/.cache}/kitty-session"
      tsv="$dir/pane-sessions.tsv"
      mkdir -p "$dir"

      # flock guards concurrent SessionStart hooks (e.g. two new claude
      # sessions starting in the same second) AND the enricher's
      # prune_tsv (which takes the same lock from Python). Replace any
      # existing entry for this window_id, then atomically rename into
      # place. The trap cleans up the tmp file if any step between
      # mktemp and the final mv fails — mv consumes the source path,
      # so on success the trap's `rm -f` is a no-op.
      (
        flock -x 9
        tmp=$(mktemp -p "$dir" ".pane-sessions.tsv.XXXX")
        trap 'rm -f "$tmp"' EXIT
        if [ -f "$tsv" ]; then
          awk -F'\t' -v wid="$KITTY_WINDOW_ID" '$1 != wid' "$tsv" > "$tmp"
        fi
        printf '%s\t%s\t%s\t%s\n' \
          "$KITTY_WINDOW_ID" "$session_id" "$cwd" "$(date +%s)" >> "$tmp"
        mv "$tmp" "$tsv"
      ) 9>"$dir/.pane-sessions.lock"
    '';
  };

  # Enrich `kitty @ ls` JSON with per-pane Claude Code session IDs.
  # Multiple `claude` panes in the same cwd are indistinguishable from
  # cmdline+cwd alone (cmdline is just `claude`, cwd matches), so on
  # restore the latest-by-mtime fallback would collapse them all onto
  # the same session. To disambiguate, look up each pane's
  # claude_session_id in pane-sessions.tsv (populated by the Claude Code
  # SessionStart hook, claude-kitty-pane-record). Keyed by kitty's
  # `id` field — the same value claude sees as $KITTY_WINDOW_ID.
  #
  # Pruning: TSV entries whose window_id is not in the current live set
  # are removed on every enrich run, keeping the TSV bounded by current
  # pane count (≤ a few hundred lines in pathological cases).
  kittySessionEnrich = pkgs.writers.writePython3Bin "kitty-session-enrich" {} ''
    import fcntl
    import json
    import os
    import re
    import sys
    import tempfile

    # Test-only seam: KITTY_ENRICH_TSV is honored only when
    # KITTY_ENRICH_TEST=1 is also set, so a stray export in a user's
    # shell rc can't silently re-route lookups in production.
    DEFAULT_TSV = os.path.join(
        os.environ.get(
            "XDG_CACHE_HOME",
            os.path.join(os.path.expanduser("~"), ".cache"),
        ),
        "kitty-session",
        "pane-sessions.tsv",
    )
    if os.environ.get("KITTY_ENRICH_TEST") == "1":
        TSV_PATH = os.environ.get("KITTY_ENRICH_TSV", DEFAULT_TSV)
    else:
        TSV_PATH = DEFAULT_TSV

    UUID_RE = re.compile(
        r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-"
        r"[0-9a-f]{4}-[0-9a-f]{12}$"
    )


    def load_tsv():
        """Return {window_id: session_id}. Malformed lines ignored."""
        if not os.path.isfile(TSV_PATH):
            return {}
        out = {}
        try:
            with open(TSV_PATH) as fh:
                for line in fh:
                    parts = line.rstrip("\n").split("\t")
                    if len(parts) < 2:
                        continue
                    wid, sid = parts[0], parts[1]
                    if not wid.isdigit() or not UUID_RE.match(sid):
                        continue
                    out[int(wid)] = sid
        except OSError:
            return {}
        return out


    def prune_tsv(live_window_ids):
        """Drop TSV entries for windows no longer in `kitty @ ls`.

        Holds the same flock the SessionStart hook
        (claude-kitty-pane-record) takes, so a concurrent row append
        can't slip in between our read and our atomic replace and get
        silently dropped. Window without the lock was ~ms but real.
        """
        if not os.path.isfile(TSV_PATH):
            return
        d = os.path.dirname(TSV_PATH)
        lock_path = os.path.join(d, ".pane-sessions.lock")
        try:
            lock_fh = open(lock_path, "w")
        except OSError:
            return
        try:
            fcntl.flock(lock_fh.fileno(), fcntl.LOCK_EX)
            try:
                with open(TSV_PATH) as fh:
                    lines = fh.readlines()
            except OSError:
                return
            kept = []
            for line in lines:
                parts = line.rstrip("\n").split("\t")
                if len(parts) < 2:
                    continue
                wid = parts[0]
                if wid.isdigit() and int(wid) in live_window_ids:
                    kept.append(line)
            if len(kept) == len(lines):
                return
            try:
                fd, tmp = tempfile.mkstemp(
                    dir=d, prefix=".pane-sessions.tsv."
                )
            except OSError:
                return
            try:
                with os.fdopen(fd, "w") as fh:
                    fh.writelines(kept)
                os.replace(tmp, TSV_PATH)
            except OSError:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
        finally:
            lock_fh.close()


    def enrich(data):
        tsv = load_tsv()
        live = set()
        for osw in data:
            for tab in osw.get("tabs", []):
                for win in tab.get("windows", []):
                    wid = win.get("id")
                    if isinstance(wid, int):
                        live.add(wid)
                    fg = win.get("foreground_processes") or []
                    has_claude = any(
                        os.path.basename((fp.get("cmdline") or [""])[0])
                        == "claude"
                        for fp in fg
                    )
                    if not has_claude:
                        continue
                    sid = tsv.get(wid) if isinstance(wid, int) else None
                    if sid:
                        win["claude_session_id"] = sid
        prune_tsv(live)
        return data


    def main():
        try:
            data = json.load(sys.stdin)
        except json.JSONDecodeError:
            sys.exit(0)
        json.dump(enrich(data), sys.stdout)


    if __name__ == "__main__":
        main()
  '';

  # Snapshot current kitty state. No-op if no kitty is listening.
  kittySessionSave = pkgs.writeShellApplication {
    name = "kitty-session-save";
    runtimeInputs = [ pkgs.kitty kittySessionConvert kittySessionEnrich pkgs.coreutils ];
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

      # Enrich with per-pane Claude session IDs before persisting.
      # Failure (e.g. enricher crash) falls back to raw json — better
      # to lose the per-pane id and use latest-by-mtime than to skip
      # the snapshot entirely.
      if ! printf '%s\n' "$json" | kitty-session-enrich > "$dir/snapshot.json.tmp"; then
        printf '%s\n' "$json" > "$dir/snapshot.json.tmp"
      fi
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
        # Write a stub session file containing just pane 0; this makes
        # kitty start directly into our restored topology with no extra
        # default-startup window to clean up. Restore-session, running
        # in the background, fills in panes 1..N once kitty's socket is up.
        ${kittyRestoreSession}/bin/kitty-restore-session --emit-stub
        ( ${kittyRestoreSession}/bin/kitty-restore-session \
            >/tmp/kitty-restore.log 2>&1 & )
        exec ${pkgs.kitty}/bin/kitty --session /tmp/kitty-stub-session "\$@"
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
    kittySessionEnrich
    kittySessionSave
    claudeKittyPaneRecord
    # WIP, not yet wired in (see wrapper above):
    kittyPaneAdd
    kittyRestoreSession
  ];

  home.file.".config/kitty/kitty.conf".text = ''
    # Scrolling — momentum-style kinetic scroll on Linux/X11 touchpad.
    # Reason for switching from Ghostty: Ghostty 1.3.1 doesn't fire kinetic
    # scroll for GDK_SOURCE_TOUCHPAD on X11 (GTK4 limitation, tracked at
    # ghostty#11460). Kitty 0.46+ shipped first-class momentum_scroll.
    # momentum_scroll = decay factor (0=stop instantly, 1=never stops). Default 0.96.
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

    # Suppress "are you sure you want to close this OS window?"
    # confirmation when closing windows via UI/shortcut.
    confirm_os_window_close 0

    # === Ghostty-default-dark theme port + matching aesthetics ===
    # Source: ghostty-org/ghostty discussions #5390
    # foreground is slightly off-white (#ebebeb) — pure #ffffff renders harsher
    # in kitty than ghostty's freetype pipeline; this reduces glare without
    # losing contrast.
    foreground            #ebebeb
    background            #292c33
    # Dark text on white bg — both #ffffff was invisible.
    selection_foreground  #1d1f21
    selection_background  #ffffff
    cursor                #ffffff
    cursor_text_color     #363a43

    # Window split dividers (kitty default = neon green, replaced)
    active_border_color   #5c6370
    inactive_border_color #3a3d44

    # Normal colors (palette 0-7)
    color0  #1d1f21
    color1  #bf6b69
    color2  #b7bd73
    color3  #e9c880
    color4  #88a1bb
    color5  #ad95b8
    color6  #95bdb7
    color7  #c5c8c6

    # Bright colors (palette 8-15)
    color8  #666666
    color9  #c55757
    color10 #bcc95f
    color11 #e1c65e
    color12 #83a5d6
    color13 #bc99d4
    color14 #83beb1
    color15 #eaeaea

    # Font (JetBrains Mono Nerd Font installed via home/jonathan.nix).
    # ghostty Linux default = 12pt freetype.
    font_family      JetBrainsMono Nerd Font Mono
    font_size        12.0
    modify_font     underline_position 1
    modify_font     underline_thickness 200%

    # Thicker glyph rendering — kitty default 1.7 renders thinner than
    # ghostty's freetype output. Bump to 2.0 to bring weight closer; pairs
    # with off-white foreground above for the "thicker but slightly duller"
    # ghostty look (esp. visible on claude-code's renamed-session label).
    text_composition_strategy 2.0 0

    # Ghostty Linux default = 2px each side.
    window_padding_width 2

    # Fade non-focused panes — ghostty overlays whole surface (fg+bg) at
    # 0.7 opacity. kitty only fades text, so go lower (0.55) to land at
    # roughly the same perceived dim.
    inactive_text_alpha 0.55

    # Cursor
    cursor_shape block
    cursor_blink_interval 0.5

    enable_audio_bell no
    scrollback_lines 10000

    # Tab bar — separator style, minimal chrome.
    tab_bar_min_tabs 2
    tab_bar_style separator
    tab_separator "  ┃  "
    tab_bar_margin_width 0
    tab_bar_margin_height 0 0
    tab_title_template "{title}"
    # Match ghostty's GTK Adwaita tab-label weight (bolder than kitty's default).
    active_tab_font_style   bold
    inactive_tab_font_style bold

    # Keybinds — mirror Ghostty config (home/ghostty.nix). These override
    # kitty defaults like ctrl+minus = decrease_font_size.
    map ctrl+minus launch --location=hsplit --cwd=current
    map ctrl+w close_window
    map ctrl+up neighboring_window up
    map ctrl+down neighboring_window down
    # Add new pane via the 2x2-grid pattern (kitty-pane-add).
    map ctrl+less launch --type=background --cwd=current /etc/profiles/per-user/jonathan/bin/kitty-pane-add
    # New tab inheriting cwd of current window.
    map ctrl+t new_tab_with_cwd

    # Copy: strip embedded newlines so multi-line commands pasted from
    # Claude Code (or any terminal output) land as a single line. Kitty
    # already joins soft-wrapped lines and omits the trailing newline of
    # the last selected line; this binding additionally removes *hard*
    # newlines within the selection. Selection is passed as argv[0] (the
    # $0 of `sh -c`); `kitten clipboard` reads stdin and writes to the
    # system clipboard (works over SSH too).
    map ctrl+shift+c pass_selection_to_program sh -c 'printf %s "$0" | tr -d "\n" | kitten clipboard'
    # Escape hatch: preserve embedded newlines (logs, diffs, error output).
    map ctrl+shift+alt+c copy_to_clipboard

    # Paste: replace-newline rewrites stray \n in paste payloads so they
    # don't auto-execute under shells without bracketed paste. confirm
    # keeps kitty's safety prompt for paste payloads with control codes.
    paste_actions quote-urls-at-prompt,replace-newline,confirm
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
