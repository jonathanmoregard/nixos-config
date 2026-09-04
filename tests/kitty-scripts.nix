# kitty-scripts: runtime-invocation harness for the kitty session
# save/restore SCRIPTS (home/kitty.nix). Not a VM lane — it boots
# nothing, drives the real derivations with fixture snapshots, and runs
# in seconds. The VM lane (tests/kitty.nix) proves the topology comes
# back under a real X session; this one proves the file formats and the
# arithmetic that lane cannot see.
#
# Reproduces the 2026-09-04 incident chain, one phase per link:
#
#   A. emit_stub wrote the restore notice into /tmp/kitty-stub-session
#      with shlex.quote, which PRESERVES real newlines. A kitty session
#      file is LINE-ORIENTED (kitty/session.py: `for line in
#      raw.splitlines()`), so a claude pane 0 carrying a real notice
#      turned one `launch` directive into 75 lines. kitty then failed
#      the unterminated launch and opened a `kitten __show_error__`
#      window instead of the user's claude.
#   B. Dropping the notice from the stub must not silently drop the
#      notice: pane 0 still has to receive it as an argv element, the
#      same way kitty-pane-add hands it to panes 1..N.
#   C. That extra error window then shifted kitty-pane-add's 2x2 grid
#      dispatch by one step (count started at 2, not 1), so every
#      restored pane stacked into one column.
#   D. The 60s save timer then overwrote the good 6-pane snapshot with
#      the degraded one, three relaunches running, and the good state
#      became unrecoverable.
#
# Run: nix build .#checks.x86_64-linux.kitty-scripts -L
{ pkgs, hmPackages }:

let
  lib = pkgs.lib;

  # Drift gate: the scripts under test are the ones dellan actually
  # installs, pulled out of home-manager's package set by name. A
  # rename in home/kitty.nix fails this lookup at eval time rather
  # than silently testing nothing.
  pick = name:
    lib.findFirst (p: (p.name or "") == name)
      (throw ("tests/kitty-scripts.nix: no package named '" + name
              + "' in home-manager's home.packages"))
      hmPackages;

  underTest = pkgs.buildEnv {
    name = "kitty-scripts-under-test";
    paths = map pick [
      "kitty-restore-session"
      "kitty-pane-add"
      "kitty-session-convert"
      "kitty-session-enrich"
    ];
  };

  # Fixture builder. Python rather than heredoc'd JSON so the encoded
  # project-dir name (which mirrors maybe_resume_claude's own
  # re.sub("[^a-zA-Z0-9]", "-", cwd)) is derived, not transcribed.
  mkFixtures = pkgs.writeText "kitty-scripts-fixtures.py" ''
    import json
    import os
    import re
    import sys

    root = sys.argv[1]
    claude_bin = sys.argv[2]

    work = os.path.join(root, "work")
    home = os.path.join(root, "home")
    cache = os.path.join(home, ".cache")
    sess = os.path.join(cache, "kitty-session")
    os.makedirs(work, exist_ok=True)
    os.makedirs(sess, exist_ok=True)

    sid = "11111111-2222-3333-4444-555555555555"
    enc = re.sub(r"[^a-zA-Z0-9]", "-", work)
    proj = os.path.join(home, ".claude", "projects", enc)
    os.makedirs(os.path.join(proj, sid, "subagents"), exist_ok=True)
    with open(os.path.join(proj, sid + ".jsonl"), "w") as fh:
        fh.write(json.dumps({"type": "user"}) + "\n")

    # A subagent cut off mid-run with six edit-tool calls. This is what
    # makes restore_notice multi-line: the orphan block, one line per
    # edited file. Without it the notice is a single paragraph and the
    # bug hides.
    agent = os.path.join(proj, sid, "subagents", "agent-fixture.jsonl")
    with open(agent, "w") as fh:
        for i in range(6):
            fh.write(json.dumps({
                "type": "assistant",
                "message": {"content": [{
                    "type": "tool_use",
                    "name": "Edit",
                    "input": {"file_path": "/work/file-%d.txt" % i},
                }]},
            }) + "\n")
        fh.write(json.dumps({
            "type": "assistant",
            "cwd": work,
            "gitBranch": "feat/fixture",
            "message": {"stop_reason": None, "content": []},
        }) + "\n")

    claude = os.path.join(claude_bin, "claude")
    snap = [{"tabs": [{"layout": "splits", "windows": [
        {
            "id": 1,
            "cwd": work,
            "title": "claude pane",
            "cmdline": [claude],
            "foreground_processes": [{"cmdline": [claude]}],
            "claude_session_id": sid,
        },
        {
            "id": 2,
            "cwd": work,
            "title": "shell pane",
            "cmdline": ["/bin/sh"],
            "foreground_processes": [{"cmdline": ["/bin/sh"]}],
        },
    ]}]}]
    with open(os.path.join(sess, "snapshot.json"), "w") as fh:
        json.dump(snap, fh)
    sys.stdout.write(sid)
  '';

  # `kitty @ ls` payloads for the grid-dispatch phase. Each is one tab
  # whose window list mixes real panes with the kitty-internal overlay
  # windows kitty spawns on its own behalf (boss.py builds them as
  # `[kitten_exe(), '__show_error__', ...]` and
  # `run_kitten_with_metadata('ask', ...)`).
  mkGridFixtures = pkgs.writeText "kitty-scripts-grid.py" ''
    import json
    import os
    import sys

    out = sys.argv[1]


    def win(wid, cmdline):
        return {
            "id": wid,
            "is_focused": wid == 1,
            "cwd": "/tmp",
            "title": "w%d" % wid,
            "cmdline": cmdline,
            "foreground_processes": [{"cmdline": cmdline}],
        }


    def tab(windows):
        return [{"tabs": [{
            "is_focused": True,
            "layout": "splits",
            "windows": windows,
        }]}]


    KITTEN = "/nix/store/fake-kitty/bin/kitten"
    SHELL = ["/run/current-system/sw/bin/zsh"]

    cases = {
        # 1 real pane + kitty's config-error overlay. The overlay is
        # what kitty opened when it choked on the 75-line stub.
        "error-overlay": tab([
            win(1, SHELL),
            win(5, [KITTEN, "__show_error__", "--title", "Errors"]),
        ]),
        # 1 real pane + the close-confirmation dialog.
        "ask-dialog": tab([
            win(1, SHELL),
            win(7, [KITTEN, "ask", "--type=yesno", "--message", "close?"]),
        ]),
        # Control: two genuine panes, no internals.
        "two-real": tab([win(1, SHELL), win(2, SHELL)]),
        # Control: a PUBLIC kitten the user ran themselves is a real
        # pane and must still be counted. Over-filtering is its own bug.
        "user-kitten": tab([
            win(1, SHELL),
            win(2, [KITTEN, "diff", "a", "b"]),
        ]),
    }
    for name, data in cases.items():
        with open(os.path.join(out, name + ".json"), "w") as fh:
            json.dump(data, fh)
  '';
