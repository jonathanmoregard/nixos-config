# offline-ai-smoke: runtime-invocation harness for the weekly smoke test
# (scripts/offline-ai-smoke.py, wrapped in modules/nixos/offline-ai.nix). No VM,
# no model: every program the script calls is a fake on PATH that records its
# argv and behaves as the environment tells it to.
#
# What must hold, whatever the model does:
#   - a pass younger than the interval means nothing is run at all;
#   - outside the night window, on battery, while the user keeps typing, or
#     while a nix build holds nix-memory-run, the night is skipped quietly —
#     and a skip is recorded beside the last verdict, never over it;
#   - a run waits for the user to go idle and for the memory lock, then goes
#     through nix-memory-run and the coreutils timeout, and asks the fixed prompt;
#   - PONG within budget is `ok` and silent; anything else is `fail`, a
#     critical toast, exit 1, with a reason that names what went wrong —
#     including a `down` that hangs, and a SIGTERM from the service timeout;
#   - after a failed run the model is brought down again — unless it was the
#     user's model to begin with, or systemd could not say whose it was;
#   - first_run is set once; the state file keeps at most 200 characters of
#     the answer.
#
# Run: nix build .#checks.x86_64-linux.offline-ai-smoke -L
{ pkgs, smoke }:
let
  fakeOfflineAi = pkgs.writeShellScript "offline-ai" ''
    echo "offline-ai $*" >> "$FAKE_LOG"
    case "$1" in
      down) sleep "''${FAKE_DOWN_SLEEP:-0}"; exit 0 ;;
    esac
    sleep "''${FAKE_SLEEP:-0}"
    [ -z "''${FAKE_STDERR:-}" ] || echo "$FAKE_STDERR" >&2
    printf '%s\n' "''${FAKE_ANSWER:-PONG}"
    exit "''${FAKE_EXIT:-0}"
  '';
  # Idle time in ms: the n-th call returns the n-th word of FAKE_IDLE_SEQ, the
  # last word repeats. Default: an hour idle.
  fakeXprintidle = pkgs.writeShellScript "xprintidle" ''
    echo "xprintidle" >> "$FAKE_LOG"
    n=$(cat "$FAKE_LOG.idle" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$FAKE_LOG.idle"
    set -- ''${FAKE_IDLE_SEQ:-3600000}
    [ "$n" -le "$#" ] || n=$#
    eval "echo \$$n"
  '';
  fakeNotify = pkgs.writeShellScript "notify-send" ''
    echo "notify-send $*" >> "$FAKE_LOG"
  '';
  # The n-th call exits with the n-th word of FAKE_LOCK_SEQ (75 = another job holds
  # the memory lock), the last word repeats; 0 runs the command. Default: lock free.
  fakeMemoryRun = pkgs.writeShellScript "nix-memory-run" ''
    echo "nix-memory-run $*" >> "$FAKE_LOG"
    n=$(cat "$FAKE_LOG.lock" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$FAKE_LOG.lock"
    i=0; code=0
    for word in ''${FAKE_LOCK_SEQ:-0}; do i=$((i + 1)); code=$word; [ "$i" -ge "$n" ] && break; done
    [ "$code" = 0 ] || exit "$code"
    [ "$1" = "--nonblock" ] && shift
    [ "$1" = "--" ] && shift
    exec "$@"
  '';
  # `systemctl --user is-active -- <unit>`: active (rc 0), inactive (rc 3), or a
  # broken systemd that cannot be asked (FAKE_UNIT_STATE=broken).
  fakeSystemctl = pkgs.writeShellScript "systemctl" ''
    echo "systemctl $*" >> "$FAKE_LOG"
    case "''${FAKE_UNIT_STATE:-inactive}" in
      active) echo active; exit 0 ;;
      inactive) echo inactive; exit 3 ;;
      *) echo "Failed to connect to bus" >&2; exit 1 ;;
    esac
  '';
