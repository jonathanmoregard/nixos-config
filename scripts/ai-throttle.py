"""ai-throttle: pause background AI work when the machine should be quiet.

Background units (the embedding backfill) share the iGPU and the memory bus
with interactive ones (speech-to-text). The iGPU has no scheduler priority a
cgroup can set, so this watcher does the only thing that works: it FREEZES the
background units (SIGSTOP via `systemctl --user kill`) while

  - the CPU package is hot  (Tctl >= PAUSE_AT_C; resumes only once it has
    cooled below RESUME_BELOW_C, so it does not flap at one temperature),
  - the laptop runs on battery (when REQUIRE_AC=1), or
  - a foreground unit used CPU within the last FOREGROUND_HOLD_S seconds
    (someone is dictating; the next dictation is likely close behind),

and resumes them (SIGCONT) once none of that holds. Pausing never kills: a
paused embed worker resumes mid-row, so no row is set aside as poison the way
a kill would. On exit every paused unit is resumed.

Configuration is environment (see modules/nixos/ai-throttle.nix):
  AI_THROTTLE_UNITS, AI_THROTTLE_FOREGROUND   space-separated unit names
  AI_THROTTLE_PAUSE_AT_C, AI_THROTTLE_RESUME_BELOW_C, AI_THROTTLE_FOREGROUND_HOLD_S,
  AI_THROTTLE_FOREGROUND_CPU_MS, AI_THROTTLE_REQUIRE_AC, AI_THROTTLE_INTERVAL_S
  AI_THROTTLE_STATE        state file (default $XDG_RUNTIME_DIR/ai-throttle/state.json)
  SYSFS_ROOT, CGROUP_ROOT, PROC_ROOT  for tests (default /sys, /sys/fs/cgroup, /proc)

`ai-throttle --once [--now EPOCH]` runs one decision against the state file
and exits; that is what tests/ai-throttle.nix drives.
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
PAUSE_AT = env_float("AI_THROTTLE_PAUSE_AT_C", 70)
RESUME_BELOW = env_float("AI_THROTTLE_RESUME_BELOW_C", 60)
HOLD_S = env_float("AI_THROTTLE_FOREGROUND_HOLD_S", 60)
FG_CPU_MS = env_float("AI_THROTTLE_FOREGROUND_CPU_MS", 50)
REQUIRE_AC = os.environ.get("AI_THROTTLE_REQUIRE_AC", "1") == "1"
INTERVAL = env_float("AI_THROTTLE_INTERVAL_S", 10)
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


def decide(st, now):
    """One decision. Mutates and returns the state dict."""
    reasons = []
    temp = hwmon_temp("k10temp")
    hot = bool(st.get("hot"))
    if temp is not None:
        if temp >= PAUSE_AT:
            hot = True
        elif temp < RESUME_BELOW:
            hot = False
    st["hot"] = hot
    if hot:
        reasons.append(f"hot:{temp}")

    ac = on_ac()
    if REQUIRE_AC and ac is False:
        reasons.append("battery")

    prev = st.get("fg_usage", {})
    usage = {}
    for u in FOREGROUND:
        cur = cgroup_usage_usec(u)
        if cur is None:
            continue
        usage[u] = cur
        if u in prev and (cur - prev[u]) / 1000 >= FG_CPU_MS:
            st["fg_last_active"] = now
    st["fg_usage"] = usage
    last = st.get("fg_last_active")
    if last is not None and now - last < HOLD_S:
        reasons.append("foreground")

    st["paused"] = bool(reasons)
    st["reasons"] = reasons
    st["temp_c"] = temp
    st["ac"] = ac
    st["ts"] = now
    return st


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


def tick(now):
    st = decide(load_state(), now)
    apply(st["paused"])
    save_state(st)
    return st


def main(argv):
    if "--once" in argv:
        now = float(argv[argv.index("--now") + 1]) if "--now" in argv else time.time()
        print(json.dumps(tick(now)))
        return 0

    def stop(*_):
        apply(False)
        sys.exit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    last_reasons = None
    while True:
        st = tick(time.time())
        kinds = [r.split(":")[0] for r in st["reasons"]]
        if kinds != last_reasons:
            print("paused: " + ", ".join(st["reasons"]) if st["paused"] else "running", flush=True)
            last_reasons = kinds
        time.sleep(INTERVAL)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
