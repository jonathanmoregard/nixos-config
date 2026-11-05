"""vm-egress-switchover load generator: a research-agent MCP process, minus MCP.

Installed under the file name `research-agent-mcp-bootstrap.py`, so the
host's research-mcp-protocheck (gate G3) counts it as an MCP process exactly
like the real wrapper's bootstrap. It imports the REAL `mcp_server.server`
from --root (commit 1's copy for legacy-mcp, the live checkout for new-mcp),
writes the G3 protocol marker the way server.main() does when the code has
it, and loops N workers, each doing what research() does for one call:

    report.touch(); with _vm_lock(...): _run_agent(prompt, id, "normal")

so the slot lock, broker registration, the ssh dial, its retries and the
egress-mode choice are all the real code. The injection scanner is not run
(out of scope; it needs external APIs). Results: one JSON line per call to
/var/log/switchover/<name>.jsonl, closed fields only.

Control files (written by the testScript, root-owned, readable by all):
  /run/lane-ctl/step            current timeline step label, stamped per call
  /run/lane-ctl/<name>.pause    present: workers finish their call and idle
  /run/lane-ctl/<name>.req/*    one-shot extra calls: a JSON plan per file;
                                result lines carry `"req": <file name>`
"""
from __future__ import annotations

import argparse
import atexit
import base64
import itertools
import json
import os
import re
import signal
import sys
import threading
import time
import uuid
from pathlib import Path

CTL = Path("/run/lane-ctl")
VARIANTS = ["exa", "ikea", "ebay", "browse", "intercept"]
RESULT_RE = re.compile(r"^RESULT (\S+) (\S+)(?: (\S+))?$", re.M)
MODE_RE = re.compile(r"^MODE (\S+)$", re.M)


