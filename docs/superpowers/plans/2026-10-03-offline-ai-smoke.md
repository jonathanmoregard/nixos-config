# offline-ai weekly smoke test — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (default) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A user timer loads the local model through the real `offline-ai` CLI about once a week at night, asks one trivial question, records the verdict, and shouts (desktop toast + Claude SessionStart notice) only when it fails.

**Architecture:** One stdlib Python script (`scripts/offline-ai-smoke.py`) wrapped by `writeShellApplication` in `modules/nixos/offline-ai.nix`, driven by `systemd.user.{services,timers}.offline-ai-smoke`. Everything it calls (`offline-ai`, `xprintidle`, `notify-send`, `nix-memory-run`, `timeout`) is found on PATH, so a no-VM flake check (`tests/offline-ai-smoke.nix`) runs it against fake binaries — the real model is never loaded by any build or check. A small SessionStart hook in `~/.claude` reads the result file.

**Tech Stack:** NixOS module + home-manager user units, Python 3 stdlib, `pkgs.runCommand` harness with `pkgs.writeShellScript` fakes, pytest for the `~/.claude` hook.

Spec: `docs/superpowers/specs/2026-10-03-offline-ai-smoke-design.md`.

Repo rules that bite: commit and push as SEPARATE commands (the push gate judges HEAD at hook time); the final HEAD commit needs a `Pre-push checklist:` block, `Type: risky` here (new `systemd.user.services.*` + `writeShellApplication`); `rm -rf`, `git checkout -- <path>`, `git -C $VAR` and heredoc python patchers are blocked by dcg — use literal paths and the Write/Edit tools; never `cd` out of the worktree; never run `offline-ai up`/`down` or load the model.

---

## File structure

- Create `scripts/offline-ai-smoke.py` — the smoke logic (due/battery/idle gates, run, judge, state, toast).
- Create `tests/offline-ai-smoke.nix` — harness with fakes; asserts the invariants in the spec.
- Modify `modules/nixos/offline-ai.nix` — `smoke` wrapper, `system.build.offline-ai-smoke`, user service + timer.
- Modify `flake.nix` (checks block near line 406) — register the `offline-ai-smoke` check.
- In `~/worktrees/claude-offline-ai-smoke-health` (repo `jonathanmoregard/.claude`, branch off `origin/master`): create `hooks/offline-ai-smoke-health.py`, `tests/test_offline_ai_smoke_health.py`, modify `settings.json` (SessionStart).

---

### Task 1: The smoke script, test-first (nixos-config worktree `~/Repos/nixos-config-worktrees/offline-ai-smoke`)

**Files:**
- Create: `tests/offline-ai-smoke.nix`
- Create: `scripts/offline-ai-smoke.py`
- Modify: `modules/nixos/offline-ai.nix` (add the wrapper + `system.build` export only; units come in Task 2)
- Modify: `flake.nix` (register the check)

- [ ] **Step 1: Write the harness (the failing test)**

Create `tests/offline-ai-smoke.nix`:

```nix
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
```

- [ ] **Step 2: Register the check and the wrapper so the harness can run**

In `flake.nix`, directly after the `offline-ai = import ./tests/offline-ai.nix { … };` block (around line 414), add:

```nix
        # Not a VM lane: runs the weekly smoke script against fake offline-ai /
        # xprintidle / notify-send / nix-memory-run binaries — gates, verdicts,
        # toast, cleanup. The real model is never loaded by a check.
        offline-ai-smoke = import ./tests/offline-ai-smoke.nix {
          pkgs = pkgsLinux;
          smoke = self.nixosConfigurations.tuxedo.config.system.build.offline-ai-smoke;
        };
```

In `modules/nixos/offline-ai.nix`, right after the `offlineAi = pkgs.writeShellApplication { … };` definition (before `in`), add:

