"""Power control of a lane test node that plays a microVM (agent / scraper).

The host node's microvm@<vm> ExecStart/ExecStop (vmctl.py) write a request
to the shared 9p directory /var/lib/lane-nodectl; this daemon carries it out:

  agent    stop:  sshd down, every `agent` process killed (a power-off: an
                  undrained restart kills in-flight calls, as in prod);
           start: switch into the specialisation the host asked for (the
                  guest the host's `current` runner would boot), then sshd.
  scraper  stop:  scraper-http and sshd down;
           start: both up again, so scraper-http loads the code on its share
                  (the scraper guest is the same in every phase).
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time

D = "/var/lib/lane-nodectl"
PHASE = "/run/lane-node/phase"


def log(msg: str) -> None:
    print(f"lane-nodectl: {msg}", flush=True)


def sh(*argv: str, check: bool = True) -> int:
    log("run " + " ".join(argv))
    rc = subprocess.run(argv).returncode
    if check and rc != 0:
        raise RuntimeError(f"{argv[0]} rc={rc}")
    return rc


def phase() -> str:
    try:
        with open(PHASE) as f:
            return f.read().strip()
    except OSError:
        return "parent"


def converge(role: str, op: str, want: str) -> None:
    if role == "agent":
        if op == "stop":
            sh("systemctl", "stop", "sshd.service", check=False)
            sh("pkill", "-KILL", "-u", "agent", check=False)
            sh("loginctl", "terminate-user", "agent", check=False)
            return
        if phase() != want:
            sh(f"/run/booted-system/specialisation/{want}/bin/switch-to-configuration", "test")
            os.makedirs(os.path.dirname(PHASE), exist_ok=True)
            with open(PHASE, "w") as f:
                f.write(want + "\n")
        # A booted guest without the scraper-token share has no /etc/scraper
        # at all; the switch leaves the unmounted mount point behind.
        if os.path.isdir("/etc/scraper") and not os.path.ismount("/etc/scraper"):
            try:
                os.rmdir("/etc/scraper")
            except OSError:
                pass
        sh("systemctl", "start", "sshd.service")
    else:
        if op == "stop":
            sh("systemctl", "stop", "scraper-http.service", "sshd.service", check=False)
            return
        sh("systemctl", "start", "scraper-http.service", "sshd.service")


def main() -> None:
    role = sys.argv[1]
    last = None
    while True:
        try:
            with open(os.path.join(D, "want")) as f:
                want = json.load(f)
        except (OSError, ValueError):
            want = None
        if want and want.get("seq") != last:
            last = want["seq"]
            log(f"request {want}")
            state = "up" if want["op"] == "start" else "down"
            try:
                converge(role, want["op"], want["phase"])
            except Exception as e:
                state = f"failed {type(e).__name__}: {e}"
            have = {"seq": last, "state": state, "phase": phase()}
            tmp = os.path.join(D, ".have.tmp")
            with open(tmp, "w") as f:
                json.dump(have, f)
            os.replace(tmp, os.path.join(D, "have"))
            log(f"answered {have}")
        time.sleep(0.3)


if __name__ == "__main__":
    main()