def plan_prompt(plan: dict) -> str:
    blob = base64.urlsafe_b64encode(json.dumps(plan).encode()).decode().rstrip("=")
    # The entry URLs are plain text so the broker ledgers them from the
    # prompt; the plan (canary URLs included) is not URL-shaped.
    return ("Lane research call: compare kettles. Start at https://shop.test/store "
            f"and https://shop.test/spa . LANEPLAN:{blob}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", required=True)
    ap.add_argument("--root", required=True)
    ap.add_argument("--workers", type=int, default=2)
    args = ap.parse_args()

    sys.path.insert(0, args.root)
    from mcp_server import server  # the real module under test
    try:
        from mcp_server import mcp_marker  # new code only (G3 marker)
    except ImportError:
        mcp_marker = None
    if mcp_marker is not None:
        atexit.register(mcp_marker.remove, mcp_marker.write())
    try:
        from mcp_server import artifact_gate
    except ImportError:
        artifact_gate = None
    unavailable = getattr(server, "_BrokerUnavailable", None)
    # Old code only (research-agent-old, the pre-broker main: no
    # `_BrokerUnavailable`): warm the static-secret cache single-threaded.
    # Its `_secrets()` snapshots SECRETS_CACHE and then skips every name
    # cached after the snapshot, so two concurrent FIRST calls race and the
    # loser ships a run with no provider keys (b5: exa "EXA_API_KEY not
    # set"). Fixed in research-agent 35895c6; the old pin is immutable, so
    # the lane cannot see past it otherwise. New code is NOT warmed: a
    # relapse of the race there must fail the step it happens in.
    if unavailable is None and hasattr(server, "_secrets"):
        server._secrets()

    out_path = Path(f"/var/log/switchover/{args.name}.jsonl")
    out_lock = threading.Lock()
    counter = itertools.count()
    inflight = [0]
    inflight_path = Path(f"/var/log/switchover/{args.name}.inflight")
    # Request priority. `_vm_lock` polls non-blocking flocks with a backoff
    # that grows to 5 s, so the longest waiter sleeps longest, and a worker
    # that just released a slot re-enters at 0.5 s and takes it back. With
    # the workers saturating both slots, a one-off request starved for the
    # whole 900 s (b8 T2b: t2b-long never registered with the broker while
    # 281 broker runs did). While a request waits for its slot it holds
    # `hold.<mcp>.<req>`; every MCP's workers start no new call meanwhile,
    # so only the pollers already waiting can overtake it.
    logd = out_path.parent

    def track(delta: int) -> None:
        with out_lock:
            inflight[0] += delta
            inflight_path.write_text(f"{inflight[0]}\n")

    # Call progress, so a step that sees no result can tell "nothing was
    # attempted" (the harness) from "waiting for a slot" (the lock) from
    # "slot held, no result" (the dial) (b12 T2c: 900 s with no way to tell).
    progress = {"attempted": 0, "locked": 0, "finished": 0}
    progress_path = Path(f"/var/log/switchover/{args.name}.progress")

    def bump(key: str) -> None:
        with out_lock:
            progress[key] += 1
            progress_path.write_text(json.dumps(progress, sort_keys=True) + "\n")

    def emit(rec: dict) -> None:
        with out_lock, open(out_path, "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, sort_keys=True) + "\n")

    def step() -> str:
        try:
            return (CTL / "step").read_text().strip()
        except OSError:
            return "?"

    def one_call(worker: int, plan: dict, req: str | None) -> None:
        rid = uuid.uuid4().hex
        st = step()
        rec = {"mcp": args.name, "worker": worker, "id": rid, "step": st,
               "variant": plan.get("v"), "req": req, "t0": time.time()}
        server.REPORTS_DIR.mkdir(parents=True, exist_ok=True)
        report = server.REPORTS_DIR / f"{rid}.md"
        report.touch()
        hold = None
        if req is not None:
            # The run id, so the testScript can follow this run in the
            # broker's log (its `run=` is this id).
            (logd / f"req.{req}.rid").write_text(rid + "\n")
            hold = logd / f"hold.{args.name}.{req}"
            hold.touch()
        track(1)
        bump("attempted")
        try:
            with server._vm_lock(server._VM_LOCK_WAIT_SECS):
                if hold is not None:
                    hold.unlink(missing_ok=True)
                rec["t_lock"] = time.time()
                bump("locked")
                rc, _out = server._run_agent(plan_prompt(plan), rid, "normal")
            rec["rc"] = rc
            body = report.read_text(encoding="utf-8", errors="replace") if report.exists() else ""
            if "\nDONE" not in body:
                # Diagnostics for a report that did not arrive: what the
                # host saw, a re-read after the share's attribute timeout,
                # and the tail of the dial's output (run-agent's stderr).
                rec["diag_size"] = report.stat().st_size if report.exists() else -1
                time.sleep(2)
                body = report.read_text(encoding="utf-8", errors="replace") if report.exists() else ""
                rec["diag_size_2s"] = len(body)
                rec["diag_out"] = (_out or "")[-600:]
            m = MODE_RE.search(body)
            rec["mode"] = m.group(1) if m else None
            rec["results"] = [[s, v, d] for s, v, d in RESULT_RE.findall(body)]
            rec["done"] = "\nDONE" in body
            if artifact_gate is not None and plan.get("v") in ("browse", "long", "reopen"):
                rec["artifacts"] = len(artifact_gate.fetch_artifacts(rid))
            want_fail = [r for r in rec["results"] if r[0].startswith("canary_")
                         and r[0] != "canary_browse_open" and r[1] != "refused"]
            # A legacy jail carries the 8 keys in its environment by design;
            # only a broker-mode jail must be clean, and must have been able
            # to read every process's environ (`envcheck_unreadable` 0):
            # a check that could not look must not read as "clean".
            envc = ("envcheck", "envcheck_unreadable")
            bad = [r for r in rec["results"] if not r[0].startswith("canary_")
                   and r[1] not in (("0",) if r[0] == "envcheck_unreadable" else ("ok", "clean"))
                   and not (r[0] in envc and rec["mode"] == "legacy")]
            rec["ok"] = rc == 0 and rec["done"] and not bad and not want_fail
            if not rec["ok"]:
                rec["diag_out"] = (_out or "")[-1200:]
        except Exception as e:  # closed: the class, and the broker's reason code
            rec["ok"] = False
            rec["error"] = type(e).__name__
            if unavailable is not None and isinstance(e, unavailable):
                rec["error"] = "research-broker unavailable"
                rec["reason"] = str(e)[:40]
        finally:
            if hold is not None:
                hold.unlink(missing_ok=True)
            report.unlink(missing_ok=True)
            rec["t1"] = time.time()
            emit(rec)
            track(-1)
            bump("finished")

    def worker(i: int) -> None:
        while True:
            if (CTL / f"{args.name}.pause").exists() or any(logd.glob("hold.*")):
                time.sleep(0.5)
                continue
            n = next(counter)
            plan = {"v": VARIANTS[n % len(VARIANTS)], "canary": True,
                    "envcheck": n % 4 == 0, "nonce": uuid.uuid4().hex[:8]}
            one_call(i, plan, None)

    def requests() -> None:
        d = CTL / f"{args.name}.req"
        seen: set[str] = set()
        while True:
            try:
                names = sorted(os.listdir(d))
            except OSError:
                names = []
            for n in names:
                if n in seen or n.startswith("."):
                    continue
                seen.add(n)
                try:
                    plan = json.loads((d / n).read_text())
                except (OSError, ValueError):
                    continue
                threading.Thread(target=one_call, args=(-1, plan, n), daemon=True).start()
            time.sleep(0.5)

    # SIGTERM (systemctl stop = the session ending) runs atexit, so the G3
    # marker goes away like the real server's on a clean exit.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    track(0)
    threading.Thread(target=requests, daemon=True).start()
    threads = [threading.Thread(target=worker, args=(i,), daemon=True) for i in range(args.workers)]
    for t in threads:
        t.start()
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
