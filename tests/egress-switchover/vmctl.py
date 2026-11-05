"""ExecStart / ExecStop of microvm@<vm> on the lane's `host` node.

The lane keeps microvm.nix's real microvm@<vm> units (restartTriggers,
X-RestartIfChanged, set-booted, install-microvm, ordering) and replaces only
these two commands, because a test VM cannot run qemu inside itself. Instead
of booting a microVM, they drive the test node that plays it over a shared
9p control directory (/var/lib/lane-vmctl/<vm>, watched by nodectl.py on that
node):

  start  ask the node to come up in the specialisation matching the host's
         current one (/etc/lane/phase), wait for it, wait for what the roll
         and the MCP see of a booted VM (sshd banner on the hostfwd port, or
         the scraper's /health), send READY=1 and stay as the main process;
  stop   ask the node to go down (sshd and every agent process gone, as on
         a VM power-off) and wait for it.
"""
from __future__ import annotations

import json
import os
import socket
import sys
import time
import urllib.request

PROBE = {
    "research-agent": ("ssh", 2223),
    "scraper": ("http", 8123),
}


def log(msg: str) -> None:
    print(f"lane-vmctl: {msg}", flush=True)


def request(d: str, op: str, phase: str, timeout: float) -> None:
    seq = time.time_ns()
    tmp = os.path.join(d, ".want.tmp")
    with open(tmp, "w") as f:
        json.dump({"seq": seq, "op": op, "phase": phase}, f)
    os.replace(tmp, os.path.join(d, "want"))
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with open(os.path.join(d, "have")) as f:
                have = json.load(f)
            if have.get("seq") == seq:
                log(f"{op} done: {have}")
                if have.get("state") not in ("up", "down"):
                    raise SystemExit(f"lane-vmctl: node failed {op}: {have.get('state')}")
                return
        except (OSError, ValueError):
            pass
        time.sleep(0.3)
    raise SystemExit(f"lane-vmctl: node did not answer {op} within {timeout:.0f}s")


def probe(vm: str) -> bool:
    kind, port = PROBE[vm]
    try:
        if kind == "ssh":
            with socket.create_connection(("127.0.0.1", port), timeout=5) as s:
                s.settimeout(5)
                return s.recv(64).startswith(b"SSH-")
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=5) as r:
            return json.load(r).get("status") == "ok"
    except (OSError, ValueError):
        return False


def notify(msg: str) -> None:
    addr = os.environ.get("NOTIFY_SOCKET")
    if not addr:
        return
    if addr.startswith("@"):
        addr = "\0" + addr[1:]
    with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as s:
        s.sendto(msg.encode(), addr)


def main() -> None:
    vm, op = sys.argv[1], sys.argv[2]
    d = f"/var/lib/lane-vmctl/{vm}"
    with open("/etc/lane/phase") as f:
        phase = f.read().strip()
    try:
        current = os.readlink(f"/var/lib/microvms/{vm}/current")
    except OSError:
        current = "none"
    log(f"{vm} {op} phase={phase} current={current}")
    if op == "stop":
        request(d, "stop", phase, 120)
        return
    request(d, "start", phase, 240)
    while not probe(vm):
        time.sleep(1)
    log(f"{vm} reachable; READY")
    notify("READY=1")
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
