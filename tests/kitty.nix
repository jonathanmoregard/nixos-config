# vm-kitty: kitty session save/restore end-to-end.
#
# Catches every silent-fail mode the no-op path masks: socket-path
# mismatches, invalid session-file directives, wrapper-detection bugs,
# and missing --session injection on first launch.
#
# Phases:
#   1. Launch kitty + 3 extra panes (4 total in a 2x2 grid)
#   2. Save snapshot.json + last.session, verify directives valid
#   3. Kill all kitty processes
#   4. Relaunch via wrapper — must auto-inject --session
#   5. Assert restored topology matches (4 windows, cwds, foreground cmdlines)
#
# Uses mkFeatureTest with home/_test-kitty.nix — only home/jonathan.nix
# + home/kitty.nix in the HM closure. Edits to home/cinnamon.nix,
# home/desktop-apps.nix, home/claude-services.nix etc. leave this lane's
# drvPath unchanged.
#
# extraModules: lightdm + autoLogin (need X for the kitty session
# restore phase) and jq/findutils on the system PATH (the testScript
# runs them as root).
#
# Run: nix build .#checks.x86_64-linux.vm-kitty -L
{ pkgs, inputs }:
let
  # Phase A — TUI hanging-indent unwrap regression. Drives the EXACT
  # shell pipeline the ctrl+shift+c binding invokes (see home/kitty.nix),
  # with xclip replaced by a file sink. Reason for file: xclip in the
  # bare-xterm test VM daemonises waiting for a paste-request that
  # never arrives and hangs the pipe-parent indefinitely. xclip is
  # kitty's already-stable primitive — what we changed is the SHELL
  # TRANSFORM (`| kitty-copy-unwrap`), which is fully sink-independent.
  #
  # PAYLOAD below is the VERBATIM mangled clipboard contents from a
  # 2026-05-22 session: a single-line PCI rebind command that the
  # claude-code TUI wrapped across 5 physical rows with a 2-space
  # hanging indent, copied raw with the prior "preserve newlines"
  # binding, pasted into a shell, and exploded into 5 broken sub-
  # commands. EXPECTED is the original single line the AI typed.
  #
  # Fails if the unwrap heuristic regresses: kitten algorithm misdetects K,
  # rstrip dropped, or block join switches from ' '.join to ''.join.
  #
  # Lives outside the testScript so its multi-line payload doesn't
  # fight the Nix `''` indent-strip — the original inline-heredoc form
  # broke the generated test-script with a Python "unexpected indent"
  # lint error because the shebang at column 0 forced strip-width = 0,
  # leaving the surrounding 4-space test-script indent in place.
  testCopyPipeline = pkgs.writeShellScript "vm-kitty-test-copy-pipeline" ''
    set -euo pipefail
    PAYLOAD='sudo sh -c '"'"'echo 0000:00:05.0 > /sys/bus/pci/drivers/intel-ipu6/unbind && sleep 1 && echo
      0000:00:05.0 > /sys/bus/pci/drivers/intel-ipu6/bind && sleep 2 && systemctl reset-failed
      v4l2-relayd-ipu6.service && systemctl restart v4l2-relayd-ipu6.service && sleep 4 &&
      systemctl is-active v4l2-relayd-ipu6.service && journalctl -u v4l2-relayd-ipu6.service
      --since "10 sec ago" --no-pager | tail -10'"'"
    EXPECTED='sudo sh -c '"'"'echo 0000:00:05.0 > /sys/bus/pci/drivers/intel-ipu6/unbind && sleep 1 && echo 0000:00:05.0 > /sys/bus/pci/drivers/intel-ipu6/bind && sleep 2 && systemctl reset-failed v4l2-relayd-ipu6.service && systemctl restart v4l2-relayd-ipu6.service && sleep 4 && systemctl is-active v4l2-relayd-ipu6.service && journalctl -u v4l2-relayd-ipu6.service --since "10 sec ago" --no-pager | tail -10'"'"
    rm -f /tmp/vm-kitty-copy-out
    sh -c 'printf %s "$0" | kitty-copy-unwrap > /tmp/vm-kitty-copy-out' "$PAYLOAD"
    RESULT=$(cat /tmp/vm-kitty-copy-out)
    if [ "$RESULT" != "$EXPECTED" ]; then
      printf 'Phase A FAIL: unwrap pipeline did not recover the original single line\n' >&2
      printf 'payload:  %q\n' "$PAYLOAD" >&2
      printf 'expected: %q\n' "$EXPECTED" >&2
      printf 'got:      %q\n' "$RESULT" >&2
      exit 1
    fi
    # Result must be exactly one line — no embedded newlines.
    LINES=$(printf '%s\n' "$RESULT" | awk 'END { print NR }')
    if [ "$LINES" -ne 1 ]; then
      printf 'Phase A FAIL: unwrap produced %s lines, expected 1\n' "$LINES" >&2
      exit 2
    fi
    # Trailing-newline regression check. The kitten only writes what
    # split/join produced; result must not end with \n. Auto-execute-
    # on-paste safety.
    if [ "$(tail -c1 /tmp/vm-kitty-copy-out | wc -c)" -ne 1 ] || \
       [ "$(tail -c1 /tmp/vm-kitty-copy-out)" = "" ]; then
      printf 'Phase A FAIL: output has trailing newline (would auto-execute on paste)\n' >&2
      exit 3
    fi
    echo "Phase A OK: TUI-wrapped 5-row payload unwrapped to original single line"
  '';

  # Shared by the two behavioural key phases below. Poll, never sleep for a
  # fixed span: every wait in them is for a condition a loaded CI runner can
  # reach late, and a fixed sleep turns late into a flake instead of into a
  # slower pass. $1 = tenths of a second to keep trying; the rest is the
  # condition, re-evaluated on each attempt, so it must arrive as a string
  # `eval` can run and not as an already-expanded value.
  waitForSh = ''
    wait_for() {
      tries=$1
      shift
      n=0
      while [ "$n" -lt "$tries" ]; do
        if eval "$*" >/dev/null 2>&1; then return 0; fi
        sleep 0.1
        n=$((n + 1))
      done
      return 1
    }
  '';

  # Phase A3 — the ctrl+c INTERRUPT, behaviourally. The config probe compares
  # the resolved chain, which catches a reordering or a dropped action but not
  # a kitty release that changes what a chain MEANS: whether the interrupt
  # survives rests entirely on copy_or_noop's return value and on
  # dispatch_action's `if passthrough is not True` protocol, neither of which
  # is config. A terminal that quietly stops interrupting is a worse
  # regression than a missed image paste, and this PR had a behavioural phase
  # only for the cheaper of the two.
  #
  # Deliberately a real X keypress. `kitty @ send-key` does not re-enter the
  # keymap (measured), so it would bypass the binding under test and assert
  # nothing about it.
  interruptObserverPy = pkgs.writeText "vm-kitty-interrupt-observer.py" ''
    """Records whether a real SIGINT arrived, the way any ordinary program
    would see one.

    Deliberately does NOT negotiate the kitty keyboard protocol and does not
    leave canonical mode. ctrl+c has to arrive as the legacy 0x03 byte that
    the pty's line discipline turns into SIGINT for the foreground process
    group, because that is the path every shell and every ordinary program is
    on. Phase A2's observer is raw mode for the mirror-image reason: there the
    keypress must be readable as bytes rather than kill the reader.
    """
    import signal
    import sys
    import time

    out = sys.argv[1]
    ready = sys.argv[2]


    def record(signum, frame):
        with open(out, "w") as f:
            f.write("INTERRUPTED")
        sys.exit(0)


    signal.signal(signal.SIGINT, record)
    with open(out, "w") as f:
        f.write("NOTHING")
    # Written last: the harness waits for this before pressing the key, so a
    # slow interpreter start cannot be mistaken for a swallowed interrupt.
    with open(ready, "w") as f:
        f.write("READY")
    deadline = time.time() + 30.0
    while time.time() < deadline:
        time.sleep(0.1)
  '';

  interruptTest = pkgs.writeShellScript "vm-kitty-interrupt" ''
    set -eu
    PATH=/run/current-system/sw/bin:$PATH
    # Raw binary, for the reason spelled out in pasteDecisionTest below.
    KITTY=${pkgs.kitty}/bin/kitty
    # xdotool is the instrument, not the thing under test, so pin it instead
    # of resolving it from the session's PATH.
    XDOTOOL=${pkgs.xdotool}/bin/xdotool
    sock=unix:/tmp/kitty-interrupt.sock
    res=/tmp/kitty-interrupt.txt
    ready=/tmp/kitty-interrupt.ready
    log=/tmp/kitty-interrupt.log

    ${waitForSh}

    rm -f "$res" "$ready"

    $KITTY -o allow_remote_control=yes --listen-on "$sock" \
      ${pkgs.python3}/bin/python3 ${interruptObserverPy} "$res" "$ready" \
      >"$log" 2>&1 &
    kpid=$!
    trap 'kill $kpid 2>/dev/null || true' EXIT

    if ! wait_for 600 "$KITTY @ --to $sock ls"; then
      echo "FAIL: test kitty never opened its socket" >&2
      cat "$log" >&2 || true
      exit 1
    fi
    if ! wait_for 300 "grep -qx READY $ready"; then
      echo "FAIL: the SIGINT observer never started in the pane" >&2
      cat "$log" >&2 || true
      exit 1
    fi

    # XTEST delivers to the FOCUSED window, so focus has to be established
    # and then CHECKED rather than assumed. Only this one kitty is running at
    # this point in the lane -- Phase A2 waits for its own instances to exit
    # and the session phases start later -- so one match is expected, and more
    # than one would make the keypress ambiguous.
    wid=$($XDOTOOL search --onlyvisible --class kitty || true)
    matches=$(printf '%s\n' "$wid" | grep -c . || true)
    if [ "$matches" -ne 1 ]; then
      echo "FAIL: expected exactly 1 kitty window to focus, found $matches" >&2
      exit 1
    fi
    # windowactivate needs a window manager advertising _NET_ACTIVE_WINDOW.
    # Measured on a bare X server it prints "claims not to support
    # _NET_ACTIVE_WINDOW" and exits 1, which under `set -e` would abort this
    # phase with no message of its own. windowfocus (XSetInputFocus) needs no
    # WM, so fall back to it, and then confirm focus instead of trusting
    # either call -- a keypress sent to the wrong window would read as a
    # missing interrupt.
    $XDOTOOL windowactivate --sync "$wid" 2>/dev/null \
      || $XDOTOOL windowfocus --sync "$wid" 2>/dev/null \
      || true
    focused=$($XDOTOOL getwindowfocus 2>/dev/null || echo none)
    if [ "$focused" != "$wid" ]; then
      echo "FAIL: could not focus the test window ($focused != $wid), so the" \
           "keypress would have gone somewhere other than the pane" >&2
      exit 1
    fi
    $XDOTOOL key ctrl+c

    if ! wait_for 100 "grep -qx INTERRUPTED $res"; then
      echo "FAIL: ctrl+c with nothing selected did not reach the program," \
           "so the interrupt is gone" >&2
      echo "  observed: $(cat "$res" 2>/dev/null || echo '<no result file>')" >&2
      cat "$log" >&2 || true
      exit 1
    fi
    echo "PASS ctrl+c with nothing selected still interrupts the program"
  '';

  # Phase A2 — the ctrl+v DECISION, behaviourally. The config assertions in
  # configParseProbe prove the binding points at a runnable decider; they say
  # nothing about which way it decides. Without this, an edit to the script's
  # TARGETS predicate could invert image and text and CI would stay green.
  #
  # Drives the decider exactly as kitty does -- `launch --type=background
  # --allow-remote-control`, so it gets the same per-launch fd channel -- and
  # observes the result in the pane with a raw-mode reader that has itself
  # negotiated the kitty keyboard protocol, which is what claude-code does.
  # A delivered keypress therefore arrives as the bytes \x1b[118;5u and a
  # paste as the token: one channel, two unambiguous outcomes.
  #
  # The observer is NOT `cat -v`, which was the first attempt and failed for
  # an instructive reason: `cat` leaves the tty in canonical mode, where the
  # line discipline claims ctrl+V as VLNEXT (literal-next) and consumes it
  # before any program can see it. The pane showed ^] and no ^V. Measuring a
  # ctrl+v delivery requires a reader that has taken the terminal out of
  # canonical mode, which is also the only configuration the real consumer
  # ever runs in.
  #
  # Its own kitty instance on its own socket, started and stopped here, so it
  # cannot disturb the session save/restore phases that follow (they glob
  # /tmp/kitty.sock-* and count windows).
  #
  # On xclip: an earlier draft of this lane abandoned clipboard automation
  # because "xclip daemonises waiting forever". That is true when xclip is a
  # SINK being read back, which is why Phase A uses a file instead. As a
  # clipboard OWNER the daemonising is the point -- it is what serves the
  # selection to kitty -- so it is backgrounded here deliberately.
  pasteObserverPy = pkgs.writeText "vm-kitty-paste-observer.py" ''
    """Raw-mode reader that records what the pane actually receives.

    Negotiates the kitty keyboard protocol with the disambiguate flag, the
    way claude-code does, then records every byte for a bounded window. Raw
    mode is essential and not incidental: in canonical mode the tty line
    discipline claims ctrl+V as VLNEXT and the keypress never reaches the
    program at all.
    """
    import os
    import select
    import sys
    import termios
    import time
    import tty

    out = sys.argv[1]
    fd = sys.stdin.fileno()
    saved = termios.tcgetattr(fd)
    buf = b""
    with open(out, "w") as f:
        f.write("NOTHING")
    try:
        tty.setraw(fd)
        sys.stdout.write("\x1b[>1u")
        sys.stdout.flush()
        deadline = time.time() + 20.0
        while time.time() < deadline:
            ready, _, _ = select.select([fd], [], [], 0.2)
            if not ready:
                continue
            data = os.read(fd, 4096)
            if not data:
                break
            buf += data
            with open(out, "w") as f:
                f.write(repr(buf))
    finally:
        sys.stdout.write("\x1b[<u")
        sys.stdout.flush()
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)
        with open(out, "w") as f:
            f.write(repr(buf) if buf else "NOTHING")
  '';

  pasteDecisionTest = pkgs.writeShellScript "vm-kitty-paste-decision" ''
    set -eu
    PATH=/run/current-system/sw/bin:$PATH
    PNG=/tmp/paste-decision.png
    TOKEN=PASTEDECISIONTOKEN
    # The raw binary, never a bare `kitty`. On the deployed PATH that name is
    # the session-restoring wrapper from home/kitty.nix (see configParseProbe
    # below), and every path through it that opens a terminal ends in
    # `exec kitty -1`. Under single-instance a second invocation hands its
    # arguments to the first instance and exits, so --listen-on would never
    # open a socket and the case would fail as "never opened its socket" --
    # for reasons depending only on what else happened to be running. The
    # wrapper does pass `kitty @` through untouched, so those calls were
    # never at risk, but there is no reason to depend on that here.
    KITTY=${pkgs.kitty}/bin/kitty

    ${waitForSh}

    # Only ever the clipboard owner this script started. `pkill -f 'xclip
    # -selection clipboard'` would also reap an owner belonging to the user's
    # own session -- harmless in a disposable VM, wrong as a habit, and the
    # pid costs nothing to keep.
    owner=""
    stop_owner() {
      [ -n "$owner" ] || return 0
      kill "$owner" 2>/dev/null || true
      wait_for 50 "! kill -0 $owner 2>/dev/null" || true
      owner=""
    }
    trap stop_owner EXIT

    decider=$(command -v kitty-paste-smart || true)
    if [ -z "$decider" ]; then
      echo "FAIL: kitty-paste-smart is not on the deployed PATH" >&2
      exit 1
    fi
    echo "decider: $decider"

    # A real 1x1 PNG, so an image clipboard is an image and not a guess.
    printf '%s' \
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==' \
      | base64 -d > "$PNG"

    # One kitty per case, each on its own socket with a fresh observer, so a
    # case cannot read bytes left over from the previous one and none of them
    # disturb the session phases that follow.
    probe_case() {
      # $1 = case name, $2 = clipboard setup command, $3 = condition that
      # proves the clipboard is really serving what this case needs before a
      # decision is asked for. Per-case rather than one shared predicate: the
      # text case checks the served CONTENT, so it cannot pass by agreeing
      # with the same TARGETS reasoning the decider under test uses.
      name=$1
      setup=$2
      ready=$3
      sock=unix:/tmp/paste-decision-$name.sock
      res=/tmp/paste-decision-$name.txt
      log=/tmp/paste-decision-$name.log

      stop_owner
      # Both halves of this line are load-bearing, and neither is obvious.
      #
      # The redirect: xclip as a clipboard owner never exits, so if it
      # inherits a pipe it holds that pipe open forever -- the hang Phase A's
      # comment above describes, and which this function reproduced when its
      # result was read through a command substitution. The result therefore
      # travels by file and the daemon gets no pipe.
      #
      # The `&` INSIDE the eval'd string: written `eval "$setup" &` instead,
      # the `&` backgrounds the eval builtin, so $! is the pid of the subshell
      # eval forks and xclip is its child. Killing that pid then leaves the
      # real clipboard owner alive to fight the next case for the selection --
      # measured, and strictly worse than the `pkill -f` this replaced. With
      # the `&` inside, eval runs in this shell and $! is the pipeline's last
      # element, which is xclip itself.
      eval "$setup >/dev/null 2>&1 &"
      owner=$!
      if ! wait_for 100 "$ready"; then
        echo "FAIL: $name: clipboard never served the case's own payload" >&2
        return 1
      fi

      $KITTY -o allow_remote_control=yes --listen-on "$sock" \
        ${pkgs.python3}/bin/python3 ${pasteObserverPy} "$res" \
        >"$log" 2>&1 &
      kpid=$!
      if ! wait_for 600 "$KITTY @ --to $sock ls"; then
        echo "FAIL: $name: test kitty never opened its socket" >&2
        cat "$log" >&2 || true
        kill $kpid 2>/dev/null || true
        return 1
      fi

      # >/dev/null: `launch` prints the new window id, and a background launch
      # has none, so it otherwise prints a bare 0 into the lane's output.
      $KITTY @ --to "$sock" launch --type=background \
        --allow-remote-control "$decider" >/dev/null

      # The observer writes NOTHING before it reads anything and overwrites
      # that with repr(buf) on the first byte, so "no longer NOTHING" is
      # exactly "something arrived". A timeout here is NOT failed on: the
      # per-case assertion below can tell "nothing arrived" from "the wrong
      # thing arrived" and says which, which is the more useful message.
      wait_for 100 "! grep -qx NOTHING $res" || true

      kill $kpid 2>/dev/null || true
      wait $kpid 2>/dev/null || true
    }

    rc=0

    echo "--- image case"
    probe_case image \
      "xclip -selection clipboard -t image/png -i $PNG" \
      "xclip -selection clipboard -t TARGETS -o | grep -qx image/png" || rc=1
    got=$(cat /tmp/paste-decision-image.txt 2>/dev/null || true)
    echo "    observed: $got"
    case $got in
      *'118;5u'*)
        echo "PASS image clipboard -> real keypress handed to the application" ;;
      *"$TOKEN"*)
        echo "FAIL: image clipboard pasted text instead of handing over the key" >&2
        rc=1 ;;
      *)
        echo "FAIL: image clipboard delivered neither the key nor a paste" >&2
        rc=1 ;;
    esac

    echo "--- text case"
    probe_case text \
      "printf '%s' $TOKEN | xclip -selection clipboard -i" \
      "xclip -selection clipboard -o | grep -qx $TOKEN" || rc=1
    got=$(cat /tmp/paste-decision-text.txt 2>/dev/null || true)
    echo "    observed: $got"
    case $got in
      *"$TOKEN"*)
        echo "PASS text clipboard -> pasted the text" ;;
      *'118;5u'*)
        echo "FAIL: text clipboard handed over the key instead of pasting" >&2
        rc=1 ;;
      *)
        echo "FAIL: text clipboard delivered neither a paste nor the key" >&2
        rc=1 ;;
    esac

    exit $rc
  '';

  # Config-parse probe, run through `kitty +runpy` so the check uses
  # kitty's OWN loader (and therefore the deployed kitty version's
  # notion of every option's type) rather than a reimplementation.
  #
  # MUST call the raw kitty binary, as pasteDecisionTest above also does.
  # `/etc/profiles/per-user/jonathan/bin/kitty` is the session-restoring bash
  # wrapper from home/kitty.nix; handed `+runpy` it does not pass the argument
  # through — it proceeds to open a terminal and blocks until the 3600s test
  # timeout.
  configParseProbe = pkgs.writeShellScript "vm-kitty-config-parse-probe" ''
    set -euo pipefail
    # Bounded so a future hang fails the lane in a minute with a clear
    # rc=124 instead of burning the whole test timeout.
    exec ${pkgs.coreutils}/bin/timeout 60 \
      ${pkgs.kitty}/bin/kitty +runpy "$(cat ${configParseProbePy})"
  '';

  # Kept in a writeText and passed as `"$(cat …)"` rather than inlined:
  # Python is indentation-sensitive and an embedded multi-line block
  # fights the surrounding `''` indent-strip — the same trap documented
  # above testCopyPipeline. The config path arrives via $KITTY_CONF to
  # keep the shell quoting flat.
  configParseProbePy = pkgs.writeText "vm-kitty-config-parse-probe.py" ''
    import os
    import sys

    from kitty.config import load_config
    from kitty.options.utils import parse_shortcut
    from kitty.keys import get_shortcut
    from kitty.boss import Boss
    from kitty.tabs import Tab
    from kitty.window import Window
    from kitty.fast_data_types import (
        KeyEvent,
        GLFW_MOD_CONTROL,
        GLFW_MOD_SHIFT,
    )

    bad = []
    opts = load_config(os.environ["KITTY_CONF"], accumulate_bad_lines=bad)
    for b in bad:
        print(
            f"kitty.conf line {b.number}: {b.line!r} -> {b.exception}",
            file=sys.stderr,
        )
    if bad:
        print(
            f"FAIL: kitty rejected {len(bad)} config line(s). kitty starts "
            "anyway and shows an error overlay window, so this would "
            "otherwise only surface as an off-by-N window count.",
            file=sys.stderr,
        )
        sys.exit(1)
    print("config parses clean under the deployed kitty")

    # Asserted against the keymap kitty builds, not by grepping
    # kitty.conf: a `map` line can parse to "unknown key, ignoring" and
    # never fire, which is how `ctrl+less` died on this build. Last entry
    # per key wins, since user binds append to kitty's defaults.
    keymap = opts.keyboard_modes[""].keymap

    # No helper function anywhere below: `kitty +runpy` exec()s this
    # inside a function frame, so these names are frame locals with no
    # closure cells and a nested def would NameError at call time.
    PANE_FOCUS = {
        "ctrl+shift+up": "neighboring_window up",
        "ctrl+shift+down": "neighboring_window down",
        "ctrl+shift+left": "neighboring_window left",
        "ctrl+shift+right": "neighboring_window right",
    }
    # Must reach the shell: zsh binds these to word movement.
    MUST_FALL_THROUGH = ("ctrl+left", "ctrl+right", "ctrl+up", "ctrl+down")
    ZOOM_STEPS = (
        "ctrl+shift+equal",
        "ctrl+shift+plus",
        "ctrl+shift+kp_add",
        "ctrl+shift+minus",
        "ctrl+shift+kp_subtract",
    )
    ZOOM_RESET = "ctrl+shift+backspace"
    # Kitty's own defaults, not declared anywhere in home/kitty.nix.
    # Asserted because ctrl+shift+left/right took pane focus, leaving
    # these the only route to either action.
    TAB_NAV = {
        "ctrl+tab": "next_tab",
        "ctrl+shift+tab": "previous_tab",
    }
    VSPLIT = "launch --location=vsplit --cwd=current"
    VSPLIT_KEYS = ("ctrl+<", "ctrl+*")
    # The se keypress that produces `*`. Dispatched for real further
    # down, because ctrl+* matches only via kitty's shifted fallback and
    # a bind on the exact ctrl+shift+' would starve it while the bind
    # itself still looked correct.
    STAR_EVENT_KEY = ord("'")
    STAR_EVENT_SHIFTED = ord("*")

    eff = {}
    for spec in (
        list(PANE_FOCUS) + list(MUST_FALL_THROUGH) + list(ZOOM_STEPS)
        + list(VSPLIT_KEYS) + list(TAB_NAV) + [ZOOM_RESET]
    ):
        defs = keymap.get(parse_shortcut(spec))
        eff[spec] = defs[-1].definition if defs else None

    errors = []

    for spec, want in PANE_FOCUS.items():
        got = eff[spec]
        if got is None:
            errors.append(f"{spec}: NOT BOUND (want {want!r})")
        elif got != want:
            errors.append(f"{spec}: resolves to {got!r}, want {want!r}")

    for spec in MUST_FALL_THROUGH:
        got = eff[spec]
        if got is not None:
            errors.append(
                f"{spec}: bound to {got!r}; must stay UNBOUND so the "
                "ctrl-arrow CSI sequence reaches the shell (zsh word movement)"
            )

    for spec in ZOOM_STEPS:
        got = eff[spec]
        if got is None:
            errors.append(
                f"{spec}: absent from keymap -- its `no_op` line did not parse"
            )
        elif got != "":
            errors.append(
                f"{spec}: resolves to {got!r}, want no_op (font zoom disabled)"
            )

    if eff[ZOOM_RESET] != "change_font_size all 0":
        errors.append(
            f"{ZOOM_RESET}: resolves to {eff[ZOOM_RESET]!r}, want "
            "'change_font_size all 0' -- reset must stay bound as the "
            "font-size recovery path"
        )

    for spec, want in TAB_NAV.items():
        got = eff[spec]
        if got is None:
            errors.append(
                f"{spec}: NOT BOUND (want {want!r}) -- this is kitty's own "
                "default, and since ctrl+shift+left/right took pane focus "
                f"it is the ONLY remaining way to reach {want}"
            )
        elif got != want:
            errors.append(f"{spec}: resolves to {got!r}, want {want!r}")

    for spec in VSPLIT_KEYS:
        got = eff[spec]
        if got is None:
            errors.append(f"{spec}: NOT BOUND (want {VSPLIT!r})")
        elif got != VSPLIT:
            errors.append(f"{spec}: resolves to {got!r}, want {VSPLIT!r}")

    # The keypress, not the bind: see STAR_EVENT_* above.
    star_ev = KeyEvent(
        key=STAR_EVENT_KEY,
        shifted_key=STAR_EVENT_SHIFTED,
        mods=GLFW_MOD_CONTROL | GLFW_MOD_SHIFT,
    )
    star_hit = get_shortcut(keymap, star_ev)
    star_got = star_hit[-1].definition if star_hit else None
    if star_got != VSPLIT:
        errors.append(
            "pressing ctrl+shift+' (what types ctrl+* on the se layout) "
            f"dispatches to {star_got!r}, want {VSPLIT!r}. The bind can be "
            "present and still never fire: it matches only via kitty's "
            "shifted fallback, which is skipped when anything claims the "
            "exact ctrl+shift+' first"
        )

    # Resolved into actions, not compared as a definition string: kitty
    # accepts an unknown action name without complaining. The line parses,
    # `bad` stays empty, and only at dispatch does getattr come up empty
    # and the key get swallowed -- a typo inside the ctrl+c chain would
    # cost the interrupt with nothing anywhere reporting it.
    CTRL_C_CHAIN = (
        "copy_or_noop",
        "pass_selection_to_program",
        "clear_selection",
    )
    CTRL_V_CHAIN = ("launch",)

    resolved = {}
    for spec in ("ctrl+c", "ctrl+shift+c", "ctrl+v"):
        defs = keymap.get(parse_shortcut(spec))
        if not defs:
            errors.append(f"{spec}: NOT BOUND")
            continue
        try:
            acts = opts.alias_map.resolve_aliases(defs[-1].definition, "map")
        except Exception as exc:
            # A bare unknown action name gets through kitty's own loader --
            # `bad` stays empty and it prints that the config parses clean --
            # and raises only here, when something actually resolves it.
            # Caught rather than left to propagate: the lane fails either
            # way, but a traceback does not say which key lost its binding.
            errors.append(
                f"{spec}: definition {defs[-1].definition!r} does not "
                f"resolve ({exc}), so the key is silently swallowed"
            )
            continue
        resolved[spec] = acts
        for a in acts:
            live = False
            if hasattr(Boss, a.func):
                live = True
            if hasattr(Tab, a.func):
                live = True
            if hasattr(Window, a.func):
                live = True
            if not live:
                errors.append(
                    f"{spec}: no such action as {a.func!r}, so the key is "
                    "silently swallowed -- the config parses clean and "
                    "kitty reports nothing"
                )

    funcs = {}
    for spec in resolved:
        chain = []
        for a in resolved[spec]:
            chain.append(a.func)
        funcs[spec] = tuple(chain)

    if "ctrl+c" in funcs and funcs["ctrl+c"] != CTRL_C_CHAIN:
        errors.append(
            f"ctrl+c resolves to {funcs['ctrl+c']}, want {CTRL_C_CHAIN} -- "
            "without copy_or_noop first the key never reaches the "
            "application and nothing interrupts, and without "
            "clear_selection a stale selection swallows every further "
            "interrupt"
        )
    if "ctrl+v" in funcs and funcs["ctrl+v"] != CTRL_V_CHAIN:
        errors.append(
            f"ctrl+v resolves to {funcs['ctrl+v']}, want {CTRL_V_CHAIN} -- "
            "paste_from_clipboard alone reads text/plain only, so an "
            "image-only clipboard pastes nothing and the application never "
            "sees the key either"
        )

    # The launch has to carry both flags and point at something runnable.
    # None of this is cosmetic: a launch whose target is missing or merely
    # not executable swallows the keypress and reports NOTHING anywhere --
    # measured, by shipping exactly that mistake into this harness. And
    # without --allow-remote-control the script gets no KITTY_LISTEN_ON, so
    # it cannot reach the kitty that launched it and the paste silently
    # does nothing.
    v_args = []
    for a in resolved.get("ctrl+v") or ():
        if a.func == "launch":
            v_args = list(a.args)
    if "ctrl+v" in funcs:
        if "--type=background" not in v_args:
            errors.append(
                f"ctrl+v launch lacks --type=background: {v_args!r} -- any "
                "other type opens a window on every paste"
            )
        if "--allow-remote-control" not in v_args:
            errors.append(
                f"ctrl+v launch lacks --allow-remote-control: {v_args!r} -- "
                "without it the script has no channel back to its own kitty "
                "and every paste is a silent no-op"
            )
        prog = v_args[-1] if v_args else ""
        if not prog.startswith("/"):
            errors.append(
                f"ctrl+v launch target {prog!r} is not an absolute path"
            )
        elif not os.path.exists(prog):
            errors.append(
                f"ctrl+v launch target {prog} does not exist, so the key is "
                "swallowed with no error anywhere"
            )
        elif not os.access(prog, os.X_OK):
            errors.append(
                f"ctrl+v launch target {prog} is not executable, so the key "
                "is swallowed with no error anywhere"
            )

    # Same pipeline on both keys, asserted by comparing them rather than
    # by restating it: ctrl+c must put the unwrapped text on the clipboard,
    # not the raw selection copy_or_noop leaves there first.
    cc_args = None
    for a in resolved.get("ctrl+c") or ():
        if a.func == "pass_selection_to_program":
            cc_args = a.args
    cs_args = None
    for a in resolved.get("ctrl+shift+c") or ():
        if a.func == "pass_selection_to_program":
            cs_args = a.args
    if cs_args is None:
        errors.append(
            "ctrl+shift+c no longer runs pass_selection_to_program, so the "
            "unwrap filter is gone"
        )
    elif cc_args != cs_args:
        errors.append(
            f"ctrl+c pipes the selection through {cc_args!r} but "
            f"ctrl+shift+c uses {cs_args!r} -- the two copy keys would put "
            "different text on the clipboard"
        )

    if errors:
        for e in errors:
            print("FAIL: " + e, file=sys.stderr)
        sys.exit(1)
    print(
        "keymap correct: kitty_mod+arrows move pane focus, ctrl+tab and "
        "ctrl+shift+tab still switch tabs, plain ctrl+arrows free for the "
        "shell, font-zoom steps disabled, reset still reachable, both "
        "ctrl+< and ctrl+* vsplit -- the latter checked by dispatching a "
        "real ctrl+shift+' keypress -- and ctrl+c / ctrl+v copy and paste "
        "through dispatchable actions, ctrl+c keeping its interrupt and "
        "ctrl+v launching an executable decider that can reach its own kitty"
    )
  '';

  # A real long-lived foreground process named `codex`. A shell wrapper
  # would make kitty report its child (`sleep`) instead, weakening the
  # restore-settlement assertion into an argv fixture rather than behavior.
  testCodex = pkgs.writeCBin "codex" ''
    #include <signal.h>
    #include <unistd.h>

    int main(void) {
      for (;;) pause();
    }
  '';

  # Headless subagent stand-in. Its basename and real argv reproduce the
  # proposal scorer that inherited the interactive Codex pane's PTY.
  testClaude = pkgs.writeCBin "claude" ''
    #include <signal.h>
    #include <unistd.h>

    int main(void) {
      for (;;) pause();
    }
  '';

  # Keep this parent shell alive while its foreground Codex child runs. The
  # background Claude child is forked first, giving live `kitty @ ls` the
  # observed order: headless Claude before root Codex in one pane.
  testMixedAgentPane = pkgs.writeShellScriptBin "mixed-agent-pane" ''
    set -eu
    ${testClaude}/bin/claude \
      --model haiku --max-turns 20 --print score-proposals &
    claude_pid=$!
    trap 'kill "$claude_pid" 2>/dev/null || true' EXIT
    ${testCodex}/bin/codex resume "$1"
  '';