in
pkgs.runCommand "offline-ai-smoke-harness"
  {
    nativeBuildInputs = [ pkgs.python3 pkgs.coreutils pkgs.jq pkgs.gnugrep ];
  } ''
    fail() { echo "FAIL: $*" >&2; [ -f calls.log ] && { echo "--- calls.log"; cat calls.log; } >&2; [ -f state/offline-ai/smoke.json ] && { echo "--- state"; cat state/offline-ai/smoke.json; } >&2; exit 1; }
    script=$(grep -o '/nix/store/[^ ]*-offline-ai-smoke.py' ${smoke}/bin/offline-ai-smoke | head -1)
    [ -n "$script" ] || fail "the wrapper does not name the smoke script"

    mkdir -p fakebin ps/AC ps/BAT0
    ln -s ${fakeOfflineAi} fakebin/offline-ai
    ln -s ${fakeXprintidle} fakebin/xprintidle
    ln -s ${fakeNotify} fakebin/notify-send
    ln -s ${fakeMemoryRun} fakebin/nix-memory-run
    ln -s ${fakeSystemctl} fakebin/systemctl
    echo Mains > ps/AC/type; echo 1 > ps/AC/online; echo Battery > ps/BAT0/type

    # Fresh fakes and log per case; the state dir persists across cases unless reset.
    reset() { rm -f calls.log calls.log.idle calls.log.lock; : > calls.log; }
    reset_state() { rm -rf state; }
    state() { jq -r "$1" state/offline-ai/smoke.json; }
    # Poll 0.1 s, wait at most 0.6 s for idle or the lock, any hour, budget 600 s
    # unless a case overrides (later env assignments win).
    smoke() {
      env PATH="$PWD/fakebin:$PATH" FAKE_LOG="$PWD/calls.log" XDG_STATE_HOME="$PWD/state" \
          OFFLINE_AI_SMOKE_POWER_SUPPLY_DIR="$PWD/ps" OFFLINE_AI_SMOKE_POLL_S=0.1 \
          OFFLINE_AI_SMOKE_WAIT_MAX_MIN=0.01 OFFLINE_AI_SMOKE_LOCK_WAIT_MIN=0.01 \
          OFFLINE_AI_SMOKE_WINDOW=0-24 "$@" python3 "$script"
    }
    stale_ok() {  # a pass 8 days ago, so a run is due
      mkdir -p state/offline-ai
      printf '{"last_ok": "%s", "status": "ok"}\n' "$(date -u -d '8 days ago' +%Y-%m-%dT%H:%M:%S+00:00)" > state/offline-ai/smoke.json
    }

    # 1. First run ever, model answers PONG: ok, silent, through nix-memory-run and timeout, no down.
    reset; reset_state
    smoke > out1 2> err1 || fail "a PONG answer did not exit 0"
    [ "$(state .status)" = ok ] || fail "status after PONG is not ok"
    [ "$(state .last_ok)" != null ] || fail "last_ok not recorded after a pass"
    grep -q '^nix-memory-run --nonblock -- timeout -k 30 600 offline-ai Automated check' calls.log || fail "the run did not go through nix-memory-run and timeout with the fixed prompt"
    grep -q 'notify-send' calls.log && fail "a pass sent a toast"
    grep -q '^offline-ai down' calls.log && fail "a pass brought the model down"
    grep -q 'ok: answered in' err1 || fail "a pass does not say so in the journal"

    # 2. Run again right away: not due, nothing called, last_check moves.
    reset
    smoke > out2 2> err2 || fail "not-due exited non-zero"
    grep -q 'offline-ai' calls.log && fail "a not-due run called offline-ai"
    grep -q 'not due' err2 || fail "not-due is not logged"
    [ "$(state .status)" = ok ] || fail "not-due changed the status"

    # 3. Due but on battery: skipped, quiet.
    reset; stale_ok; echo 0 > ps/AC/online
    smoke > out3 2> err3 || fail "battery skip exited non-zero"
    [ "$(state .last_skip)" != null ] || fail "battery did not skip"
    [ "$(state .skip_reason)" = "on battery" ] || fail "battery skip has the wrong reason"
    grep -q 'offline-ai' calls.log && fail "battery skip called offline-ai"
    grep -q 'notify-send' calls.log && fail "battery skip sent a toast"
    echo 1 > ps/AC/online

    # 4. Due, user active for two polls then idle: waits, then runs.
    reset; stale_ok
    smoke FAKE_IDLE_SEQ="1000 1000 3600000" > out4 2> err4 || fail "run after waiting for idle failed"
    [ "$(grep -c '^xprintidle' calls.log)" -ge 3 ] || fail "did not poll idle time until the user went idle"
    grep -q '^offline-ai Automated check' calls.log || fail "did not run once the user went idle"
    [ "$(state .status)" = ok ] || fail "run after idle wait is not ok"

    # 5. Due, user never idle: skipped after the wait, no run, no toast.
    reset; stale_ok
    smoke FAKE_IDLE_SEQ="1000" > out5 2> err5 || fail "active-user skip exited non-zero"
    [ "$(state .last_skip)" != null ] || fail "active user did not skip"
    grep -q 'user active' <<< "$(state .skip_reason)" || fail "active-user skip has the wrong reason"
    grep -q 'offline-ai Automated' calls.log && fail "active-user skip ran the model"
    grep -q 'notify-send' calls.log && fail "active-user skip sent a toast"

    # 6. Exit 0 but no PONG: fail, critical toast, exit 1; the CLI itself already left the mode.
    reset; stale_ok
    smoke FAKE_ANSWER="I cannot help with that." > out6 2> err6 && fail "an answer without PONG exited 0"
    [ "$(state .status)" = fail ] || fail "unexpected answer is not a fail"
    grep -q 'unexpected answer' <<< "$(state .reason)" || fail "unexpected-answer reason missing"
    grep -q '^notify-send -u critical -a offline-ai offline-ai smoke FAILED' calls.log || fail "no critical toast on failure"
    grep -q '^offline-ai down' calls.log && fail "down was run although the CLI exited normally"

    # 7. Exit 1 (model not loadable): fail with the CLI's last words, down is run.
    reset; stale_ok
    smoke FAKE_EXIT=1 FAKE_STDERR="offline-ai-llm.service did not become ready within 10 minutes" > out7 2> err7 && fail "exit 1 was treated as a pass"
    [ "$(state .status)" = fail ] || fail "exit 1 is not a fail"
    grep -q 'not loadable' <<< "$(state .reason)" || fail "exit-1 reason does not say the model is not loadable"
    grep -q 'did not become ready' <<< "$(state .reason)" || fail "exit-1 reason drops the CLI's stderr"
    grep -q '^offline-ai down' calls.log || fail "model not brought down after a failed load"
    [ "$(state .exit_code)" = 1 ] || fail "exit code not recorded"

    # 8. Exit 2 (answer cut off).
    reset; stale_ok
    smoke FAKE_EXIT=2 > out8 2> err8 && fail "exit 2 was treated as a pass"
    grep -q 'cut off' <<< "$(state .reason)" || fail "exit-2 reason does not say cut off"

    # 9. Over budget: timeout kills the CLI, fail says so, down is run.
    reset; stale_ok
    smoke FAKE_SLEEP=3 OFFLINE_AI_SMOKE_BUDGET_S=1 > out9 2> err9 && fail "a run past the budget passed"
    grep -q 'no answer within 1 s' <<< "$(state .reason)" || fail "timeout reason missing"
    grep -q '^offline-ai down' calls.log || fail "model not brought down after a timeout"

    # 10. The model was the user's (already up) and the run fails: no down.
    reset; stale_ok
    smoke FAKE_UNIT_STATE=active FAKE_EXIT=1 > out10 2> err10 && fail "exit 1 with the model already up passed"
    grep -q '^offline-ai down' calls.log && fail "brought down a model the user had up"
    [ "$(state .was_up)" = true ] || fail "was_up not recorded"

    # 11. Long answer is truncated in the state file; model-ready time is parsed.
    reset; stale_ok
    long=$(head -c 1000 /dev/zero | tr '\0' x)
    smoke FAKE_ANSWER="PONG $long" FAKE_STDERR="model ready after 12.5 s" > out11 2> err11 || fail "long PONG answer failed"
    [ "$(state '.answer | length')" -le 200 ] || fail "answer not truncated to 200 chars"
    [ "$(state .model_ready_s)" = 12.5 ] || fail "model ready time not parsed"

    # 12. Outside the night window (a timer that elapsed during suspend fires at resume): skipped, nothing run.
    reset; stale_ok
    smoke OFFLINE_AI_SMOKE_WINDOW=1-7 OFFLINE_AI_SMOKE_LOCAL_HOUR=10 > out12 2> err12 || fail "window skip exited non-zero"
    grep -q 'outside the night window 01-07' <<< "$(state .skip_reason)" || fail "window skip has the wrong reason"
    grep -q 'offline-ai' calls.log && fail "window skip ran something"
    reset
    smoke OFFLINE_AI_SMOKE_WINDOW=1-7 OFFLINE_AI_SMOKE_LOCAL_HOUR=3 > out12b 2> err12b || fail "run inside the window failed"
    [ "$(state .status)" = ok ] || fail "run inside the window is not ok"

    # 13. A skip the night after a failure keeps the failure visible.
    reset; stale_ok
    smoke FAKE_EXIT=1 > out13 2> err13 && fail "exit 1 passed"
    reset; echo 0 > ps/AC/online
    smoke > out13b 2> err13b || fail "battery skip after a fail exited non-zero"
    echo 1 > ps/AC/online
    [ "$(state .status)" = fail ] || fail "a skip overwrote the fail verdict"
    [ "$(state .skip_reason)" = "on battery" ] || fail "skip not recorded beside the verdict"

    # 14. `offline-ai down` hangs: the verdict still lands, with the hang named; no traceback.
    reset; stale_ok
    smoke FAKE_EXIT=1 FAKE_DOWN_SLEEP=3 OFFLINE_AI_SMOKE_DOWN_TIMEOUT_S=1 > out14 2> err14 && fail "exit 1 with a hanging down passed"
    [ "$(state .status)" = fail ] || fail "hanging down lost the verdict"
    grep -q 'down timed out' <<< "$(state .reason)" || fail "hanging down not named in the reason"
    grep -q 'Traceback' err14 && fail "hanging down produced a traceback"
    grep -q '^notify-send -u critical' calls.log || fail "no toast when down hung"

    # 15. systemd cannot be asked whether the model was up: never bring it down.
    reset; stale_ok
    smoke FAKE_UNIT_STATE=broken FAKE_EXIT=1 > out15 2> err15 && fail "exit 1 with unknown unit state passed"
    grep -q '^offline-ai down' calls.log && fail "brought the model down without knowing whose it was"
    [ "$(state .was_up)" = null ] || fail "unknown unit state not recorded as null"
    grep -q 'not touched' <<< "$(state .cleanup)" || fail "unknown-state cleanup not recorded"

    # 16. nix-memory-run busy twice then free: waits and runs; busy for good: skipped.
    reset; stale_ok
    smoke FAKE_LOCK_SEQ="75 75 0" > out16 2> err16 || fail "run after a busy lock failed"
    [ "$(grep -c '^nix-memory-run --nonblock' calls.log)" = 3 ] || fail "did not retry the lock"
    [ "$(state .status)" = ok ] || fail "run after a busy lock is not ok"
    reset; stale_ok
    smoke FAKE_LOCK_SEQ="75" > out16b 2> err16b || fail "lock-held skip exited non-zero"
    grep -q 'held nix-memory-run' <<< "$(state .skip_reason)" || fail "lock-held skip has the wrong reason"
    grep -q '^offline-ai Automated' calls.log && fail "ran the model while the lock was held"

    # 17. SIGTERM mid-run (service timeout): the abort is recorded and toasted. env execs
    #     python, so $! is the script's pid.
    reset; stale_ok
    env PATH="$PWD/fakebin:$PATH" FAKE_LOG="$PWD/calls.log" XDG_STATE_HOME="$PWD/state" \
        OFFLINE_AI_SMOKE_POWER_SUPPLY_DIR="$PWD/ps" OFFLINE_AI_SMOKE_WINDOW=0-24 FAKE_SLEEP=5 \
        python3 "$script" > out17 2> err17 &
    pid=$!
    sleep 1
    kill -TERM "$pid"
    wait "$pid" && fail "an aborted run exited 0"
    [ "$(state .status)" = fail ] || fail "abort not recorded as fail"
    grep -q 'aborted by signal 15' <<< "$(state .reason)" || fail "abort reason missing"
    grep -q '^notify-send -u critical' calls.log || fail "no toast on abort"

    # 18. first_run is set once and kept.
    reset; reset_state
    smoke > out18 2> err18 || fail "first run failed"
    first=$(state .first_run); [ "$first" != null ] || fail "first_run not set"
    sleep 1; reset
    smoke > out18b 2> err18b || fail "second run failed"
    [ "$(state .first_run)" = "$first" ] || fail "first_run changed on a later run"

    mkdir -p "$out"
    echo 'offline-ai-smoke harness passed' > "$out/result"
  ''
