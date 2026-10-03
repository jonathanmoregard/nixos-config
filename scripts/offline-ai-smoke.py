#!/usr/bin/env python3
"""Weekly smoke test for the offline-ai model.

Loads the model through the real `offline-ai` CLI, asks one trivial question, records
the verdict in a state file, and shouts only when it fails. Why: the model is an
emergency tool that is loaded a few times a month, and a model that no longer loads
is otherwise discovered exactly when the network is gone.

Driven by the offline-ai-smoke user timer: a nightly opportunity, a weekly cadence
(nothing runs while the last pass is younger than INTERVAL_DAYS). A night is skipped
outside the night window (a timer that elapsed during suspend fires at resume, which
would otherwise be mid-day), on battery, while the user is active, or while a nix
build holds nix-memory-run; a skip never hides the last verdict.

Every program used is found on PATH (offline-ai, systemctl, xprintidle, notify-send,
nix-memory-run, timeout) so tests/offline-ai-smoke.nix can stand in fakes.

Exit status: 0 for ok / skipped / not due, 1 for fail, 128+signal when aborted.
"""
import json
import os
import re
import signal
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
WINDOW = os.environ.get("OFFLINE_AI_SMOKE_WINDOW", "1-7")  # local hours, start inclusive, end exclusive
IDLE_MIN = env_float("OFFLINE_AI_SMOKE_IDLE_MIN", 15)
WAIT_MAX_MIN = env_float("OFFLINE_AI_SMOKE_WAIT_MAX_MIN", 120)
LOCK_WAIT_MIN = env_float("OFFLINE_AI_SMOKE_LOCK_WAIT_MIN", 60)
POLL_S = env_float("OFFLINE_AI_SMOKE_POLL_S", 300)
BUDGET_S = int(env_float("OFFLINE_AI_SMOKE_BUDGET_S", 600))
DOWN_TIMEOUT_S = int(env_float("OFFLINE_AI_SMOKE_DOWN_TIMEOUT_S", 900))
POWER_SUPPLY = Path(os.environ.get("OFFLINE_AI_SMOKE_POWER_SUPPLY_DIR", "/sys/class/power_supply"))
UNIT = os.environ.get("OFFLINE_AI_UNIT", "offline-ai-llm.service")
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


def local_hour():
    """The local hour; OFFLINE_AI_SMOKE_LOCAL_HOUR lets the harness pick one."""
    forced = os.environ.get("OFFLINE_AI_SMOKE_LOCAL_HOUR")
    return int(forced) if forced else datetime.now().hour


def window():
    start, end = WINDOW.split("-", 1)
    return int(start), int(end)


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


def unit_active():
    """Whether the model unit is running before we touch anything: True, False, or
    None when systemd could not be asked (then the model is never brought down)."""
    try:
        out = subprocess.run(["systemctl", "--user", "is-active", "--", UNIT],
                             capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired):
        return None
    state = out.stdout.strip()
    if out.returncode == 0 and state == "active":
        return True
    if out.returncode == 3 and state in ("inactive", "failed"):
        return False
    return None  # activating, deactivating, or systemd itself unreachable


