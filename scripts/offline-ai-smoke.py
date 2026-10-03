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


def finish(state, status, reason, rc, **extra):
    """Record the verdict, log it, toast on fail; returns rc, the process exit status.
    (Not named exit_code: extra carries the CLI's exit_code into the state file.)"""
    state.update({"last_run": iso(now()), "status": status, "reason": reason, **extra})
    if status == "ok":
        state["last_ok"] = state["last_run"]
    save_state(state)
    log(f"{status}: {reason}")
    if status == "fail":
        notify("offline-ai smoke FAILED", f"{reason}\njournalctl --user -u offline-ai-smoke")
    return rc


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
