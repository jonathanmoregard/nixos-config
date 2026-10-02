"""host-telemetry: one JSON line per minute about heat, power and who caused it.

Written so "the machine ran hot and loud" can be matched against what was
running. Each line in $STATE/host-telemetry/YYYY-MM-DD.jsonl holds:

  ts            unix time
  tctl_c        CPU package temperature (k10temp Tctl, what drives the fans)
  gpu_c         iGPU edge temperature
  ram_c         DIMM temperatures (spd5118), list
  nvme_c        SSD temperature
  pkg_w         APU package power as amdgpu reports it (PPT)
  gpu_busy      iGPU busy percent at the sample instant
  ac            on mains power
  load1         1-minute load average
  mem_avail_gb, swap_used_gb
  cpu_top       [[unit, cpu_ms], ...] leaf units by CPU time in the last interval
  gpu_top       [[unit, gpu_ms], ...] units by iGPU time in the last interval
                (from /proc/<pid>/fdinfo; only this user's processes are
                readable, which covers every AI server on this host)
  throttle      ai-throttle's current state, if it runs

The fan speed itself is not here: this laptop's embedded controller drives the
fans and exposes no RPM to Linux without the vendor's kernel module.

`host-telemetry --once` writes one line and exits (tests drive that).
SYSFS_ROOT, CGROUP_ROOT, PROC_ROOT override the kernel trees for tests.
"""
import json
import os
import sys
import time
from datetime import datetime
from pathlib import Path

SYSFS = Path(os.environ.get("SYSFS_ROOT", "/sys"))
CGROUP = Path(os.environ.get("CGROUP_ROOT", "/sys/fs/cgroup"))
PROC = Path(os.environ.get("PROC_ROOT", "/proc"))
STATE_HOME = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state"))
OUT_DIR = Path(os.environ.get("HOST_TELEMETRY_DIR", STATE_HOME / "host-telemetry"))
INTERVAL = float(os.environ.get("HOST_TELEMETRY_INTERVAL_S", "60"))
KEEP_DAYS = int(os.environ.get("HOST_TELEMETRY_KEEP_DAYS", "30"))
TOP_N = 8
THROTTLE_STATE = Path(os.environ.get(
    "AI_THROTTLE_STATE",
    os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "ai-throttle", "state.json"),
))
SNAPSHOT = OUT_DIR / ".last-sample.json"


def read(path):
    try:
        return Path(path).read_text().strip()
    except OSError:
        return None


def num(v, scale=1.0):
    if v is None:
        return None
    try:
        return round(int(v) / scale, 1)
    except ValueError:
        return None


def hwmons():
    out = {}
    for d in sorted((SYSFS / "class/hwmon").glob("hwmon*")):
        out.setdefault(read(d / "name") or "", []).append(d)
    return out


def sensors():
    hw = hwmons()

    def temp(chip):
        for d in hw.get(chip, []):
            t = num(read(d / "temp1_input"), 1000)
            if t is not None:
                return t
        return None

    pkg_w = None
    for d in hw.get("amdgpu", []):
        for f in ("power1_average", "power1_input"):
            pkg_w = num(read(d / f), 1_000_000)
            if pkg_w is not None:
                break
    gpu_busy = None
    for p in sorted((SYSFS / "class/drm").glob("card*/device/gpu_busy_percent")):
        gpu_busy = num(read(p))
        if gpu_busy is not None:
            break
    ac = None
    for p in (SYSFS / "class/power_supply").glob("*"):
        if read(p / "type") == "Mains":
            ac = read(p / "online") == "1"
    return {
        "tctl_c": temp("k10temp"),
        "gpu_c": temp("amdgpu"),
        "ram_c": [t for t in (num(read(d / "temp1_input"), 1000) for d in hw.get("spd5118", []))
                  if t is not None],
        "nvme_c": temp("nvme"),
        "pkg_w": pkg_w,
        "gpu_busy": gpu_busy,
        "ac": ac,
    }


