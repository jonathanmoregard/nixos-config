"""ai-throttle: keep background AI work quiet by governing its duty cycle.

Background units (the embedding backfill) share the iGPU and the memory bus
with everything interactive. The iGPU has no scheduler priority a cgroup can
set, so this watcher does the only thing that works: it FREEZES the background
units (SIGSTOP via `systemctl --user kill`) for part of every period and lets
them run for the rest. The run fraction, the duty, is the outcome of one
control loop:

    every CONTROL_S seconds:
        duty += GAIN * (setpoint - mean Tctl over the window), clamped to [DUTY_MIN, 1]

The setpoint is the input: QUIET_AT_C while someone is at the desk (the
temperature where the fans become audible), IDLE_QUIET_AT_C once nobody has
touched the machine for IDLE_AFTER_S (xprintidle; on mains). Duty 1 sends no
signal at all. A period runs pause-then-run, so an interrupted loop leaves the
units running.

Three conditions pause the units outright, whatever the duty:

  - the CPU package is very hot (Tctl >= PAUSE_AT_C; resumes only once it has
    cooled below RESUME_BELOW_C, so it does not flap at one temperature): the
    safety net above the governor, not its everyday tool,
  - the laptop runs on battery (when REQUIRE_AC=1),
  - a foreground unit used CPU within the last FOREGROUND_HOLD_S seconds
    (someone is dictating; the next dictation is likely close behind). Use
    is a rate, FOREGROUND_CPU_MS_PER_S of CPU per second of wall time since
    the previous sample, so the period length does not change what counts.

While paused outright the governor is frozen. Pausing never kills: a paused
embed worker resumes mid-row, so no row is set aside as poison the way a kill
would. On exit every paused unit is resumed.

Why a governor (telemetry of 2026-10-03): with the 70/60 C band alone, Tctl
swung 80 -> <60 -> 80 inside one 10 s tick, the journal held 234 heat pauses
in three hours, the backfill ran 23-44 % of the time and the fans surged with
it. A band is the wrong controller for a load whose heat answers in seconds.

Configuration is environment (see modules/nixos/ai-throttle.nix):
  AI_THROTTLE_UNITS, AI_THROTTLE_FOREGROUND   space-separated unit names
  AI_THROTTLE_QUIET_AT_C, AI_THROTTLE_IDLE_QUIET_AT_C, AI_THROTTLE_IDLE_AFTER_S
  AI_THROTTLE_PERIOD_S, AI_THROTTLE_CONTROL_S, AI_THROTTLE_GAIN, AI_THROTTLE_DUTY_MIN
  AI_THROTTLE_PAUSE_AT_C, AI_THROTTLE_RESUME_BELOW_C, AI_THROTTLE_FOREGROUND_HOLD_S,
  AI_THROTTLE_FOREGROUND_CPU_MS_PER_S, AI_THROTTLE_REQUIRE_AC
  AI_THROTTLE_STATE        state file (default $XDG_RUNTIME_DIR/ai-throttle/state.json)
  SYSFS_ROOT, CGROUP_ROOT, PROC_ROOT  for tests (default /sys, /sys/fs/cgroup, /proc)

`ai-throttle --once [--now EPOCH]` runs one control step and one period
against the state file and exits; that is what tests/ai-throttle.nix drives.
"""
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

SYSFS = Path(os.environ.get("SYSFS_ROOT", "/sys"))
CGROUP = Path(os.environ.get("CGROUP_ROOT", "/sys/fs/cgroup"))
PROC = Path(os.environ.get("PROC_ROOT", "/proc"))


def env_float(name, default):
    try:
        return float(os.environ.get(name, default))
    except ValueError:
        return float(default)