in
(import ./lib/common.nix { inherit pkgs inputs; }).mkFeatureTest {
  name = "vm-kitty";
  hm = ../home/_test-kitty.nix;
  extraModules = [
    ({ pkgs, ... }: {
      services.xserver = {
        enable = true;
        displayManager.lightdm.enable = true;
        # Bare xterm session (no Cinnamon, no full WM) — kitty just needs
        # a DISPLAY to attach to. Registers `none+xterm` as a session.
        desktopManager.xterm.enable = true;
      };
      services.displayManager.autoLogin = {
        enable = true;
        user = "jonathan";
      };
      services.displayManager.defaultSession = "xterm";
      environment.systemPackages = with pkgs; [ jq findutils testCodex ];
    })
  ];
  testScript = ''
    import json
    import shlex

    workstation.wait_for_unit("multi-user.target")
    workstation.wait_for_unit("home-manager-jonathan.service")
    workstation.wait_for_unit("default.target", "jonathan")

    # Copy + paste config: BOTH must preserve embedded newlines so a
    # multi-line shell command or code block copied out of kitty
    # round-trips byte-for-byte through the X11 clipboard. The earlier
    # design (PR #70, `tr -d "\n"` on copy + `paste_actions
    # replace-newline` on paste) had each half independently flattening
    # newlines; the combined effect was that "any multi-line selection
    # came out as a single line", which broke ordinary cmd-line use.
    kitty_conf = "/home/jonathan/.config/kitty/kitty.conf"
    # Regression guard: the `tr -d` step that mangled the copy is GONE
    # from the BINDING (not the surrounding docstring — the new
    # comment explicitly mentions `tr -d` to explain why it was
    # removed, so a bare `grep tr -d` would false-positive on the
    # comment line).
    workstation.fail(
        f"grep -qE '^map ctrl\\+shift\\+c.*tr -d' {kitty_conf}"
    )
    # Regression guard: paste_actions no longer contains replace-newline.
    workstation.fail(
        f"grep -qE '^paste_actions .*replace-newline' {kitty_conf}"
    )
    # Safety invariant: paste_actions keeps the confirm prompt for
    # control-code-containing payloads.
    workstation.succeed(
        f"grep -qE '^paste_actions .*confirm' {kitty_conf}"
    )

    # Whole-config parse guard. kitty does NOT fail to start on a bad
    # directive — it starts fine and pops an `Errors parsing
    # configuration` OVERLAY WINDOW instead. That is invisible to every
    # liveness assertion above, and the only downstream symptom is an
    # inflated window count, which surfaces three phases later as an
    # inscrutable `length == 4` timeout. (Exactly how the 0.48
    # auto_reload_config retyping presented: 4 real panes + 3 error
    # windows = 7.) Ask kitty's own config loader instead, and name the
    # offending line.
    workstation.succeed(
        f"su jonathan -c 'KITTY_CONF={kitty_conf} ${configParseProbe}'"
    )

    # Persistence timer is enabled, active, and scheduled. Fresh-home VM boot
    # has one test-only race: lingering can start the user manager and reach
    # timers.target while HM is still linking user units; HM then observes no
    # usable manager bus and skips its reload. Production activation runs
    # against an established user manager. Converge those two test fixtures
    # explicitly, after asserting the generated enablement link exists.
    user_systemctl = "systemctl --machine=jonathan@.host --user"
    workstation.succeed(
        f"{user_systemctl} is-enabled --quiet kitty-session-save.timer"
    )
    workstation.succeed(f"{user_systemctl} daemon-reload")
    workstation.succeed(f"{user_systemctl} start kitty-session-save.timer")
    workstation.succeed(
        f"{user_systemctl} is-active --quiet kitty-session-save.timer"
    )

    # Save script no-ops cleanly when no kitty is running
    workstation.succeed("su - jonathan -c kitty-session-save")
    workstation.succeed("test -d /home/jonathan/.cache/kitty-session")
    workstation.fail("test -f /home/jonathan/.cache/kitty-session/snapshot.json")

    # Convert script processes empty JSON array → empty session file
    workstation.succeed(
        "su - jonathan -c 'printf %s \"[]\" | kitty-session-convert > /tmp/empty.session'"
    )

    # === Positive-path e2e: full save → kill → restore cycle ===
    workstation.wait_for_x()

    # === Multi-line copy round-trip (Phase A — shell pipeline) ===
    # Drives the EXACT shell command that ctrl+shift+c invokes,
    # passing a known multi-line string as $0 (the same way kitty's
    # `pass_selection_to_program` does), and reads xclip back. Asserts
    # byte-for-byte equality. Skips mouse-selection automation
    # (would need pixel-accurate xdotool drag + font-metric awareness
    # — brittle).
    #
    # If this fails: someone reintroduced a transform (e.g. `tr -d`,
    # `awk`-strip, sed) into the ctrl+shift+c binding.
    #
    # The script body lives in `testCopyPipeline` (writeShellScript)
    # outside this testScript string so its multi-line payload doesn't
    # fight Nix's indent-strip on the surrounding raw-string block.
    workstation.succeed(
        "su jonathan -c 'DISPLAY=:0 ${testCopyPipeline}'"
    )

    # === ctrl+v decision (Phase A2 — which way the decider decides) ===
    # The config probe proves ctrl+v launches a runnable decider. This proves
    # it decides correctly: an image clipboard must hand the real keypress to
    # the application (only the application can paste an image — claude-code's
    # chat:imagePaste reads the clipboard itself), and a text clipboard must
    # paste the text. Inverting those two would leave the config probe green.
    print("[paste-decision]\n" + workstation.succeed(
        "su jonathan -c 'DISPLAY=:0 ${pasteDecisionTest}'"
    ))

    # === ctrl+c interrupt (Phase A3 — the key still reaches the program) ===
    # Claiming ctrl+c for copy is the riskiest half of this binding: a
    # terminal that silently stops interrupting is worse than one that misses
    # an image paste. The chain comparison in the config probe cannot see
    # this, because whether the interrupt survives depends on copy_or_noop's
    # return value and kitty's passthrough protocol, not on the config.
    print("[interrupt]\n" + workstation.succeed(
        "su jonathan -c 'DISPLAY=:0 ${interruptTest}'"
    ))

    # Helper: glob discovers the live socket regardless of kitty's PID.
    sock_cmd = (
        'sock=$(find /tmp -maxdepth 1 -name "kitty.sock-*" -type s '
        '2>/dev/null | head -1); '
        '[ -n "$sock" ] && kitty @ --to unix:$sock'
    )

    # --- Phase 1: bring up kitty + 3 extra windows, each with a distinct
    # cwd and a distinct long-running command. The default first window
    # holds the user's shell. We end with 4 windows total. ---
    workstation.succeed(
        "su jonathan -c 'DISPLAY=:0 nohup kitty -1 --detach "
        ">/tmp/kitty-launch.log 2>&1' &"
    )
    # 30s was tight under host load (parallel VM builds, cold caches);
    # 60s gives kitty time to spawn and start its remote-control socket.
    workstation.wait_until_succeeds(
        f"su jonathan -c '{sock_cmd} ls >/dev/null'", timeout=60
    )

    # === kitty config-reload BEHAVIORAL test ===
    # The failure mode being defended: home-manager activation
    # rewrites the kitty.conf SYMLINK target to a new /nix/store path.
    # A running kitty does NOT notice that swap on its own — kitty's
    # `auto_reload_config` inotify watcher binds to the resolved
    # store-path inode at launch, and that inode never mutates.
    # Verified empirically (this exact test, see git history): with
    # only `auto_reload_config` set, a symlink swap + 10s wait shows
    # no foreground-color change in `kitty @ get-colors`.
    #
    # The actual fix is the `home.activation.kittyReloadConfig` hook
    # in home/kitty.nix that runs `kitty @ load-config` on every live
    # kitty socket after `linkGeneration`. This test reproduces that
    # exact command sequence: swap the symlink, then invoke the same
    # for-loop the hook uses, then assert the reload actually fired.
    #
    # Failure of this assertion = the fix is dead in production.
    kitty_conf = "/home/jonathan/.config/kitty/kitty.conf"
    orig_target = workstation.succeed(f"readlink {kitty_conf}").strip()
    # Build a mutated config that mirrors the original plus one
    # observable change. Sentinel color #ff00ff (magenta) is unique
    # vs the deployed palette so stale colors can't masquerade.
    workstation.succeed(
        f"cp -L {kitty_conf} /tmp/kitty-mutated.conf && "
        "chmod u+w /tmp/kitty-mutated.conf && "
        "sed -i 's/^foreground.*$/foreground #ff00ff/' /tmp/kitty-mutated.conf"
    )
    # Atomic symlink swap — same operation home-manager activation performs.
    workstation.succeed(
        f"su jonathan -c 'ln -sfT /tmp/kitty-mutated.conf {kitty_conf}'"
    )
    # Sanity: kitty has not picked up the new color on its own
    # (auto_reload_config does NOT fire on symlink-target swaps).
    # Wait 3s to give any rogue watcher time to misbehave.
    workstation.sleep(3)
    workstation.fail(
        f"su jonathan -c '{sock_cmd} get-colors' | "
        "grep -qE '^foreground[[:space:]]+#?ff00ff'"
    )
    # Now run the activation-hook's exact command sequence. The hook
    # body (see home/kitty.nix `home.activation.kittyReloadConfig`)
    # iterates kitty sockets and runs `kitty @ load-config`. The
    # reload must produce the magenta foreground.
    workstation.succeed(
        "su jonathan -c '"
        "for sock in /tmp/kitty.sock-*; do "
        "  [ -S \"$sock\" ] || continue; "
        "  kitty @ --to \"unix:$sock\" load-config 2>/dev/null || true; "
        "done'"
    )
    # Reload is synchronous to the @ call; a short wait is just paranoia
    # for the test runner's scheduling jitter.
    workstation.wait_until_succeeds(
        f"su jonathan -c '{sock_cmd} get-colors' | "
        "grep -qE '^foreground[[:space:]]+#?ff00ff'",
        timeout=5,
    )
    # Restore original symlink + reload back to canonical colors so
    # subsequent test phases (session save/restore) see the deployed
    # palette. Bidirectional reload proof comes free.
    workstation.succeed(
        f"su jonathan -c 'ln -sfT {orig_target} {kitty_conf}'"
    )
    workstation.succeed(
        "su jonathan -c '"
        "for sock in /tmp/kitty.sock-*; do "
        "  [ -S \"$sock\" ] || continue; "
        "  kitty @ --to \"unix:$sock\" load-config 2>/dev/null || true; "
        "done'"
    )
    workstation.wait_until_succeeds(
        f"su jonathan -c '{sock_cmd} get-colors' | "
        "grep -qE '^foreground[[:space:]]+#?ebebeb'",
        timeout=5,
    )
    # === end kitty config-reload behavioral test ===

    # === Multi-line paste behaviour ===
    # The paste half of the round-trip is fully governed by kitty's
    # `paste_actions` config directive — kitty itself decides whether
    # to transform the paste payload before delivering it to the
    # running shell. We've already asserted (further up in this
    # testScript) that the rendered kitty.conf:
    #   - does NOT contain `paste_actions ... replace-newline`
    #     (the destructive setting that would turn every embedded
    #     \n into a space)
    #   - DOES contain `paste_actions ... confirm`
    #
    # A live-paste round-trip test would add no signal beyond those
    # config assertions: kitty's paste handler is upstream code with
    # its own coverage. An earlier draft of this test exercised the
    # full xclip → xdotool ctrl+shift+v → `kitten @ get-text` path,
    # but xclip in the bare-xterm test VM has no clipboard manager
    # to handshake with and daemonises waiting forever; the resulting
    # X-auth + clipboard-ownership setup churn outweighed the marginal
    # coverage. The deployed paste path is exercised every time the
    # user does ctrl+shift+v on the real desktop — that's the manual
    # verification step the PR description hands them.
    sleep_bin = "/run/current-system/sw/bin/sleep"
    claude_bin = "${testClaude}/bin/claude"
    codex_bin = "${testCodex}/bin/codex"
    mixed_agent_bin = "${testMixedAgentPane}/bin/mixed-agent-pane"
    codex_sid = "77777777-aaaa-4777-8777-777777777777"
    panes = [
        ("/tmp", "11111"),
        ("/var", "22222"),
    ]
    # Set up 4 panes via kitty-pane-add — two ordinary commands plus a real
    # no-hook Codex root sharing its PTY with a headless Claude scorer.
    # Default first window acts as pane 1; 3 additional pane-adds give us
    # 4 total in 2x2.
    for cwd, magic in panes:
        workstation.succeed(
            "su jonathan -c "
            f"'kitty-pane-add --cwd {cwd} -- {sleep_bin} {magic}'"
        )
    workstation.succeed(
        "su jonathan -c "
        f"'kitty-pane-add --cwd /etc -- {mixed_agent_bin} {codex_sid}'"
    )
    workstation.wait_until_succeeds(
        f"su jonathan -c '{sock_cmd} ls' | "
        "jq -e '[.[].tabs[].windows[]] | length == 4'",
        timeout=15,
    )
    # Wait for all 4 windows to register.
    workstation.wait_until_succeeds(
        f"su jonathan -c '{sock_cmd} ls' | "
        "jq -e '[.[].tabs[].windows[]] | length == 4'",
        timeout=15,
    )
    # Pane 0 gets a command of its OWN before the save. Left as the
    # login shell it is byte-identical to what the exec-time refusal
    # opens (`os.environ["SHELL"]`, also
    # /run/current-system/sw/bin/zsh), so phase 5b below could not tell
    # "pane 0 became its recorded command" from "--exec-pane0 refused
    # and handed the user a shell" — and an assertion that cannot tell
    # those apart is not asserting the thing it is named after.
    # `exec` replaces the shell in place, so the window keeps its pid
    # and phase 6's respawn comparison is unaffected.
    pane0_magic = "44444"
    workstation.succeed(
        "su jonathan -c '" + sock_cmd
        + ' send-text --match id:1 "exec ' + sleep_bin + " "
        + pane0_magic + '\\n"' + "'"
    )
    # Sent ONCE: the pty buffers input, so text written before the shell
    # starts reading is not lost. The wait is long because pane 0 holds
    # the FIRST interactive zsh in a cold VM, which pays for compinit
    # and the whole rc chain before it runs anything — measured at 77s
    # on a green run in tests/claude-egress.nix, which warms it for the
    # same reason. A 15s cap timed out here at 16.5s with the text still
    # queued.
    workstation.wait_until_succeeds(
        "su jonathan -c '" + sock_cmd + " ls' | "
        "jq -e '[.[].tabs[].windows[].cmdline | join(\" \")] | "
        'any(. == "' + sleep_bin + " " + pane0_magic + "\")'",
        timeout=300,
    )
    print("[diag] pane 0 after exec:\n" + workstation.succeed(
        "su jonathan -c '" + sock_cmd + " ls' | "
        "jq -c '[.[].tabs[].windows[] | {id, cmdline}]'"
    ))
    workstation.succeed(f"su jonathan -c '{sock_cmd} ls > /tmp/ls-before.json'")
    print("[diag] before save:\n" + workstation.succeed("cat /tmp/ls-before.json"))

    # Empirical precondition: real Kitty discovery, not fixture JSON, must
    # show both agents attached to one PTY and the headless Haiku first.
    # Without this assertion the restore test could pass because the setup
    # failed to reproduce the process order that caused the incident.
    workstation.succeed(
        "jq -e --arg claude '" + claude_bin
        + "' --arg codex '" + codex_bin
        + "' --arg sid '" + codex_sid + "' '"
        "[.[].tabs[].windows[].foreground_processes "
        "| map(.cmdline) as $cmds "
        "| select($cmds[1] == [$claude, \"--model\", \"haiku\", "
        "\"--max-turns\", \"20\", \"--print\", \"score-proposals\"] "
        "and $cmds[2] == [$codex, \"resume\", $sid])] "
        "| length == 1' /tmp/ls-before.json"
    )

    # Model the durable no-hook binding that the restore bootstrap itself
    # must recreate. The live foreground argv selects exactly one window;
    # writing a guessed or cwd-matched ID would let this test pass while the
    # next save silently attached the thread to the wrong pane.
    workstation.succeed(
        "su jonathan -c '"
        + sock_cmd
        + " ls' | jq -r --arg codex '"
        + codex_bin
        + "' --arg sid '"
        + codex_sid
        + "' '[.[].tabs[].windows[] | select("
        + ".foreground_processes[]?.cmdline == [$codex, \"resume\", $sid])"
        + " | .id] | unique | if length == 1 then .[0] else error("
        + "\"expected one live Codex pane\") end' > /tmp/codex-window-id"
    )
    workstation.succeed(
        "su jonathan -c 'wid=$(cat /tmp/codex-window-id); "
        "printf \"%s\\tcodex\\t%s\\t/etc\\t%s\\n\" \"$wid\" "
        f"\"{codex_sid}\" \"$(date +%s)\" > "
        "/home/jonathan/.cache/kitty-session/pane-sessions.tsv'"
    )
    codex_window_id = int(workstation.succeed(
        "cat /tmp/codex-window-id"
    ).strip())

    # --- Phase 2: save. Files must materialize and parse cleanly. ---
    workstation.succeed("su jonathan -c kitty-session-save")
    workstation.succeed("test -s /home/jonathan/.cache/kitty-session/snapshot.json")
    workstation.succeed("test -s /home/jonathan/.cache/kitty-session/last.session")
    workstation.succeed(
        "jq -e --arg sid '" + codex_sid + "' '"
        ".[0].tabs[].windows[] "
        f"| select(.id == {codex_window_id}) "
        "| .codex_session_id == $sid "
        "and (has(\"claude_session_id\") | not)' "
        "/home/jonathan/.cache/kitty-session/snapshot.json"
    )
    print(
        "[diag] saved session:\n"
        + workstation.succeed("cat /home/jonathan/.cache/kitty-session/last.session")
    )
    # Session file must contain valid kitty directives only — every line
    # has to start with one of the known keywords. Catches future bugs
    # like emitting `new_window` (which kitty rejects with "unknown
    # command new_window" and aborts session loading).
    workstation.succeed(
        "awk 'NF && !/^(new_os_window|new_tab|launch|cd|layout|focus|"
        "enabled_layouts|tab_title|os_window_class|os_window_name|"
        "os_window_state|os_window_size)( |$)/ {print; bad=1} "
        "END {exit bad}' /home/jonathan/.cache/kitty-session/last.session"
    )
    # 4 launch directives — one per pane.
    workstation.succeed(
        "test $(grep -c '^launch' "
        "/home/jonathan/.cache/kitty-session/last.session) -eq 4"
    )
    # Each magic sleep arg must appear in the session file (proves the
    # convert script preserves the foreground command, not just titles).
    for _, magic in panes:
        workstation.succeed(
            f"grep -q 'sleep {magic}' "
            "/home/jonathan/.cache/kitty-session/last.session"
        )

    # --- Phase 3: kill kitty. Try graceful close first; many kitty
    # processes ignore SIGKILL when started via --detach, but respond
    # to its own remote-control close-os-window protocol. ---
    print("[diag] ps before kill:\n" + workstation.succeed(
        "ps -u jonathan -o pid,comm,args --no-headers || true"
    ))
    workstation.succeed(
        f"su jonathan -c '{sock_cmd} close-os-window --match=all || true'"
    )
    workstation.sleep(2)
    # Then SIGKILL any stragglers. Comm pattern matches `.kitty-wrapped`
    # (nixpkgs wrap-program prefixes the binary with `.`) and `kitten`.
    workstation.succeed(
        "for _ in 1 2 3 4 5; do "
        "  pids=$(ps -u jonathan -o pid,comm --no-headers | "
        "    awk '$2 ~ /kit/ {print $1}'); "
        "  [ -z \"$pids\" ] && break; "
        "  echo $pids | xargs kill -KILL 2>/dev/null || true; "
        "  sleep 1; "
        "done; true"
    )
    print("[diag] ps after kill:\n" + workstation.succeed(
        "ps -u jonathan -o pid,comm,args --no-headers || true"
    ))
    workstation.succeed("rm -f /tmp/kitty.sock-*")

    # --- Phase 4: relaunch via wrapper — must auto-inject --session.
    # Use shell backgrounding (& + setsid) instead of kitty's --detach,
    # which can spawn an extra default OS window alongside the session. ---
    workstation.succeed(
        "su jonathan -c 'DISPLAY=:0 setsid kitty </dev/null "
        ">/tmp/kitty-relaunch.log 2>&1 &'"
    )
    # Diagnostic dump before the wait — failures at the wait give us
    # nothing to inspect otherwise.
    workstation.sleep(3)
    print("[diag pre-wait] restore.log:\n" + workstation.succeed(
        "cat /tmp/kitty-restore.log 2>&1 || true"
    ))
    print("[diag pre-wait] sockets:\n" + workstation.succeed(
        "find /tmp -maxdepth 1 -name 'kitty.sock-*' 2>&1 || true"
    ))
    workstation.wait_until_succeeds(
        f"su jonathan -c '{sock_cmd} ls >/dev/null'", timeout=30
    )

    # --- Phase 5: capture restored state and assert the full topology
    # (4 windows, expected cwds, expected sleep cmdlines). ---
    # First make sure the socket answers; then capture state; then assert.
    workstation.wait_until_succeeds(
        f"su jonathan -c '{sock_cmd} ls > /tmp/ls-after.json'", timeout=20
    )
    # Give kitty a moment to finish spawning all session-restored windows.
    workstation.sleep(3)
    workstation.succeed(f"su jonathan -c '{sock_cmd} ls > /tmp/ls-after.json'")
    print("[diag] kitty-wrapper.log:\n" + workstation.succeed(
        "cat /tmp/kitty-wrapper.log 2>&1 || true"
    ))
    print("[diag] kitty-restore.log:\n" + workstation.succeed(
        "cat /tmp/kitty-restore.log 2>&1 || true"
    ))
    print("[diag] kitty-relaunch.log:\n" + workstation.succeed(
        "cat /tmp/kitty-relaunch.log 2>&1 || true"
    ))
    print("[diag] ls-after.json:\n" + workstation.succeed("cat /tmp/ls-after.json"))

    # Wait for restore-session to finish injecting all panes (async).
    workstation.wait_until_succeeds(
        f"su jonathan -c '{sock_cmd} ls > /tmp/ls-after.json' && "
        "jq -e '[.[].tabs[].windows[]] | length == 4' /tmp/ls-after.json",
        timeout=30,
    )
    # Successful completion is stricter than terminal settlement: the guard
    # may disappear only after the exact intended Codex argv is foreground.
    restore_guard = (
        "/home/jonathan/.local/state/claude/kitty-restore/restore-incomplete"
    )
    workstation.wait_until_succeeds(
        f"su jonathan -c '{sock_cmd} ls > /tmp/ls-after.json' && "
        "jq -e --arg codex '"
        + codex_bin
        + "' --arg sid '"
        + codex_sid
        + "' '[.[].tabs[].windows[].foreground_processes[]?.cmdline] "
        "| any(. == [$codex, \"resume\", $sid])' /tmp/ls-after.json",
        timeout=30,
    )
    workstation.wait_until_succeeds(f"test ! -e {restore_guard}", timeout=30)

    # A subsequent real save must keep the exact restored thread identity.
    # This is the no-hook regression: process argv alone cannot safely invent
    # which same-cwd Codex thread the pane owns.
    workstation.succeed("su jonathan -c kitty-session-save")
    workstation.succeed(
        "jq -e --arg sid '"
        + codex_sid
        + "' '[.[].tabs[].windows[].codex_session_id?] | any(. == $sid)' "
        "/home/jonathan/.cache/kitty-session/snapshot.json"
    )
    print("[diag] ls-after final:\n" + workstation.succeed("cat /tmp/ls-after.json"))

    # Both ordinary commands must be back, with their cwds. The Codex pane's
    # exact foreground command was asserted above before guard removal.
    for cwd, magic in panes:
        workstation.succeed(
            f"jq -e '[.[].tabs[].windows[].cwd] | any(. == \"{cwd}\")' "
            "/tmp/ls-after.json"
        )
        workstation.succeed(
            "jq -e '[.[].tabs[].windows[].foreground_processes[]?.cmdline | "
            f"join(\" \")] | any(. | endswith(\"sleep {magic}\"))' "
            "/tmp/ls-after.json"
        )

    # 2x2 grid. `groups | length == 4` only says there are four splits,
    # not that they form the 2x2 — four panes in a column pass it too,
    # which is exactly the shape the 2026-09-04 bad restore produced.
    # Pixel geometry really is absent from `kitty @ ls`
    # (kitty/window.py:2272 as_dict has no at_x/at_y), but the split
    # TREE is not: `tabs[].layout_state.pairs` (kitty/tabs.py:1461 ->
    # layout/splits.py:959) is the exact Pair tree. `shp` below erases
    # the leaf ids (which kitty reallocates constantly) and keeps the
    # structure. Note `horizontal` is serialized only when FALSE
    # (splits.py:42-45), hence the has()-test rather than `// true`,
    # which jq would take for the false branch.
    shp = (
        'def shp: if . == null then null '
        'elif type == "object" then '
        '[(if has("horizontal") then .horizontal else true end), '
        '(.one|shp), (.two|shp)] else "pane" end; '
    )
    # Two side-by-side columns, each split top/bottom.
    grid_2x2 = '[true,[false,"pane","pane"],[false,"pane","pane"]]'
    # Two panes side by side — the canonical form for a remainder of 2.
    grid_1x2 = '[true,"pane","pane"]'
    workstation.succeed(
        "jq -e '.[0].tabs[0].layout == \"splits\"' /tmp/ls-after.json"
    )
    workstation.succeed(
        "jq -e '.[0].tabs[0].groups | length == 4' /tmp/ls-after.json"
    )
    workstation.succeed(
        f"jq -e '{shp}.[0].tabs[0].layout_state.pairs | shp == {grid_2x2}' "
        "/tmp/ls-after.json"
    )

    # --- Phase 5b: what a LATER snapshot can record for pane 0.
    #
    # `window.cmdline` is `Child.cmdline` (kitty/child.py:593-598): the
    # live /proc/<pid>/cmdline, falling back to the argv kitty SPAWNED
    # when that process is gone. Pane 0 is spawned as
    # `kitty-restore-session --exec-pane0 <argv...>`, so while it lives
    # the readout is whatever --exec-pane0 became — asserted below — but
    # the moment pane 0's own process dies with the pty still held open
    # (the documented zombie case: claude gone, an orphaned stdio MCP
    # server holding it), kitty answers with that spawn argv instead.
    # While the launch line carried no argv, that fallback WAS the
    # stub's own launch line, so the next snapshot recorded it as pane
    # 0's command and the restore after that exec'd the launcher, which
    # re-read the same record and exec'd it again: a tight loop at 100%
    # CPU with the session gone.
    #
    # The stub is therefore the artifact to assert on — it is what
    # decides the fallback. tests/kitty-scripts.nix phase J drives the
    # dead-process half against the scripts; this is the real-kitty
    # half.
    stub = "/home/jonathan/.cache/kitty-session/stub-session"
    stub_line = workstation.succeed(f"cat {stub}").strip()
    print("[diag] stub:\n" + stub_line)
    # kitty session-parses the line with shlex (kitty/session.py), so
    # shlex is also how the argv it hands pane 0 is read back out.
    stub_toks = shlex.split(stub_line)
    assert "--exec-pane0" in stub_toks, (
        "the stub does not launch pane 0 through --exec-pane0:\n" + stub_line
    )
    pane0_argv = stub_toks[stub_toks.index("--exec-pane0") + 1:]
    assert pane0_argv, (
        "the stub named NO argv after --exec-pane0. That is the shape "
        "whose recorded cmdline pointed back at the launcher, and pane 0 "
        "opens a bare shell instead of its own command:\n" + stub_line
    )
    cmdlines = json.loads(workstation.succeed(
        "jq -c '[.[].tabs[].windows[].cmdline]' /tmp/ls-after.json"
    ))
    print("[diag] pane-0 argv: " + json.dumps(pane0_argv))
    print("[diag] live cmdlines: " + json.dumps(cmdlines))
    # The assertion this replaced was `[cmdline | select(index(
    # "--exec-pane0")) | length] | all(. > 2)`, and it could not fail:
    # execvp KEEPS the pid, so child.cmdline (kitty/child.py:593-596)
    # reports the EXEC'D command and no live window's cmdline ever holds
    # the flag. The select() yielded [] and all([]) is true. The green
    # run's own diagnostic said so:
    #   [["/run/current-system/sw/bin/zsh"],[".../sleep","11111"], ...]
    #
    # What is actually worth asserting is the positive: pane 0 IS running
    # the argv the stub named. That fails if --exec-pane0 refused (the
    # window would show $SHELL — distinguishable now that pane 0 carries
    # a sleep of its own), if the exec never happened (the launcher argv
    # would still be there), or if the argv was truncated in transit.
    assert pane0_argv in cmdlines, (
        "no window is running pane 0's recorded command "
        f"{pane0_argv}; live cmdlines are {cmdlines}. --exec-pane0 either "
        "refused and opened a shell, or never exec'd at all."
    )
    assert not [c for c in cmdlines if len(c) > 1 and c[1] == "--exec-pane0"], (
        f"a window is still running the pane-0 launcher: {cmdlines}. The "
        "next snapshot would record that as pane 0's command, and the "
        "restore after it would exec the launcher again."
    )

    # === Phase 6: kitty-panes-reflow ===
    #
    # Reflow moves the panes a running kitty ALREADY has into that same
    # grid. Every pane may be a long-lived `claude`, so the contract is
    # re-parent, never respawn — which is why each assertion below
    # carries a PID comparison rather than just a topology one. And
    # because the user is invited to run it on a hunch, doing nothing at
    # all when the layout is already right is a hard requirement, not an
    # optimisation.

    def reflow_state(path):
        """(group ids per tab, focused window, window->pid) from ls.

        `window.pid` — kitty's `child.pid`, the process it forked for
        that window — is what answers "was this pane respawned": a
        `detach-window` re-parent keeps it, a `launch` cannot. NOT
        `foreground_processes`, which kitty derives live from the pty's
        foreground process GROUP and which can come back empty between
        two `ls` calls a second apart while the pane is perfectly
        alive. Measured on this lane: window 1 reported pid 1678 in one
        readout and [] in the next, same process still attached, same
        tree that had passed the phase a run earlier. Comparing that
        field failed the lane for a race rather than for a regression.
        """
        workstation.succeed(f"su jonathan -c '{sock_cmd} ls > {path}'")
        groups = workstation.succeed(
            f"jq -cS '[.[].tabs[] | {{tab: .id, g: [.groups[].id]}}]' {path}"
        ).strip()
        focus = workstation.succeed(
            "jq -cS '[.[].tabs[] | select(.is_focused) | .windows[] | "
            f"select(.is_focused) | .id]' {path}"
        ).strip()
        pids = workstation.succeed(
            "jq -cS '[.[].tabs[].windows[] | {id: .id, pid: .pid}] "
            f"| sort_by(.id)' {path}"
        ).strip()
        return groups, focus, pids

    # --- 6a: a layout that is already canonical is left completely
    # alone. Group ids are the tell: kitty reallocates them on every
    # attach (observed 1 -> 7 -> 19 across runs), so an unchanged set
    # proves no detach happened, not merely that the end state matched.
    before = reflow_state("/tmp/reflow-noop-before.json")
    print("[diag] reflow no-op before: " + repr(before))
    workstation.succeed("su jonathan -c kitty-panes-reflow")
    workstation.sleep(1)
    after = reflow_state("/tmp/reflow-noop-after.json")
    print("[diag] reflow no-op after:  " + repr(after))
    assert before == after, (
        "reflow churned an already-canonical layout.\n"
        f"before: {before}\nafter:  {after}\n"
        "Group ids move only when a window is detached; focus moves "
        "because every detach makes its target tab active. Either "
        "changing here means running this on a hunch would tear up a "
        "screenful of live claude sessions."
    )

    # --- 6b: a tab in `stack` layout. It serializes no `pairs` at all,
    # so it can never be canonical; reflow has to switch it to splits
    # and rebuild — without restarting any of the four processes.
    workstation.succeed(f"su jonathan -c '{sock_cmd} goto-layout stack'")
    workstation.sleep(1)
    workstation.succeed(
        f"su jonathan -c '{sock_cmd} ls > /tmp/reflow-stack-before.json'"
    )
    workstation.succeed(
        "jq -e '.[0].tabs[0].layout == \"stack\"' "
        "/tmp/reflow-stack-before.json"
    )
    _, _, pids_before = reflow_state("/tmp/reflow-stack-before.json")
    workstation.succeed("su jonathan -c kitty-panes-reflow")
    workstation.sleep(2)
    workstation.succeed(
        f"su jonathan -c '{sock_cmd} ls > /tmp/reflow-stack-after.json'"
    )
    print("[diag] after stack reflow:\n" + workstation.succeed(
        "cat /tmp/reflow-stack-after.json"
    ))
    workstation.succeed(
        "jq -e '.[0].tabs | length == 1' /tmp/reflow-stack-after.json"
    )
    workstation.succeed(
        "jq -e '.[0].tabs[0].layout == \"splits\"' "
        "/tmp/reflow-stack-after.json"
    )
    workstation.succeed(
        f"jq -e '{shp}.[0].tabs[0].layout_state.pairs | shp == {grid_2x2}' "
        "/tmp/reflow-stack-after.json"
    )
    _, _, pids_after = reflow_state("/tmp/reflow-stack-after2.json")
    assert pids_before == pids_after, (
        "reflow did not preserve the pane processes.\n"
        f"before: {pids_before}\nafter:  {pids_after}\n"
        "Every step must be a `detach-window` re-parent; a `launch` "
        "anywhere in the sequence kills the user's claude session and "
        "starts a new one."
    )

    # --- 6c: more panes than fit one tab. Six in a single tab spill to
    # a second tab holding the canonical form for the remainder (2),
    # again with every process intact.
    for magic in ("44444", "55555"):
        workstation.succeed(
            f"su jonathan -c '{sock_cmd} launch --location=hsplit "
            f"--keep-focus {sleep_bin} {magic}'"
        )
    workstation.sleep(2)
    workstation.succeed(
        f"su jonathan -c '{sock_cmd} ls > /tmp/reflow-six-before.json'"
    )
    workstation.succeed(
        "jq -e '[.[].tabs[].windows[]] | length == 6' "
        "/tmp/reflow-six-before.json"
    )
    workstation.succeed(
        "jq -e '.[0].tabs | length == 1' /tmp/reflow-six-before.json"
    )
    _, focus_before, six_pids_before = reflow_state(
        "/tmp/reflow-six-before.json"
    )
    workstation.succeed("su jonathan -c kitty-panes-reflow")
    workstation.sleep(2)
    workstation.succeed(
        f"su jonathan -c '{sock_cmd} ls > /tmp/reflow-six-after.json'"
    )
    print("[diag] after six-pane reflow:\n" + workstation.succeed(
        "cat /tmp/reflow-six-after.json"
    ))
    workstation.succeed(
        "jq -e '.[0].tabs | length == 2' /tmp/reflow-six-after.json"
    )
    workstation.succeed(
        f"jq -e '{shp}.[0].tabs[0].layout_state.pairs | shp == {grid_2x2}' "
        "/tmp/reflow-six-after.json"
    )
    workstation.succeed(
        f"jq -e '{shp}.[0].tabs[1].layout_state.pairs | shp == {grid_1x2}' "
        "/tmp/reflow-six-after.json"
    )
    _, focus_after, six_pids_after = reflow_state(
        "/tmp/reflow-six-after2.json"
    )
    assert six_pids_before == six_pids_after, (
        "a six-pane reflow lost or restarted a pane process.\n"
        f"before: {six_pids_before}\nafter:  {six_pids_after}"
    )
    assert focus_before == focus_after, (
        "reflow left the cursor somewhere the user did not put it.\n"
        f"before: {focus_before}\nafter:  {focus_after}\n"
        "Every detach ends with target_tab.make_active(), so the "
        "originally-focused window has to be re-focused at the end."
    )

    # --- 6d: and the rebuilt two-tab layout is itself canonical, so a
    # follow-up run does nothing. Without this, a reflow that converged
    # on a shape it does not itself recognise would churn on every
    # invocation forever.
    settled_before = reflow_state("/tmp/reflow-settle-before.json")
    workstation.succeed("su jonathan -c kitty-panes-reflow")
    workstation.sleep(1)
    settled_after = reflow_state("/tmp/reflow-settle-after.json")
    assert settled_before == settled_after, (
        "reflow does not recognise its own output as canonical.\n"
        f"before: {settled_before}\nafter:  {settled_after}"
    )

    # --- 6e: a refusal has to reach the user. The only invocation the
    # user makes is the ctrl+shift+r binding, which is `launch
    # --type=background` — and kitty spawns such a process with its OWN
    # stdout and stderr, so everything it prints goes to kitty's log and
    # into no window at all. Driven here exactly the way the binding
    # does it, with the reflow lock held so the refusal is a certainty.
    workstation.succeed(
        "su jonathan -c 'flock -x /home/jonathan/.cache/kitty-session/"
        "reflow.lock sleep 30 >/dev/null 2>&1 &'"
    )
    workstation.sleep(2)
    workstation.succeed(
        f"su jonathan -c '{sock_cmd} launch --type=background -- "
        "/etc/profiles/per-user/jonathan/bin/kitty-panes-reflow'"
    )
    workstation.sleep(3)
    workstation.succeed(f"su jonathan -c '{sock_cmd} ls > /tmp/reflow-notice.json'")
    print("[diag] with the notice up:\n" + workstation.succeed(
        "jq -c '[.[].tabs[] | {g: [.groups[] | {id, windows}], "
        "w: [.windows[] | {id, title, ui: .env.KITTY_SESSION_UI}]}]' "
        "/tmp/reflow-notice.json"
    ))
    workstation.succeed(
        "jq -e '[.[].tabs[].windows[] | "
        'select(.title == "kitty-panes-reflow")] | length == 1\' '
        "/tmp/reflow-notice.json"
    )
    # Marked as this module's own chrome, so a snapshot taken while it
    # is up does not restore it as a pane.
    workstation.succeed(
        "jq -e '[.[].tabs[].windows[] | "
        'select(.title == "kitty-panes-reflow") | '
        ".env.KITTY_SESSION_UI] == [\"1\"]' /tmp/reflow-notice.json"
    )
    notice_text = workstation.succeed(
        f"su jonathan -c '{sock_cmd} get-text "
        "--match title:kitty-panes-reflow'"
    )
    print("[diag] notice text:\n" + notice_text)
    assert "another reflow is already running" in notice_text, (
        "the notice overlay does not carry the refusal, so the user is "
        "left with an unexplained non-event.\n" + notice_text
    )
    assert "press Enter to dismiss" in notice_text, (
        "the notice does not say how to get rid of it."
    )

    # And it takes no grid slot: it is an overlay in its base window's
    # group, and window_is_internal() filters it, so a reflow run while
    # it is up still sees the layout as canonical and does nothing.
    # Wait the holder out rather than killing it: `flock` keeps the
    # locked fd open in the child it execs, so killing the pid the
    # shell reports leaves the lock held, and `pkill -f` matches the
    # driver's own shell running the pattern and kills that instead
    # (measured: exit 143). Probing the lock itself needs no pid and no
    # guess at how long anything takes.
    workstation.wait_until_succeeds(
        "flock -n -x /home/jonathan/.cache/kitty-session/reflow.lock "
        "true",
        timeout=60,
    )
    workstation.sleep(1)
    notice_before = reflow_state("/tmp/reflow-notice-before.json")
    workstation.succeed("su jonathan -c kitty-panes-reflow")
    workstation.sleep(1)
    notice_after = reflow_state("/tmp/reflow-notice-after.json")
    assert notice_before == notice_after, (
        "a reflow notice window was counted as a pane, so reflow tore "
        "up a canonical layout to make room for kitty chrome.\n"
        f"before: {notice_before}\nafter:  {notice_after}"
    )
  '';
}