```nix
  # Weekly smoke test: loads the model through the CLI above, asks one question,
  # records the verdict, shouts only on failure. Runs from a user timer; see
  # docs/superpowers/specs/2026-10-03-offline-ai-smoke-design.md. Everything it
  # calls is found on PATH so tests/offline-ai-smoke.nix can stand in fakes.
  smoke = pkgs.writeShellApplication {
    name = "offline-ai-smoke";
    runtimeInputs = [
      pkgs.python3
      pkgs.coreutils
      pkgs.xprintidle
      pkgs.libnotify
      offlineAi
      config.services.buildCoordination.runnerPackage
    ];
    text = ''
      exec python3 ${../../scripts/offline-ai-smoke.py} "$@"
    '';
  };
```

and in the attribute set after `in`, next to `system.build.offline-ai = offlineAi;`:

```nix
  system.build.offline-ai-smoke = smoke;
```

- [ ] **Step 3: Run the check to verify it fails**

Run (from the worktree root): `git add -A && nix build --no-link -L .#checks.x86_64-linux.offline-ai-smoke 2>&1 | tail -5`
Expected: evaluation error — `scripts/offline-ai-smoke.py` does not exist (path `../../scripts/offline-ai-smoke.py` not found). (`git add -A` first: flakes only see tracked files.)

- [ ] **Step 4: Write the script**

Create `scripts/offline-ai-smoke.py`:

