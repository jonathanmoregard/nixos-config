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
      # The session-restoring `kitty` wrapper itself, so the stub path
      # it READS can be checked against the one the writer emits.
      "kitty-with-session"
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

  # Become pane 0 exactly the way kitty does: shlex-split the stub's
  # single `launch` line the same way kitty/session.py does, take the
  # argv from the executable that precedes --exec-pane0, and execvp it.
  #
  # execvp, not subprocess: the process under test then IS this process,
  # so a `timeout` around the harness's python kills the thing that is
  # looping instead of orphaning it.
  mkStubExec = pkgs.writeText "kitty-scripts-stub-exec.py" ''
    import os
    import shlex
    import sys

    toks = shlex.split(open(sys.argv[1]).read())
    if "--exec-pane0" not in toks:
        sys.stderr.write(
            "stub line has no --exec-pane0 launcher: %r\n" % (toks,)
        )
        sys.exit(2)
    argv = toks[toks.index("--exec-pane0") - 1:]
    sys.stderr.write("stub argv: %r\n" % (argv,))
    os.execvp(argv[0], argv)
  '';

  # The same argv as JSON, so an assertion can inspect what kitty will
  # record as pane 0's `window.cmdline` after the restore.
  mkStubArgv = pkgs.writeText "kitty-scripts-stub-argv.py" ''
    import json
    import shlex
    import sys

    toks = shlex.split(open(sys.argv[1]).read())
    if "--exec-pane0" not in toks:
        json.dump([], sys.stdout)
    else:
        json.dump(toks[toks.index("--exec-pane0") - 1:], sys.stdout)
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
    #
    # Driven through the STUB rather than by calling --exec-pane0 bare:
    # the argv kitty parses off the launch line is half of what decides
    # what pane 0 becomes (phase J), so a test that skips the line is
    # testing a call nothing makes.
    export ARGV_OUT="$PWD/state/pane0-argv"
    python3 ${mkStubExec} "$KITTY_STUB_PATH" 2> state/pane0-stderr
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

      # E10b — and the user actually HEARS it. The only invocation
      # they make is the ctrl+shift+r binding, which runs reflow
      # through `launch --type=background`: kitty spawns such a
      # process with its OWN stdout and stderr
      # (boss.run_background_process), so stderr goes to kitty's log
      # and into no window at all. Measured under Xvfb against kitty
      # 0.48.2 -- a background launch printing to both streams left
      # the text in kitty's stderr log, and `kitty @ get-text` over
      # every window found none of it. A refusal nobody can hear
      # leaves a visibly half-rebuilt layout and no way to know why.
      grep -q 'launch --type=overlay' "$KITTY_CMD_LOG" || {
        echo "FAIL(E10b): the refusal went to stderr only, which on the"
        echo "  ctrl+shift+r path is kitty's log. The user is left with"
        echo "  a part-rebuilt layout and no message."
        exit 1; }
      grep -qi 'part-rebuilt, run it again' "$KITTY_CMD_LOG" || {
        echo "FAIL(E10b): the overlay does not carry the refusal text,"
        echo "  so it says nothing about what happened or what to do."
        exit 1; }
      grep -q 'KITTY_SESSION_UI=1' "$KITTY_CMD_LOG" || {
        echo "FAIL(E10b): the notice overlay is not marked as this"
        echo "  module's own chrome, so a snapshot taken while it is up"
        echo "  restores it as a pane and the next reflow gives it a"
        echo "  grid slot."
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
      cat "$KITTY_CMD_LOG"
      if grep -qE '^(detach-window|focus-window|goto-layout|action)' \
           "$KITTY_CMD_LOG"; then
        echo "FAIL(E11): the refusal came after commands that MOVE"
        echo "  something had already been issued."
        exit 1
      fi
      # The one command it may issue is the notice itself: a refusal
      # the user cannot hear is the E10b failure in another costume.
      grep -q 'launch --type=overlay' "$KITTY_CMD_LOG" || {
        echo "FAIL(E11): the lock refusal is invisible on the"
        echo "  ctrl+shift+r path, where stderr goes to kitty's log."
        exit 1; }
      grep -qi 'another reflow is already running' "$KITTY_CMD_LOG" || {
        echo "FAIL(E11): the overlay does not say WHY reflow refused."
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
    jq -e '.cmd[1] == "-c"' "$pane0_json" > /dev/null || {
      echo "FAIL(F1): the launcher shell does not run a command string."
      exit 1; }
    jq -e '.cmd[2] | test("source .*zshrc")' "$pane0_json" > /dev/null || {
      echo "FAIL(F1): the launcher never reads the rc that defines"
      echo "  _claude_slice, so every restored claude pane would take"
      echo "  the unobserved fallback."
      exit 1; }
    jq -e '.cmd[2] | test("_claude_slice")' "$pane0_json" > /dev/null || {
      echo "FAIL(F1): the launcher does not call _claude_slice — the"
      echo "  single definition of the slice policy."
      exit 1; }
    jq -e '.cmd[3] | endswith("/claude")' "$pane0_json" > /dev/null || {
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

    # --- Phase G: a save that cannot commit must not stay green -----
    #
    # kitty-session-save exited 0 for every kitty-session-commit rc, and
    # only rc 0 regenerated last.session. A persistently crashing commit
    # therefore stopped snapshots updating FOREVER while the systemd
    # unit stayed green — and the staleness only surfaced at the next
    # crash, restoring state from whenever the breakage started.
    #
    # rc 3 (the collapse guard refusing) and enrich rc 2 (the
    # partial-snapshot guard) are DESIGNED outcomes and have to stay
    # silent; the timer fires every 60s and a guard doing its job is not
    # news. Anything else is a bug, and it surfaces the systemd way: a
    # message on stderr and a non-zero exit, which puts the unit in
    # `systemctl --user --failed`. Deliberately NOT a desktop
    # notification — at one tick a minute that would be unusable, and
    # the failed unit is already where a user looks.
    #
    # kitty-session-save is a writeShellApplication, so its PATH is
    # pinned to its runtimeInputs and no directory can shadow them.
    # Exported bash FUNCTIONS can — bash resolves a function ahead of
    # PATH — so the script under test is the one dellan installs, byte
    # for byte, with only the exit codes of the three programs it calls
    # chosen by the test.
    save_bin=$(command -v kitty-session-save)
    mkdir -p gsave
    save_case() { # <label> <enrich-rc> <commit-rc>
      (
        export XDG_CACHE_HOME="$PWD/gsave/$1"
        mkdir -p "$XDG_CACHE_HOME/kitty-session"
        : > "$XDG_CACHE_HOME/kitty-session/snapshot.json"
        export KITTY_LISTEN_ON="unix:/nonexistent-fake"
        export G_ENRICH_RC="$2" G_COMMIT_RC="$3"
        kitty() { printf '[]\n'; }
        # Consumes stdin like the real enricher: a stub that exits
        # without reading gives the wrapper's `printf ... |` a SIGPIPE,
        # and under pipefail that races into enrich_rc.
        kitty-session-enrich() { cat >/dev/null; printf '[]\n'
                                 return "$G_ENRICH_RC"; }
        kitty-session-commit() { return "$G_COMMIT_RC"; }
        kitty-session-convert() { printf 'layout splits\n'; }
        export -f kitty kitty-session-enrich kitty-session-commit \
                  kitty-session-convert
        rc=0
        bash "$save_bin" > "$PWD/gsave/$1.out" \
          2> "$PWD/gsave/$1.err" || rc=$?
        echo "$rc"
      )
    }
    show_case() { # <label>
      echo "--- save($1) stderr ---"
      cat "gsave/$1.err"
    }

    # G1 — control: the collapse guard refusing is a normal outcome.
    # Exit 0, nothing on stderr, and last.session left in step with the
    # snapshot it was rendered from.
    g1=$(save_case guard-refused 0 3); show_case guard-refused
    [ "$g1" -eq 0 ] || {
      echo "FAIL(G1): a collapse-guard refusal (rc 3) failed the save"
      echo "  unit; it is the guard working, not a fault."
      exit 1; }
    [ ! -s gsave/guard-refused.err ] || {
      echo "FAIL(G1): rc 3 wrote to stderr. At one tick a minute a"
      echo "  working guard would fill the journal."
      exit 1; }
    [ ! -e gsave/guard-refused/kitty-session/last.session ] || {
      echo "FAIL(G1): last.session was regenerated from a snapshot the"
      echo "  guard refused to write."
      exit 1; }

    # G2 — the finding: any OTHER commit rc means snapshots have
    # silently stopped updating, and must not leave the unit green.
    g2=$(save_case commit-crashed 0 1); show_case commit-crashed
    [ "$g2" -ne 0 ] || {
      echo "FAIL(G2): kitty-session-commit crashed and the save unit"
      echo "  still reported success. Snapshots stop updating forever"
      echo "  and nothing says so until the next crash restores stale"
      echo "  state."
      exit 1; }
    grep -qi 'commit' gsave/commit-crashed.err || {
      echo "FAIL(G2): the failure is not named on stderr, so the"
      echo "  journal entry cannot be acted on."
      exit 1; }

    # G3 — control: the enricher's partial-snapshot guard (rc 2) is
    # also a designed outcome and stays quiet.
    g3=$(save_case enrich-partial 2 0); show_case enrich-partial
    [ "$g3" -eq 0 ] || {
      echo "FAIL(G3): the partial-snapshot guard (rc 2) failed the save"
      echo "  unit."
      exit 1; }
    [ ! -s gsave/enrich-partial.err ] || {
      echo "FAIL(G3): rc 2 wrote to stderr."; exit 1; }

    # G4 — and the same rule for an enricher that crashed.
    g4=$(save_case enrich-crashed 1 0); show_case enrich-crashed
    [ "$g4" -ne 0 ] || {
      echo "FAIL(G4): kitty-session-enrich crashed and the save unit"
      echo "  still reported success."
      exit 1; }
    grep -qi 'enrich' gsave/enrich-crashed.err || {
      echo "FAIL(G4): the enricher failure is not named on stderr."
      exit 1; }

    # G5 — control: the happy path still commits and re-renders
    # last.session, so G2/G4 are not passing by breaking the save.
    g5=$(save_case happy 0 0); show_case happy
    [ "$g5" -eq 0 ] || {
      echo "FAIL(G5): a clean save failed."; exit 1; }
    [ -s gsave/happy/kitty-session/last.session ] || {
      echo "FAIL(G5): last.session was not regenerated after a commit."
      exit 1; }

    # --- Phase H: the stub kitty EXECUTES is not left in /tmp -------
    #
    # kitty runs the launch directives in the stub, so the stub is a
    # program. Its default path was /tmp/kitty-stub-session — a fixed
    # name in a world-writable directory — and _write_atomic used
    # open('w'), which follows a symlink planted at the path it is
    # about to write. Cheap to close, and the file is executed.
    mkdir -p hstub
    (
      export XDG_CACHE_HOME="$PWD/hstub"
      unset KITTY_STUB_PATH
      mkdir -p "$XDG_CACHE_HOME/kitty-session"
      cp "$PWD/fx/home/.cache/kitty-session/snapshot.json" \
         "$XDG_CACHE_HOME/kitty-session/snapshot.json"
      kitty-restore-session --emit-stub
    ) || { echo "FAIL(H1): --emit-stub failed with the default path"
           exit 1; }
    [ -s hstub/kitty-session/stub-session ] || {
      ls -la hstub/kitty-session 2>&1 || true
      echo "FAIL(H1): the default stub is not written under the user's"
      echo "  own cache dir. A predictable name in world-writable /tmp"
      echo "  is a file kitty then executes."
      exit 1; }
    # The sandbox's /tmp is private and starts empty (verified), so
    # this says the default really moved, not that something cleaned up.
    [ ! -e /tmp/kitty-stub-session ] || {
      echo "FAIL(H1): a stub was still written to /tmp."; exit 1; }

    # H2 — writer and reader must agree. The wrapper is what hands the
    # path to kitty; a default that drifts means kitty is fed a stale
    # stub describing a different session, or none at all.
    # PATH puts the harness's fake kitty first, so name the wrapper by
    # the package under test rather than by lookup.
    wrapper_bin="$(dirname "$(command -v kitty-restore-session)")/kitty"
    grep -q 'kitty-session/stub-session' "$wrapper_bin" || {
      grep -n 'stub=' "$wrapper_bin" || true
      echo "FAIL(H2): the kitty wrapper still looks for the stub in the"
      echo "  old location, so the writer and the reader disagree."
      exit 1; }

    # H3 — and the write itself does not follow a symlink. _write_atomic
    # writes <path>.tmp and renames, so <path>.tmp is the plantable
    # name; following it truncates whatever it points at and then
    # renames the LINK into place, leaving kitty executing a file an
    # attacker still owns.
    mkdir -p hlink/kitty-session
    echo "canary contents" > hlink/canary
    ln -sfn "$PWD/hlink/canary" "$PWD/hlink/stub-session.tmp"
    (
      export XDG_CACHE_HOME="$PWD/hlink"
      export KITTY_STUB_PATH="$PWD/hlink/stub-session"
      cp "$PWD/fx/home/.cache/kitty-session/snapshot.json" \
         "$XDG_CACHE_HOME/kitty-session/snapshot.json"
      kitty-restore-session --emit-stub
    ) 2> state/hlink.err || true
    # The refusal surfaces as an ELOOP from os.open — that traceback
    # is the assertion passing, not a fault. The wrapper already
    # treats a failed --emit-stub as "launch plain kitty", which is
    # the right outcome for a stub path someone else is holding.
    echo "--- symlink attempt stderr ---"; cat state/hlink.err
    [ "$(cat hlink/canary)" = "canary contents" ] || {
      echo "canary now: $(cat hlink/canary)"
      echo "FAIL(H3): the stub writer followed a planted symlink and"
      echo "  overwrote the file it pointed at."
      exit 1; }

    # --- Phase I: the session state is the user's alone -------------
    #
    # snapshot.json, the history ring and pane0-launch.json record
    # cwds, window titles, argv and claude session ids. There are no
    # secrets in them — per-pane env in a snapshot is KITTY_WINDOW_ID
    # and PWD — but they are nobody else's business either, and the
    # default 0644-in-0755 left them readable by anyone on the host,
    # contained only by home-manager's homeMode 700.
    mode_is() { # <path> <mode>
      local got
      got=$(stat -c %a "$1")
      [ "$got" = "$2" ] || {
        echo "FAIL(I): $1 is mode $got, want $2"
        exit 1; }
      echo "  $1 -> $got"
    }
    echo "--- session state modes ---"
    mode_is sess/snapshot.json 600
    mode_is sess/history 700
    for f in sess/history/*.json; do mode_is "$f" 600; done
    mode_is "$XDG_CACHE_HOME/kitty-session/pane0-launch.json" 600
    mode_is hstub/kitty-session/stub-session 600

    # And the directory the save wrapper creates on a fresh machine.
    (
      export XDG_CACHE_HOME="$PWD/imode"
      export KITTY_LISTEN_ON="unix:/nonexistent-fake"
      kitty() { printf '[]\n'; }
      kitty-session-enrich() { cat >/dev/null; printf '[]\n'; }
      kitty-session-commit() { return 3; }
      export -f kitty kitty-session-enrich kitty-session-commit
      bash "$save_bin"
    ) || { echo "FAIL(I): the save wrapper failed on a fresh cache dir"
           exit 1; }
    mode_is imode/kitty-session 700

    # --- Phase J: the pane-0 launcher is never a pane's command ------
    #
    # `--exec-pane0` is a LAUNCHER, not a command. kitty records a
    # window's cmdline as what it SPAWNED, so after a restore pane 0's
    # cmdline is that launcher, and the next snapshot reads it back.
    # While the launch line carried no argv after the flag, that record
    # was `[kitty-restore-session, --exec-pane0]` — the stub's own
    # launch line, stored as pane 0's command. Measured on the built
    # derivation before the fix, from a snapshot whose pane 0 was a
    # zombie claude (and identically from one whose pane 0 was an
    # ordinary shell, since both fall past the foreground-claude arm
    # onto window.cmdline):
    #
    #   $ timeout 3 kitty-restore-session --exec-pane0
    #   rc=124 after 3s          <- killed; no output, 100% CPU
    #
    # and the same record restored into pane N would have re-read
    # pane0-launch.json and duplicated pane 0's `claude --resume <sid>`
    # onto a second pane — the corruption claimed_sids exists to stop.
    rs_exe=$(command -v kitty-restore-session)
    mkdir -p jloop/kitty-session

    # An orphaned stdio MCP server: what is left holding the pty in the
    # zombie case, and the only thing a poisoned record leaves to fall
    # back to.
    cat > fakebin/orphan-mcp <<'STUB'
    #!/bin/sh
    : > "$ORPHAN_RAN"
    exit 0
    STUB
    chmod +x fakebin/orphan-mcp
    export ORPHAN_RAN="$PWD/state/orphan-ran"

    # J1 — a snapshot ALREADY carrying the poisoned record (every
    # snapshot taken after a pre-fix restore does) must not produce a
    # stub that points back at the launcher.
    jq -n --arg rs "$rs_exe" --arg orphan "$PWD/fakebin/orphan-mcp" '
      [{tabs:[{layout:"splits",windows:[{
         id: 1, cwd: "/tmp", title: "zombie pane 0",
         cmdline: [$rs, "--exec-pane0"],
         foreground_processes: [{cmdline: [$orphan]}]
       }]}]}]' > jloop/kitty-session/snapshot.json
    (
      export XDG_CACHE_HOME="$PWD/jloop"
      export KITTY_STUB_PATH="$PWD/state/stub-jloop"
      kitty-restore-session --emit-stub
    ) || { echo "FAIL(J1): --emit-stub failed on the poisoned snapshot"
           exit 1; }
    echo "--- poisoned-record stub ---"; cat state/stub-jloop
    echo "--- poisoned-record pane0-launch.json ---"
    cat jloop/kitty-session/pane0-launch.json; echo
    jq -e '.cmd | (length < 2 or .[1] != "--exec-pane0")' \
      jloop/kitty-session/pane0-launch.json > /dev/null || {
      echo "FAIL(J1): pane 0's recorded command IS the pane-0 launcher."
      echo "  --exec-pane0 reads this file and execs it, which lands"
      echo "  back here: an exec loop at 100% CPU, session lost, and"
      echo "  nothing the user can do about it."
      exit 1; }
    # The pane's live foreground process is all a poisoned record leaves
    # to go on, and it is the right answer for the ordinary case (pane 0
    # is a shell). Assert it, so "not the launcher" cannot be satisfied
    # by dropping the pane instead.
    jq -e --arg orphan "$PWD/fakebin/orphan-mcp" '.cmd == [$orphan]' \
      jloop/kitty-session/pane0-launch.json > /dev/null || {
      echo "FAIL(J1): the launcher was stripped but nothing took its"
      echo "  place; pane 0 came back as neither its command nor what"
      echo "  is actually running in it."
      exit 1; }

    # J2 — and executing that stub the way kitty does TERMINATES.
    rm -f "$ORPHAN_RAN"
    jrc=0
    timeout 10 python3 ${mkStubExec} state/stub-jloop </dev/null \
      > state/jloop.out 2> state/jloop.err || jrc=$?
    echo "--- poisoned-record exec: rc=$jrc ---"; cat state/jloop.err
    [ "$jrc" -ne 124 ] || {
      echo "FAIL(J2): pane 0 never stopped exec'ing itself — the timeout"
      echo "  killed it. This is the loop: 100% CPU, no pane, and the"
      echo "  snapshot that would restore the session is the one feeding"
      echo "  the loop."
      exit 1; }
    [ -f "$ORPHAN_RAN" ] || {
      echo "FAIL(J2): pane 0 exec'd something other than the command the"
      echo "  stub named."
      exit 1; }

    # J3 — the round trip that MATTERS: what kitty records for a pane 0
    # the current stub launched. The argv on the launch line is what
    # `window.cmdline` becomes, so it has to unwrap back to claude —
    # otherwise a zombie pane 0 (claude gone, MCP orphan holding the
    # pty) loses its identity and its sid, which is precisely the case
    # window.cmdline is read for.
    python3 ${mkStubArgv} "$KITTY_STUB_PATH" > state/stub-argv.json
    echo "--- what kitty will record for pane 0 ---"
    cat state/stub-argv.json; echo
    jq -e '.[1] == "--exec-pane0" and (.[2] | endswith("/zsh"))' \
      state/stub-argv.json > /dev/null || {
      echo "FAIL(J3): the stub's launch line carries no argv after the"
      echo "  flag, so kitty records pane 0 as the launcher itself."
      exit 1; }
    mkdir -p jzombie/kitty-session
    jq -n --slurpfile argv state/stub-argv.json \
       --arg cwd "$PWD/fx/work" --arg sid "$SID" \
       --arg orphan "$PWD/fakebin/orphan-mcp" '
      [{tabs:[{layout:"splits",windows:[{
         id: 1, cwd: $cwd, title: "restored claude pane",
         cmdline: $argv[0],
         claude_session_id: $sid,
         foreground_processes: [{cmdline: [$orphan]}]
       }]}]}]' > jzombie/kitty-session/snapshot.json
    (
      export XDG_CACHE_HOME="$PWD/jzombie"
      kitty-restore-session --dump-panes
    ) > state/jzombie-panes.json
    echo "--- zombie pane 0, one restore later ---"
    cat state/jzombie-panes.json; echo
    jq -e --arg sid "$SID" '
      .[0].cmd as $c
      | ($c[0] | endswith("/claude")) and $c[1] == "--resume"
        and $c[2] == $sid' state/jzombie-panes.json > /dev/null || {
      echo "FAIL(J3): a zombie pane 0 launched by the current stub did"
      echo "  not come back as its own claude session. The pane-0"
      echo "  launcher has to be transparent to every consumer, exactly"
      echo "  as the claude-egress one is."
      exit 1; }

    # J4 — a bare --exec-pane0 must not adopt whatever pane 0 was last
    # recorded as. That call is the shape a pane restored from a
    # poisoned snapshot runs, and pane0-launch.json holds pane 0's
    # `claude --resume <sid>`: adopting it puts two panes on one
    # session, which corrupts both.
    export ARGV_OUT="$PWD/state/jbare-argv"
    rm -f "$ARGV_OUT"
    jrc=0
    timeout 10 kitty-restore-session --exec-pane0 </dev/null \
      > state/jbare.out 2> state/jbare.err || jrc=$?
    echo "--- bare --exec-pane0: rc=$jrc ---"; cat state/jbare.err
    [ "$jrc" -ne 124 ] || {
      echo "FAIL(J4): a bare --exec-pane0 never terminated."; exit 1; }
    [ ! -f "$ARGV_OUT" ] || {
      cat "$ARGV_OUT"
      echo "FAIL(J4): a launcher invocation that names no command still"
      echo "  started pane 0's claude session. A second pane on one"
      echo "  session corrupts it for both."
      exit 1; }

    # J5 — and the guard is not just an argv shape. Anything that leads
    # back into --exec-pane0 within the same process is a loop, however
    # it got there; the marker survives execvp because the pid does.
    cat > fakebin/pane0-relaunch <<STUB
    #!/bin/sh
    exec $rs_exe --exec-pane0 $PWD/fakebin/pane0-relaunch
    STUB
    chmod +x fakebin/pane0-relaunch
    jrc=0
    timeout 10 kitty-restore-session --exec-pane0 \
      "$PWD/fakebin/pane0-relaunch" </dev/null \
      > state/jindirect.out 2> state/jindirect.err || jrc=$?
    echo "--- indirect loop: rc=$jrc ---"; cat state/jindirect.err
    [ "$jrc" -ne 124 ] || {
      echo "FAIL(J5): pane 0's command led back into --exec-pane0 and"
      echo "  the launcher went round again. An exec loop has to be"
      echo "  structurally impossible, not merely unlikely."
      exit 1; }

    # J6 — last.session is a session file a human can feed straight back
    # to `kitty --session`, so the launcher must not be rendered into it
    # either: doing that hands kitty the same loop from a file the user
    # was told to trust.
    kitty-session-convert < jloop/kitty-session/snapshot.json \
      > state/jconv.session
    echo "--- converted poisoned record ---"; cat state/jconv.session
    if grep -q -- '--exec-pane0' state/jconv.session; then
      echo "FAIL(J6): last.session launches the pane-0 launcher as a"
      echo "  pane's command."
      exit 1
    fi

    # --- Phase K: the rc cannot swallow the pane -------------------
    #
    # The launcher's whole job is to reach _claude_slice, which lives in
    # the user's zsh rc. `zsh -i -c CMD` reads that rc — and an rc that
    # `exec`s or `exit`s FOR INTERACTIVE SHELLS (a tmux auto-attach line
    # is the classic) then never reaches CMD at all. For panes 1..N that
    # loses a pane; for pane 0 it loses everything, because pane 0 is
    # the stub's ONLY window and kitty exits with it. That is the
    # no-terminal class this module already had to fix once.
    #
    # Driven through the launcher the WRITER emitted — shell, flag and
    # command string all read out of pane0-launch.json — so this cannot
    # pass against a launcher shape restore no longer uses.
    slice_sh=$(jq -r '.cmd[0]' "$pane0_json")
    slice_flag=$(jq -r '.cmd[1]' "$pane0_json")
    jq -r '.cmd[2]' "$pane0_json" > state/slice-script
    mkdir -p krc
    cat > krc/.zshrc <<'RC'
    _claude_slice() { print "SLICE-RAN: $*"; }
    if [[ -o interactive ]]; then
      exec true
    fi
    RC
    krc_out=$(
      HOME="$PWD/krc" ZDOTDIR="$PWD/krc" \
        "$slice_sh" "$slice_flag" "$(cat state/slice-script)" \
        /nonexistent-claude --resume K1 2>&1
    ) || true
    echo "--- launcher under an rc that execs when interactive ---"
    printf '%s\n' "$krc_out"
    case "$krc_out" in
      *SLICE-RAN*) ;;
      *)
        echo "FAIL(K1): the rc pre-empted the launcher, so the pane's"
        echo "  command never ran. In pane 0 that closes kitty outright:"
        echo "  no terminal, no session, nothing to retry from."
        exit 1;;
    esac

    # K2 — control: a rc that defines nothing still degrades LOUDLY and
    # still starts the session (the established trade-off). Same rc
    # directory minus the definition, so K1 cannot be passing because
    # the launcher stopped consulting the rc at all.
    mkdir -p krc2
    cat > krc2/.zshrc <<'RC'
    typeset -g KRC2_SOURCED=1
    RC
    rm -f "$ORPHAN_RAN"
    krc2_out=$(
      HOME="$PWD/krc2" ZDOTDIR="$PWD/krc2" \
        "$slice_sh" "$slice_flag" "$(cat state/slice-script)" \
        "$PWD/fakebin/orphan-mcp" 2>&1
    ) || true
    echo "--- launcher under an rc with no _claude_slice ---"
    printf '%s\n' "$krc2_out"
    case "$krc2_out" in
      *"claude-egress: UNOBSERVED"*) ;;
      *)
        echo "FAIL(K2): an rc that does not define _claude_slice went"
        echo "  through silently. An unobserved session that looks"
        echo "  observed is the failure this guards."
        exit 1;;
    esac
    [ -f "$ORPHAN_RAN" ] || {
      echo "FAIL(K2): the fallback said UNOBSERVED and then did not"
      echo "  start the session. Observation degrades; the tool never"
      echo "  fails to start."
      exit 1; }

    echo "ok: single-line stub, pane-0 notice intact, grid dispatch and"
    echo "    session convert count real panes only, snapshot rotation"
    echo "    survives a relaunch burst, reflow is a true no-op on a"
    echo "    canonical layout and rebuilds every other shape"
    touch $out
  ''