UNITS = os.environ.get("AI_THROTTLE_UNITS", "").split()
FOREGROUND = os.environ.get("AI_THROTTLE_FOREGROUND", "").split()
QUIET_AT = env_float("AI_THROTTLE_QUIET_AT_C", 70)
IDLE_QUIET_AT = env_float("AI_THROTTLE_IDLE_QUIET_AT_C", 78)
IDLE_AFTER_S = env_float("AI_THROTTLE_IDLE_AFTER_S", 900)
PERIOD = env_float("AI_THROTTLE_PERIOD_S", 2)
CONTROL_S = env_float("AI_THROTTLE_CONTROL_S", 30)
GAIN = env_float("AI_THROTTLE_GAIN", 0.02)
DUTY_MIN = env_float("AI_THROTTLE_DUTY_MIN", 0.1)
PAUSE_AT = env_float("AI_THROTTLE_PAUSE_AT_C", 90)
RESUME_BELOW = env_float("AI_THROTTLE_RESUME_BELOW_C", 80)
HOLD_S = env_float("AI_THROTTLE_FOREGROUND_HOLD_S", 60)
FG_CPU_MS_PER_S = env_float("AI_THROTTLE_FOREGROUND_CPU_MS_PER_S", 5)
REQUIRE_AC = os.environ.get("AI_THROTTLE_REQUIRE_AC", "1") == "1"
STATE = Path(os.environ.get(
    "AI_THROTTLE_STATE",
    os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "ai-throttle", "state.json"),
))


def read(path):
    try:
        return Path(path).read_text().strip()
    except OSError:
        return None


def hwmon_temp(chip):
    """First temp1_input of the hwmon named `chip`, in degrees C, or None."""
    for d in sorted((SYSFS / "class/hwmon").glob("hwmon*")):
        if read(d / "name") == chip:
            v = read(d / "temp1_input")
            if v is not None and v.lstrip("-").isdigit():
                return int(v) / 1000
    return None


def on_ac():
    """True on mains, False on battery, None when there is no AC adapter node."""
    vals = [read(p / "online") for p in (SYSFS / "class/power_supply").glob("*")
            if read(p / "type") == "Mains"]
    vals = [v for v in vals if v is not None]
    if not vals:
        return None
    return any(v == "1" for v in vals)