```python
#!/usr/bin/env python3
"""Weekly smoke test for the offline-ai model.

Loads the model through the real `offline-ai` CLI, asks one trivial question, records
the verdict in a state file, and shouts only when it fails. Why: the model is an
emergency tool that is loaded a few times a month, and a model that no longer loads
is otherwise discovered exactly when the network is gone.

Driven by the offline-ai-smoke user timer: a nightly opportunity, a weekly cadence
(nothing runs while the last pass is younger than INTERVAL_DAYS). Skips the night on
battery or while the user is active, because loading the model evicts voquill,
local-stt and the aggregator for the duration.

Every program used is found on PATH (offline-ai, xprintidle, notify-send,
nix-memory-run, timeout) so tests/offline-ai-smoke.nix can stand in fakes.

Exit status: 0 for ok / skipped / not due, 1 for fail.
"""
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path


def env_float(name, default):
    return float(os.environ.get(name, default))


STATE_HOME = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local" / "state")
STATE = Path(os.environ.get("OFFLINE_AI_SMOKE_STATE") or STATE_HOME / "offline-ai" / "smoke.json")
INTERVAL_DAYS = env_float("OFFLINE_AI_SMOKE_INTERVAL_DAYS", 6)
IDLE_MIN = env_float("OFFLINE_AI_SMOKE_IDLE_MIN", 15)
WAIT_MAX_MIN = env_float("OFFLINE_AI_SMOKE_WAIT_MAX_MIN", 120)
POLL_S = env_float("OFFLINE_AI_SMOKE_POLL_S", 300)
BUDGET_S = int(env_float("OFFLINE_AI_SMOKE_BUDGET_S", 600))
POWER_SUPPLY = Path(os.environ.get("OFFLINE_AI_SMOKE_POWER_SUPPLY_DIR", "/sys/class/power_supply"))
# Plain words on purpose: nothing here matches the CLI's SAFETY regex, so the
# citation gate never adds a turn to the smoke.
PROMPT = os.environ.get("OFFLINE_AI_SMOKE_PROMPT",
                        "Automated check of the local assistant. Reply with exactly one word: PONG")
EXPECT = re.compile(r"\bPONG\b", re.IGNORECASE)
ANSWER_KEEP = 200


def log(message):
    print(f"offline-ai-smoke: {message}", file=sys.stderr, flush=True)


def now():
    return datetime.now(timezone.utc)


def iso(moment):
    return moment.replace(microsecond=0).isoformat()


def parse(text):
    try:
        return datetime.fromisoformat(text)
    except (TypeError, ValueError):
        return None


def load_state():
    try:
        with open(STATE) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def save_state(state):
    STATE.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATE.with_name(STATE.name + ".tmp")
    tmp.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n")
    os.replace(tmp, STATE)


def on_battery():
    """True when a mains supply exists and none is online. No mains entry: a desktop; run."""
    online = []
    for supply in POWER_SUPPLY.glob("*"):
        try:
            if (supply / "type").read_text().strip() == "Mains":
                online.append((supply / "online").read_text().strip())
        except OSError:
            continue
    return bool(online) and "1" not in online


def idle_seconds():
    """Seconds since the last input, or None when there is no display to ask."""
    try:
        out = subprocess.run(["xprintidle"], capture_output=True, text=True, timeout=10)
        return int(out.stdout.strip()) / 1000 if out.returncode == 0 else None
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None


def model_up():
    try:
        out = subprocess.run(["offline-ai", "status"], capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return out.stdout.startswith("model server: ready")


def notify(summary, body):
    try:
        subprocess.run(["notify-send", "-u", "critical", "-a", "offline-ai", summary, body],
                       timeout=15, check=False)
    except (OSError, subprocess.TimeoutExpired):
        pass


def finish(state, status, reason, exit_code, **extra):
    state.update({"last_run": iso(now()), "status": status, "reason": reason, **extra})
    if status == "ok":
        state["last_ok"] = state["last_run"]
    save_state(state)
    log(f"{status}: {reason}")
    if status == "fail":
        notify("offline-ai smoke FAILED", f"{reason}\njournalctl --user -u offline-ai-smoke")
    return exit_code


def main():
    state = load_state()
    state["last_check"] = iso(now())
    last_ok = parse(state.get("last_ok"))
    if last_ok and now() - last_ok < timedelta(days=INTERVAL_DAYS):
        save_state(state)
        log(f"not due: last ok {iso(last_ok)}")
        return 0
    if on_battery():
        return finish(state, "skipped", "on battery", 0)

    deadline = time.monotonic() + WAIT_MAX_MIN * 60
    while True:
        idle = idle_seconds()
        if idle is None or idle >= IDLE_MIN * 60:
            break
        if time.monotonic() >= deadline:
            return finish(state, "skipped", f"user active for {WAIT_MAX_MIN:g} min", 0)
        time.sleep(POLL_S)

    was_up = model_up()
    env = dict(os.environ, OFFLINE_AI_READY_TIMEOUT=str(BUDGET_S))
    began = time.monotonic()
    try:
        # nix-memory-run waits for a running nix build and keeps auto-deploy from
        # starting one while the model holds its memory; timeout bounds the CLI,
        # which leaves offline mode in its own finally when it gets SIGTERM.
        run = subprocess.run(
            ["nix-memory-run", "--", "timeout", "-k", "30", str(BUDGET_S), "offline-ai", PROMPT],
            capture_output=True, text=True, errors="replace", env=env)
    except OSError as exc:
        return finish(state, "fail", f"could not run offline-ai: {exc}", 1, was_up=was_up)
    elapsed = round(time.monotonic() - began, 1)
    ready = re.search(r"model ready after (\d+(?:\.\d+)?) s", run.stderr)
    answer = run.stdout.strip()[:ANSWER_KEEP]
    last_words = " | ".join(run.stderr.strip().splitlines()[-3:])
    extra = {"exit_code": run.returncode, "elapsed_s": elapsed, "answer": answer, "was_up": was_up,
             "model_ready_s": float(ready[1]) if ready else None}

    # A CLI that exited by itself already left offline mode; one killed past the
    # grace period did not. Never touch a model the user had up before us.
    if not was_up and run.returncode != 0:
        log("bringing the model down after a failed run")
        subprocess.run(["offline-ai", "down"], capture_output=True, text=True, timeout=900, check=False)

    if run.returncode == 0 and EXPECT.search(run.stdout):
        detail = f"answered in {elapsed} s" + (f", model ready after {ready[1]} s" if ready else "")
        return finish(state, "ok", detail, 0, **extra)
    if run.returncode in (124, 137):
        reason = f"no answer within {BUDGET_S} s"
    elif run.returncode == 1:
        reason = "model not loadable or unreachable: " + (last_words or "no detail")
    elif run.returncode == 2:
        reason = "answer cut off at the context limit"
    elif run.returncode == 0:
        reason = f"unexpected answer: {answer!r}"
    else:
        reason = f"offline-ai exited {run.returncode}: " + (last_words or "no detail")
    return finish(state, "fail", reason, 1, **extra)


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 5: Run the check to verify it passes**

Run: `git add -A && nix build --no-link -L .#checks.x86_64-linux.offline-ai-smoke 2>&1 | tail -5`
Expected: build succeeds (the derivation writes `offline-ai-smoke harness passed`). Any `FAIL:` line: fix the script (or a wrong assertion), rerun. Also run `python3 -m py_compile scripts/offline-ai-smoke.py` once.

