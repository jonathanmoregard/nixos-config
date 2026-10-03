# offline-ai-smoke: runtime-invocation harness for the weekly smoke test
# (scripts/offline-ai-smoke.py, wrapped in modules/nixos/offline-ai.nix). No VM,
# no model: every program the script calls is a fake on PATH that records its
# argv and behaves as the environment tells it to.
#
# What must hold, whatever the model does:
#   - a pass younger than the interval means nothing is run at all;
#   - on battery, or while the user keeps typing, the night is skipped quietly;
#   - a run waits for the user to go idle, then goes through nix-memory-run
#     and the coreutils timeout, and asks the fixed prompt;
#   - PONG within budget is `ok` and silent; anything else is `fail`, a
#     critical toast, exit 1, with a reason that names what went wrong;
#   - after a failed run the model is brought down again — unless it was the
#     user's model to begin with;
#   - the state file keeps at most 200 characters of the answer.
#
# Run: nix build .#checks.x86_64-linux.offline-ai-smoke -L
{ pkgs, smoke }:
let
  fakeOfflineAi = pkgs.writeShellScript "offline-ai" ''
    echo "offline-ai $*" >> "$FAKE_LOG"
    case "$1" in
      status) printf 'model server: %s\nmode: default\n' "''${FAKE_STATUS:-inactive}"; exit 0 ;;
      down) exit 0 ;;
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
  fakeMemoryRun = pkgs.writeShellScript "nix-memory-run" ''
    echo "nix-memory-run $*" >> "$FAKE_LOG"
    [ "$1" = "--" ] && shift
    exec "$@"
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
    echo Mains > ps/AC/type; echo 1 > ps/AC/online; echo Battery > ps/BAT0/type

    # Fresh fakes and log per case; the state dir persists across cases unless reset.
    reset() { rm -f calls.log calls.log.idle; : > calls.log; }
    reset_state() { rm -rf state; }
    state() { jq -r "$1" state/offline-ai/smoke.json; }
    # Poll 0.1 s, wait at most 0.6 s for idle, budget 600 s unless a case overrides.
    smoke() {
      env PATH="$PWD/fakebin:$PATH" FAKE_LOG="$PWD/calls.log" XDG_STATE_HOME="$PWD/state" \
          OFFLINE_AI_SMOKE_POWER_SUPPLY_DIR="$PWD/ps" OFFLINE_AI_SMOKE_POLL_S=0.1 \
          OFFLINE_AI_SMOKE_WAIT_MAX_MIN=0.01 "$@" python3 "$script"
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
    grep -q '^nix-memory-run -- timeout -k 30 600 offline-ai Automated check' calls.log || fail "the run did not go through nix-memory-run and timeout with the fixed prompt"
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
    [ "$(state .status)" = skipped ] || fail "battery did not skip"
    [ "$(state .reason)" = "on battery" ] || fail "battery skip has the wrong reason"
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
    [ "$(state .status)" = skipped ] || fail "active user did not skip"
    grep -q 'user active' <<< "$(state .reason)" || fail "active-user skip has the wrong reason"
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
    smoke FAKE_STATUS=ready FAKE_EXIT=1 > out10 2> err10 && fail "exit 1 with the model already up passed"
    grep -q '^offline-ai down' calls.log && fail "brought down a model the user had up"
    [ "$(state .was_up)" = true ] || fail "was_up not recorded"

    # 11. Long answer is truncated in the state file; model-ready time is parsed.
    reset; stale_ok
    long=$(head -c 1000 /dev/zero | tr '\0' x)
    smoke FAKE_ANSWER="PONG $long" FAKE_STDERR="model ready after 12.5 s" > out11 2> err11 || fail "long PONG answer failed"
    [ "$(state '.answer | length')" -le 200 ] || fail "answer not truncated to 200 chars"
    [ "$(state .model_ready_s)" = 12.5 ] || fail "model ready time not parsed"

    mkdir -p "$out"
    echo 'offline-ai-smoke harness passed' > "$out/result"
  ''
