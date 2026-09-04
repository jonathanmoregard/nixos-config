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
      "kitty-session-commit"
      "kitty-session-save"
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
        # A live claude pane whose argv HOLDS a restore notice. Panes
        # 1..N are launched that way by kitty-pane-add, so kitty reports
        # a multi-line cmdline for them and last.session inherits it.
        "multiline-cmd": tab([
            win(1, [
                "/opt/bin/claude", "--resume", "abc",
                "first line\nsecond line\nthird line",
            ]),
        ]),
    }
    for name, data in cases.items():
        with open(os.path.join(out, name + ".json"), "w") as fh:
            json.dump(data, fh)
  '';

  # Snapshot generator for the retention phase: N real panes, plus an
  # optional kitty-internal overlay so the phase can prove the pane
  # count that drives retention is the REAL one.
  mkSnapshot = pkgs.writeText "kitty-scripts-snapshot.py" ''
    import json
    import sys

    n = int(sys.argv[1])
    path = sys.argv[2]
    internal = len(sys.argv) > 3 and sys.argv[3] == "internal"

    wins = []
    for i in range(n):
        wins.append({
            "id": i + 1,
            "cwd": "/tmp",
            "title": "pane%d" % (i + 1),
            "cmdline": ["/bin/sh"],
            "foreground_processes": [{"cmdline": ["/bin/sh"]}],
        })
    if internal:
        overlay = ["/nix/store/fake/bin/kitten", "__show_error__", "-t", "E"]
        wins.append({
            "id": 900,
            "cwd": "/tmp",
            "title": "error overlay",
            "cmdline": overlay,
            "foreground_processes": [{"cmdline": overlay}],
        })
    with open(path, "w") as fh:
        json.dump([{"tabs": [{"layout": "splits", "windows": wins}]}], fh)
  '';