in
pkgs.runCommand "kitty-scripts-harness"
  {
    nativeBuildInputs = [
      underTest
      pkgs.python3
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.jq
    ];
  } ''
    set -euo pipefail
    export PATH="$PWD/fakebin:$PATH"
    mkdir -p fakebin fx state

    # Fake claude: records the argv it was handed, one arg per record,
    # so an assertion can look for the notice as a real argv element
    # rather than as text that merely appeared somewhere.
    cat > fakebin/claude <<'STUB'
    #!/bin/sh
    : > "$ARGV_OUT"
    for a in "$@"; do
      printf '%s\n===ARG===\n' "$a" >> "$ARGV_OUT"
    done
    exit 0
    STUB
    chmod +x fakebin/claude

    SID=$(python3 ${mkFixtures} "$PWD/fx" "$PWD/fakebin")
    export HOME="$PWD/fx/home"
    export XDG_CACHE_HOME="$HOME/.cache"
    # Never the real /tmp/kitty-stub-session — that file belongs to the
    # user's live kitty.
    export KITTY_STUB_PATH="$PWD/state/stub-session"

    # --- Phase A: the stub is exactly one line, notice or no notice ---
    kitty-restore-session --emit-stub
    [ -s "$KITTY_STUB_PATH" ] || {
      echo "FAIL(A): --emit-stub wrote no stub at all"; exit 1; }
    echo "--- stub ---"; cat "$KITTY_STUB_PATH"; echo "--- end stub ---"
    stub_lines=$(wc -l < "$KITTY_STUB_PATH")
    [ "$stub_lines" -eq 1 ] || {
      echo "FAIL(A): stub is $stub_lines lines, not 1. A kitty session"
      echo "  file is line-oriented; every extra line is a directive"
      echo "  kitty mis-parses into an error overlay window."
      exit 1; }
    grep -q '^launch ' "$KITTY_STUB_PATH" || {
      echo "FAIL(A): stub's single line is not a launch directive"; exit 1; }

    # Sanity: the fixture really does produce a multi-line notice, so
    # phase A is not passing because there was nothing to break on.
    kitty-restore-session --dump-panes > state/panes.json
    jq -e '.[0].cmd | map(select(test("restored by kitty"))) | length == 1' \
      state/panes.json > /dev/null || {
      cat state/panes.json
      echo "FAIL(A): fixture pane 0 carries no restore notice — phase A"
      echo "  would pass vacuously. Fix the fixture, not the assertion."
      exit 1; }
    jq -e '.[0].cmd | map(select(test("\n"))) | length == 1' \
      state/panes.json > /dev/null || {
      echo "FAIL(A): fixture notice is single-line — phase A would pass"
      echo "  vacuously."
      exit 1; }

    # --- Phase B: pane 0 still receives the notice, as argv ---
    export ARGV_OUT="$PWD/state/pane0-argv"
    kitty-restore-session --exec-pane0
    [ -s "$ARGV_OUT" ] || {
      echo "FAIL(B): pane 0's command never ran / recorded no argv"; exit 1; }
    echo "--- pane0 argv ---"; cat "$ARGV_OUT"; echo "--- end argv ---"
    grep -qxF -- "--resume" "$ARGV_OUT" || {
      echo "FAIL(B): pane 0 did not resume the recorded session"; exit 1; }
    grep -qxF -- "$SID" "$ARGV_OUT" || {
      echo "FAIL(B): pane 0 resumed the wrong session id"; exit 1; }
    grep -qF "This pane was restored by kitty" "$ARGV_OUT" || {
      echo "FAIL(B): the restore notice never reached pane 0. Dropping"
      echo "  it from the stub must not drop it from the pane."
      exit 1; }
    grep -qF "edited 6 file(s):" "$ARGV_OUT" || {
      echo "FAIL(B): pane 0's notice lost the orphan block — the"
      echo "  multi-line part is exactly what must survive the"
      echo "  line-oriented session file."
      exit 1; }

    # --- Phase C: grid dispatch counts real panes only ---
    #
    # kitty-pane-add picks vsplit / hsplit-left / hsplit-right / new-tab
    # from the number of windows in the active tab, assuming that number
    # starts at 1. An `__show_error__` overlay makes it start at 2, and
    # every subsequent pane lands in one column — the user-visible
    # "stacked instead of a 2x2 grid".
    #
    # Never uses /tmp/kitty.sock-*: those belong to the user's live
    # kitty. KITTY_LISTEN_ON points kitty-pane-add at the fake instead.
    mkdir -p grid
    python3 ${mkGridFixtures} "$PWD/grid"
    cat > fakebin/kitty <<'STUB'
    #!/bin/sh
    # argv is always: @ --to <sock> <subcommand> [args...]
    if [ "$4" = "ls" ]; then
      cat "$LS_JSON"
      exit 0
    fi
    shift 3
    printf '%s\n' "$*" >> "$KITTY_CMD_LOG"
    exit 0
    STUB
    chmod +x fakebin/kitty
    export KITTY_LISTEN_ON="unix:/nonexistent-socket-handled-by-fake"

    pane_add() { # <fixture-name>
      export LS_JSON="$PWD/grid/$1.json"
      export KITTY_CMD_LOG="$PWD/state/$1.log"
      : > "$KITTY_CMD_LOG"
      kitty-pane-add --cwd /tmp -- /bin/sh
      echo "--- kitty-pane-add($1) issued ---"
      cat "$KITTY_CMD_LOG"
    }

    # 1 real pane + an internal overlay must dispatch as ONE pane:
    # a plain vsplit, no focus-window hop.
    for case in error-overlay ask-dialog; do
      pane_add "$case"
      grep -q '^launch --location=vsplit' "$PWD/state/$case.log" || {
        echo "FAIL(C/$case): expected the 1-real-pane branch (vsplit);"
        echo "  a kitty-internal window was counted as a user pane and"
        echo "  shifted the 2x2 grid dispatch by a step."
        exit 1; }
      if grep -q 'focus-window' "$PWD/state/$case.log"; then
        echo "FAIL(C/$case): focused a sibling that does not exist"
        exit 1
      fi
    done

    # Controls: two genuine panes — including a public kitten the user
    # ran themselves — must still take the 2-pane branch.
    for case in two-real user-kitten; do
      pane_add "$case"
      grep -q '^focus-window --match=id:1' "$PWD/state/$case.log" || {
        echo "FAIL(C/$case): 2-real-pane branch lost — over-filtering"
        echo "  real panes is the mirror-image bug."
        exit 1; }
      grep -q '^launch --location=hsplit' "$PWD/state/$case.log" || {
        echo "FAIL(C/$case): expected hsplit on the left column"
        exit 1; }
    done

    # And the same class of window must not reach a restored session:
    # kitty-session-convert would otherwise write `launch kitten
    # __show_error__ ...` into last.session and re-open the overlay.
    kitty-session-convert < grid/error-overlay.json > state/error.session
    echo "--- converted error-overlay ---"; cat state/error.session
    if grep -q '__show_error__' state/error.session; then
      echo "FAIL(C/convert): an internal overlay window was written into"
      echo "  the session file; restoring it re-opens kitty's own error"
      echo "  window as if the user had asked for it."
      exit 1
    fi
    [ "$(grep -c '^launch' state/error.session)" -eq 1 ] || {
      echo "FAIL(C/convert): expected exactly one launch directive"
      exit 1; }

    echo "ok: stub is single-line, pane 0 keeps its notice, grid"
    echo "    dispatch and session convert count real panes only"
    touch $out
  ''