def idle_ms():
    """Milliseconds since the last input event (xprintidle), or None without an answer."""
    try:
        out = subprocess.run(["xprintidle"], capture_output=True, text=True,
                             check=False, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return None
    v = out.stdout.strip()
    if out.returncode != 0 or not v.isdigit():
        return None
    return int(v)


_cg_paths = {}


def cgroup_usage_usec(unit):
    """CPU time used so far by `unit`, wherever it sits in the hierarchy."""
    d = _cg_paths.get(unit)
    if d is None or not d.is_dir():
        d = next((p for p in CGROUP.rglob(unit) if p.is_dir()), None)
        if d is None:
            return None
        _cg_paths[unit] = d
    for line in (read(d / "cpu.stat") or "").splitlines():
        k, _, v = line.partition(" ")
        if k == "usage_usec" and v.isdigit():
            return int(v)
    return None


def systemctl(*args):
    return subprocess.run(["systemctl", "--user", *args],
                          capture_output=True, text=True, check=False)


def unit_procs(unit):
    """(ActiveState, [process states]) for every process in the unit's cgroup."""
    out = systemctl("show", "-p", "ActiveState", "-p", "ControlGroup", unit).stdout
    props = dict(line.split("=", 1) for line in out.splitlines() if "=" in line)
    states = []
    cg = props.get("ControlGroup", "")
    if cg:
        for pid in (read(CGROUP / cg.lstrip("/") / "cgroup.procs") or "").split():
            stat = read(PROC / pid / "stat") or ""
            # The state is the field after the parenthesised command name.
            rest = stat.rsplit(")", 1)[-1].split()
            if rest:
                states.append(rest[0])
    return props.get("ActiveState", ""), states


def apply(paused):
    """Bring every background unit to the wanted run state.

    SIGSTOP / SIGCONT, NOT the cgroup freezer: systemd refuses to stop a
    frozen unit ("Cannot stop frozen unit"), which would break offline-ai's
    eviction and a Home Manager switch that restarts the unit. A stopped
    process is still stoppable: on stop systemd sends SIGTERM followed by
    SIGCONT, so the unit shuts down through its normal handler.
    """
    for u in UNITS:
        active, states = unit_procs(u)
        if active != "active" or not states:
            continue
        if paused and any(st != "T" for st in states):
            systemctl("kill", "--signal=SIGSTOP", u)
        elif not paused and any(st == "T" for st in states):
            systemctl("kill", "--signal=SIGCONT", u)


def hard_reasons(st, now, temp, ac):
    """The conditions that pause the units outright. Mutates st (latches)."""
    reasons = []
    hot = bool(st.get("hot"))
    if temp is not None:
        if temp >= PAUSE_AT:
            hot = True
        elif temp < RESUME_BELOW:
            hot = False
    st["hot"] = hot
    if hot:
        reasons.append(f"hot:{temp}")

    if REQUIRE_AC and ac is False:
        reasons.append("battery")

    prev = st.get("fg_usage", {})
    elapsed = now - st["fg_ts"] if st.get("fg_ts") is not None else None
    usage = {}
    for u in FOREGROUND:
        cur = cgroup_usage_usec(u)
        if cur is None:
            continue
        usage[u] = cur
        if u in prev and elapsed and elapsed > 0 and (cur - prev[u]) / 1000 / elapsed >= FG_CPU_MS_PER_S:
            st["fg_last_active"] = now
    st["fg_usage"] = usage
    st["fg_ts"] = now
    last = st.get("fg_last_active")
    if last is not None and now - last < HOLD_S:
        reasons.append("foreground")
    return reasons


def govern(st, mean_temp, ac):
    """One control step: choose the setpoint, move the duty. Mutates st."""
    ms = idle_ms()
    idle = ms is not None and ms >= IDLE_AFTER_S * 1000 and ac is not False
    setpoint = IDLE_QUIET_AT if idle else QUIET_AT
    duty = float(st.get("duty", 1.0))
    if mean_temp is not None:
        duty = min(1.0, max(DUTY_MIN, duty + GAIN * (setpoint - mean_temp)))
    st["idle"] = idle
    st["setpoint_c"] = setpoint
    st["mean_c"] = mean_temp
    st["duty"] = round(duty, 3)


def decide(st, now, temp, ac, mean_temp=None, control=False):
    """One tick. `control` runs a governor step on `mean_temp`. Mutates and returns st."""
    reasons = hard_reasons(st, now, temp, ac)
    st["paused"] = bool(reasons)
    st["reasons"] = reasons
    if control and not reasons:
        govern(st, mean_temp, ac)
    st.setdefault("duty", 1.0)
    st.setdefault("setpoint_c", QUIET_AT)
    st.setdefault("idle", False)
    st.setdefault("mean_c", None)
    st["temp_c"] = temp
    st["ac"] = ac
    st["ts"] = now
    return st


def run_period(st, sleep=time.sleep):
    """One period: paused outright, or pause-then-run at the duty.

    Ends with the units running unless paused outright, so a loop that dies
    between periods leaves the backfill running (ExecStopPost covers a crash
    inside one).
    """
    if st["paused"]:
        apply(True)
        sleep(PERIOD)
        return
    duty = float(st["duty"])
    if duty < 1.0:
        apply(True)
        sleep(PERIOD * (1.0 - duty))
    apply(False)
    sleep(PERIOD * duty)


def load_state():
    try:
        return json.loads(STATE.read_text())
    except (OSError, ValueError):
        return {}


def save_state(st):
    STATE.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATE.with_suffix(".tmp")
    tmp.write_text(json.dumps(st))
    tmp.replace(STATE)


def describe(st):
    if st["paused"]:
        return "paused: " + ", ".join(st["reasons"])
    where = "idle" if st.get("idle") else "present"
    return (f"duty {st['duty']:.2f} (mean {st.get('mean_c')} C, "
            f"setpoint {st.get('setpoint_c')} C, {where})")


def main(argv):
    # Interrupted anywhere, even inside a --once pause phase, the units run on.
    def stop(*_):
        apply(False)
        sys.exit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    if "--once" in argv:
        now = float(argv[argv.index("--now") + 1]) if "--now" in argv else time.time()
        temp = hwmon_temp("k10temp")
        st = decide(load_state(), now, temp, on_ac(), mean_temp=temp, control=True)
        save_state(st)
        run_period(st)
        print(json.dumps(st))
        return 0

    st = load_state()
    samples = []
    last_control = 0.0
    last_line = None
    while True:
        now = time.time()
        temp = hwmon_temp("k10temp")
        if temp is not None:
            samples.append(temp)
        control = now - last_control >= CONTROL_S
        mean = sum(samples) / len(samples) if samples else None
        st = decide(st, now, temp, on_ac(), mean_temp=mean, control=control)
        if control:
            samples = []
            last_control = now
        if st["paused"]:
            # Temperatures measured with the units stopped say nothing about
            # the duty: the window restarts when the governor gets them back.
            samples = []
        save_state(st)
        line = describe(st)
        if line != last_line:
            print(line, flush=True)
            last_line = line
        run_period(st)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