- [ ] **Step 6: Confirm the prompt does not trip the citation gate**

Run: `python3 -c "import re,importlib.util,sys; spec=importlib.util.spec_from_file_location('oa','scripts/offline-ai.py'); m=importlib.util.module_from_spec(spec); sys.argv=['x']; spec.loader.exec_module(m); print(bool(m.SAFETY.search('Automated check of the local assistant. Reply with exactly one word: PONG')))"`
Expected: `False`. (If importing executes `main()`, instead grep the SAFETY word list by eye for `check`, `local`, `assistant`, `reply`, `exactly`, `word`, `pong` — none may appear.)

- [ ] **Step 7: Commit**

```bash
git add scripts/offline-ai-smoke.py tests/offline-ai-smoke.nix modules/nixos/offline-ai.nix flake.nix
git commit -m "feat(offline-ai): weekly smoke script with a no-model harness" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: User service + timer, eval, final commit (same worktree)

**Files:**
- Modify: `modules/nixos/offline-ai.nix` (after `systemd.user.services.offline-ai-library = { … };`)

- [ ] **Step 1: Add the units**

Append inside the module's attribute set, after the `offline-ai-library` service:

```nix
  # Weekly smoke: a nightly opportunity (the script itself skips while the last
  # pass is younger than six days, on battery, or while the user is active), so a
  # laptop that sleeps through 03:33 catches up the next night instead of running
  # mid-day. DISPLAY/DBUS as autodoro does: xprintidle needs the X server and
  # notify-send the session bus.
  systemd.user.services.offline-ai-smoke = {
    description = "offline-ai weekly smoke test (loads the model, asks one question)";
    unitConfig.ConditionPathExists = model;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${smoke}/bin/offline-ai-smoke";
      # up to 2 h waiting for an idle user + a build holding nix-memory-run + the run
      TimeoutStartSec = "3h";
      Environment = [
        "DISPLAY=:0"
        "DBUS_SESSION_BUS_ADDRESS=unix:path=%t/bus"
      ];
    };
  };
  systemd.user.timers.offline-ai-smoke = {
    description = "offline-ai weekly smoke test, nightly opportunity";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 03:33:00";
      RandomizedDelaySec = "20min";
      Persistent = true;
    };
  };
```

- [ ] **Step 2: Evaluate the host and inspect the rendered units**

Run: `git add -A && nix eval --raw .#nixosConfigurations.tuxedo.config.system.build.toplevel.drvPath && echo && nix build --no-link -L .#checks.x86_64-linux.offline-ai-smoke 2>&1 | tail -2`
Expected: a `.drv` path, then the check still passes.

Run: `nix eval --raw .#nixosConfigurations.tuxedo.config.systemd.user.units.\"offline-ai-smoke.timer\".text; echo; nix eval --raw .#nixosConfigurations.tuxedo.config.systemd.user.units.\"offline-ai-smoke.service\".text`
Expected: timer text contains `OnCalendar=*-*-* 03:33:00`, `Persistent=true`, `WantedBy=timers.target`; service text contains `Type=oneshot`, `ConditionPathExists=/home/jonathan/.local/share/llm-models/…gguf`, `TimeoutStartSec=3h`, `Environment=DISPLAY=:0`, an `ExecStart=/nix/store/…/bin/offline-ai-smoke`.

