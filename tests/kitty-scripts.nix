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
      "kitty-panes-reflow"
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
        # A second claude pane, so the restore path's panes-1..N loop
        # has a claude in it and phase F can watch how it is launched.
        # Its sid is already claimed by pane 0, so the collision guard
        # leaves it a bare `claude` -- still a claude pane, and it must
        # still land in claude-egress.slice.
        {
            "id": 3,
            "cwd": work,
            "title": "second claude pane",
            "cmdline": [claude],
            "foreground_processes": [{"cmdline": [claude]}],
        },
    ]}]}]
    with open(os.path.join(sess, "snapshot.json"), "w") as fh:
        json.dump(snap, fh)
    sys.stdout.write(sid)
  '';

  # Count a session file's directives the way kitty's own parser does.
  #
  # kitty/session.py:249 is `for line in raw.splitlines()`, so the
  # parser's notion of a line break IS str.splitlines()'s: it breaks on
  # ten code points, not just \n. `wc -l` sees only \n and therefore
  # cannot see U+0085, U+2028/9 or \x1c-\x1e — which is exactly how a
  # sanitiser that misses one of them passes a wc -l assertion while
  # kitty still mis-parses the file into extra windows.
  mkLineCheck = pkgs.writeText "kitty-scripts-linecheck.py" ''
    import sys

    path = sys.argv[1]
    want = int(sys.argv[2])
    with open(path, encoding="utf-8", errors="replace") as fh:
        raw = fh.read()
    lines = [ln for ln in raw.splitlines() if ln.strip()]
    sys.stdout.write(
        "%s: wc -l says %d, str.splitlines() says %d\n"
        % (path, raw.count("\n"), len(lines))
    )
    for ln in lines:
        sys.stdout.write("  " + repr(ln) + "\n")
    if len(lines) != want:
        sys.stderr.write(
            "FAIL: kitty parses %s as %d session-file directive(s), want "
            "%d. A value carrying a line break str.splitlines() honours "
            "turns one `launch` into several lines, and kitty answers "
            "with `kitten __show_error__` instead of the user's pane.\n"
            % (path, len(lines), want)
        )
        sys.exit(1)
  '';

  # One snapshot per code point str.splitlines() treats as a line
  # break, plus one carrying all of them at once. Each puts the
  # character everywhere a session file will quote it: the pane's cwd,
  # its title and its argv. A path component may hold any byte but '/'
  # and NUL, so every one of these is a legal cwd.
  mkBreakFixtures = pkgs.writeText "kitty-scripts-breaks.py" ''
    import json
    import os
    import sys

    out = sys.argv[1]

    # kitty reads a session file with `for line in raw.splitlines()`
    # (kitty/session.py:249), so str.splitlines() IS kitty's line-break
    # definition. Ask CPython which characters those are rather than
    # believing a list in a comment -- a transcribed list is exactly
    # what left U+0085 out of the sanitiser in the first place.
    BREAKS = [
        c for c in map(chr, range(0x110000))
        if len(("a" + c + "b").splitlines()) > 1
    ]

    cases = [("U+%04X" % ord(c), c) for c in BREAKS]
    cases.append(("ALL", "".join(BREAKS)))

    for label, ch in cases:
        sess = os.path.join(out, label, "kitty-session")
        os.makedirs(sess, exist_ok=True)
        cmd = ["/bin/sh", "-c", "echo" + ch + "hi"]
        snap = [{"tabs": [{"layout": "splits", "windows": [{
            "id": 1,
            "cwd": "/tmp/we" + ch + "ird",
            "title": "pane" + ch + "title",
            "cmdline": cmd,
            "foreground_processes": [{"cmdline": cmd}],
        }]}]}]
        with open(os.path.join(sess, "snapshot.json"), "w") as fh:
            json.dump(snap, fh)
        sys.stdout.write(label + "\n")
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


    def win(wid, cmdline, ui=False):
        # `ui` models the env marker kitty puts on every window it
        # spawns as its OWN UI (boss.py:2359 and :2487). Measured
        # against real kitty 0.48.2 under Xvfb on 2026-09-04: the
        # hints / unicode_input / command-palette overlays each came
        # back from `kitty @ ls` with env.KITTEN_RUNNING_AS_UI == "1",
        # the user's shell pane with none.
        env = {"PWD": "/tmp"}
        if ui:
            env["KITTEN_RUNNING_AS_UI"] = "1"
        return {
            "id": wid,
            "is_focused": wid == 1,
            "cwd": "/tmp",
            "title": "w%d" % wid,
            "cmdline": cmdline,
            "env": env,
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
            win(7, [KITTEN, "ask", "--type=yesno", "--message", "close?"],
                ui=True),
        ]),
        # The overlays kitty opens from its own default bindings:
        # `hints` (boss.py:2649), `unicode_input` (:2424) and
        # `command-palette` (:2432) all reach
        # run_kitten_with_metadata (:2358) and come back as
        # `kitten <name>`. None is dunder-named and none is `ask`, so
        # a rule built on either misses all three, and a snapshot
        # taken while one is open counts it as a pane.
        "hints-overlay": tab([
            win(1, SHELL),
            win(8, [KITTEN, "hints"], ui=True),
        ]),
        "unicode-input-overlay": tab([
            win(1, SHELL),
            win(9, [KITTEN, "unicode_input"], ui=True),
        ]),
        "command-palette-overlay": tab([
            win(1, SHELL),
            win(10, [KITTEN, "command-palette"], ui=True),
        ]),
        # `resize_window` (boss.py:1803) is NOT one of kitty's wrapped
        # kittens, so it takes the OTHER branch of the same `if`
        # (:2364): `kitty +runpy 'from kittens.runner import main;
        # main()' <config-dir> <kitten> ...`, and kitty sets no env
        # marker on it at all. Measured shape, verbatim.
        "resize-window-overlay": tab([
            win(1, SHELL),
            win(11, [
                "/nix/store/fake-kitty/bin/kitty", "+runpy",
                "from kittens.runner import main; main()",
                "/home/jonathan/.config/kitty", "resize_window",
                "--horizontal-increment=2", "--vertical-increment=2",
            ]),
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
  #
  # Usage: mkSnapshot <n> <path> [internal|-] [marker]
  #
  # `marker` is stamped into every pane's cwd so two snapshots can share
  # a pane COUNT while differing in CONTENT. Retention keyed on the
  # count alone cannot tell those apart, which is how a days-old
  # same-size history entry ends up shadowing the live one (phase D10).
  mkSnapshot = pkgs.writeText "kitty-scripts-snapshot.py" ''
    import json
    import sys

    n = int(sys.argv[1])
    path = sys.argv[2]
    internal = len(sys.argv) > 3 and sys.argv[3] == "internal"
    marker = sys.argv[4] if len(sys.argv) > 4 else "generic"

    wins = []
    for i in range(n):
        wins.append({
            "id": i + 1,
            "cwd": "/tmp/" + marker,
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

  # `kitty @ ls` payloads for the reflow phase. Unlike the grid
  # fixtures above these carry the FULL topology kitty really reports —
  # per-tab `layout_state.pairs` (kitty/tabs.py:1461 ->
  # layout/splits.py:959) and `groups` (tabs.py:1465) — because that
  # tree is the only thing kitty-panes-reflow can compare against to
  # decide it has nothing to do.
  #
  # Every serialized tree here is written out by hand from the shapes
  # observed against real kitty 0.48.2 (tasks/findings.md), NOT
  # generated by the same helper the script uses. A fixture that
  # recomputed the expected shape with the implementation's own
  # function would agree with any bug it contained.
  #
  # Note `horizontal` appears only on the vertically-split (stacked)
  # pairs: Pair.serialize (layout/splits.py:42-45) emits the key only
  # when it is False.
  mkReflowFixtures = pkgs.writeText "kitty-scripts-reflow.py" ''
    import json
    import os
    import sys

    out = sys.argv[1]

    SHELL = ["/run/current-system/sw/bin/zsh"]
    KITTEN = "/nix/store/fake-kitty/bin/kitten"


    def win(wid, cmdline=None, focused=False):
        cl = cmdline or SHELL
        return {
            "id": wid,
            "is_focused": focused,
            "is_active": focused,
            "cwd": "/tmp",
            "title": "w%d" % wid,
            "cmdline": cl,
            "foreground_processes": [{"cmdline": cl}],
        }


    def tab(tid, pairs, groups, windows, layout="splits", focused=True):
        """One tab. `pairs=None` means a non-splits layout (stack)."""
        state = {"class": "Splits" if layout == "splits" else "Stack"}
        if pairs is not None:
            state["pairs"] = pairs
        return {
            "id": tid,
            "is_focused": focused,
            "is_active": focused,
            "layout": layout,
            "layout_state": state,
            "groups": groups,
            "windows": windows,
        }


    def osw(oid, tabs, focused=True):
        return {
            "id": oid,
            "is_focused": focused,
            "is_active": focused,
            "tabs": tabs,
        }


    def grp(gid, wids):
        return {"id": gid, "windows": wids}


    def stacked(gids):
        """One column: nested vertical pairs, top-most first."""
        if len(gids) == 1:
            return {"one": gids[0]}
        node = gids[-1]
        for g in reversed(gids[:-1]):
            node = {"horizontal": False, "one": g, "two": node}
        return node


    def canon(gids):
        """The canonical grid tree, transcribed from findings.md."""
        n = len(gids)
        if n == 1:
            return {"one": gids[0]}
        if n == 2:
            return {"one": gids[0], "two": gids[1]}
        left = {"horizontal": False, "one": gids[0], "two": gids[2]}
        if n == 3:
            return {"one": left, "two": gids[1]}
        return {
            "one": left,
            "two": {"horizontal": False, "one": gids[1], "two": gids[3]},
        }


    def column(n, first_win=1, first_grp=101, tid=1, layout="splits",
               focused=True):
        """A tab of `n` panes stacked in one column."""
        wids = list(range(first_win, first_win + n))
        gids = list(range(first_grp, first_grp + n))
        return tab(
            tid,
            stacked(gids) if layout == "splits" else None,
            [grp(g, [w]) for g, w in zip(gids, wids)],
            [win(w, focused=(focused and w == first_win)) for w in wids],
            layout=layout,
            focused=focused,
        )


    def grid(n, first_win=1, first_grp=101, tid=1, focused=True):
        """A tab of `n` panes already in the canonical grid.

        Group order mirrors what kitty reports after the rebuild
        (findings.md observed groups [(27,[1]),(29,[3]),(28,[2]),
        (30,[4])]): UL, LL, UR, LR.
        """
        wids = list(range(first_win, first_win + n))
        gids = list(range(first_grp, first_grp + n))
        slot_order = [i for i in (0, 2, 1, 3) if i < n]
        return tab(
            tid,
            canon(gids),
            [grp(gids[i], [wids[i]]) for i in slot_order],
            [win(w, focused=(focused and w == first_win)) for w in wids],
            focused=focused,
        )


    OVERLAY = [KITTEN, "__show_error__", "--title", "Errors"]

    cases = {}

    # Already canonical, in every remainder shape. Reflow must be a
    # pure no-op on each: exit 0, no detach, no focus change.
    cases["canonical-4"] = [osw(1, [grid(4)])]
    cases["canonical-1"] = [osw(1, [grid(1)])]
    cases["canonical-2"] = [osw(1, [grid(2)])]
    cases["canonical-3"] = [osw(1, [grid(3)])]
    # 4 + remainder across two tabs — the n>4 canonical forms.
    for rest in (1, 2, 3):
        cases["canonical-4-plus-%d" % rest] = [osw(1, [
            grid(4),
            grid(rest, first_win=5, first_grp=201, tid=2, focused=False),
        ])]

    # Canonical, but the user has dragged a divider off centre. kitty
    # serializes that as a `bias` key (splits.py:46-47). Rebuilding
    # the tab would silently re-equalize it, so this must stay a
    # no-op.
    biased = canon([101, 102, 103, 104])
    biased["bias"] = 0.3
    biased["one"]["bias"] = 0.7
    cases["canonical-4-biased"] = [osw(1, [tab(
        1, biased,
        [grp(101, [1]), grp(103, [3]), grp(102, [2]), grp(104, [4])],
        [win(1, focused=True), win(2), win(3), win(4)],
    )])]

    # Canonical grid + kitty's own error overlay. boss.py:2485-2494
    # builds it with overlay_for=<window id>, so it joins that
    # window's GROUP rather than taking a grid slot of its own.
    cases["canonical-4-overlay"] = [osw(1, [tab(
        1, canon([101, 102, 103, 104]),
        [grp(101, [1, 90]), grp(103, [3]), grp(102, [2]), grp(104, [4])],
        [win(1, focused=True), win(2), win(3), win(4),
         win(90, cmdline=OVERLAY)],
    )])]

    # The same overlay on a NON-canonical tab: the plan must move
    # three panes and must never name the overlay's window id.
    cases["stacked-3-overlay"] = [osw(1, [tab(
        1, stacked([101, 102, 103]),
        [grp(101, [1, 90]), grp(102, [2]), grp(103, [3])],
        [win(1, focused=True), win(2), win(3), win(90, cmdline=OVERLAY)],
    )])]

    # N panes stacked in one column — the shape a bad restore leaves
    # behind. 5/6/7 cover the n%4 in {1,2,3} spill-to-a-second-tab
    # forms.
    for n in (5, 6, 7):
        cases["stacked-%d" % n] = [osw(1, [column(n)])]

    # A tab in `stack` layout: no `pairs` at all, so it can never be
    # canonical and reflow has to `goto-layout splits`.
    cases["stack-layout"] = [osw(1, [column(4, layout="stack")])]

    # 2 + 2 across two tabs is four panes in the wrong PLACE: the
    # canonical form for 4 is one tab.
    cases["split-tabs-2-2"] = [osw(1, [
        grid(2),
        grid(2, first_win=3, first_grp=201, tid=2, focused=False),
    ])]

    # The same six stacked panes, but the user has alt-tabbed to a
    # SECOND kitty OS window since the plan was built. Serving this
    # from the middle of a reflow models exactly that race:
    # `detach-window --target-tab new` creates its tab in whatever OS
    # window is current WHEN IT RUNS (boss.py:3325 ->
    # current_os_window()), so carrying on here scatters the panes
    # into a window the plan never looked at.
    cases["race-after"] = [
        osw(1, [column(6)], focused=False),
        osw(2, [column(2, first_win=201, first_grp=401)], focused=True),
    ]

    # `kitty @ ls` returns a LIST of OS windows. Reflow must scope to
    # exactly one — here the focused one, whose panes are 201..203.
    cases["two-os-windows"] = [
        osw(1, [column(6, first_win=11, first_grp=301, focused=False)],
            focused=False),
        osw(2, [column(3, first_win=201, first_grp=401)], focused=True),
    ]

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
      pkgs.gnused
      pkgs.jq
      # flock, for the concurrent-reflow assertion (E11).
      pkgs.util-linux
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

    # --- Phase A2: the sanitiser's alphabet is kitty's, not wc's ---
    #
    # Phase A counts with `wc -l`, which sees U+000A and nothing else.
    # kitty does not: kitty/session.py:249 is `for line in
    # raw.splitlines()`, and str.splitlines() breaks on TEN code points.
    # A sanitiser missing any of them writes a stub that is one line to
    # `wc` and several to kitty — and the writer's own single-line
    # invariant, sharing the same character class, cannot see it either.
    #
    # The alphabet is enumerated from CPython at fixture-build time, so
    # this phase covers whatever str.splitlines() actually breaks on
    # rather than whatever a comment claims it does.
    mkdir -p breaks
    python3 ${mkBreakFixtures} "$PWD/breaks" > state/break-labels
    echo "str.splitlines() breaks on:" \
      "$(tr '\n' ' ' < state/break-labels)"
    [ "$(wc -l < state/break-labels)" -ge 2 ] || {
      echo "FAIL(A2): the line-break alphabet came back empty; every"
      echo "  assertion below would pass vacuously."
      exit 1; }
    while read -r label; do
      (
        export XDG_CACHE_HOME="$PWD/breaks/$label"
        export KITTY_STUB_PATH="$PWD/state/stub-$label"
        kitty-restore-session --emit-stub
      ) || {
        echo "FAIL(A2/$label): --emit-stub failed outright"; exit 1; }
      python3 ${mkLineCheck} "$PWD/state/stub-$label" 1 || {
        echo "FAIL(A2/$label): a $label in the pane's cwd/title survived"
        echo "  into the --session stub, so kitty parses one launch"
        echo "  directive as several and answers with an error overlay"
        echo "  instead of the user's pane."
        exit 1; }
      # last.session is a session file too, and convert quotes the same
      # values plus the pane's argv.
      kitty-session-convert \
        < "$PWD/breaks/$label/kitty-session/snapshot.json" \
        > "$PWD/state/conv-$label.session"
      python3 ${mkLineCheck} "$PWD/state/conv-$label.session" 2 || {
        echo "FAIL(A2/$label): last.session renders one pane as more"
        echo "  than a layout plus a launch — kitty refuses the file"
        echo "  with 'The startup session was invalid'."
        exit 1; }
    done < state/break-labels

    # --- Phase B: pane 0 still receives the notice, as argv ---
    export ARGV_OUT="$PWD/state/pane0-argv"
    kitty-restore-session --exec-pane0 2> state/pane0-stderr
    echo "--- pane0 stderr ---"; cat state/pane0-stderr
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
      if [ -n "''${LS_JSON_2:-}" ] && [ -f "''${LS_SWITCHED:-/nonexistent}" ]; then
        cat "$LS_JSON_2"
      else
        cat "$LS_JSON"
      fi
      exit 0
    fi
    # A non-ls command means kitty has actually been driven. When the
    # caller armed LS_SWITCHED that is the moment the modelled user
    # alt-tabs to another kitty OS window, so every later `ls` reports
    # a different one as focused.
    if [ -n "''${LS_SWITCHED:-}" ]; then : > "$LS_SWITCHED"; fi
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
    #
    # The overlay class is not `__show_error__` plus `ask`: kitty
    # opens `hints`, `unicode_input` and `command-palette` from its
    # own default bindings through the same call, and `resize_window`
    # through the +runpy branch of it. Each of those is a window a
    # snapshot can capture and a restore can bring back as a pane.
    for case in error-overlay ask-dialog hints-overlay \
                unicode-input-overlay command-palette-overlay \
                resize-window-overlay; do
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

    # D10 — the history must keep the FRESHEST snapshot of a topology
    # size, not the first one it ever saw at that size.
    #
    # D5 and D6 above both use identical fixtures on either side of the
    # comparison, so neither can see this: a ring keyed on pane count
    # alone treats "6 panes" as one thing, and a 6-pane entry rotated in
    # days ago makes today's 6-pane snapshot look like a duplicate. It
    # is not — it is the only copy holding the CURRENT session ids, and
    # it is the one the incident replay destroys:
    #
    #   1. a 6-pane snapshot rotates into history (stale sids);
    #   2. the session goes on running, snapshot.json is replaced by a
    #      fresh 6-pane one (live sids) — same count, so no rotation;
    #   3. kitty dies, the restore comes back with one pane. The
    #      collapse guard refuses it while it is fresh...
    #   4. ...and stops refusing once the broken state has outlived the
    #      grace window, at which point the fresh 6-pane snapshot is
    #      overwritten. If the rotation on the way out is skipped as a
    #      duplicate, the live state is gone and only the stale copy
    #      remains — the exact loss the ring exists to prevent.
    mkdir -p sess2
    python3 ${mkSnapshot} 6 cands/stale6.json - stale
    python3 ${mkSnapshot} 6 cands/fresh6.json - fresh
    python3 ${mkSnapshot} 1 cands/one.json - post-crash
    commit2_rc() { # <candidate>
      local rc=0
      kitty-session-commit "$PWD/sess2" < "$1" || rc=$?
      echo "$rc"
    }
    markers() { # <snapshot> -> the distinct cwd markers it holds
      jq -r '[.[].tabs[].windows[].cwd] | unique | join(",")' "$1"
    }

    [ "$(commit2_rc cands/stale6.json)" -eq 0 ] || {
      echo "FAIL(D10): first snapshot refused"; exit 1; }
    [ "$(commit2_rc cands/fresh6.json)" -eq 0 ] || {
      echo "FAIL(D10): a same-size snapshot was refused"; exit 1; }
    [ "$(commit2_rc cands/one.json)" -eq 3 ] || {
      echo "FAIL(D10): the collapse guard did not refuse 6 -> 1"; exit 1; }
    touch -d "@$(( $(date +%s) - GRACE - 60 ))" sess2/snapshot.json
    [ "$(commit2_rc cands/one.json)" -eq 0 ] || {
      echo "FAIL(D10): a collapse past the grace window was still refused"
      exit 1; }
    echo "--- sess2/history after the replay ---"
    : > state/hist-markers
    for f in sess2/history/*.json; do
      echo "  $(basename "$f") -> $(markers "$f")"
      markers "$f" >> state/hist-markers
    done
    if ! grep -q 'fresh' state/hist-markers; then
      echo "FAIL(D10): the 6-pane snapshot that was live when kitty died"
      echo "  was destroyed without being rotated, because an older"
      echo "  entry happened to share its pane count. History keeps only"
      echo "  the stale copy, so the session ids needed to restore the"
      echo "  panes are unrecoverable — this is the 2026-09-04 loss with"
      echo "  the ring in place."
      exit 1
    fi
    # One slot per topology size: the fresh entry REPLACED the stale one
    # rather than being appended beside it, so a session that churns
    # between two sizes cannot flush the ring.
    [ "$(ls sess2/history | wc -l)" -eq 1 ] || {
      ls -la sess2/history
      echo "FAIL(D10): history holds more than one entry for a single"
      echo "  topology size; the ring is a slot per size, not a log."
      exit 1; }

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

    # --- Phase E: kitty-panes-reflow ---
    #
    # Reflow takes the panes a RUNNING kitty already has and moves them
    # into the same 2x2-per-tab grid kitty-pane-add creates, without
    # killing or respawning any of them (every step is a
    # `detach-window` re-parent). The two things that can go wrong here
    # are both invisible to a happy-path test:
    #
    #   * it churns a layout that was already right — the user is
    #     invited to run this on a hunch, so a spurious detach/focus
    #     storm across live claude panes is the headline bug;
    #   * it counts something that is not a pane (kitty's own overlay
    #     windows) and shifts every slot by one, which is exactly the
    #     2026-09-04 grid-dispatch failure one phase up.
    #
    # `--plan` renders the command sequence from a `kitty @ ls` payload
    # on stdin without talking to any kitty, so every assertion below
    # runs with no terminal and no socket — /tmp/kitty.sock-* belongs
    # to the user's live session and is never reachable from here.
    mkdir -p reflow
    python3 ${mkReflowFixtures} "$PWD/reflow"

    plan() { # <fixture-name>
      kitty-panes-reflow --plan \
        < "$PWD/reflow/$1.json" > "$PWD/state/plan-$1.json"
      echo "--- plan($1) ---"
      cat "$PWD/state/plan-$1.json"; echo
    }

    # E1 — an already-canonical layout plans NOTHING, in every
    # remainder shape, with a dragged divider (`bias`), and with
    # kitty's error overlay sharing a pane's group.
    for case in canonical-1 canonical-2 canonical-3 canonical-4 \
                canonical-4-plus-1 canonical-4-plus-2 \
                canonical-4-plus-3 canonical-4-biased \
                canonical-4-overlay; do
      plan "$case"
      jq -e '.noop == true and (.steps | length) == 0' \
        "$PWD/state/plan-$case.json" > /dev/null || {
        echo "FAIL(E1/$case): reflow planned work on a layout that is"
        echo "  already canonical. This command is meant to be safe to"
        echo "  run on a hunch; a detach storm across live claude panes"
        echo "  is the worst thing it can do."
        exit 1; }
    done

    # E2 — and the no-op is a real no-op at the WIRE, not just in the
    # plan: driven against the fake kitty, an already-canonical session
    # must produce an empty command log — no detach, no focus-window,
    # no goto-layout.
    reflow_run() { # <fixture-name>
      export LS_JSON="$PWD/reflow/$1.json"
      export KITTY_CMD_LOG="$PWD/state/reflow-$1.log"
      : > "$KITTY_CMD_LOG"
      kitty-panes-reflow
      echo "--- kitty-panes-reflow($1) issued ---"
      cat "$KITTY_CMD_LOG"
    }
    reflow_run canonical-4
    [ ! -s "$PWD/state/reflow-canonical-4.log" ] || {
      echo "FAIL(E2): reflow issued remote-control commands against an"
      echo "  already-canonical layout. Exit 0 with no detach and no"
      echo "  focus change is a hard requirement, not an optimisation."
      exit 1; }

    # E3 — control for E2: a stacked session DOES reach the wire, so
    # E2 is not passing because the script is inert.
    reflow_run stacked-6
    grep -q 'detach-window' "$PWD/state/reflow-stacked-6.log" || {
      echo "FAIL(E3): reflow issued no detach-window for six stacked"
      echo "  panes — E2 above would then be vacuous."
      exit 1; }

    # E4 — the exact sequence, step for step, against the call
    # sequence measured on real kitty 0.48.2 (tasks/findings.md).
    # `detach-window --target-tab id:T` is not an append: it vsplits
    # to the right of the TARGET TAB'S ACTIVE window
    # (layout/splits.py:629), so each detach must be preceded by a
    # focus-window naming its anchor, and `layout_action rotate 90`
    # (splits.py:780) reads the tab's active group — not the
    # command's --match — so the focus before each rotate is load
    # bearing too.
    # Each chunk opens by focusing its own anchor. That focus is not
    # cosmetic: `--target-tab new` creates its tab in the CURRENT OS
    # window, and focusing a window in the planned one is what makes
    # the planned one current (rc/focus_window.py ->
    # set_active_window(switch_os_window_if_needed=True)).
    C1='[["focus",1],["detach-new",1],["layout-splits",1],
         ["focus",1],["detach-to",2,1],
         ["focus",1],["detach-to",3,1],["focus",3],["rotate"],
         ["focus",2],["detach-to",4,1],["focus",4],["rotate"],
         ["focus",1],["equalize"]]'
    # Spill tails: n%4 of 2, 1 and 3 panes in the second tab, each in
    # its own canonical form, then focus back where the user was.
    T6='[["focus",5],["detach-new",5],["layout-splits",5],
         ["focus",5],["detach-to",6,5],
         ["focus",5],["equalize"],["focus",1]]'
    T5='[["focus",5],["detach-new",5],["layout-splits",5],
         ["focus",5],["equalize"],["focus",1]]'
    T7='[["focus",5],["detach-new",5],["layout-splits",5],
         ["focus",5],["detach-to",6,5],
         ["focus",5],["detach-to",7,5],["focus",7],["rotate"],
         ["focus",5],["equalize"],["focus",1]]'
    for spec in "stacked-5 $T5" "stacked-6 $T6" "stacked-7 $T7"; do
      case_name=''${spec%% *}
      tail_json=''${spec#* }
      plan "$case_name"
      want=$(jq -cn --argjson a "$C1" --argjson b "$tail_json" '$a + $b')
      jq -e --argjson want "$want" '.noop == false and .steps == $want' \
        "$PWD/state/plan-$case_name.json" > /dev/null || {
        echo "want: $want"
        echo "FAIL(E4/$case_name): planned sequence does not match the"
        echo "  one measured against real kitty 0.48.2."
        exit 1; }
    done

    # E5 — a kitty overlay window gets no grid slot of its own.
    # boss.py:2485-2494 creates `kitten __show_error__` with
    # overlay_for=<window id>, so it joins that pane's GROUP; counting
    # it as a pane is what stacked every restored pane into one column
    # on 2026-09-04.
    plan stacked-3-overlay
    jq -e '[.steps[] | select(.[0] == "detach-new" or .[0] == "detach-to")]
           | length == 3' \
      "$PWD/state/plan-stacked-3-overlay.json" > /dev/null || {
      echo "FAIL(E5): three real panes plus one overlay did not plan as"
      echo "  three moves — the overlay took a grid slot."
      exit 1; }
    jq -e '[.steps[] | .[1:] | .[]] | map(select(. == 90)) | length == 0' \
      "$PWD/state/plan-stacked-3-overlay.json" > /dev/null || {
      echo "FAIL(E5): the plan names kitty's overlay window (id 90)."
      exit 1; }

    # E6 — a tab in `stack` layout has no `pairs` at all, so it can
    # never be canonical and the rebuilt tab has to be switched to
    # splits before anything is attached into it.
    plan stack-layout
    jq -e '.noop == false and
           ([.steps[] | select(.[0] == "layout-splits")] | length == 1)' \
      "$PWD/state/plan-stack-layout.json" > /dev/null || {
      echo "FAIL(E6): a stack-layout tab was either called canonical or"
      echo "  rebuilt without goto-layout splits."
      exit 1; }

    # E7 — four panes spread 2+2 over two tabs are four panes in the
    # WRONG PLACE: the canonical form for four is a single tab.
    plan split-tabs-2-2
    jq -e '.noop == false and
           ([.steps[] | select(.[0] == "detach-new")] | length == 1) and
           ([.steps[] | select(.[0] == "detach-to")] | length == 3)' \
      "$PWD/state/plan-split-tabs-2-2.json" > /dev/null || {
      echo "FAIL(E7): 2+2 across two tabs was not consolidated into one"
      echo "  canonical tab."
      exit 1; }

    # E8 — `kitty @ ls` returns a LIST of OS windows. Reflow scopes to
    # exactly one (the focused one, whose panes are 201..203) and never
    # names a window belonging to the other. `detach-window
    # --target-tab new` creates its tab in the CURRENT OS window
    # (boss.py:3338), so planning against a non-focused one would
    # scatter its panes into the focused one.
    plan two-os-windows
    jq -e '.os_window == 2' \
      "$PWD/state/plan-two-os-windows.json" > /dev/null || {
      echo "FAIL(E8): reflow did not scope to the focused OS window."
      exit 1; }
    jq -e '[.steps[] | .[1:] | .[]]
           | length > 0 and all(. >= 201 and . <= 203)' \
      "$PWD/state/plan-two-os-windows.json" > /dev/null || {
      echo "FAIL(E8): the plan reaches into a second OS window."
      exit 1; }
    # E9 — focus restoration. Every detach makes its target tab active
    # and every anchor focus moves the cursor, so the last thing reflow
    # does must be putting the user back where they were.
    jq -e '.steps[-1] == ["focus", 201]' \
      "$PWD/state/plan-two-os-windows.json" > /dev/null || {
      echo "FAIL(E9): reflow does not restore the originally-focused"
      echo "  window."
      exit 1; }

    # E10 — reflow must stay bound to the OS window it PLANNED
    # against. `detach-window --target-tab new` builds its tab in
    # whatever OS window is current when it runs (boss.py:3325 ->
    # current_os_window()), and `action layout_action rotate|equalize`
    # hits the ambient active window (rc/action.py sends its --match
    # as `match_window`, which windows_for_match_payload never reads,
    # so it falls through to boss.active_window). If the user alt-tabs
    # to a second kitty OS window mid-reflow, or a second reflow
    # races, the panes scatter into a window nobody planned for and an
    # untouched tab's pair gets flipped.
    #
    # The fake kitty starts serving a payload in which a DIFFERENT OS
    # window is focused the moment reflow drives its first command.
    # Refusing loudly is the requirement; carrying on is not.
    (
      export LS_JSON="$PWD/reflow/stacked-6.json"
      export LS_JSON_2="$PWD/reflow/race-after.json"
      export LS_SWITCHED="$PWD/state/race-switched"
      export KITTY_CMD_LOG="$PWD/state/reflow-race.log"
      rm -f "$LS_SWITCHED"
      : > "$KITTY_CMD_LOG"
      rc=0
      kitty-panes-reflow 2> "$PWD/state/reflow-race.err" || rc=$?
      echo "--- reflow race: rc=$rc ---"
      cat "$PWD/state/reflow-race.err"
      echo "--- commands issued ---"
      cat "$KITTY_CMD_LOG"
      [ "$rc" -ne 0 ] || {
        echo "FAIL(E10): reflow reported success after the OS window it"
        echo "  planned against stopped being the current one."
        exit 1; }
      if grep -q 'detach-window' "$KITTY_CMD_LOG"; then
        echo "FAIL(E10): reflow detached a pane while a DIFFERENT OS"
        echo "  window was current, so the pane landed in a window the"
        echo "  plan never looked at. Failing loudly beats scattering."
        exit 1
      fi
      grep -qi 'os window' "$PWD/state/reflow-race.err" || {
        echo "FAIL(E10): the refusal does not say which OS window went"
        echo "  away; the user has to be able to tell this apart from a"
        echo "  crash."
        exit 1; }
    ) || exit 1

    # E11 — two reflows must not interleave. Each plans against a
    # topology the other is halfway through rebuilding, and both drive
    # the same ambient focus. The lock is held for the whole run, so a
    # second invocation refuses instead of issuing a single command.
    lockdir="$XDG_CACHE_HOME/kitty-session"
    mkdir -p "$lockdir"
    (
      export LS_JSON="$PWD/reflow/stacked-6.json"
      export KITTY_CMD_LOG="$PWD/state/reflow-locked.log"
      : > "$KITTY_CMD_LOG"
      rc=0
      flock -x "$lockdir/reflow.lock" kitty-panes-reflow \
        2> "$PWD/state/reflow-locked.err" || rc=$?
      echo "--- reflow under a held lock: rc=$rc ---"
      cat "$PWD/state/reflow-locked.err"
      [ "$rc" -ne 0 ] || {
        echo "FAIL(E11): a second concurrent reflow ran anyway; two of"
        echo "  them interleaving rebuild each other's half-finished"
        echo "  tabs."
        exit 1; }
      [ ! -s "$KITTY_CMD_LOG" ] || {
        cat "$KITTY_CMD_LOG"
        echo "FAIL(E11): the refusal came after commands had already"
        echo "  been issued."
        exit 1; }
    ) || exit 1

    # --- Phase F: a restored claude pane lands in claude-egress.slice --
    #
    # The slice is a SECURITY CONTROL: modules/nixos/
    # claude-egress-observe.nix binds an nftables rule to that cgroup's
    # inode, so a Claude Code running outside it is unobserved while
    # looking exactly like an observed one. Restore starts claude two
    # ways -- an execvp for pane 0 and `kitty @ launch --` for panes
    # 1..N -- and both spawn children of kitty, which lives in the
    # desktop session's own scope. Every restored session was therefore
    # silently unconfined, and the user's egress report under-counted
    # rather than warning.
    #
    # The policy itself (resolve the binary at call time, probe the
    # scope, degrade LOUDLY) lives once, in `_claude_slice` from
    # home/claude-egress-slice.nix. These assertions are about the
    # restore path REACHING it, and about the recorded claude argv
    # surviving the trip intact.

    # F1 — pane 0's recorded launch argv is the slice launcher, with
    # the resolved claude argv (notice included) inside it.
    pane0_json="$XDG_CACHE_HOME/kitty-session/pane0-launch.json"
    echo "--- pane0-launch.json ---"; cat "$pane0_json"; echo
    jq -e '.cmd[0] | endswith("/zsh")' "$pane0_json" > /dev/null || {
      echo "FAIL(F1): pane 0 is launched by execvp'ing claude directly,"
      echo "  so the restored session runs outside claude-egress.slice"
      echo "  while looking identical to a confined one."
      exit 1; }
    jq -e '.cmd[1:3] == ["-i","-c"]' "$pane0_json" > /dev/null || {
      echo "FAIL(F1): the launcher shell is not interactive; ~/.zshrc is"
      echo "  what defines _claude_slice, and only -i sources it."
      exit 1; }
    jq -e '.cmd[3] | test("_claude_slice")' "$pane0_json" > /dev/null || {
      echo "FAIL(F1): the launcher does not call _claude_slice — the"
      echo "  single definition of the slice policy."
      exit 1; }
    jq -e '.cmd[4] | endswith("/claude")' "$pane0_json" > /dev/null || {
      echo "FAIL(F1): the recorded claude path is not passed through as"
      echo "  \$0, so the fallback branch has nothing to exec."
      exit 1; }
    jq -e '.cmd | map(select(test("restored by kitty"))) | length == 1' \
      "$pane0_json" > /dev/null || {
      echo "FAIL(F1): the restore notice did not survive being wrapped."
      exit 1; }
    jq -e '.cmd | index("--resume") != null' "$pane0_json" > /dev/null || {
      echo "FAIL(F1): the resume argv did not survive being wrapped."
      exit 1; }

    # F2 — and the fallback is LOUD. Nothing defines _claude_slice in
    # this sandbox, so --exec-pane0 above took the degraded branch: it
    # must have SAID it was unobserved and still started the session
    # (phase B already asserted the argv it started with).
    grep -q 'claude-egress: UNOBSERVED' state/pane0-stderr || {
      echo "FAIL(F2): the launcher fell back to running claude outside"
      echo "  the slice without saying so. A session that is unobserved"
      echo "  but looks observed is the whole failure this guards."
      exit 1; }

    # F3 — panes 1..N take the same path. The restore loop hands each
    # one to kitty-pane-add, so the wrapper has to be in the argv that
    # reaches `kitty @ launch --`.
    #
    # kitty-restore-session finds its kitty by globbing
    # /tmp/kitty.sock-* — it runs before kitty exists, so it has no
    # KITTY_LISTEN_ON to prefer. The stdenv build sandbox has its own
    # private, EMPTY /tmp (verified: `ls -la /tmp` inside a sandboxed
    # derivation lists nothing), so planting a stand-in there cannot
    # reach the user's live session sockets.
    : > /tmp/kitty.sock-1
    export LS_JSON="$PWD/grid/two-real.json"
    export KITTY_CMD_LOG="$PWD/state/restore-launch.log"
    : > "$KITTY_CMD_LOG"
    kitty-restore-session
    echo "--- restore issued ---"; cat "$KITTY_CMD_LOG"
    grep -q '^launch .*_claude_slice' "$KITTY_CMD_LOG" || {
      echo "FAIL(F3): a restored claude pane was launched as a bare"
      echo "  claude, so panes 1..N run outside claude-egress.slice."
      exit 1; }
    # Control: the shell pane in the same restore is NOT wrapped. The
    # slice is for Claude Code; putting a shell in it would make the
    # egress report meaningless.
    [ "$(grep -c '^launch .*_claude_slice' "$KITTY_CMD_LOG")" -eq 1 ] || {
      echo "FAIL(F3): the wrapper was applied to something that is not"
      echo "  claude — over-wrapping poisons the observed cgroup."
      exit 1; }

    # F4 — every consumer must see THROUGH the launcher. kitty records
    # `window.cmdline` as what it spawned, which after a restore is the
    # launcher; that field is exactly what identifies a ZOMBIE pane
    # (claude gone, an orphaned stdio MCP server still holding the
    # pty). If the enricher stops recognising it, the first restore
    # strips the pane of its claude identity and the second relaunches
    # the orphan.
    #
    # The wrapper argv is taken from pane0-launch.json rather than
    # transcribed, so this cannot pass against a launcher shape the
    # writer no longer emits.
    ZSID="99999999-8888-7777-6666-555555555555"
    printf '%s\t%s\t%s\t%s\n' 501 "$ZSID" /tmp 0 > state/zombie.tsv
    jq -c --arg sid "$ZSID" '
      [{tabs: [{windows: [{
         id: 501, cwd: "/tmp", title: "zombie",
         cmdline: .cmd,
         foreground_processes: [{cmdline: ["/nix/store/x/bin/node",
                                           "mcp-server"]}]
       }]}]}]' "$pane0_json" > state/zombie-ls.json
    KITTY_ENRICH_TEST=1 KITTY_ENRICH_TSV="$PWD/state/zombie.tsv" \
      kitty-session-enrich < state/zombie-ls.json > state/zombie-out.json
    echo "--- enriched zombie ---"; cat state/zombie-out.json; echo
    jq -e --arg sid "$ZSID" \
      '.[0].tabs[0].windows[0].claude_session_id == $sid' \
      state/zombie-out.json > /dev/null || {
      echo "FAIL(F4): a pane whose window cmdline is the claude-egress"
      echo "  launcher was not recognised as a claude pane, so it lost"
      echo "  its session id and the next restore would relaunch the"
      echo "  orphaned MCP server instead."
      exit 1; }

    # F5 — last.session is a session file a human can feed back to
    # `kitty --session`, so it has to be an honest rendering of what
    # restore does. A bare `launch claude` there hands whoever uses it
    # an unobserved session. Still exactly one directive per pane.
    kitty-session-convert < state/zombie-ls.json > state/zombie.session
    echo "--- converted zombie ---"; cat state/zombie.session
    grep -q '^launch .*_claude_slice' state/zombie.session || {
      echo "FAIL(F5): last.session renders a claude pane as an"
      echo "  unconfined launch."
      exit 1; }
    # One directive: the fixture's tab carries no `layout`, so the
    # launch line is all convert emits for it.
    python3 ${mkLineCheck} state/zombie.session 1 || {
      echo "FAIL(F5): wrapping a claude pane made last.session"
      echo "  multi-line, which kitty refuses outright."
      exit 1; }

    echo "ok: single-line stub, pane-0 notice intact, grid dispatch and"
    echo "    session convert count real panes only, snapshot rotation"
    echo "    survives a relaunch burst, reflow is a true no-op on a"
    echo "    canonical layout and rebuilds every other shape"
    touch $out
  ''
