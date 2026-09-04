{ pkgs, lib, ... }:
let
  # Shared Python: is this `kitty @ ls` window one of kitty's OWN
  # windows rather than a user pane? Interpolated verbatim into every
  # script that has to answer the question, because answering it
  # differently in different places is what the 2026-09-04 incident
  # was made of — kitty-session-convert and kitty-restore-session each
  # skipped `kitten ask` while kitty-pane-add skipped nothing, so an
  # error overlay left the two restore paths disagreeing about how
  # many panes existed.
  #
  # Requires `import os` in the consuming script.
  kittyInternalWindowPy = ''
    # kitty spawns its own UI as `<kitten-exe> <name> ...` — boss.py
    # builds the config-error overlay as
    # `[kitten_exe(), '__show_error__', '--title', title]` and the
    # close-confirmation dialog via `run_kitten_with_metadata('ask',
    # ...)`. Dunder names are kitty-private by convention: they are not
    # in `kitten --help` and a user cannot mean to run one. `ask` is the
    # one public-named kitten kitty spawns on the user's behalf.
    #
    # Public kittens the user CAN mean (`kitten diff`, `kitten icat`,
    # `kitten ssh`, and the `kitten run-shell` wrapper kitty puts around
    # every shell-integration pane) are deliberately NOT filtered —
    # dropping a real pane is the mirror-image bug and just as bad.
    INTERNAL_KITTENS = ("ask",)


    def _kitten_subcommand(cmdline):
        """The kitten sub-command name, or None when not a kitten call.

        Both spellings: kitty >= 0.42 execs `kitten <name>`, older
        builds (and anything restored from an old snapshot) used
        `kitty +kitten <name>`.
        """
        if not cmdline:
            return None
        exe = os.path.basename(cmdline[0])
        if exe == "kitten" and len(cmdline) > 1:
            return cmdline[1]
        if exe == "kitty" and len(cmdline) > 2 and cmdline[1] == "+kitten":
            return cmdline[2]
        return None


    def is_internal_window(cmdline):
        """True for a cmdline kitty spawned as its own chrome."""
        sub = _kitten_subcommand(cmdline)
        if sub is None:
            return False
        if sub in INTERNAL_KITTENS:
            return True
        return len(sub) > 4 and sub.startswith("__") and sub.endswith("__")


    def window_is_internal(win):
        """True for a `kitty @ ls` window that is kitty's own chrome.

        Checks what kitty LAUNCHED the window with first: that survives
        the death of the process, which is the same reason pane_cmd
        prefers it.
        """
        if is_internal_window(win.get("cmdline") or []):
            return True
        fg = win.get("foreground_processes") or []
        return any(
            is_internal_window(fp.get("cmdline") or []) for fp in fg
        )
  '';

  # Shared Python: quote one value for a kitty session file. Used by
  # every writer of one — kitty-session-convert (last.session) and
  # kitty-restore-session (the --session stub) — because a session file
  # only has to be corrupted by ONE of them to be refused.
  #
  # Requires `import re` and `import shlex` in the consuming script.
  kittySessionTokenPy = ''
    # A kitty session file is LINE-ORIENTED: kitty/session.py does
    # `for line in raw.splitlines()` and then shlex-splits the rest of
    # that ONE line. shlex.quote does NOT make a newline safe there --
    # it keeps real newlines inside the quotes -- so a multi-line argv
    # element turns one `launch` into as many directives as the value
    # has lines. The restore notice is exactly such a value, and
    # kitty-pane-add hands it to every claude pane, so it comes back in
    # the pane's live cmdline on the next snapshot too.
    #
    # Measured 2026-09-04 against real kitty 0.48.2 under Xvfb: fed a
    # 12-line session file, kitty opened `kitten __show_error__ --title
    # 'The startup session was invalid'` and never started the user's
    # claude. Fed the single-line one, it opened exactly one window.
    #
    # Line breaks are removed BEFORE quoting because quoting preserves
    # them. \x1c-\x1e and the Unicode separators are in the class
    # because str.splitlines() treats them as breaks even though
    # kitty's parser does not -- a value that is one line for kitty and
    # two for anything reading the file back is still a trap.
    LINEBREAKS = re.compile("[\\r\\n\\v\\f\\x1c-\\x1e\\u2028\\u2029]")


    def session_token(value):
        """One quoted token that cannot break a session-file line."""
        return shlex.quote(LINEBREAKS.sub(" ", value))
  '';

  # Convert `kitty @ ls` JSON snapshot → kitty session-file format
  # (https://sw.kovidgoyal.net/kitty/overview/#startup-sessions).
  # Restores OS-window/tab/window topology, layouts, cwds, titles. Does
  # NOT restore foreground commands or scrollback — kitty has no API for
  # those, same gap as tmux-resurrect.
  kittySessionConvert = pkgs.writers.writePython3Bin "kitty-session-convert" {} ''
    import json
    import os
    import re
    import shlex
    import sys


    ${kittySessionTokenPy}

    ${kittyInternalWindowPy}

    def _is_claude(cmdline):
        """True when cmdline[0] is the claude-code CLI."""
        if not cmdline:
            return False
        return os.path.basename(cmdline[0]) == "claude"


    def pane_cmd(win):
        """The command this pane should be recorded as running.

        Mirrors kitty-restore-session's picker: a `claude` entry
        anywhere in the pid-ordered foreground list wins, then the
        cmdline kitty actually launched the window with, then
        foreground_processes[0]. Keeps last.session an honest
        rendering of what restore will do.
        """
        fg = win.get("foreground_processes") or []
        for fp in fg:
            cl = fp.get("cmdline") or []
            if _is_claude(cl):
                return cl
        wc = win.get("cmdline") or []
        if wc:
            return wc
        return (fg[0].get("cmdline") or []) if fg else []


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
                # Skip kitty's own chrome (the `kitten ask` close
                # confirmation, the `__show_error__` config-error
                # overlay). Restoring one re-shows a dialog nobody
                # asked for, and it inflates the pane count every
                # other script derives its behaviour from.
                if window_is_internal(win):
                    continue
                cwd = win.get("cwd")
                wtitle = win.get("title", "")
                cmdline = pane_cmd(win)
                parts = ["launch"]
                if cwd:
                    parts.append("--cwd")
                    parts.append(session_token(cwd))
                if wtitle:
                    parts.append("--title")
                    parts.append(session_token(wtitle))
                if cmdline:
                    parts.extend(session_token(a) for a in cmdline)
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
    import os
    import subprocess
    import sys


    ${kittyInternalWindowPy}

    def _answers(sock):
        """True when a live kitty is listening on `sock`."""
        r = subprocess.run(
            ["kitty", "@", "--to", sock, "ls"],
            capture_output=True, timeout=3,
        )
        return r.returncode == 0


    def find_socket():
        """Locate the kitty to talk to, preferring the one that spawned us.

        kitty exports KITTY_LISTEN_ON into every window it launches, so
        the ctrl+n binding (`launch --type=background kitty-pane-add`)
        already knows the right socket. The glob is the fallback for
        invocations from outside kitty, and it only ever knew about the
        `unix:/tmp/kitty.sock` default -- it finds nothing if listen_on
        is ever moved. Both candidates are still probed, so a stale
        KITTY_LISTEN_ON falls through to the glob instead of failing.
        """
        env_sock = os.environ.get("KITTY_LISTEN_ON")
        if env_sock and _answers(env_sock):
            return env_sock
        for f in sorted(glob.glob("/tmp/kitty.sock-*")):
            if _answers(f"unix:{f}"):
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

        # Inherit cwd from the focused window if --cwd wasn't given —
        # but not from an overlay kitty focused on its own (its cwd is
        # wherever kitty happened to be, not where the user is).
        if (
            cwd is None
            and focused_win is not None
            and not window_is_internal(focused_win)
        ):
            cwd = focused_win.get("cwd")

        # Count REAL panes only. kitty's own overlay windows (config
        # error, close confirmation) live in the same tab and are
        # indistinguishable from panes in `kitty @ ls`; counting one
        # shifts the whole vsplit/hsplit/new-tab sequence by a step and
        # every added pane lands in a single column instead of the 2x2
        # grid. Reproduced 2026-09-04: a mis-parsed session stub left an
        # `__show_error__` window behind and the restored session came
        # back stacked.
        windows = [
            w for w in active_tab.get("windows", [])
            if not window_is_internal(w)
        ]
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
        #
        # Insertion order rather than geometry because CREATING the
        # next pane only needs to know which existing pane to split.
        # An earlier comment here claimed geometry was unavailable at
        # all; that is wrong and it misled the reflow work. Pixel
        # coordinates really are absent (window.py:2272 as_dict has no
        # at_x/at_y), but the full split TREE is not: `kitty @ ls`
        # carries `tabs[].layout_state.pairs` (tabs.py:1461 ->
        # layout/splits.py:959) plus `tabs[].groups`. That is what
        # kitty-panes-reflow below reads to decide whether an existing
        # layout is already the canonical grid.
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

  # Rearrange the panes a RUNNING kitty already has into the same
  # canonical grid kitty-pane-add CREATES, without killing or
  # respawning anything: every pane may be a long-lived `claude`
  # session, so the only acceptable primitive is one that RE-PARENTS a
  # window. `kitty @ detach-window` is that primitive; `launch` is not.
  #
  # Why detach-and-rebuild rather than driving the existing tree in
  # place: no remote-control primitive can put a window at a CHOSEN
  # INTERIOR slot of an arbitrary splits tree.
  # `layout_action move_to_screen_edge` only re-roots outside-in
  # (layout/splits.py:799 sets new_root=(win, whole_old_tree)),
  # `layout_action rotate` only flips the pair holding the active
  # window (splits.py:780), and `action move_window` is a pure SWAP of
  # two existing leaves (window_list.py:517) which never changes the
  # tree SHAPE. `_insert_window_in_direction` (boss.py:3368) is the
  # primitive that would do it and is reachable only from mouse
  # drag-and-drop (tabs.py:2101). Rebuilding into fresh EMPTY tabs is
  # therefore the only sequence whose result is deterministic.
  #
  # Verified against kitty 0.48.2 by driving a real kitty under Xvfb:
  # six stacked panes came back as 2x2 + 2 with all six PIDs
  # byte-identical before and after.
  kittyPanesReflow = pkgs.writers.writePython3Bin "kitty-panes-reflow" {} ''
    """Reflow a running kitty's panes into the canonical 2x2 grid.

    Usage: kitty-panes-reflow [--plan]
    """
    import glob
    import json
    import os
    import subprocess
    import sys


    ${kittyInternalWindowPy}

    # Panes per tab in the canonical grid. Not a tunable: it IS the
    # 2x2 shape kitty-pane-add creates (pane 1 full, pane 2 vsplit,
    # pane 3 hsplit on the left, pane 4 hsplit on the right, pane 5+
    # a new tab), and canonical_pairs()/plan_chunk() below are written
    # for exactly those four slots. Wanting a different grid means
    # rewriting both of them, not editing this number.
    PANES_PER_TAB = 4


    def _answers(sock):
        """True when a live kitty is listening on `sock`."""
        r = subprocess.run(
            ["kitty", "@", "--to", sock, "ls"],
            capture_output=True, timeout=3,
        )
        return r.returncode == 0


    def find_socket():
        """The kitty to reflow. KITTY_LISTEN_ON wins outright.

        Deliberately unlike kitty-pane-add: a stale KITTY_LISTEN_ON
        does NOT fall through to the /tmp/kitty.sock-* glob. Adding a
        pane to the wrong kitty is a nuisance; rearranging every pane
        of the wrong kitty is destruction, and the glob is precisely
        the path by which a test harness would reach the user's live
        session.
        """
        env_sock = os.environ.get("KITTY_LISTEN_ON")
        if env_sock:
            return env_sock if _answers(env_sock) else None
        for f in sorted(glob.glob("/tmp/kitty.sock-*")):
            if _answers("unix:" + f):
                return "unix:" + f
        return None


    def ls(sock):
        out = subprocess.check_output(
            ["kitty", "@", "--to", sock, "ls"], text=True,
        )
        return json.loads(out)


    def rc(sock, *args):
        subprocess.run(["kitty", "@", "--to", sock, *args], check=True)


    def tab_panes(tab):
        """The tab's real panes, one per window GROUP, in group order.

        A pane is a GROUP, not a window. kitty puts an overlay into
        the SAME group as the window it covers -- the config-error
        window is built with overlay_for=<window id>
        (boss.py:2485-2494) and the close-confirmation `ask` kitten
        likewise -- and the splits tree is keyed by group id
        (tabs.py:1465 list_groups). So an overlay can never occupy a
        grid slot of its own, and a group holding nothing but kitty's
        own chrome is not a pane at all and is left exactly where it
        is. Same window_is_internal() predicate kitty-pane-add,
        kitty-session-convert and kitty-session-commit use, so none of
        the four can disagree about what a pane is.

        Falls back to one-pane-per-window for a payload with no
        `groups` key.
        """
        by_id = {w.get("id"): w for w in tab.get("windows", [])}
        panes = []
        groups = tab.get("groups")
        if groups:
            for g in groups:
                real = [
                    by_id[i] for i in g.get("windows", [])
                    if i in by_id and not window_is_internal(by_id[i])
                ]
                if real:
                    panes.append(
                        {"group": g.get("id"), "window": real[0]["id"]}
                    )
            return panes
        for w in tab.get("windows", []):
            if not window_is_internal(w):
                panes.append({"group": None, "window": w.get("id")})
        return panes


    def canonical_pairs(gids):
        """kitty's serialized splits tree for `gids` in slot order.

        Slot order is creation order: upper-left, upper-right,
        lower-left, lower-right. `horizontal` shows up only on the
        vertically-split pairs because Pair.serialize emits the key
        only when it is False (layout/splits.py:42-45) -- a tree
        compared against one that spells out `"horizontal": true`
        would never match anything kitty reports.
        """
        n = len(gids)
        if n <= 1:
            return {"one": gids[0]} if gids else {}
        if n == 2:
            return {"one": gids[0], "two": gids[1]}
        left = {"horizontal": False, "one": gids[0], "two": gids[2]}
        if n == 3:
            return {"one": left, "two": gids[1]}
        return {
            "one": left,
            "two": {"horizontal": False, "one": gids[1], "two": gids[3]},
        }


    def tree_shape(node):
        """A serialized Pair tree with its leaf identities erased.

        Leaf identity is dropped on purpose: reflow's contract is the
        GRID, not which pane sits in which cell, so a tab that already
        has the canonical shape must not be torn down merely to
        reorder it. `bias` is ignored for the same reason -- kitty
        serializes it only when the user has dragged a divider off
        centre (splits.py:46-47), and rebuilding would silently undo
        that.
        """
        if node is None:
            return None
        if not isinstance(node, dict):
            return "pane"
        return (
            bool(node.get("horizontal", True)),
            tree_shape(node.get("one")),
            tree_shape(node.get("two")),
        )


    def tree_leaves(node):
        if node is None:
            return []
        if not isinstance(node, dict):
            return [node]
        return tree_leaves(node.get("one")) + tree_leaves(node.get("two"))


    def tab_is_canonical(tab, panes):
        """True when this tab already holds the canonical grid."""
        if tab.get("layout") != "splits":
            # `stack` (and anything else) serializes no `pairs` at
            # all, so there is nothing to compare and the tab has to
            # be rebuilt into a splits one.
            return False
        pairs = (tab.get("layout_state") or {}).get("pairs")
        if not isinstance(pairs, dict):
            return False
        gids = [p["group"] for p in panes]
        if None in gids:
            return False
        if sorted(tree_leaves(pairs)) != sorted(gids):
            # A slot is held by something that is not one of this
            # tab's panes -- e.g. a kitten kitty opened as a window of
            # its own rather than as an overlay. Not the canonical
            # grid; reflow rebuilds around it and leaves it put.
            return False
        if len(gids) == 1:
            # A lone pane looks identical in either slot of the root
            # pair, so `{"two": g}` counts as canonical too: detaching
            # it into a fresh tab would be pure churn.
            return True
        return tree_shape(pairs) == tree_shape(canonical_pairs(gids))


    def pick_os_window(data):
        """The single OS window to reflow, or None when unsure.

        `kitty @ ls` returns a LIST of OS windows (boss.py:509
        list_os_windows) and `detach-window --target-tab new` creates
        its tab in the CURRENT one (boss.py:3338 ->
        current_os_window()), so reflowing a non-focused OS window
        would scatter its panes into the focused one. Refusing beats
        guessing. `is_focused` is empty when no window manager has
        assigned focus (a bare X server, e.g. under Xvfb), hence the
        is_active / last_focused fallbacks before the single-window
        one.
        """
        for key in ("is_focused", "is_active", "last_focused"):
            for osw in data:
                if osw.get(key):
                    return osw
        return data[0] if len(data) == 1 else None


    def focused_window(osw):
        """Id of the window the user is actually sitting in.

        Not a scan for `is_focused` over every window: kitty sets that
        flag on the active window of EVERY tab of the focused OS
        window (tabs.py:1064 -- `w is active_window` of its own tab,
        and the OS window is focused), so a naive scan picks whichever
        tab happens to come last.
        """
        tabs = osw.get("tabs", [])
        tab = next((t for t in tabs if t.get("is_focused")), None)
        if tab is None:
            tab = next((t for t in tabs if t.get("is_active")), None)
        if tab is None:
            return None
        for w in tab.get("windows", []):
            if w.get("is_focused") or w.get("is_active"):
                return w.get("id")
        return None


    def collect(osw):
        """[(tab, panes)] for every tab of `osw` holding a real pane."""
        out = []
        for tab in osw.get("tabs", []):
            panes = tab_panes(tab)
            if panes:
                out.append((tab, panes))
        return out


    def is_canonical(osw):
        """True when this OS window needs no work at all.

        Two conditions. The panes have to be DISTRIBUTED canonically
        --- full tabs of PANES_PER_TAB with the remainder last --- and
        each tab has to hold the canonical shape for its own count.
        Tabs holding no real pane are skipped rather than counted,
        which is what makes a second run after a reflow that left a
        chrome-only tab behind settle instead of oscillating.
        """
        entries = collect(osw)
        total = sum(len(p) for _, p in entries)
        if total == 0:
            return True
        full, rest = divmod(total, PANES_PER_TAB)
        want = [PANES_PER_TAB] * full + ([rest] if rest else [])
        if [len(p) for _, p in entries] != want:
            return False
        return all(tab_is_canonical(t, p) for t, p in entries)


    def plan_chunk(chunk):
        """Steps that rebuild one canonical tab out of `chunk`.

        Transcribed from the sequence measured against kitty 0.48.2.
        Every step RE-PARENTS an existing window, so no pane's process
        is ever killed or respawned:

          * `--target-tab new` makes an EMPTY tab -- new_tab(
            empty_tab=True), boss.py:3338 -- and moves the anchor into
            it. No shell is spawned.
          * `--target-tab id:T` is NOT an append. attach_windows ->
            Tab._add_window(location=None) ->
            add_non_overlay_window (layout/splits.py:629) splits along
            the default axis, anchored on the TARGET TAB'S ACTIVE
            window. That is why every detach is preceded by an
            explicit focus-window naming its anchor.
          * `layout_action rotate 90` flips `horizontal` on the pair
            holding the ACTIVE window (splits.py:780-798), turning the
            vsplit that was just made into the hsplit the lower row
            needs. It reads the tab's active group, NOT the command's
            --match, so the focus step before it is load bearing.

        Anchor windows, not tab ids: `--target-tab new` allocates an
        id that cannot be known when the plan is built, and kitty
        reallocates GROUP ids on every attach. Window ids are the only
        identifier that survives the whole sequence.
        """
        ul = chunk[0]["window"]
        steps = [["detach-new", ul], ["layout-splits", ul]]
        if len(chunk) > 1:
            steps += [["focus", ul], ["detach-to", chunk[1]["window"], ul]]
        if len(chunk) > 2:
            ll = chunk[2]["window"]
            steps += [
                ["focus", ul], ["detach-to", ll, ul],
                ["focus", ll], ["rotate"],
            ]
        if len(chunk) > 3:
            lr = chunk[3]["window"]
            steps += [
                ["focus", chunk[1]["window"]], ["detach-to", lr, ul],
                ["focus", lr], ["rotate"],
            ]
        # Leave the rebuilt tab level. kitty serializes a non-central
        # `bias` and tree_shape() deliberately ignores it, so without
        # this a rebuilt tab could come back visibly lopsided and no
        # later run would ever notice.
        steps += [["focus", ul], ["equalize"]]
        return steps


    def build_plan(data):
        """{os_window, noop, steps} for a `kitty @ ls` payload."""
        osw = pick_os_window(data)
        if osw is None:
            return None
        if is_canonical(osw):
            return {"os_window": osw.get("id"), "noop": True, "steps": []}
        panes = [p for _, ps in collect(osw) for p in ps]
        steps = []
        for i in range(0, len(panes), PANES_PER_TAB):
            steps += plan_chunk(panes[i:i + PANES_PER_TAB])
        focused = focused_window(osw)
        if focused is not None:
            # Every detach ends with target_tab.make_active()
            # (boss.py:3352) and every anchor focus moves the cursor,
            # so reflow finishes somewhere arbitrary unless it puts
            # the user back.
            steps.append(["focus", focused])
        return {"os_window": osw.get("id"), "noop": False, "steps": steps}


    def tab_of(sock, wid):
        """Id of the tab currently holding window `wid`."""
        for osw in ls(sock):
            for tab in osw.get("tabs", []):
                for w in tab.get("windows", []):
                    if w.get("id") == wid:
                        return tab.get("id")
        return None


    def _resolve_tab(sock, anchor):
        tab = tab_of(sock, anchor)
        if tab is None:
            raise SystemExit(
                "kitty-panes-reflow: anchor window %s disappeared "
                "mid-reflow" % anchor
            )
        return tab


    def execute(sock, steps):
        for step in steps:
            op = step[0]
            if op == "focus":
                rc(sock, "focus-window", "--match=id:%d" % step[1])
            elif op == "detach-new":
                rc(sock, "detach-window", "--match=id:%d" % step[1],
                   "--target-tab", "new")
            elif op == "detach-to":
                tab = _resolve_tab(sock, step[2])
                rc(sock, "detach-window", "--match=id:%d" % step[1],
                   "--target-tab", "id:%d" % tab)
            elif op == "layout-splits":
                tab = _resolve_tab(sock, step[1])
                rc(sock, "goto-layout", "--match=id:%d" % tab, "splits")
            elif op == "rotate":
                rc(sock, "action", "layout_action", "rotate", "90")
            elif op == "equalize":
                rc(sock, "action", "layout_action", "equalize")
            else:
                raise SystemExit("unknown reflow step: " + repr(step))


    def main():
        if "--plan" in sys.argv:
            # Test-only seam, same role as kitty-restore-session's
            # --dump-panes: render the plan from a `kitty @ ls`
            # payload on stdin without talking to any kitty. It is how
            # the grid arithmetic is asserted with no terminal at all,
            # and it is why the fast check never has to go looking for
            # a socket -- /tmp/kitty.sock-* belongs to the user's live
            # session.
            try:
                data = json.load(sys.stdin)
            except ValueError:
                print("--plan: stdin is not `kitty @ ls` JSON",
                      file=sys.stderr)
                sys.exit(1)
            plan = build_plan(data)
            if plan is None:
                print("--plan: cannot tell which OS window to reflow",
                      file=sys.stderr)
                sys.exit(1)
            json.dump(plan, sys.stdout)
            return

        sock = find_socket()
        if not sock:
            print("no live kitty", file=sys.stderr)
            sys.exit(1)
        plan = build_plan(ls(sock))
        if plan is None:
            print(
                "several OS windows and none is focused; refusing to "
                "guess which one to reflow",
                file=sys.stderr,
            )
            sys.exit(1)
        if plan["noop"]:
            # Nothing is issued: no detach, no focus change, no
            # visible churn. This command is meant to be safe to fire
            # on a hunch.
            print("layout is already canonical")
            return
        try:
            execute(sock, plan["steps"])
        except subprocess.CalledProcessError as err:
            # A pane closed between the plan and the step that moves
            # it, or kitty refused the command. Say so instead of
            # emitting a traceback: the layout is now part-rebuilt,
            # and a second run converges on it from wherever it
            # stopped.
            print(
                "kitty-panes-reflow: `%s` failed (rc %d); the layout is "
                "part-rebuilt, run it again"
                % (" ".join(err.cmd), err.returncode),
                file=sys.stderr,
            )
            sys.exit(1)


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
    import shutil
    import subprocess
    import sys
    import time


    ${kittySessionTokenPy}

    ${kittyInternalWindowPy}

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


    # ---- restore notice -----------------------------------------------
    #
    # A restored pane resumes a conversation whose PROCESSES are gone.
    # Background subagents die with the parent; their file edits usually
    # do not. On 2026-08-25 the same agent was lost twice this way, each
    # time after it had already staged its work, and the resumed session
    # went on believing it was still running.
    #
    # The notice fires on EVERY restore, unconditionally. The resumed
    # session cannot tell from its own transcript that it was restarted,
    # so the restore itself is the thing worth saying; orphans and dirty
    # state are sections within the message, never conditions on it.
    #
    # Completion is decided by a recorded terminal value, never by a
    # timestamp. Recovery keyed on mtime is defeated by clock movement in
    # both directions -- a backward step hides in-flight work, a forward
    # jump makes settled work look fresh -- which is why projects that
    # started there (hardy #521, SeaweedFS #9944) removed it. A
    # stop_reason already written to a transcript does not move.
    #
    # Measured across 196 agent transcripts on this host: 166 ended
    # type=assistant with stop_reason end_turn, 19 ended type=assistant
    # with stop_reason null, 10 ended type=user, 1 ended tool_use. Only
    # the first shape is a finished agent.

    AGENT_TAIL_BYTES = 262144
    AGENT_SCAN_BYTES = 4194304
    RESTORE_BUDGET_S = 3.0
    MAX_FILES_PER_AGENT = 12
    EDIT_TOOLS = ("Edit", "Write", "MultiEdit", "NotebookEdit")


    def _last_record(path):
        """Last complete JSONL record of path, or None when unsure.

        Reads a bounded tail rather than the whole file: these run to
        hundreds of KB and this happens while panes wait to launch. A
        record larger than the window comes back unparseable, which the
        caller treats as unknown rather than as evidence.
        """
        try:
            size = os.path.getsize(path)
            with open(path, "rb") as fh:
                want = min(size, AGENT_TAIL_BYTES)
                fh.seek(size - want)
                blob = fh.read(want)
        except OSError:
            return None
        lines = [ln for ln in blob.split(b"\n") if ln.strip()]
        if not lines:
            return None
        try:
            return json.loads(lines[-1].decode("utf-8", "replace"))
        except ValueError:
            return None


    def _is_orphaned(rec):
        """True when rec is not a clean end_turn completion."""
        if not isinstance(rec, dict):
            return False
        if rec.get("type") != "assistant":
            return True
        msg = rec.get("message")
        if not isinstance(msg, dict):
            return True
        return msg.get("stop_reason") != "end_turn"


    def _edited_paths(path, deadline):
        """Files this agent's OWN edit tool calls named, first-use order.

        Attribution is exact rather than inferred: the record lives in
        the agent's own transcript, so a file touched by the main session
        or by a sibling agent cannot appear here. That is the whole point
        — a resumed session needs to know which edits are unowned, and a
        git diff cannot tell it who made them.

        Bash-mediated writes DO NOT appear: in a 40-transcript sample
        there were 956 Bash calls against 91 edit-tool calls, so shell
        redirection and `git add` leave nothing to attribute. The per-cwd
        git summary is what covers those.

        Scans forward with a byte cap and the shared deadline; a
        transcript too large or too slow yields a short list rather than
        a late restore.
        """
        out = []
        seen = set()
        try:
            with open(path, "r", errors="replace") as fh:
                read = 0
                for ln in fh:
                    read += len(ln)
                    if read > AGENT_SCAN_BYTES or time.time() > deadline:
                        break
                    # Most records are user/tool_result and cannot match.
                    # Skipping their json.loads is the entire budget:
                    # 0.05s against a real 800KB transcript.
                    if '"tool_use"' not in ln:
                        continue
                    try:
                        rec = json.loads(ln)
                    except ValueError:
                        continue
                    msg = rec.get("message")
                    if not isinstance(msg, dict):
                        continue
                    content = msg.get("content")
                    if not isinstance(content, list):
                        continue
                    for blk in content:
                        if not isinstance(blk, dict):
                            continue
                        if blk.get("type") != "tool_use":
                            continue
                        if blk.get("name") not in EDIT_TOOLS:
                            continue
                        inp = blk.get("input")
                        if not isinstance(inp, dict):
                            continue
                        fp = inp.get("file_path") or inp.get("notebook_path")
                        if isinstance(fp, str) and fp and fp not in seen:
                            seen.add(fp)
                            out.append(fp)
        except OSError:
            return out
        return out


    def _dirty_counts(work_dir, deadline):
        """(changed, staged) from git porcelain, or None when unknown."""
        if not work_dir or time.time() > deadline:
            return None
        try:
            r = subprocess.run(
                ["git", "-C", work_dir, "status", "--porcelain"],
                capture_output=True, timeout=3, text=True,
            )
        except (OSError, subprocess.SubprocessError):
            return None
        if r.returncode != 0:
            return None
        rows = [x for x in r.stdout.split("\n") if x.strip()]
        staged = sum(1 for x in rows if x[:1] not in (" ", "?"))
        return (len(rows), staged)


    def _orphans(proj_dir, sid, deadline):
        """[(name, cwd, branch, [edited paths])] for this session.

        Scoping is by session IDENTITY, not recency: the transcripts live
        under the spawning session, so agents belonging to other sessions
        are excluded by construction rather than by an age cap. On this
        host 19 of 196 transcripts look orphaned, the oldest ~2900h --
        an age cap would have been the wrong axis and a noisy one.
        """
        if not proj_dir or not sid:
            return []
        pattern = os.path.join(
            proj_dir, sid, "subagents", "agent-*.jsonl"
        )
        found = []
        for path in sorted(glob.glob(pattern)):
            if time.time() > deadline:
                break
            rec = _last_record(path)
            if rec is None or not _is_orphaned(rec):
                continue
            name = os.path.basename(path)
            name = name.removeprefix("agent-").removesuffix(".jsonl")
            found.append((
                name, rec.get("cwd"), rec.get("gitBranch"),
                _edited_paths(path, deadline),
            ))
        return found


    def restore_notice(proj_dir, sid, cwd=None):
        """Prompt handed to every restored pane. Never None.

        Unconditional on purpose: the point is to kick the resumed
        session back into the work, and it has no other way to learn its
        processes are gone. A notice that only fired on orphans would be
        absent exactly when the session had to reconstruct state for some
        other reason.
        """
        deadline = time.time() + RESTORE_BUDGET_S
        found = _orphans(proj_dir, sid, deadline)
        parts = [
            "This pane was restored by kitty after the previous Claude "
            "Code process exited. Any background subagents this session "
            "started died with it; their file edits did not."
        ]
        dirs = []
        if cwd:
            dirs.append(cwd)
        if found:
            parts.append(
                str(len(found)) + " subagent(s) have no completion "
                "record, so they were cut off mid-run rather than "
                "finishing:"
            )
            for name, work_dir, branch, edited in found:
                line = "  - " + name
                if work_dir:
                    line += " (cwd " + work_dir
                    if branch:
                        line += ", branch " + branch
                    line += ")"
                parts.append(line)
                if edited:
                    shown = edited[:MAX_FILES_PER_AGENT]
                    parts.append(
                        "      edited " + str(len(edited)) + " file(s):"
                    )
                    for fp in shown:
                        parts.append("        " + fp)
                    if len(edited) > len(shown):
                        parts.append(
                            "        ... and "
                            + str(len(edited) - len(shown)) + " more"
                        )
                else:
                    parts.append(
                        "      no edit-tool calls recorded (it may still "
                        "have written via shell)"
                    )
                if work_dir and work_dir not in dirs:
                    dirs.append(work_dir)
        else:
            parts.append("No subagent of this session was left mid-run.")
        for work_dir in dirs:
            counts = _dirty_counts(work_dir, deadline)
            if counts is None:
                continue
            changed, staged = counts
            if not changed:
                parts.append("  " + work_dir + ": clean tree.")
                continue
            parts.append(
                "  " + work_dir + ": " + str(changed)
                + " changed file(s), " + str(staged) + " staged. "
                "Includes anything written via shell, which is not "
                "attributable to an agent."
            )
        parts.append(
            "Detached `systemd-run --user` units DO survive this "
            "boundary, unlike subagents, and may have finished or failed "
            "while the session was gone. `systemctl --user list-units` "
            "and any sentinel log they were writing hold the result."
        )
        parts.append(
            "Anything above, and anything the transcript describes as in "
            "flight, is a claim about the past. Establish current state "
            "from the filesystem before continuing that work or "
            "describing its status, then pick the work back up."
        )
        return "\n".join(parts)


    def _resume_cmd(claude, sid, proj_dir, cwd=None):
        """Resume command, plus the restore prompt.

        The probe must never cost a restore: recovering the pane layout
        matters more than delivering the notice, so every failure path
        returns the plain resume command.
        """
        base = [claude, "--resume", sid]
        try:
            notice = restore_notice(proj_dir, sid, cwd)
        except Exception:
            return base
        return base + [notice] if notice else base


    def maybe_resume_claude(cmd, cwd, session_id, claimed_sids):
        """If cmd is the claude-code CLI, rewrite to resume the correct
        session. Prefers the per-pane session_id captured at snapshot
        time (TSV populated by the SessionStart hook
        claude-kitty-pane-record, keyed by kitty window id and joined in
        by kitty-session-enrich).

        Fallback is latest-by-mtime in the cwd's project dir, BUT skips
        any sid already claimed by a sibling pane in this restore. Two
        same-cwd panes both losing their per-pane sid (because their
        SessionStart hook hadn't fired before the snapshot tick that
        captured them) is the canonical wrong-collide scenario this
        guard prevents — one pane took the snapshot sid, the other one
        falling back to latest-by-mtime would otherwise pick that same
        sid (latest === sibling's freshly-touched jsonl). When every
        candidate is claimed, return cmd unchanged → claude launches
        fresh rather than wrong-resume. Losing one pane's resume is
        recoverable; merging two panes onto one session corrupts both.

        Mutates `claimed_sids` with the sid this pane ends up using.
        """
        if not cmd or os.path.basename(cmd[0]) != "claude":
            return cmd
        proj_dir = None
        if cwd:
            encoded = re.sub(r"[^a-zA-Z0-9]", "-", cwd)
            proj_dir = os.path.expanduser(f"~/.claude/projects/{encoded}")
        if session_id and proj_dir and os.path.isfile(
            os.path.join(proj_dir, f"{session_id}.jsonl")
        ):
            claimed_sids.add(session_id)
            return _resume_cmd(cmd[0], session_id, proj_dir, cwd)
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
        for fname, _mtime in sessions:
            candidate = fname.removesuffix(".jsonl")
            if candidate in claimed_sids:
                continue
            claimed_sids.add(candidate)
            return _resume_cmd(cmd[0], candidate, proj_dir, cwd)
        return cmd


    # ---- pane-0 transport ----------------------------------------------
    #
    # session_token() above keeps every value that DOES go into the stub
    # on one line, but flattening the restore notice would gut it: the
    # orphan block is one line per subagent and one per edited file, and
    # a wall of run-together text is not the message. So NO pane-0 argv
    # travels through the session file at all. The stub's launch
    # command is this very script in --exec-pane0 mode; the real argv,
    # restore notice included, travels in JSON (where newlines are
    # escaped by construction) and --exec-pane0 execs it. Pane 0 then
    # receives the notice as an argv element by exactly the mechanism
    # panes 1..N get it -- kitty-pane-add's `-- <cmd> <notice>` -- which
    # is why there is no second notice-delivery path to keep in sync.
    #
    # The considered alternative was `kitty @ send-text` once the socket
    # is up. Rejected: it types into whatever the pane is showing, so it
    # races claude's TUI coming up and the notice's own newlines read as
    # submissions -- mangling the one message whose job is to be read
    # exactly.

    # Where kitty's `--session` stub is written. Overridable so a test
    # can drive emit_stub without touching the LIVE session's file --
    # /tmp/kitty-stub-session belongs to the running kitty. The wrapper
    # in home/kitty.nix reads the same variable with the same default,
    # so writer and reader cannot drift.
    STUB_PATH = os.environ.get(
        "KITTY_STUB_PATH", "/tmp/kitty-stub-session"
    )


    def cache_dir():
        base = os.environ.get(
            "XDG_CACHE_HOME",
            os.path.join(os.path.expanduser("~"), ".cache"),
        )
        return os.path.join(base, "kitty-session")


    def pane0_path():
        return os.path.join(cache_dir(), "pane0-launch.json")


    def _self_exe():
        """Absolute path to this script, for the stub's launch line.

        kitty parses the session file before any login shell has run,
        so a bare name is not guaranteed to resolve. argv[0] is the
        store path the wrapper invoked; PATH lookup is the fallback.
        """
        cand = sys.argv[0]
        if cand and os.sep in cand:
            return os.path.realpath(cand)
        return (
            shutil.which("kitty-restore-session") or "kitty-restore-session"
        )


    def _is_claude(cmdline):
        """True when cmdline[0] is the claude-code CLI."""
        if not cmdline:
            return False
        return os.path.basename(cmdline[0]) == "claude"


    def pane_cmd(win):
        """Resolve the command a restored pane should be launched with.

        Priority:
          1. a `claude` entry anywhere in foreground_processes. kitty
             reports that list in pid order, so index 0 is only claude
             by luck — every MCP-server child claude spawns has a
             higher pid, but the moment claude itself exits the list
             starts with whichever child outlived it.
          2. `window.cmdline` when kitty launched the pane AS claude.
             This is the ZOMBIE case: claude is gone, an orphaned
             stdio MCP server still holds the pty open, and fg lists
             only that orphan. kitty remembers what it spawned, so the
             pane is still recoverable as a claude pane (the sid comes
             from the snapshot's claude_session_id, attached by
             kitty-session-enrich from pane-sessions.tsv).
          3. `window.cmdline` otherwise — what kitty actually spawned
             beats whatever happens to be in the foreground right now.
             Restoring the pane's shell is better than re-running
             someone's half-finished `nix build`, and strictly better
             than resurrecting an orphaned MCP server as if the user
             had asked for it.
          4. foreground_processes[0], for kitty builds that do not
             report a per-window `cmdline` at all.
        """
        fg = win.get("foreground_processes") or []
        for fp in fg:
            cl = fp.get("cmdline") or []
            if _is_claude(cl):
                return cl
        wc = win.get("cmdline") or []
        if wc:
            return wc
        return (fg[0].get("cmdline") or []) if fg else []


    def load_panes():
        snap_path = os.path.join(cache_dir(), "snapshot.json")
        if not os.path.exists(snap_path) or os.path.getsize(snap_path) == 0:
            return []
        with open(snap_path) as fh:
            snap = json.load(fh)
        # Seed claimed_sids with sids explicitly attached in the snapshot
        # before resolving any fallback, so an un-enriched same-cwd pane
        # can't grab a sibling's sid via latest-by-mtime.
        claimed_sids = set()
        for osw in snap:
            for tab in osw.get("tabs", []):
                for win in tab.get("windows", []):
                    sid = win.get("claude_session_id")
                    if sid:
                        claimed_sids.add(sid)
        panes = []
        for osw in snap:
            for tab in osw.get("tabs", []):
                for win in tab.get("windows", []):
                    # Skip kitty's own chrome — the `kitten ask`
                    # close-confirmation dialog (saved if a snapshot
                    # tick fires while it is open) and the
                    # `__show_error__` config-error overlay. Same
                    # predicate kitty-pane-add and
                    # kitty-session-convert use, so the three cannot
                    # disagree about how many panes there are.
                    if window_is_internal(win):
                        continue
                    cmd = pane_cmd(win)
                    cwd = win.get("cwd")
                    sid = win.get("claude_session_id")
                    cmd = maybe_resume_claude(cmd, cwd, sid, claimed_sids)
                    panes.append({
                        "cwd": cwd,
                        "title": win.get("title", ""),
                        "cmd": cmd,
                    })
        return panes


    def _write_atomic(path, text):
        tmp = path + ".tmp"
        with open(tmp, "w") as fh:
            fh.write(text)
        os.replace(tmp, path)


    def emit_stub():
        """Write kitty's --session stub: pane 0, exactly one line.

        Kitty starts directly into this single window (no default
        extra), avoiding a close-window prompt on a spurious startup
        shell. Pane 0's real argv goes to pane0_path() and is executed
        by --exec-pane0; see the pane-0 transport note above for why it
        cannot travel in the session file.
        """
        panes = load_panes()
        if not panes:
            return
        p = panes[0]
        _write_atomic(pane0_path(), json.dumps({
            "cwd": p["cwd"],
            "title": p["title"],
            "cmd": p["cmd"],
        }))
        parts = ["launch"]
        if p["cwd"]:
            parts += ["--cwd", session_token(p["cwd"])]
        if p["title"]:
            parts += ["--title", session_token(p["title"])]
        parts += [session_token(_self_exe()), "--exec-pane0"]
        line = " ".join(parts)
        # Invariant, not a cleanup. Every token above is line-break-free
        # by construction, so this can only fire if a later edit adds an
        # unsanitised one -- and then refusing to write beats handing
        # kitty a stub it will mis-parse into extra windows. The wrapper
        # treats a missing stub as "launch plain kitty".
        if LINEBREAKS.search(line):
            raise ValueError("stub line is not single-line: " + repr(line))
        _write_atomic(STUB_PATH, line + "\n")


    def exec_pane0():
        """Become pane 0's real command, inside the window kitty made.

        Reached only from the stub's launch line. The argv -- restore
        notice included -- comes from pane0_path(), so a multi-line
        notice reaches pane 0 as a single argv element exactly as it
        reaches panes 1..N through kitty-pane-add.
        """
        cmd = None
        try:
            with open(pane0_path()) as fh:
                rec = json.load(fh)
            if isinstance(rec, dict):
                cmd = rec.get("cmd")
        except (OSError, ValueError):
            cmd = None
        if not (
            isinstance(cmd, list)
            and cmd
            and all(isinstance(a, str) for a in cmd)
        ):
            # No usable record: hand the user a shell rather than let
            # kitty close an empty pane out from under them.
            cmd = [os.environ.get("SHELL") or "/bin/sh"]
        try:
            os.execvp(cmd[0], cmd)
        except OSError:
            os.execvp("/bin/sh", ["/bin/sh"])


    def main():
        if "--emit-stub" in sys.argv:
            emit_stub()
            return

        if "--exec-pane0" in sys.argv:
            exec_pane0()
            return

        if "--dump-panes" in sys.argv:
            # Test-only: emit resolved panes JSON so assertions can
            # inspect maybe_resume_claude's per-pane outcome (including
            # the same-cwd-collision-avoidance fallback) without having
            # to spin up a real kitty.
            json.dump(load_panes(), sys.stdout)
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
      # "sdk-cli" / future values = subprocess; skip. Use the bare-form
      # default (''${VAR-cli} not ''${VAR:-cli}) so an explicitly empty
      # value ("") fails the gate instead of falling through to "cli":
      # empty string is what a misconfigured shell launcher injects,
      # and we want that to be loud (no TSV write), not silently
      # treated as the main interactive session.
      [ "''${CLAUDE_CODE_ENTRYPOINT-cli}" = "cli" ] || exit 0

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
  #
  # Exit codes:
  #   0  — enriched JSON written, safe to commit as new snapshot.
  #   2  — collision risk: at least one cwd has multiple claude panes
  #         and at least one of them lacks a TSV row (SessionStart
  #         hook hadn't fired yet when the snapshot tick captured it).
  #         The save wrapper treats this as "preserve the prior good
  #         snapshot.json"; persisting the partial would let the
  #         un-enriched pane fall back to latest-by-mtime on restore
  #         and collide with the sibling's freshly-touched jsonl.
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


    def _is_claude(cmdline):
        """True when cmdline[0] is the claude-code CLI."""
        if not cmdline:
            return False
        return os.path.basename(cmdline[0]) == "claude"


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
        """Annotate each claude pane with its session id. Returns
        (data, collision_risk) where collision_risk is True when the
        snapshot is partial in a way that would collapse same-cwd
        sibling panes on restore — i.e. at least one cwd has multiple
        claude panes and at least one of them lacks a TSV entry. The
        caller uses this to decide whether to overwrite snapshot.json
        or preserve the prior good one.
        """
        # Audited 2026-09-04 against the internal-window class that
        # broke kitty-pane-add (`kitten __show_error__`, `kitten ask`):
        # this function needs no such filter and deliberately has none.
        # `live` only decides which TSV rows to prune, and a TSV row
        # exists only for a window whose claude ran the SessionStart
        # hook, so an overlay's id can never be in it. The collision
        # check keys off has_claude, which an overlay never satisfies.
        # Adding a filter here would be dead code, not defence.
        tsv = load_tsv()
        live = set()
        claude_panes_by_cwd = {}
        for osw in data:
            for tab in osw.get("tabs", []):
                for win in tab.get("windows", []):
                    wid = win.get("id")
                    if isinstance(wid, int):
                        live.add(wid)
                    fg = win.get("foreground_processes") or []
                    # A window counts as a claude pane when claude is
                    # among its foreground processes OR when claude is
                    # what kitty launched it with.
                    #
                    # The second arm catches a ZOMBIE pane: claude has
                    # exited but an orphaned stdio MCP server (in
                    # practice research-agent, sitting in its 60s
                    # scanner re-check loop and never noticing stdin
                    # EOF) still holds the pty open, so kitty keeps the
                    # window alive and reports only the orphan in
                    # foreground_processes. Keying off fg alone left
                    # such a window un-enriched, and restore then
                    # relaunched the ORPHAN as the pane's command — the
                    # user's session silently dropped, the pane came
                    # back showing the MCP server's boot log.
                    #
                    # `window.cmdline` is what kitty spawned and
                    # survives the death of that process, so it is the
                    # stable record of "this pane is a claude pane".
                    # It stays FALSE for a pane the user launched as a
                    # shell and then quit claude inside — that window's
                    # cmdline is the shell, so no resurrection.
                    has_claude = _is_claude(win.get("cmdline")) or any(
                        _is_claude(fp.get("cmdline")) for fp in fg
                    )
                    if not has_claude:
                        continue
                    sid = tsv.get(wid) if isinstance(wid, int) else None
                    if sid:
                        win["claude_session_id"] = sid
                    cwd = win.get("cwd") or ""
                    claude_panes_by_cwd.setdefault(cwd, []).append(sid)
        prune_tsv(live)
        collision_risk = any(
            len(sids) > 1 and any(s is None for s in sids)
            for sids in claude_panes_by_cwd.values()
        )
        return data, collision_risk


    def main():
        try:
            data = json.load(sys.stdin)
        except json.JSONDecodeError:
            sys.exit(0)
        enriched, collision_risk = enrich(data)
        json.dump(enriched, sys.stdout)
        # Exit 2 (distinct from 1 = generic error) signals "snapshot
        # would collide on restore; caller should preserve prior good".
        if collision_risk:
            sys.exit(2)


    if __name__ == "__main__":
        main()
  '';

  # ctrl+shift+c copy filter: unwrap TUI hanging-indent line wraps so a
  # single shell command that the source app (claude-code, less, man,
  # any wide-text TUI) hard-wrapped for display copies back to its
  # original single line.
  #
  # Algorithm: stdin → stdout. A "block" is one non-indented line
  # followed by 1+ lines all starting with the SAME K>0 leading
  # spaces. Continuation lines have their K spaces stripped, all lines
  # rstrip'd, block joined with single spaces (matches the implicit
  # word-boundary space at terminal wrap points). Lines outside any
  # block pass through verbatim.
  #
  # Trade-off: a uniformly K-indented multi-line shell body (for/do/done,
  # if/then/fi with consistent indent) ALSO collapses. The escape hatch
  # is ctrl+shift+alt+c (`copy_to_clipboard`, kitty built-in, no
  # transform). Heuristic-only by necessity: when the source TUI emits
  # real `\n` for display wraps, kitty has no per-line "continued" flag
  # to recover from.
  kittyCopyUnwrap = pkgs.writers.writePython3Bin "kitty-copy-unwrap" {} ''
    import sys


    def unwrap(text):
        lines = text.split("\n")
        out = []
        i = 0
        while i < len(lines):
            cur = lines[i]
            if cur and cur[0] != " " and i + 1 < len(lines):
                nxt = lines[i + 1]
                stripped = nxt.lstrip(" ")
                k = len(nxt) - len(stripped)
                if k > 0 and stripped:
                    block = [cur.rstrip()]
                    j = i + 1
                    while (
                        j < len(lines)
                        and len(lines[j]) > k
                        and lines[j][:k] == " " * k
                        and lines[j][k] != " "
                    ):
                        block.append(lines[j][k:].rstrip())
                        j += 1
                    out.append(" ".join(block))
                    i = j
                    continue
            out.append(cur)
            i += 1
        return "\n".join(out)


    sys.stdout.write(unwrap(sys.stdin.read()))
  '';

  # ---- snapshot retention: named inputs, derived thresholds ---------
  #
  # Every number below is an INPUT with a reason. The two thresholds
  # the code actually reads are PRODUCTS of them, so tuning happens by
  # changing a reason rather than by nudging a constant until the
  # symptom stops.
  #
  # saveIntervalSeconds — how often kitty-session-save.timer fires. The
  #   timer and the collapse guard read this same binding, so they
  #   cannot drift apart.
  saveIntervalSeconds = 60;
  # failedRelaunchBurst — how many relaunches one bad-restore episode
  #   produces before a human intervenes. Three, observed 2026-09-04:
  #   kitty died holding 6 panes, each of three relaunches re-saved a
  #   degraded topology, and the third left one pane, at which point
  #   restore hit `len(panes) <= 1` and opened nothing.
  failedRelaunchBurst = 3;
  # A pane-count collapse is only believed once it has SURVIVED a whole
  # relaunch burst — each failed relaunch can persist at most one
  # degraded snapshot, one tick apart. Product: 180s.
  collapseGraceSeconds = failedRelaunchBurst * saveIntervalSeconds;
  # collapseDivisor — what makes a drop "sharp": losing at least this
  #   fraction of the panes between two consecutive ticks. Halving is
  #   not something a user does by hand inside one tick, and closing
  #   panes one at a time never trips it.
  collapseDivisor = 2;
  # historyBurstsCovered — how many independent bad episodes the
  #   history has to outlive. The ring holds one entry per DISTINCT
  #   pane count (the newest snapshot at that size), so an episode
  #   contributes at most failedRelaunchBurst slots — one per failed
  #   relaunch. Product: 12 slots, ~20KB each.
  historyBurstsCovered = 4;
  snapshotHistoryKeep = failedRelaunchBurst * historyBurstsCovered;
  # historyMinPanes — the smallest topology worth recovering. A
  #   snapshot at or below one pane carries nothing a human would
  #   restore, so it never enters the ring and therefore can never
  #   evict one that does.
  historyMinPanes = 2;

  # Decide whether a freshly-enriched snapshot may replace the current
  # one, and keep a bounded history of the good ones. Split out of
  # kitty-session-save so this arithmetic is testable without a kitty:
  # the save wrapper's PATH is pinned to its runtimeInputs, so a test
  # cannot stand in for `kitty @ ls` there.
  #
  # Exit codes:
  #   0 — candidate committed as the new snapshot.json.
  #   3 — candidate refused; the prior good snapshot is preserved.
  #   1 — bad usage / unreadable candidate.
  kittySessionCommit = pkgs.writers.writePython3Bin "kitty-session-commit" {} ''
    """Commit a kitty snapshot, or preserve the prior good one.

    Usage: kitty-session-commit <cache-dir>   (candidate JSON on stdin)
    """
    import json
    import os
    import re
    import shutil
    import sys
    import time


    ${kittyInternalWindowPy}

    # Retention inputs, injected from home/kitty.nix where each one is
    # stated with its reason. Named here so the values a test asserts
    # against are read out of the deployed script rather than
    # transcribed into the test.
    SAVE_INTERVAL_S = ${toString saveIntervalSeconds}
    FAILED_RELAUNCH_BURST = ${toString failedRelaunchBurst}
    COLLAPSE_GRACE_S = ${toString collapseGraceSeconds}
    COLLAPSE_DIVISOR = ${toString collapseDivisor}
    HISTORY_KEEP = ${toString snapshotHistoryKeep}
    HISTORY_MIN_PANES = ${toString historyMinPanes}

    HISTORY_RE = re.compile(r"^snapshot-\d+\.\d+-(\d+)p\.json$")


    def real_pane_count(data):
        """Panes a human would recognise as theirs.

        Excludes kitty's own overlay windows for the same reason
        kitty-pane-add does: an error overlay padding the count is
        exactly what would disarm the collapse guard below.
        """
        n = 0
        for osw in data:
            for tab in osw.get("tabs", []):
                for win in tab.get("windows", []):
                    if not window_is_internal(win):
                        n += 1
        return n


    def _load(path):
        """The current snapshot, or None when there isn't a usable one.

        A truncated or hand-mangled snapshot.json reads as "no prior
        good": committing over it is right, and it must not take the
        save timer down with a traceback every 60 seconds.
        """
        try:
            with open(path) as fh:
                data = json.load(fh)
        except (OSError, ValueError):
            return None
        return data if isinstance(data, list) else None


    def _history_names(hdir):
        try:
            names = os.listdir(hdir)
        except OSError:
            return []
        return sorted(n for n in names if HISTORY_RE.match(n))


    def _entry_for_panes(hdir, count, skip=None):
        """The history entry currently holding a `count`-pane topology.

        At most one exists: rotate() below keeps the ring as one SLOT
        per distinct pane count, so the count is the slot key.
        """
        suffix = "-%dp.json" % count
        for name in _history_names(hdir):
            if name != skip and name.endswith(suffix):
                return name
        return None


    def collapsed(prev_count, new_count, snap_path):
        """True when the pane count fell off a cliff, recently.

        Two conditions, both needed. The DROP has to be sharp
        (COLLAPSE_DIVISOR), which a user closing panes one at a time
        never produces between two ticks. And the prior snapshot has to
        be YOUNGER than the grace window, because a crash-and-relaunch
        burst resolves inside it while a deliberate close does not — so
        a real shrink is accepted a few minutes late instead of never.
        Not writing is what keeps the age growing: preserving leaves
        snapshot.json's mtime alone, so the window cannot renew itself.
        """
        # Below the smallest recoverable topology there is nothing to
        # protect, so the same input that keeps such a snapshot out of
        # the history also switches the guard off.
        if prev_count < HISTORY_MIN_PANES:
            return False
        if new_count * COLLAPSE_DIVISOR > prev_count:
            return False
        try:
            age = time.time() - os.path.getmtime(snap_path)
        except OSError:
            return False
        return age < COLLAPSE_GRACE_S


    def rotate(dirpath, snap_path, prev_count):
        """Keep the outgoing snapshot as its topology size's entry.

        The ring is one SLOT PER DISTINCT PANE COUNT, each holding the
        FRESHEST snapshot seen at that size. Three properties follow,
        and all three are load bearing:

        * Bounded churn. A session sitting at one size (or oscillating
          between two) replaces its own slot every tick instead of
          appending, so it cannot flush the recoverable topologies out
          by waiting — which a 60s timer would otherwise do in
          HISTORY_KEEP minutes.
        * Nothing recoverable is discarded on the way out. Keying on
          "has the count CHANGED since the last rotation" instead was
          the 2026-09-04 loss in miniature: a 6-pane entry rotated in
          days ago made today's 6-pane snapshot look like a duplicate,
          so when the post-crash collapse finally outlived the grace
          window it overwrote the only copy carrying live session ids
          and left the stale one behind. Same count is not same state.
        * A snapshot below HISTORY_MIN_PANES never enters the ring at
          all, so a degenerate state cannot evict a good one.

        Write-then-unlink, never the reverse: a failed copy must not be
        able to leave a size with no entry at all.
        """
        if prev_count < HISTORY_MIN_PANES:
            return
        hdir = os.path.join(dirpath, "history")
        try:
            os.makedirs(hdir, exist_ok=True)
        except OSError:
            return
        name = "snapshot-%.6f-%dp.json" % (time.time(), prev_count)
        try:
            shutil.copyfile(snap_path, os.path.join(hdir, name))
        except OSError:
            return
        stale = _entry_for_panes(hdir, prev_count, skip=name)
        if stale is not None:
            try:
                os.unlink(os.path.join(hdir, stale))
            except OSError:
                pass
        sys.stderr.write(
            "kitty-session-commit: rotated %d-pane snapshot to %s\n"
            % (prev_count, name)
        )
        prune(hdir)


    def prune(hdir):
        names = _history_names(hdir)
        for name in names[:max(len(names) - HISTORY_KEEP, 0)]:
            try:
                os.unlink(os.path.join(hdir, name))
            except OSError:
                pass


    def _write_atomic(path, text):
        tmp = path + ".tmp"
        with open(tmp, "w") as fh:
            fh.write(text)
        os.replace(tmp, path)


    def main():
        if len(sys.argv) < 2:
            sys.stderr.write("usage: kitty-session-commit <cache-dir>\n")
            sys.exit(1)
        dirpath = sys.argv[1]
        try:
            cand = json.load(sys.stdin)
        except ValueError:
            sys.stderr.write("kitty-session-commit: candidate is not JSON\n")
            sys.exit(1)
        if not isinstance(cand, list):
            sys.stderr.write("kitty-session-commit: candidate is not a list\n")
            sys.exit(1)

        snap_path = os.path.join(dirpath, "snapshot.json")
        prev = _load(snap_path)
        new_count = real_pane_count(cand)
        prev_count = real_pane_count(prev) if prev is not None else 0

        if prev is not None and collapsed(prev_count, new_count, snap_path):
            sys.stderr.write(
                "kitty-session-commit: refusing %d-pane snapshot over a "
                "%d-pane one saved %ds ago; preserving prior good\n"
                % (
                    new_count, prev_count,
                    int(time.time() - os.path.getmtime(snap_path)),
                )
            )
            sys.exit(3)

        if prev is not None:
            rotate(dirpath, snap_path, prev_count)
        _write_atomic(snap_path, json.dumps(cand))


    if __name__ == "__main__":
        main()
  '';

  # Snapshot current kitty state. No-op if no kitty is listening.
  kittySessionSave = pkgs.writeShellApplication {
    name = "kitty-session-save";
    runtimeInputs = [
      pkgs.kitty
      kittySessionConvert
      kittySessionEnrich
      kittySessionCommit
      pkgs.coreutils
    ];
    text = ''
      set -euo pipefail

      dir="''${XDG_CACHE_HOME:-$HOME/.cache}/kitty-session"
      mkdir -p "$dir"

      # Discover live kitty socket. kitty appends `-{pid}` to the
      # configured listen_on path on every launch (not only under `-1`),
      # so glob and pick the first live socket file.
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
      # Exit codes from kitty-session-enrich:
      #   0  — fully enriched, snapshot safe to commit
      #   2  — partial / collision-risk (multiple same-cwd claude panes
      #        and at least one lacks a TSV row); the un-enriched pane
      #        would fall back to latest-by-mtime on restore and collide
      #        with a sibling. Preserve the prior good snapshot.json
      #        instead of overwriting it with the dangerous partial.
      #   any other non-zero — enricher crashed; preserve prior good.
      set +e
      printf '%s\n' "$json" | kitty-session-enrich > "$dir/candidate.json.tmp"
      enrich_rc=$?
      set -e
      if [ "$enrich_rc" -ne 0 ]; then
        rm -f "$dir/candidate.json.tmp"
        exit 0
      fi

      # Retention gate. kitty-session-commit decides whether the
      # candidate may replace snapshot.json and keeps a bounded history
      # of the good ones (thresholds and their rationale live in
      # home/kitty.nix). Exit codes:
      #   0  — committed; last.session is regenerated to match.
      #   3  — refused, prior good snapshot preserved. NOT an error: it
      #        is the guard doing its job, and last.session must stay in
      #        step with the snapshot it was rendered from.
      #   any other non-zero — commit crashed; leave everything alone.
      #
      # This is a SECOND gate, not a replacement for the enricher's:
      # rc 2 above (partial snapshot, same-cwd claude panes with a
      # missing TSV row) still short-circuits before we get here.
      set +e
      kitty-session-commit "$dir" < "$dir/candidate.json.tmp"
      commit_rc=$?
      set -e
      rm -f "$dir/candidate.json.tmp"
      if [ "$commit_rc" -eq 0 ]; then
        kitty-session-convert < "$dir/snapshot.json" > "$dir/last.session.tmp"
        mv "$dir/last.session.tmp" "$dir/last.session"
      fi
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
      # Detect a running kitty by probing each socket — a kitty crash can
      # leave stale /tmp/kitty.sock-PID files behind that would otherwise
      # block restore on next launch. pgrep is unsafe here because the
      # kernel sets comm to argv[0] which is "kitty" for this wrapper too.
      shopt -s nullglob
      live=0
      sockets_seen=0
      for f in /tmp/kitty.sock-*; do
        [ -S "\$f" ] || continue
        sockets_seen=1
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
      # Drop the TSV before the new kitty starts: kitty assigns window
      # ids starting at 1 per instance, so the old kitty's wid→sid
      # rows would otherwise alias onto fresh panes in the window
      # between pane creation and SessionStart hook firing, and the
      # next snapshot tick would bake a stale sid into the new
      # snapshot. Guarded on sockets_seen=0 (no socket files existed
      # at all) — not on live=0 — so a transiently-unresponsive live
      # kitty whose @ ls call failed doesn't make us nuke its TSV
      # underfoot. SessionStart re-populates correct rows within
      # seconds; meanwhile the partial-snapshot guard in
      # kitty-session-enrich keeps the prior good snapshot in place.
      if [ "\$sockets_seen" -eq 0 ]; then
        rm -f "\''${XDG_CACHE_HOME:-\$HOME/.cache}/kitty-session/pane-sessions.tsv"
      fi
      stub="\''${KITTY_STUB_PATH:-/tmp/kitty-stub-session}"
      if [ -s "\$snap" ] && [ "\$live" -eq 0 ]; then
        # Write a stub session file containing just pane 0; this makes
        # kitty start directly into our restored topology with no extra
        # default-startup window to clean up. Restore-session, running
        # in the background, fills in panes 1..N once kitty's socket is up.
        #
        # emit-stub is NOT allowed to take kitty down with it. Under
        # \`set -e\` a non-zero exit here (or a stale file left by an
        # earlier run) used to mean either no terminal at all or kitty
        # being handed a session file describing the wrong session.
        # Remove the old file first, run the writer inside an \`if\` so
        # errexit does not fire, and fall through to a plain kitty when
        # it produced nothing.
        rm -f "\$stub"
        if ${kittyRestoreSession}/bin/kitty-restore-session --emit-stub \
             && [ -s "\$stub" ]; then
          ( ${kittyRestoreSession}/bin/kitty-restore-session \
              >/tmp/kitty-restore.log 2>&1 & )
          exec ${pkgs.kitty}/bin/kitty --session "\$stub" "\$@"
        fi
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
    kittySessionCommit
    kittySessionSave
    kittyCopyUnwrap
    claudeKittyPaneRecord
    kittyPanesReflow
    # WIP, not yet wired in (see wrapper above):
    kittyPaneAdd
    kittyRestoreSession
    # Used by the ctrl+shift+c copy-strip bind below. `kitten clipboard`
    # opens /dev/tty to push via OSC 52; `pass_selection_to_program`
    # runs its child without a controlling terminal, so that path fails
    # silently ("Error: open /dev/tty: no such device or address"). xclip
    # writes to the X11 CLIPBOARD selection without needing a TTY.
    pkgs.xclip
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
    # Kitty appends `-{pid}` to this path on EVERY launch, not only under
    # `-1` (measured 2026-09-04: a plain `kitty --config` with
    # `listen_on unix:/tmp/kreflow2-sock` created
    # `/tmp/kreflow2-sock-2094322`). Nothing may assume the bare path
    # exists; the save script globs `/tmp/kitty.sock-*` to find the live
    # one, and kitty exports the resolved path as KITTY_LISTEN_ON.
    allow_remote_control yes
    listen_on unix:/tmp/kitty.sock

    # Splits layout enables hsplit/vsplit launch locations
    enabled_layouts splits,stack

    # Suppress "are you sure you want to close this OS window?"
    # confirmation when closing windows via UI/shortcut.
    confirm_os_window_close 0

    # Watch kitty.conf for direct in-place edits. Empirically (vm-kitty
    # auto-reload behavioral test) this directive does NOT fire on
    # home-manager's symlink-target swap — kitty resolves the symlink
    # at startup and watches the resolved inode in /nix/store, which
    # is immutable. The HM activation path is handled separately by
    # the `kittyReloadConfig` activation hook below. Keeping the
    # directive anyway covers the direct-edit case (e.g. user fiddling
    # with kitty.conf out-of-band for prototyping).
    #
    # NOT a boolean. kitty 0.48 retyped this option from bool to float:
    # the value is the debounce delay in SECONDS before a changed config
    # is re-read, and a NEGATIVE value disables auto-reload. The old
    # `yes` spelling no longer parses, and kitty reports config errors
    # by popping an `Errors parsing configuration` overlay window rather
    # than by failing to start — so the breakage is invisible to every
    # liveness check and just quietly adds a window. 0.1 is upstream's
    # default; set explicitly so the intent survives future retypings.
    auto_reload_config 0.1

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
    # Plain vsplit of the focused pane — no grid logic, just side-by-side.
    # Use literal `<` (ASCII 0x3C, matches X11 keysym at runtime) rather
    # than `less`: kitty's `dlopen("libxkbcommon.so")` fails on this
    # NixOS build, so named-keysym binds like `ctrl+less` parse-error
    # ("unknown key, ignoring") at config-load and never fire.
    map ctrl+< launch --location=vsplit --cwd=current
    # Add new pane via the 2x2-grid pattern (kitty-pane-add).
    map ctrl+n launch --type=background --cwd=current /etc/profiles/per-user/jonathan/bin/kitty-pane-add
    # Rearrange the panes this kitty ALREADY has into that same grid,
    # re-parenting them rather than respawning them (kitty-panes-reflow).
    # A no-op when the layout is already canonical, so it is safe to
    # fire on a hunch.
    #
    # ctrl+shift+r, not a plain ctrl+<char>: every ctrl+<letter> worth
    # having is a readline binding, and reflow is a rarely-used
    # deliberate gesture rather than a per-minute one like ctrl+n. It
    # is free in kitty 0.48.2 (no default binds it — kitty reloads its
    # config on ctrl+shift+f5) and it does NOT shadow the shell's
    # ctrl+r reverse-i-search, because kitty matches the exact modifier
    # set and passes plain ctrl+r straight through. It also sits in the
    # same ctrl+shift namespace as the copy binds below. `r` is a
    # literal character, so the libxkbcommon problem noted on ctrl+<
    # above does not apply.
    map ctrl+shift+r launch --type=background --cwd=current /etc/profiles/per-user/jonathan/bin/kitty-panes-reflow
    # New tab inheriting cwd of current window.
    map ctrl+t new_tab_with_cwd

    # Copy: pipe selection through kitty-copy-unwrap (see let-binding
    # above) to undo TUI hanging-indent line wraps before xclip.
    # Recovers single-line shell commands that the source TUI
    # (claude-code, less, man, etc.) hard-wrapped for display — pasting
    # the result back into a shell runs the original single command
    # instead of choking on `\n  ` mid-pipeline.
    #
    # Selection is passed as argv[0] (the $0 of `sh -c`). `printf %s`
    # does NOT append a trailing newline. xclip writes to the X11
    # CLIPBOARD selection without a controlling TTY (kitten clipboard /
    # OSC 52 fails under pass_selection_to_program — see comment near
    # `pkgs.xclip` above).
    map ctrl+shift+c pass_selection_to_program sh -c 'printf %s "$0" | kitty-copy-unwrap | xclip -selection clipboard -in'
    # Escape hatch: kitty's built-in copy_to_clipboard, no transform.
    # Use for uniformly-indented multi-line shell bodies (for/do/done,
    # if/then/fi) that the unwrap heuristic would collapse — kitty has
    # no way to distinguish a soft-wrap continuation from a deliberate
    # same-indent code line.
    map ctrl+shift+alt+c copy_to_clipboard

    # Paste: preserve newlines in the paste payload byte-for-byte.
    # `replace-newline` was a destructive hack that rewrote every \n in
    # the paste into a space — broke pasting multi-line shell commands,
    # diffs, code, anything the user expected to land as the bytes they
    # copied. `confirm` keeps kitty's safety prompt for paste payloads
    # carrying control codes (the actual injection risk); `quote-urls-
    # at-prompt` keeps the URL-quoting nicety. Modern shells (zsh+bash
    # with vi/emacs mode) handle bracketed paste correctly — they hold
    # the payload in the buffer without auto-executing, so the
    # safety story is already covered by the shell side.
    paste_actions quote-urls-at-prompt,confirm
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
      # Same binding the collapse guard's grace window is derived from
      # (see "snapshot retention" in the let block above), so the two
      # cannot drift apart.
      OnUnitActiveSec = "${toString saveIntervalSeconds}s";
      AccuracySec = "10s";
    };
    Install.WantedBy = [ "timers.target" ];
  };

  # Send `kitty @ load-config` to every running kitty socket after
  # home-manager finishes activation. Compensates for the fact that
  # `auto_reload_config` (above) does NOT pick up HM's symlink-
  # target swap — kitty's inotify watcher stays bound to the original
  # /nix/store path, which never mutates. Without this hook, every
  # config-change PR (PR #70 ctrl+shift+c xclip fix being the
  # motivating case) lands on disk but doesn't take effect until the
  # user manually restarts kitty.
  #
  # Best-effort: silent no-op when no kitty is running, and a single
  # socket's reload failure does not abort activation. Runs in
  # entryAfter ["linkGeneration"] so it fires after the new
  # kitty.conf symlink target is in place.
  home.activation.kittyReloadConfig =
    lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      for sock in /tmp/kitty.sock-*; do
        [ -S "$sock" ] || continue
        ${pkgs.kitty}/bin/kitty @ --to "unix:$sock" load-config \
          2>/dev/null || true
      done
    '';

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