- [ ] **Step 3: Dry-run the wrapper on the host without loading anything**

Run: `out=$(nix build --no-link --print-out-paths .#nixosConfigurations.tuxedo.config.system.build.offline-ai-smoke) && OFFLINE_AI_SMOKE_STATE=/tmp/claude-1003/offline-ai-smoke-dryrun.json OFFLINE_AI_SMOKE_POWER_SUPPLY_DIR=/nonexistent OFFLINE_AI_SMOKE_INTERVAL_DAYS=6 bash -c 'printf "{\"last_ok\": \"%s\", \"status\": \"ok\"}" "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)" > /tmp/claude-1003/offline-ai-smoke-dryrun.json' && "$out/bin/offline-ai-smoke"; echo "rc=$?"; cat /tmp/claude-1003/offline-ai-smoke-dryrun.json`
Expected: `offline-ai-smoke: not due: last ok …`, `rc=0`, the file gained `last_check`. This proves the built wrapper finds python and runs the real script on the host — with a fresh pass seeded so it does NOT load the model. Remove the temp file afterwards (`rm /tmp/claude-1003/offline-ai-smoke-dryrun.json`).

- [ ] **Step 4: Commit with the pre-push checklist (this becomes HEAD)**

Write the message to a file first, then commit with `-F`:

```
feat(offline-ai): weekly smoke test of the local model

A user timer (03:33 nightly opportunity, weekly cadence, Persistent) runs
offline-ai-smoke: skips on battery or while the user is active, waits for
nix-memory-run, asks the model for the word PONG through the real CLI with a
600 s budget, records the verdict in ~/.local/state/offline-ai/smoke.json,
brings the model down after a failed run it started, and sends a critical
desktop toast on failure. A SessionStart hook in ~/.claude reads the file
(separate PR). Design: docs/superpowers/specs/2026-10-03-offline-ai-smoke-design.md.

Pre-push checklist:
- Type: risky
- Rebased on origin/main: yes
- Local gate: nix build --no-link .#checks.x86_64-linux.offline-ai-smoke rc=0; nix eval tuxedo toplevel drvPath rc=0
- Interactive smoke (nixos-agent-testing): N/A — the real model must not be loaded by a build or check (operator constraint); the deployed timer's first night is the live run, verdict in smoke.json + journal
- Advisor review (advice-refine-test-loop): <fill in after the review round>
- feature-vm.nix modified: no
- Risky markers in diff: systemd.user.services.offline-ai-smoke, systemd.user.timers.offline-ai-smoke, writeShellApplication (offline-ai-smoke)
- Behavioural evidence: harness `nix build .#checks.x86_64-linux.offline-ai-smoke` → "offline-ai-smoke harness passed" (11 cases: not-due no-op, battery skip, idle wait, active skip, PONG ok silent, no-PONG fail+toast, exit1 fail+down, exit2, timeout fail+down, user's model left up, truncation); built wrapper dry-run on tuxedo with a seeded fresh pass → "not due", rc=0, last_check written

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
```

Run: `git add -A && git commit -F <message file>`

---

### Task 3: SessionStart health hook in `~/.claude` (worktree `~/worktrees/claude-offline-ai-smoke-health`, branch `feat/offline-ai-smoke-health` off fresh `origin/master`)

**Files:**
- Create: `hooks/offline-ai-smoke-health.py`
- Create: `tests/test_offline_ai_smoke_health.py`
- Modify: `settings.json` (`hooks.SessionStart`, next to `aggregator-recall-health.py`)

- [ ] **Step 1: Create the worktree**

```bash
git -C /home/jonathan/.claude fetch origin master
git -C /home/jonathan/.claude worktree add /home/jonathan/worktrees/claude-offline-ai-smoke-health -b feat/offline-ai-smoke-health origin/master
```

- [ ] **Step 2: Write the failing test**

Create `tests/test_offline_ai_smoke_health.py` (look at `tests/conftest.py` and `tests/test_aggregator_recall_health_hook.py` first and follow their way of running a hook; if they shell out with `subprocess.run([sys.executable, hook_path], …)`, do the same):

```python
"""offline-ai-smoke-health: silent when the weekly smoke passed recently, loud on
fail or when no pass is on record for 10 days, and a missing file means nothing."""
import json
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