def system():
    load = read(PROC / "loadavg")
    mem = {}
    for line in (read(PROC / "meminfo") or "").splitlines():
        k, _, v = line.partition(":")
        if v.strip().split()[0].isdigit():
            mem[k] = int(v.strip().split()[0])
    gb = 1024 * 1024
    return {
        "load1": float(load.split()[0]) if load else None,
        "mem_avail_gb": round(mem["MemAvailable"] / gb, 1) if "MemAvailable" in mem else None,
        "swap_used_gb": round((mem["SwapTotal"] - mem["SwapFree"]) / gb, 1)
        if "SwapTotal" in mem and "SwapFree" in mem else None,
    }


def leaf_units():
    """CPU usage_usec of every leaf .service/.scope cgroup, keyed by unit name."""
    usage = {}
    for stat in CGROUP.rglob("cpu.stat"):
        d = stat.parent
        if not d.name.endswith((".service", ".scope")):
            continue
        if any(c.is_dir() and c.name.endswith((".service", ".scope")) for c in d.iterdir()):
            continue
        for line in (read(stat) or "").splitlines():
            k, _, v = line.partition(" ")
            if k == "usage_usec" and v.isdigit():
                usage[d.name] = usage.get(d.name, 0) + int(v)
    return usage


def gpu_by_unit():
    """iGPU engine time (ns) per unit, summed over each DRM client once."""
    clients = {}
    for pid_dir in PROC.glob("[0-9]*"):
        unit = None
        for line in (read(pid_dir / "cgroup") or "").splitlines():
            unit = line.rsplit("/", 1)[-1]
        fdinfo = pid_dir / "fdinfo"
        try:
            entries = list(fdinfo.iterdir())
        except OSError:
            continue
        for f in entries:
            text = read(f)
            if not text or "drm-client-id" not in text:
                continue
            cid, ns = None, 0
            for line in text.splitlines():
                k, _, v = line.partition(":")
                v = v.strip()
                if k == "drm-client-id":
                    cid = v
                elif k.startswith("drm-engine-") and v.endswith(" ns"):
                    ns += int(v.split()[0])
            if cid is not None:
                clients[cid] = (unit or "?", ns)
    out = {}
    for unit, ns in clients.values():
        out[unit] = out.get(unit, 0) + ns
    return out


def top(cur, prev, scale):
    deltas = []
    for k, v in cur.items():
        d = (v - prev.get(k, v)) / scale
        if d > 0:
            deltas.append([k, round(d)])
    deltas.sort(key=lambda kv: -kv[1])
    return deltas[:TOP_N]


def sample():
    try:
        prev = json.loads(SNAPSHOT.read_text())
    except (OSError, ValueError):
        prev = {}
    cpu, gpu = leaf_units(), gpu_by_unit()
    rec = {"ts": int(time.time()), **sensors(), **system(),
           "cpu_top": top(cpu, prev.get("cpu", {}), 1000),
           "gpu_top": top(gpu, prev.get("gpu", {}), 1_000_000)}
    try:
        rec["throttle"] = json.loads(THROTTLE_STATE.read_text())
        rec["throttle"] = {k: rec["throttle"].get(k) for k in ("paused", "reasons")}
    except (OSError, ValueError):
        rec["throttle"] = None
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    SNAPSHOT.write_text(json.dumps({"cpu": cpu, "gpu": gpu}))
    day = datetime.fromtimestamp(rec["ts"]).strftime("%Y-%m-%d")
    with open(OUT_DIR / f"{day}.jsonl", "a") as f:
        f.write(json.dumps(rec) + "\n")
    prune()
    return rec


def prune():
    cutoff = time.time() - KEEP_DAYS * 86400
    for p in OUT_DIR.glob("*.jsonl"):
        try:
            if p.stat().st_mtime < cutoff:
                p.unlink()
        except OSError:
            pass


def main(argv):
    if "--once" in argv:
        print(json.dumps(sample()))
        return 0
    while True:
        sample()
        time.sleep(INTERVAL)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