def notify(summary, body):
    """Desktop toast. A toast that cannot be sent must not hide the verdict, which is
    already in the state file and the journal; so the failure is logged, not fatal."""
    try:
        subprocess.run(["notify-send", "-u", "critical", "-a", "offline-ai", summary, body],
                       timeout=15, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        log(f"desktop notification failed ({exc}); verdict is in {STATE} and this journal")


def skip(state, reason):
    """A night not used. Recorded beside, never over, the last verdict."""
    moment = iso(now())
    state.update({"last_run": moment, "last_skip": moment, "skip_reason": reason})
    save_state(state)
    log(f"skipped: {reason}")
    return 0


def verdict(state, status, reason, **extra):
    """Record an attempt's verdict, log it, toast on fail; returns the exit status."""
    moment = iso(now())
    state.update({"last_run": moment, "last_attempt": moment, "status": status, "reason": reason, **extra})
    if status == "ok":
        state["last_ok"] = moment
    save_state(state)
    log(f"{status}: {reason}")
    if status == "fail":
        notify("offline-ai smoke FAILED", f"{reason}\njournalctl --user -u offline-ai-smoke")
        return 1
    return 0


def attempt(state):
    was_up = unit_active()
    env = dict(os.environ, OFFLINE_AI_READY_TIMEOUT=str(BUDGET_S))
    # nix-memory-run --nonblock exits 75 while a nix build holds the memory lock;
    # while we hold it, auto-deploy defers its own build. timeout bounds the CLI,
    # which leaves offline mode in its own finally when it gets SIGTERM.
    lock_deadline = time.monotonic() + LOCK_WAIT_MIN * 60
    while True:
        began = time.monotonic()
        try:
            run = subprocess.run(
                ["nix-memory-run", "--nonblock", "--", "timeout", "-k", "30", str(BUDGET_S), "offline-ai", PROMPT],
                capture_output=True, text=True, errors="replace", env=env)
        except OSError as exc:
            return verdict(state, "fail", f"could not run offline-ai: {exc}", was_up=was_up)
        if run.returncode != 75:
            break
        if time.monotonic() >= lock_deadline:
            return skip(state, f"a memory-heavy job held nix-memory-run for {LOCK_WAIT_MIN:g} min")
        time.sleep(POLL_S)
    elapsed = round(time.monotonic() - began, 1)
    ready = re.search(r"model ready after (\d+(?:\.\d+)?) s", run.stderr)
    answer = run.stdout.strip()[:ANSWER_KEEP]
    last_words = " | ".join(run.stderr.strip().splitlines()[-3:])
    extra = {"exit_code": run.returncode, "elapsed_s": elapsed, "answer": answer, "was_up": was_up,
             "model_ready_s": float(ready[1]) if ready else None}

    # A CLI that exited by itself already left offline mode; one killed past the
    # grace period did not. Never touch a model the user had up before us, nor one
    # we could not tell about.
    cleanup = None
    if run.returncode != 0 and was_up is False:
        log("bringing the model down after a failed run")
        try:
            down = subprocess.run(["offline-ai", "down"], capture_output=True, text=True,
                                  timeout=DOWN_TIMEOUT_S, check=False)
            cleanup = "down ok" if down.returncode == 0 else f"down exited {down.returncode}"
        except subprocess.TimeoutExpired:
            cleanup = f"down timed out after {DOWN_TIMEOUT_S} s; the model may still be up"
        except OSError as exc:
            cleanup = f"down could not run: {exc}"
    elif run.returncode != 0 and was_up is None:
        cleanup = "not touched: could not tell whether the model was up before"
    if cleanup:
        log(cleanup)
        extra["cleanup"] = cleanup

    if run.returncode == 0 and EXPECT.search(run.stdout):
        detail = f"answered in {elapsed} s" + (f", model ready after {ready[1]} s" if ready else "")
        return verdict(state, "ok", detail, **extra)
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
    if cleanup and cleanup != "down ok":
        reason += f" [{cleanup}]"
    return verdict(state, "fail", reason, **extra)


def main():
    state = load_state()
    state["last_check"] = iso(now())
    state.setdefault("first_run", state["last_check"])
    last_ok = parse(state.get("last_ok"))
    if last_ok and now() - last_ok < timedelta(days=INTERVAL_DAYS):
        save_state(state)
        log(f"not due: last ok {iso(last_ok)}")
        return 0
    start, end = window()
    hour = local_hour()
    if not start <= hour < end:
        return skip(state, f"outside the night window {start:02d}-{end:02d} (hour {hour:02d})")
    if on_battery():
        return skip(state, "on battery")

    deadline = time.monotonic() + WAIT_MAX_MIN * 60
    while True:
        idle = idle_seconds()
        if idle is None:
            log("idle time unavailable (no display?); proceeding")
            break
        if idle >= IDLE_MIN * 60:
            break
        if time.monotonic() >= deadline:
            return skip(state, f"user active for {WAIT_MAX_MIN:g} min")
        time.sleep(POLL_S)

    # systemd stops us with SIGTERM when TimeoutStartSec runs out; the verdict must
    # still land in the state file and the journal. The children get their own
    # SIGTERM from the service's control group; the CLI leaves offline mode on it.
    def aborted(signum, frame):
        raise SystemExit(128 + signum)
    for number in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, aborted)
    try:
        return attempt(state)
    except SystemExit as exc:
        if isinstance(exc.code, int) and exc.code >= 128:
            verdict(state, "fail",
                    f"aborted by signal {exc.code - 128} (service timeout?); "
                    "run `offline-ai status` and `offline-ai down` if the model is still up")
        raise


if __name__ == "__main__":
    sys.exit(main())