HOOK = Path(__file__).resolve().parent.parent / "hooks" / "offline-ai-smoke-health.py"


def run(tmp_path, state):
    path = tmp_path / "smoke.json"
    if state is not None:
        path.write_text(json.dumps(state) if not isinstance(state, str) else state)
    out = subprocess.run([sys.executable, str(HOOK)], capture_output=True, text=True,
                         env={"OFFLINE_AI_SMOKE_STATE": str(path), "PATH": "/usr/bin:/bin"})
    assert out.returncode == 0, out.stderr
    return json.loads(out.stdout) if out.stdout.strip() else None


def ago(days):
    return (datetime.now(timezone.utc) - timedelta(days=days)).replace(microsecond=0).isoformat()


def test_missing_file_is_silent(tmp_path):
    assert run(tmp_path, None) is None


def test_recent_pass_is_silent(tmp_path):
    assert run(tmp_path, {"status": "ok", "last_ok": ago(2), "last_run": ago(2)}) is None


def test_fail_is_announced_with_reason(tmp_path):
    out = run(tmp_path, {"status": "fail", "last_run": ago(1), "last_ok": ago(8),
                         "reason": "model not loadable or unreachable: did not become ready"})
    assert "FAILED" in out["systemMessage"]
    assert "did not become ready" in out["systemMessage"]
    assert out["hookSpecificOutput"]["hookEventName"] == "SessionStart"
    assert "did not become ready" in out["hookSpecificOutput"]["additionalContext"]


def test_no_pass_for_ten_days_is_announced(tmp_path):
    out = run(tmp_path, {"status": "skipped", "reason": "on battery", "last_ok": ago(11), "last_run": ago(1)})
    assert "has not passed" in out["systemMessage"]
    assert "on battery" in out["systemMessage"]


def test_skipped_recently_after_recent_pass_is_silent(tmp_path):
    assert run(tmp_path, {"status": "skipped", "reason": "on battery", "last_ok": ago(5), "last_run": ago(1)}) is None


def test_unreadable_file_is_announced(tmp_path):
    out = run(tmp_path, "{not json")
    assert "unreadable" in out["systemMessage"]
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd /home/jonathan/worktrees/claude-offline-ai-smoke-health && python3 -m pytest tests/test_offline_ai_smoke_health.py -q`
Expected: failures — the hook file does not exist (`returncode != 0`).

- [ ] **Step 4: Write the hook**

Create `hooks/offline-ai-smoke-health.py`:

```python
#!/usr/bin/env python3
"""SessionStart check: say when the local model's weekly smoke test failed or went quiet.

The offline-ai model is an emergency tool. nixos-config's offline-ai-smoke user timer
loads it about once a week at night and writes its verdict to
~/.local/state/offline-ai/smoke.json. A failure already raises a critical desktop
toast; this hook carries the same fact into the session, where an agent about to
recommend `offline-ai` for an outage can see that it does not work.

Silence is the budget (see aggregator-recall-health.py): healthy prints nothing.
A missing file is silence too — the timer has not had its first night, or this host
has no offline-ai. An unreadable file is announced: silence must mean "checked".
Every path exits 0; an announcement is systemMessage + additionalContext, never a
block.
"""
import json
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

STALE_DAYS = 10
STATE_HOME = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local" / "state")
STATE = Path(os.environ.get("OFFLINE_AI_SMOKE_STATE") or STATE_HOME / "offline-ai" / "smoke.json")