in
pkgs.runCommand "kitty-scripts-harness"
  {
    nativeBuildInputs = [
      underTest
      pkgs.python3
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
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

    # last.session is a session file too, and a claude pane's live argv
    # carries the restore notice kitty-pane-add handed it — so convert
    # can emit the same multi-line directive that broke the stub.
    kitty-session-convert < grid/multiline-cmd.json > state/multi.session
    echo "--- converted multiline-cmd ---"; cat state/multi.session
    [ "$(wc -l < state/multi.session)" -eq 2 ] || {
      echo "FAIL(C/convert): last.session has"
      echo "  $(wc -l < state/multi.session) lines for one layout + one"
      echo "  pane. A pane whose argv holds the restore notice renders"
      echo "  as a multi-line launch directive, i.e. a session file"
      echo "  kitty refuses with 'The startup session was invalid'."
      exit 1; }
    [ "$(grep -c '^launch' state/multi.session)" -eq 1 ] || {
      echo "FAIL(C/convert): expected exactly one launch directive"
      exit 1; }

    # --- Phase D: snapshot retention ---
    #
    # The 60s save timer had no rotation and no guard, so within
    # minutes of the bad restore the degraded topology overwrote the
    # good 6-pane snapshot, and then the single surviving pane
    # overwrote that. By the third relaunch load_panes() returned one
    # pane, hit `len(panes) <= 1`, and returned early: "nothing
    # opened", with the good state unrecoverable.
    #
    # Thresholds are READ OUT of the deployed script rather than
    # transcribed here, so this phase tests the shipped inputs and
    # fails if they are renamed away.
    commit_bin=$(command -v kitty-session-commit)
    KEEP=$(sed -n 's/^HISTORY_KEEP = \([0-9]*\)$/\1/p' "$commit_bin")
    GRACE=$(sed -n 's/^COLLAPSE_GRACE_S = \([0-9]*\)$/\1/p' "$commit_bin")
    MINP=$(sed -n 's/^HISTORY_MIN_PANES = \([0-9]*\)$/\1/p' "$commit_bin")
    echo "retention inputs: KEEP=$KEEP GRACE=$GRACE MIN_PANES=$MINP"
    for v in "$KEEP" "$GRACE" "$MINP"; do
      [ -n "$v" ] || {
        echo "FAIL(D): a retention input is missing from the deployed"
        echo "  kitty-session-commit — the numbers below would be"
        echo "  asserting against nothing."
        exit 1; }
    done

    mkdir -p sess cands
    for n in 1 3 5 6; do
      python3 ${mkSnapshot} "$n" "cands/c$n.json"
    done
    python3 ${mkSnapshot} 3 "cands/c3-plus-overlay.json" internal

    commit_rc() { # <candidate>
      local rc=0
      kitty-session-commit "$PWD/sess" < "$1" || rc=$?
      echo "$rc"
    }
    real_panes() { # <snapshot>
      jq '[.[].tabs[].windows[]] | length' "$1"
    }
    age_out() { # push snapshot.json's mtime past the grace window
      touch -d "@$(( $(date +%s) - GRACE - 60 ))" sess/snapshot.json
    }
    # Name-based, not glob-based: stdenv runs with nullglob, so an
    # unmatched `ls history/*-1p.json` silently lists the whole
    # directory and reads as a match.
    have_hist() { # <pane-count>
      ls sess/history 2>/dev/null | grep -q -- "-$1p\.json\$"
    }

    # D1 — first snapshot commits, nothing to rotate yet.
    [ "$(commit_rc cands/c6.json)" -eq 0 ] || {
      echo "FAIL(D1): first snapshot refused"; exit 1; }
    [ "$(real_panes sess/snapshot.json)" -eq 6 ] || {
      echo "FAIL(D1): committed snapshot is not the candidate"; exit 1; }

    # D2 — the incident: a 1-pane snapshot arriving one tick after a
    # 6-pane one must NOT overwrite it.
    [ "$(commit_rc cands/c1.json)" -eq 3 ] || {
      echo "FAIL(D2): a 6-pane snapshot was overwritten by a 1-pane one"
      echo "  within the grace window — this is the 2026-09-04 loss."
      exit 1; }
    [ "$(real_panes sess/snapshot.json)" -eq 6 ] || {
      echo "FAIL(D2): prior good snapshot was not preserved"; exit 1; }

    # D3 — the guard counts REAL panes. 3 real + 1 error overlay is a
    # collapse from 6; counting the overlay would make it 4 and let the
    # degraded snapshot through.
    [ "$(commit_rc cands/c3-plus-overlay.json)" -eq 3 ] || {
      echo "FAIL(D3): a kitty overlay window padded the pane count and"
      echo "  disarmed the collapse guard."
      exit 1; }
    [ "$(real_panes sess/snapshot.json)" -eq 6 ] || {
      echo "FAIL(D3): prior good snapshot was not preserved"; exit 1; }

    # D4 — an ordinary shrink (6 -> 5) is not a collapse; it commits and
    # rotates the outgoing 6-pane snapshot into history.
    [ "$(commit_rc cands/c5.json)" -eq 0 ] || {
      echo "FAIL(D4): a normal one-pane close was treated as a crash"
      exit 1; }
    [ "$(real_panes sess/snapshot.json)" -eq 5 ] || {
      echo "FAIL(D4): candidate was not committed"; exit 1; }
    have_hist 6 || {
      ls -la sess/history 2>&1 || true
      echo "FAIL(D4): the outgoing 6-pane snapshot was not retained"
      exit 1; }

    # D5 — history holds distinct topologies, not ticks. A session that
    # sits at the same size cannot flush the good history out by
    # waiting, which is what a 60s timer would otherwise do.
    [ "$(commit_rc cands/c5.json)" -eq 0 ] || exit 1
    before=$(ls sess/history | wc -l)
    [ "$(commit_rc cands/c5.json)" -eq 0 ] || exit 1
    [ "$(commit_rc cands/c5.json)" -eq 0 ] || exit 1
    after=$(ls sess/history | wc -l)
    [ "$before" -eq "$after" ] || {
      ls -la sess/history
      echo "FAIL(D5): repeated identical topologies each pushed a"
      echo "  history entry ($before -> $after); a stuck bad state"
      echo "  would evict every good one inside KEEP ticks."
      exit 1; }

    # D6 — once the collapse has outlived the grace window it is
    # believed: the user really did close those panes.
    age_out
    [ "$(commit_rc cands/c1.json)" -eq 0 ] || {
      echo "FAIL(D6): a collapse that persisted past the grace window"
      echo "  was still refused — snapshot.json would never catch up."
      exit 1; }
    [ "$(real_panes sess/snapshot.json)" -eq 1 ] || {
      echo "FAIL(D6): candidate was not committed"; exit 1; }

    # D7 — a degenerate snapshot never enters history, so it can never
    # evict a good one.
    age_out
    [ "$(commit_rc cands/c1.json)" -eq 0 ] || exit 1
    if have_hist 1; then
      ls -la sess/history
      echo "FAIL(D7): a 1-pane snapshot was rotated into history; with"
      echo "  a 60s timer that alone would evict the recoverable"
      echo "  topologies inside KEEP ticks."
      exit 1
    fi
    for f in sess/history/*.json; do
      n=$(echo "$f" | sed 's/.*-\([0-9]*\)p\.json$/\1/')
      [ "$n" -ge "$MINP" ] || {
        echo "FAIL(D7): history holds a $n-pane snapshot, below the"
        echo "  declared HISTORY_MIN_PANES=$MINP"
        exit 1; }
    done

    # D8 — history is bounded at the declared depth, keeping the newest.
    # Only growth, so the collapse guard never fires and every commit
    # rotates a distinct count.
    top=$(( KEEP + 8 ))
    for n in $(seq 2 "$top"); do
      python3 ${mkSnapshot} "$n" "cands/grow.json"
      [ "$(commit_rc cands/grow.json)" -eq 0 ] || {
        echo "FAIL(D8): growth to $n panes was refused"; exit 1; }
    done
    got=$(ls sess/history | wc -l)
    [ "$got" -eq "$KEEP" ] || {
      ls -la sess/history
      echo "FAIL(D8): history holds $got entries, declared depth is $KEEP"
      exit 1; }
    have_hist "$(( top - 1 ))" || {
      ls -la sess/history
      echo "FAIL(D8): the newest rotation was pruned instead of the oldest"
      exit 1; }
    if have_hist 2; then
      ls -la sess/history
      echo "FAIL(D8): the OLDEST rotation survived the prune"
      exit 1
    fi

    # D9 — drift gate: the deployed save script actually routes through
    # kitty-session-commit, and still gates on the enricher's exit code
    # (the partial-snapshot / same-cwd-collision guard this must not
    # weaken).
    save_bin=$(command -v kitty-session-save)
    grep -q 'kitty-session-commit' "$save_bin" || {
      echo "FAIL(D9): kitty-session-save does not call"
      echo "  kitty-session-commit — every assertion above is testing a"
      echo "  script nothing runs."
      exit 1; }
    grep -q 'enrich_rc' "$save_bin" || {
      echo "FAIL(D9): the enricher exit-code gate (partial-snapshot"
      echo "  collision guard) is gone from kitty-session-save."
      exit 1; }

    echo "ok: single-line stub, pane-0 notice intact, grid dispatch and"
    echo "    session convert count real panes only, snapshot rotation"
    echo "    survives a relaunch burst"
    touch $out
  ''