def parse(text):
    try:
        return datetime.fromisoformat(text)
    except (TypeError, ValueError):
        return None


def announce(text):
    print(json.dumps({
        "systemMessage": text,
        "hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": text},
    }))
    return 0


def main():
    try:
        state = json.loads(STATE.read_text())
    except FileNotFoundError:
        return 0
    except (OSError, ValueError) as exc:
        return announce(f"offline-ai smoke state unreadable ({STATE}): {exc}")
    if not isinstance(state, dict):
        return announce(f"offline-ai smoke state unreadable ({STATE}): not an object")

    last_ok = parse(state.get("last_ok"))
    last_run = parse(state.get("last_run"))
    reason = state.get("reason") or "no reason recorded"
    if state.get("status") == "fail":
        return announce(
            f"offline-ai weekly smoke FAILED on {state.get('last_run', '?')}: {reason}. "
            "The local model may not load in an emergency. "
            "Check: journalctl --user -u offline-ai-smoke; offline-ai status")
    reference = last_ok or last_run
    if reference and datetime.now(timezone.utc) - reference > timedelta(days=STALE_DAYS):
        return announce(
            f"offline-ai weekly smoke has not passed since "
            f"{last_ok.date() if last_ok else 'never'} (last run {last_run.date() if last_run else 'never'}, "
            f"{state.get('status', '?')}: {reason}). "
            "Check: systemctl --user list-timers offline-ai-smoke.timer")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BaseException:  # a broken health check must never break a session start
        sys.exit(0)
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `python3 -m pytest tests/test_offline_ai_smoke_health.py -q`
Expected: `6 passed`.

- [ ] **Step 6: Wire the hook into settings.json**

In `settings.json`, find the `hooks.SessionStart` entry whose command is `python3 $HOME/.claude/hooks/aggregator-recall-health.py` and add a sibling entry with the same shape (same `matcher`/`type`/`timeout` keys as that entry) and command `python3 $HOME/.claude/hooks/offline-ai-smoke-health.py`. Then validate: `python3 -c "import json; json.load(open('settings.json'))"` and `grep -n offline-ai-smoke-health settings.json`.

- [ ] **Step 7: Run the repo's hook tests, commit, push, PR**

Run: `python3 -m pytest tests -q -x --ignore=tests/live.sh 2>&1 | tail -3` (expected: all pass; if pytest collects shell files badly, run `python3 -m pytest tests/test_offline_ai_smoke_health.py tests/test_aggregator_recall_health_hook.py -q`).

```bash
git add hooks/offline-ai-smoke-health.py tests/test_offline_ai_smoke_health.py settings.json
git commit -m "feat(hooks): announce a failed or stale offline-ai weekly smoke at SessionStart" -m "Reads ~/.local/state/offline-ai/smoke.json written by nixos-config's offline-ai-smoke timer. Silent when the last pass is recent or the file is missing; loud on fail, on no pass for 10 days, or on an unreadable file." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```
Then, as a SEPARATE command: `git push -u origin feat/offline-ai-smoke-health`. Then `gh pr create --title "feat(hooks): announce a failed or stale offline-ai weekly smoke at SessionStart" --body-file <file>` with a body (Summary / Test plan with the pytest line / `🤖 Generated with [Claude Code](https://claude.com/claude-code)`).

---

## Self-review

- Spec coverage: due check (T1 case 2), battery + idle gates (cases 3–5), nix-memory-run + timeout (case 1 grep), prompt + judge + reasons (6–9), cleanup rule (7, 9, 10), state truncation + model_ready (11), units + Environment (T2), toast (6), SessionStart hook with fail/stale/missing/unreadable (T3), design doc already committed. Gap: none.
- Placeholders: the commit message's `Advisor review` field is filled by the orchestrator after the review round, deliberately.
- Names consistent: `smoke` (nix let-binding) / `system.build.offline-ai-smoke` / `offline-ai-smoke.{service,timer}` / `OFFLINE_AI_SMOKE_*` env / `smoke.json`.
