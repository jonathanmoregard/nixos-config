# testScript of vm-egress-switchover (tests/egress-switchover.nix). `LANE` is
# prepended by the .nix file: {"old": <research-agent-old>, "keyValues": [8 test
# key values], "keyedHosts": [...], "agentGlobal": <agent's address towards the
# internet>}.
import json
import time

C = LANE  # noqa: F821 (defined by the prelude)
KEYED = set(C["keyedHosts"])
# The 8 exact test key values. Never grep for the bare `LANEKEY-` prefix:
# fake_agent.py carries it as KEY_MARK and sits in the checkout the agent
# mounts as /workspace, so a prefix grep matched the marker's own
# definition (b10 T5). -a: /proc/*/environ is NUL-separated.
KEYS = C["keyValues"]
assert len(KEYS) == 8, KEYS
KEYGREP = "grep -lsaF " + " ".join(f"-e {k}" for k in KEYS)


def key_hits(node, where):
    """Files under `where` holding any of the 8 key values, by name."""
    return node.succeed(f"{KEYGREP} {where} || true").strip()
CO = "/home/jonathan/Repos/research-agent"
LOG = "/home/jonathan/.cache/research-agent/server.log"
MARK = {}


def say(msg):
    print(f"=== lane: {msg}", flush=True)


def now():
    return float(host.succeed("date +%s.%N").strip())


def set_step(s):
    host.succeed(f"echo {s} > /run/lane-ctl/step")
    MARK[s] = now()
    say(f"step {s}")


def records():
    out = host.succeed("cat /var/log/switchover/*.jsonl 2>/dev/null || true")
    rs = []
    for line in out.splitlines():
        try:
            rs.append(json.loads(line))
        except ValueError:
            pass  # a line being appended right now
    return rs


def xfail(r):
    return (r.get("req") or "").startswith("xfail-")


def check_no_failures(where):
    bad = [r for r in records() if not r["ok"] and not xfail(r)]
    if bad:
        rid = bad[0]["id"]
        agent.execute(f"ls -la /out | tail -n 5 >&2; cat /out/{rid}.md >&2; "
                      f"journalctl -t research-agent -n 20 -o cat >&2")
        host.execute(f"ls -la {CO}/reports | tail -n 5 >&2; tail -n 30 {LOG} >&2")
    assert not bad, f"{where}: {len(bad)} failed call(s): " + json.dumps(bad[:4], indent=1)


def wait_ok(step, n, mcp=None, mode=None, timeout=900):
    deadline = time.time() + timeout
    t_start = time.time()
    attempted0 = progress(mcp).get("attempted", 0) if mcp else None
    while True:
        rs = [r for r in records() if r["step"] == step and r["ok"] and not r.get("req")
              and (mcp is None or r["mcp"] == mcp) and (mode is None or r.get("mode") == mode)]
        if len(rs) >= n:
            return rs
        check_no_failures(f"{step} (waiting for {n} ok calls)")
        if mcp and time.time() - t_start > 120:
            # Fail fast on the harness case: the MCP started no call at all,
            # and has none in flight. Waiting for a slot or for a dial counts
            # as attempted, and is left to the full timeout.
            p = progress(mcp)
            if p.get("attempted", 0) == attempted0 and inflight_of(mcp) == 0:
                raise AssertionError(f"{step}: {mcp} attempted NO call in 120 s and has none in flight "
                                     f"(harness: paused, held, or its workers are not running): {p}")
        if time.time() >= deadline:
            # Say what DID happen in the step (b12 T2c timed out with no
            # way to tell a starved MCP from a hung dial).
            seen = {}
            for r in records():
                if r["step"] == step:
                    k = (r["mcp"], r.get("mode"), r["ok"])
                    seen[k] = seen.get(k, 0) + 1
            state = host.succeed("grep -H . /var/log/switchover/*.inflight "
                                 "/var/log/switchover/*.progress || true").strip()
            raise AssertionError(f"{step}: only {len(rs)} ok call(s) after {timeout}s; "
                                 f"calls in this step by (mcp, mode, ok): {sorted(seen.items(), key=str)}; "
                                 f"per-MCP in flight and progress (attempted/locked/finished, "
                                 f"cumulative): {state!r}")
        time.sleep(5)


def progress(mcp):
    out = host.succeed(f"cat /var/log/switchover/{mcp}.progress 2>/dev/null || true").strip()
    return json.loads(out) if out else {}


def inflight_of(mcp):
    out = host.succeed(f"cat /var/log/switchover/{mcp}.inflight 2>/dev/null || true").strip()
    return int(out or 0)


def req(mcp, name, plan):
    tmp = f"/run/lane-ctl/{mcp}.req/.{name}"
    host.succeed(f"echo {json.dumps(json.dumps(plan))} > {tmp} && mv {tmp} /run/lane-ctl/{mcp}.req/{name}")


def wait_req(name, timeout=900):
    deadline = time.time() + timeout
    while True:
        rs = [r for r in records() if r.get("req") == name]
        if rs:
            say(f"request {name}: {json.dumps(rs[0])}")
            return rs[0]
        assert time.time() < deadline, f"request {name}: no result after {timeout}s"
        time.sleep(3)


def pause(mcp):
    # While `mcp` drains, hold EVERY MCP's workers (loadgen honours
    # /var/log/switchover/hold.*): a call of `mcp` still waiting for a slot
    # is otherwise starved by the other MCP's workers, which re-enter
    # `_vm_lock` at 0.5 s while it backs off to 5 s (b10 T3: 617 s).
    hold = f"/var/log/switchover/hold.pause.{mcp}"
    host.succeed(f"touch /run/lane-ctl/{mcp}.pause {hold}")
    t0 = now()
    host.wait_until_succeeds(f"grep -qx 0 /var/log/switchover/{mcp}.inflight", timeout=1200)
    host.succeed(f"rm -f {hold}")
    say(f"pause {mcp}: drained in {now() - t0:.1f}s")


def resume(mcp):
    host.succeed(f"rm -f /run/lane-ctl/{mcp}.pause")


def switch(phase):
    out = host.succeed(f"/run/booted-system/specialisation/{phase}/bin/switch-to-configuration test 2>&1")
    say(f"switch into {phase}:\n{out}")
    return out


def units_in(out, prefix):
    names = []
    for line in out.splitlines():
        if line.startswith(prefix):
            names += [u.strip() for u in line[len(prefix):].split(",")]
    return names


def restarted_by_switch(out, unit):
    return any(unit in units_in(out, p) for p in (
        "stopping the following units: ", "restarting the following units: "))


def released(vm):
    return int(host.succeed(
        f"journalctl -u research-vm-roll@{vm}.service -o cat | grep -c ': released$' || true").strip())


def wait_released(vm, before, timeout=900):
    host.wait_until_succeeds(
        f"test $(journalctl -u research-vm-roll@{vm}.service -o cat | grep -c ': released$') -gt {before}",
        timeout=timeout)
    say(host.succeed(f"journalctl -u research-vm-roll@{vm}.service -o cat | tail -n 25"))


def wait_roll_done(vm, timeout=900):
    host.wait_until_fails(f"systemctl is-active --quiet research-vm-roll@{vm}.service", timeout=timeout)


def agent_phase(p):
    agent.wait_until_succeeds(f"grep -qx {p} /run/lane-node/phase", timeout=300)


def dial_line(rid):
    return host.succeed(f"grep -h 'egress dial id={rid} ' {LOG} || true").strip()


def scraper_health():
    return json.loads(host.succeed("curl -fsS -m 10 http://127.0.0.1:8123/health"))


def no_key_in_guest(where):
    hits = key_hits(agent, "/proc/[0-9]*/environ")
    assert not hits, f"{where}: a test key value in agent process environ(s): {hits}"
    upstream.succeed("test ! -s /var/log/canary")
    say(f"{where}: none of the 8 key values in any agent process environment; /var/log/canary empty")


# ---------------------------------------------------------------- boot
lane = host.shared_dir / "lane"
for d in ("research-agent", "bearer", "ctl-agent", "ctl-scraper"):
    (lane / d).mkdir(parents=True, exist_ok=True)
    (lane / d).chmod(0o777)

upstream.start()
host.start()
upstream.wait_for_unit("lane-upstream.service")
upstream.wait_for_unit("dnsmasq.service")
host.wait_for_unit("multi-user.target")
host.wait_for_unit("lane-secrets.service")
UID = host.succeed("id -u jonathan").strip()

with subtest("checkout: commit 1 checked out, commit 2 waiting on origin"):
    host.succeed("runuser -u jonathan -- lane-git setup")
    host.succeed(f"test -f {CO}/scraper/server.py && test ! -e {CO}/broker/server.py")
    host.succeed(f"runuser -u jonathan -- git -C {CO} log --oneline >&2")

scraper.start()
agent.start()
for node in (agent, scraper):
    node.wait_for_unit("multi-user.target")
    node.wait_for_unit("lane-nodectl.service")

with subtest("T0 setup: host into base (pre-nixos-A); both microVMs boot"):
    host.succeed("echo T0 > /run/lane-ctl/step")
    switch("base")
    for vm in ("research-agent", "scraper"):
        host.wait_for_unit(f"microvm@{vm}.service", timeout=600)
        # Type=simple (as the real qemu runner): active before the guest is up.
        host.wait_until_succeeds(f"journalctl -u microvm@{vm}.service -o cat | grep -q 'reachable; READY'",
                                 timeout=600)
    agent_phase("base")
    host.succeed("test ! -e /etc/research-agent/egress-era")

with subtest("SLIRP emulation: hostfwds, gateway DNAT, guest egress"):
    host.succeed("ssh-keyscan -t ed25519 -p 2223 127.0.0.1 | grep -q ssh-ed25519")
    host.succeed("ssh-keyscan -t ed25519 -p 2225 127.0.0.1 | grep -q ssh-ed25519")
    host.succeed("ssh -i /run/lane-secrets/research-agent-host-key -o StrictHostKeyChecking=no "
                 "-o UserKnownHostsFile=/dev/null -p 2223 agent@127.0.0.1 true")
    say(host.succeed("curl -fsS -m 10 http://127.0.0.1:8123/health"))
    agent.succeed("curl -sS -m 10 -o /dev/null http://10.0.2.2:8123/health")
    rc = agent.execute("curl -sS -m 5 -o /dev/null http://10.0.2.2:8124/")[0]
    assert rc == 28, f"base: the pre-A guest egress must drop :8124 (curl rc {rc}, want 28)"
    agent.succeed("getent ahostsv4 api.exa.ai | grep -q 11.0.0.10")
    agent.succeed("test -r /etc/scraper/token")
    agent.fail("getent ahostsv4 evil.test")

with subtest("T0: base config, old code, legacy-mcp: calls succeed"):
    set_step("T0")
    host.succeed(f"lane-mcp legacy-mcp {C['old']}")
    wait_ok("T0", 3, mcp="legacy-mcp")
    check_no_failures("T0")

# ---------------------------------------------------------------- T1
with subtest("T1: switch into expand; the switch leaves microvm@research-agent running; drained roll"):
    set_step("T1")
    n_agent = released("research-agent")
    out = switch("expand")
    assert not restarted_by_switch(out, "microvm@research-agent.service"), \
        "T1: switch-to-configuration restarted microvm@research-agent (undrained)"
    assert "microvm@research-agent.service" in units_in(out, "NOT restarting the following changed units: "), \
        "T1 positive control: the switch must see microvm@research-agent as changed"
    wait_released("research-agent", n_agent)
    agent_phase("expand")
    wait_roll_done("scraper")
    say(host.succeed("journalctl -u research-vm-roll@scraper.service -o cat | tail -n 25"))
    wait_ok("T1", 3)
    check_no_failures("T1")
    host.succeed("grep -qx legacy-ok /etc/research-agent/egress-era")
    rc = agent.execute("curl -sS -m 5 -o /dev/null http://10.0.2.2:8124/")[0]
    assert rc == 7, f"expand: :8124 must be open and refused by the inert broker (curl rc {rc}, want 7)"
    agent.succeed("curl -sS -m 10 -o /dev/null http://10.0.2.2:8123/health")
    agent.succeed("getent ahostsv4 api.exa.ai | grep -q 11.0.0.10")
    for s in ("research-broker.socket", "research-broker-admin.socket"):
        assert host.succeed(f"systemctl show -P ActiveState {s}").strip() == "inactive", s
        assert host.succeed(f"systemctl show -P ConditionResult {s}").strip() == "no", s

# ---------------------------------------------------------------- T2
with subtest("T2: pull; broker sockets start; scraper roll; new-mcp broker, legacy-mcp legacy guest-side"):
    n_scraper = released("scraper")
    host.succeed("runuser -u jonathan -- lane-git pull")
    set_step("T2")
    host.wait_until_succeeds("systemctl is-active research-broker.socket research-broker-admin.socket",
                             timeout=120)
    host.succeed(f"lane-mcp new-mcp {CO}")
    wait_released("scraper", n_scraper)
    h = scraper_health()
    assert "stale" in h and h["stale"] is False, f"T2: the scraper must run the pulled code: {h}"
    new = wait_ok("T2", 3, mcp="new-mcp", mode="broker")
    # server.log begins with new-mcp's first dial; T3's G3 window must not
    # reach back before it (b10: a window opened 120 s before T2 failed the
    # log-coverage check on its own).
    MARK["log"] = now()
    old = wait_ok("T2", 3, mcp="legacy-mcp")
    for r in new[:3]:
        line = dial_line(r["id"])
        assert "mode=broker reason=broker-present era=legacy-ok" in line, f"new-mcp dial: {line!r}"
    for r in old[:3]:
        assert r["mode"] == "legacy", r
        agent.succeed("journalctl -t research-agent -o cat | grep -qx "
                      f"'run-agent: protocol=legacy fields=11 broker_token=absent run={r['id']}'")
    browse = [r for r in records() if r["variant"] == "browse" and r["ok"] and not r.get("req")]
    assert browse and all(r.get("artifacts", 0) >= 1 for r in browse), \
        "every browse call's screenshot artifact must reach the host: " + json.dumps(browse)
    check_no_failures("T2")

with subtest("T2b: no-op change under broker/ reloads the broker; a long browse run spans it"):
    set_step("T2b")
    req("new-mcp", "t2b-long", {"v": "long", "long_s": 60, "canary": False, "envcheck": False, "nonce": "t2b"})
    # THIS run's session, not any earlier one: T2's browse calls have
    # already logged `session/open`, so a bare grep matched at once (b8).
    host.wait_until_succeeds("test -s /var/log/switchover/req.t2b-long.rid", timeout=60)
    rid = host.succeed("cat /var/log/switchover/req.t2b-long.rid").strip()
    host.wait_until_succeeds(
        f"journalctl -u research-broker.service -o cat | grep -q 'run={rid} POST /v1/scraper/session/open 200'",
        timeout=300)
    time.sleep(10)
    host.succeed("runuser -u jonathan -- lane-git noop && runuser -u jonathan -- lane-git pull")
    host.wait_until_succeeds("journalctl -u research-broker.service -o cat | grep -q 'state saved'", timeout=300)
    host.wait_until_succeeds("journalctl -u research-broker.service -o cat | grep -q 'state loaded'", timeout=300)
    say(host.succeed("journalctl -u research-broker.service -o cat | grep -E 'state (saved|loaded)'"))
    r = wait_req("t2b-long")
    assert r["ok"], f"T2b: the long run spanning the reload failed: {r}"
    wait_ok("T2b", 3)
    check_no_failures("T2b")

# ---------------------------------------------------------------- T3
with subtest("T3: G3 gate fails while legacy-mcp lives, passes once it has stopped"):
    set_step("T3")
    # From just after server.log's first lines (MARK["log"], +5 s for the
    # 4-decimal hours rounding), never before them: the log-coverage check
    # must pass on its own, so rc=1 below can only come from a marker.
    hours = (now() - MARK["log"] - 5) / 3600
    gate = (f"runuser -u jonathan -- env XDG_RUNTIME_DIR=/run/user/{UID} "
            f"research-mcp-protocheck --window-hours {hours:.4f}")
    rc, out = host.execute(gate)
    say(f"G3 with legacy-mcp alive: rc={rc}\n{out}")
    assert rc == 1 and "no protocol marker" in out, "T3: G3 must fail while a pre-pull MCP process lives"
    assert "not the whole" not in out, "T3: the G3 window reaches back before server.log (lane bug)"
    pause("legacy-mcp")
    host.succeed("systemctl stop lane-legacy-mcp.service")
    rc, out = host.execute(gate)
    say(f"G3 after legacy-mcp stopped: rc={rc}\n{out}")
    assert rc == 0, "T3: G3 must pass once every MCP process runs new code"

# ---------------------------------------------------------------- T4
with subtest("T4: switch into contract; drained roll; zero failed calls"):
    set_step("T4")
    n_agent = released("research-agent")
    out = switch("contract")
    assert not restarted_by_switch(out, "microvm@research-agent.service"), \
        "T4: switch-to-configuration restarted microvm@research-agent (undrained)"
    wait_released("research-agent", n_agent)
    agent_phase("contract")
    wait_ok("T4", 3, mcp="new-mcp", mode="broker")
    check_no_failures("T4")
    MARK["T4done"] = now()

# ---------------------------------------------------------------- T5
with subtest("T5: final state"):
    set_step("T5")
    host.succeed("grep -qx broker-only /etc/research-agent/egress-era")
    agent.succeed("test ! -e /etc/scraper")
    agent.fail("getent ahostsv4 api.exa.ai")
    agent.fail("curl -sS -m 5 -o /dev/null http://10.0.2.2:8123/health")
    req("new-mcp", "t5-jail", {"v": "none", "canary": True, "envcheck": True, "nonce": "t5"})
    for _ in range(10):
        hits = key_hits(agent, "/proc/[0-9]*/environ")
        assert not hits, f"T5: a test key value in agent process environ(s) during the jail run: {hits}"
        time.sleep(2)
    r = wait_req("t5-jail")
    verdicts = {s: v for s, v, _ in r.get("results") or []}
    # Not just "no key seen": every process's environ must have been read.
    # Checked before `ok`, which a non-zero count also clears, so the
    # failure names the count.
    assert verdicts.get("envcheck_unreadable") == "0", \
        f"T5: the jail envcheck could not read {verdicts.get('envcheck_unreadable')} process environ(s): {verdicts}"
    assert r["ok"] and r["mode"] == "broker", f"T5 jail run: {r}"
    assert verdicts.get("envcheck") == "clean" and verdicts.get("tlsprobe") == "ok", verdicts
    assert all(v == "refused" for s, v in verdicts.items()
               if s.startswith("canary_") and s != "canary_browse_open"), verdicts
    hits = key_hits(agent, "-r /workspace /etc")
    assert not hits, f"T5: a test key value in agent file(s): {hits}"
    wait_ok("T5", 3, mcp="new-mcp", mode="broker")
    check_no_failures("T5")
    no_key_in_guest("T5")
    reqs = [json.loads(x) for x in upstream.succeed("cat /var/log/upstream/requests.jsonl").splitlines() if x]
    leaks = [x for x in reqs if x["client"] == C["agentGlobal"] and x["host"] in KEYED
             and x["ts"] > MARK["T4done"]]
    assert not leaks, f"T5: keyed hosts reached from the agent under contract: {leaks[:5]}"
    from_host = [x for x in reqs if x["host"] in KEYED and x["ts"] > MARK["T4done"]]
    assert from_host and all(x["client"] != C["agentGlobal"] for x in from_host), \
        "T5: keyed calls must still happen, from the broker"

# G2^-1 (§12.6 step 2 rollback, §12.7): an MCP spawned while nixos-B's wrapper
# exports no keys keeps an empty key environment for life. It is fine in
# broker mode; at code^-1 it goes legacy/no-protocol-marker with no keys and
# fails closed until its session reconnects, even in the right B^-1 -> code^-1
# order. A SECOND MCP: T5b's 8-key precondition covers new-mcp and stays.
with subtest("G2^-1 setup: a keyless MCP spawned under broker-only serves in broker mode"):
    host.succeed("touch /run/lane-ctl/g2inv-mcp.pause")  # requests only
    host.succeed(f"lane-mcp g2inv-mcp {CO} keyless")
    host.wait_until_succeeds("systemctl is-active --quiet lane-g2inv-mcp.service", timeout=60)
    kpid = host.succeed("systemctl show -P MainPID lane-g2inv-mcp.service").strip()
    kenv = host.succeed(f"tr '\\0' '\\n' < /proc/{kpid}/environ")
    assert "CLAUDE_CODE_OAUTH_TOKEN=" in kenv, "G2^-1: read the wrong environ (no provider token in it)"
    k_keys = sum(1 for v in C["keyValues"] if v in kenv)
    assert k_keys == 0, f"G2^-1 precondition: g2inv-mcp must hold no key ({k_keys} of 8)"
    req("g2inv-mcp", "t5-keyless", {"v": "exa", "canary": True, "envcheck": True, "nonce": "t5k"})
    r = wait_req("t5-keyless")
    assert r["ok"] and r["mode"] == "broker", f"G2^-1: a keyless MCP under broker-only must serve in broker mode: {r}"

with subtest("T5b: broker gone under contract; the T2 MCP holding all 8 keys fails closed"):
    set_step("T5b")
    pause("new-mcp")
    host.succeed("systemctl stop research-broker.socket research-broker-admin.socket research-broker.service")
    left = host.execute("test -e /run/research-broker/admin.sock")[0] == 0
    say(f"admin socket path after the stop: {'still on disk' if left else 'gone'}")
    pid = host.succeed("systemctl show -P MainPID lane-new-mcp.service").strip()
    n_keys = int(host.succeed(f"tr '\\0' '\\n' < /proc/{pid}/environ | grep -c '=LANEKEY-'").strip())
    assert n_keys == 8, f"T5b precondition: new-mcp must hold all 8 keys in its environment ({n_keys})"
    req("new-mcp", "xfail-t5b", {"v": "exa", "canary": True, "envcheck": True, "nonce": "t5b"})
    r = wait_req("xfail-t5b")
    assert not r["ok"] and r.get("error") == "research-broker unavailable", f"T5b: {r}"
    line = dial_line(r["id"])
    say(f"T5b dial line: {line!r}")
    assert line and "mode=legacy" not in line and "era=broker-only" in line, f"T5b dial: {line!r}"
    # §12.5 T5b: record the observed mode, never demand one the mechanism
    # cannot produce. `_egress_mode` tests the socket PATH, which a stopped
    # socket unit leaves on disk (RemoveOnStop=no), so a stopped broker can
    # read as `mode=broker reason=broker-present` and fail closed at the
    # connect; the predicate's fix is research-agent's (PR 4). What must hold
    # is a designed mode: anything outside this set fails loudly.
    fields = dict(kv.split("=", 1) for kv in line.split() if "=" in kv)
    say(f"T5b observed: mode={fields.get('mode')} reason={fields.get('reason')} "
        f"(admin socket path left on disk: {left})")
    assert fields.get("mode") in ("broker", "closed"), f"T5b: an undesigned dial mode: {line!r}"
    agent.fail(f"journalctl -t research-agent -o cat | grep -q 'run={r['id']}'")
    no_key_in_guest("T5b")
    host.succeed("systemctl start research-broker.socket research-broker-admin.socket")
    resume("new-mcp")
    wait_ok("T5b", 3, mcp="new-mcp", mode="broker")
    check_no_failures("T5b")

# ---------------------------------------------------------------- T6
with subtest("T6a: B^-1 first: back into expand"):
    set_step("T6a")
    n_agent = released("research-agent")
    out = switch("expand")
    assert not restarted_by_switch(out, "microvm@research-agent.service"), "T6a: undrained restart"
    wait_released("research-agent", n_agent)
    agent_phase("expand")
    host.succeed("grep -qx legacy-ok /etc/research-agent/egress-era")
    wait_ok("T6a", 3, mcp="new-mcp")
    check_no_failures("T6a")
    req("g2inv-mcp", "t6a-keyless", {"v": "exa", "canary": True, "envcheck": False, "nonce": "t6ak"})
    r = wait_req("t6a-keyless")
    assert r["ok"] and r["mode"] == "broker", f"G2^-1: after B^-1 the keyless MCP is still broker-mode and fine: {r}"

with subtest("T6b: then code^-1: revert pushed and pulled"):
    n_scraper = released("scraper")
    host.succeed("runuser -u jonathan -- lane-git revert && runuser -u jonathan -- lane-git pull")
    set_step("T6b")
    host.succeed(f"test ! -e {CO}/broker/server.py")
    host.wait_until_succeeds(
        "! systemctl is-active --quiet research-broker.socket"
        " && ! systemctl is-active --quiet research-broker-admin.socket"
        " && ! systemctl is-active --quiet research-broker.service", timeout=300)
    rs = wait_ok("T6b", 3, mcp="new-mcp", mode="legacy")
    say(f"T6b dial line: {dial_line(rs[0]['id'])!r}")
    assert "mode=legacy" in dial_line(rs[0]["id"]) and "era=legacy-ok" in dial_line(rs[0]["id"])
    check_no_failures("T6b")
    # G2^-1: the keyless MCP, spawned under broker-only, fails closed at
    # code^-1 even in the right order (downtime, not a leak) ...
    req("g2inv-mcp", "xfail-g2inv-t6b", {"v": "exa", "canary": False, "envcheck": False, "nonce": "t6bk"})
    r = wait_req("xfail-g2inv-t6b")
    line = dial_line(r["id"])
    say(f"G2^-1 keyless MCP at code^-1: {r.get('error')} reason={r.get('reason')}; dial line: {line!r}")
    assert not r["ok"] and r.get("error") == "research-broker unavailable" \
        and r.get("reason") == "legacy-no-keys", f"G2^-1: {r}"
    assert "mode=closed reason=legacy-no-keys era=legacy-ok" in line, f"G2^-1 dial: {line!r}"
    agent.fail(f"journalctl -t research-agent -o cat | grep -q 'run={r['id']}'")
    # ... and recovers once its session reconnects: a fresh spawn after B^-1
    # has the wrapper's key exports again.
    host.succeed("systemctl stop lane-g2inv-mcp.service")
    host.succeed("touch /run/lane-ctl/reconnect-mcp.pause")
    host.succeed(f"lane-mcp reconnect-mcp {CO}")
    req("reconnect-mcp", "t6b-reconnect", {"v": "exa", "canary": False, "envcheck": False, "nonce": "t6br"})
    r = wait_req("t6b-reconnect")
    assert r["ok"] and r["mode"] == "legacy", f"G2^-1: the reconnected session must serve legacy: {r}"
    host.succeed("systemctl stop lane-reconnect-mcp.service")
    # The reverted scraper code must be loaded too: a drained roll of the
    # NEW scraper, the first roll in this timeline whose idleness the roll
    # reads from the real /health counters (at T2 the old scraper reports
    # none, so the roll takes its legacy branch). This is the end-to-end pin
    # of the roll's field names against the real scraper.
    deadline = time.time() + 300
    while time.time() < deadline and "stale" in scraper_health():
        time.sleep(5)
    h = scraper_health()
    roll_log = host.succeed("journalctl -u research-vm-roll@scraper.service -o cat | tail -n 30")
    say(roll_log)
    assert "stale" not in h, f"T6b: the scraper still runs the reverted-away code 300 s after code^-1: {h}"
    assert "scraper idle: 0 open sessions, 0 pending artifacts" in roll_log, roll_log

# ------------------------------------------- T6, wrong order (§12.5 sub-run)
with subtest("T6 wrong order: code^-1 without B^-1 fails closed, never legacy"):
    set_step("W1")
    host.succeed("runuser -u jonathan -- lane-git reapply && runuser -u jonathan -- lane-git pull")
    host.wait_until_succeeds("systemctl is-active research-broker.socket research-broker-admin.socket",
                             timeout=120)
    wait_ok("W1", 2, mcp="new-mcp", mode="broker")
    set_step("W2")
    n_agent = released("research-agent")
    switch("contract")
    wait_released("research-agent", n_agent)
    agent_phase("contract")
    wait_ok("W2", 2, mcp="new-mcp", mode="broker")
    set_step("W3")
    pause("new-mcp")
    host.succeed("runuser -u jonathan -- lane-git revert && runuser -u jonathan -- lane-git pull")
    host.wait_until_succeeds("! systemctl is-active --quiet research-broker.socket", timeout=300)
    req("new-mcp", "xfail-wrong-order", {"v": "exa", "canary": True, "envcheck": True, "nonce": "w3"})
    r = wait_req("xfail-wrong-order")
    line = dial_line(r["id"])
    say(f"wrong-order dial line: {line!r}")
    assert not r["ok"] and r.get("error") == "research-broker unavailable", f"wrong order: {r}"
    assert "mode=closed reason=no-protocol-marker era=broker-only" in line, f"wrong order: {line!r}"
    no_key_in_guest("wrong order")
    set_step("W4")
    n_agent = released("research-agent")
    switch("expand")
    wait_released("research-agent", n_agent)
    agent_phase("expand")
    resume("new-mcp")
    wait_ok("W4", 2, mcp="new-mcp", mode="legacy")
    check_no_failures("W4")

# ---------------------------------------------------------------- T6c, A^-1
with subtest("T6c: back to base (nixos-A reverted), drained by hand first (§12.6 step 1)"):
    # A^-1 removes the roll units themselves, and base's microvm@research-agent
    # has restartIfChanged=true: the switch restarts the VM and nothing can
    # drain it. Zero downtime here is a property of the runbook, not of the
    # mechanism: drain the MCP servers to 0 in flight, then revert. The two
    # facts are asserted apart: a restart is EXPECTED (False would mean
    # something still drains, i.e. the mechanism changed); a failed call is
    # downtime. b12 had both at once: restart True, 0 failed calls.
    set_step("T6c")
    pause("new-mcp")  # the only MCP alive here (legacy-mcp ended at T3)
    out = switch("base")
    restarted = restarted_by_switch(out, "microvm@research-agent.service")
    say(f"T6c restart observed (expected on A^-1, not downtime): microvm@research-agent restarted={restarted}")
    assert restarted, "T6c: A^-1 did NOT restart microvm@research-agent; base has restartIfChanged=true " \
                      "and no roll, so something still drains: the mechanism changed, update §12.6"
    host.wait_for_unit("microvm@research-agent.service", timeout=600)
    agent_phase("base")
    host.succeed("test ! -e /etc/research-agent/egress-era")
    resume("new-mcp")
    wait_ok("T6c", 3, mcp="new-mcp", mode="legacy")
    bad = [r for r in records() if r["step"] == "T6c" and not r["ok"] and not xfail(r)]
    say(f"T6c downtime check (the zero-downtime claim): {len(bad)} failed call(s) after the hand drain")
    check_no_failures("T6c")

# --------------------------------------------- T2c, wrong-order deploy (sub-run)
with subtest("T2c: new code on a base (pre-nixos-A) host: mode=legacy reason=no-broker"):
    set_step("T2c")
    host.succeed("runuser -u jonathan -- lane-git reapply && runuser -u jonathan -- lane-git pull")
    # A fresh pre-A host has never had the admin socket; a reboot clears /run.
    host.succeed("rm -f /run/research-broker/admin.sock")
    # b12 T2c: new-mcp2 had 0 ok calls in 900 s while ~560 legacy runs went
    # through, the shape of the slot-lock starvation of b8 T2b and b10 T3
    # (a fresh MCP's pollers back off to 5 s in `_vm_lock`; new-mcp's two
    # workers re-enter at 0.5 s and keep both slots). Measured here first,
    # with new-mcp still running, then new-mcp (not under test) is paused
    # to the end.
    host.succeed(f"lane-mcp new-mcp2 {CO}")
    time.sleep(60)
    mine = [r for r in records() if r["step"] == "T2c"]
    by = {}
    for r in mine:
        k = (r["mcp"], r.get("mode"), r["ok"])
        by[k] = by.get(k, 0) + 1
    say(f"T2c contention, 60 s with new-mcp running: new-mcp2 progress {progress('new-mcp2')} "
        f"in flight {inflight_of('new-mcp2')}; T2c calls by (mcp, mode, ok): {sorted(by.items(), key=str)}")
    pause("new-mcp")
    rs = wait_ok("T2c", 3, mcp="new-mcp2", mode="legacy")
    line = dial_line(rs[0]["id"])
    say(f"T2c dial line: {line!r}")
    assert "mode=legacy reason=no-broker era=absent" in line, f"T2c: {line!r}"
    bad = [r for r in records() if r["step"] == "T2c" and not r["ok"] and not xfail(r)]
    assert not bad, f"T2c: {json.dumps(bad[:3])}"

# ------------------------------- T2d, undrained scraper restart (sub-run)
# §12.4's real window for unbound sessions: between the pull and the drained
# roll, any undrained scraper restart (Restart=always after a crash or a
# MemoryMax kill, or the watchdog) loads the pulled scraper/server.py off the
# live share while a pre-pull run's OLD shim, which names no run_id on
# open/act/screenshot/close, is still alive. On base (no roll to compete for
# slots); the restart mechanism does not depend on the phase.
with subtest("T2d: a pre-pull run's old shim opens a NEW session on a scraper restarted undrained"):
    set_step("T2d")
    pause("new-mcp2")  # new-mcp is paused since T2c: nothing else is in flight
    host.succeed("runuser -u jonathan -- lane-git revert && runuser -u jonathan -- lane-git pull")
    host.succeed(f"test ! -e {CO}/broker/server.py")
    scraper.succeed("systemctl restart scraper-http.service")  # 0 in flight
    host.wait_until_succeeds("curl -fsS -m 5 http://127.0.0.1:8123/health", timeout=120)
    h = scraper_health()
    assert "stale" not in h, f"T2d: the scraper must run the old code before the pull: {h}"
    CLOSES = ("journalctl -u scraper-http.service -o cat | "
              "grep -c '\"POST /session/[0-9a-f]*/close HTTP/1.1\" 200' || true")
    closes0 = int(scraper.succeed(CLOSES).strip() or 0)
    host.succeed("touch /run/lane-ctl/legacy-mcp2.pause")  # its workers stay idle
    host.succeed(f"lane-mcp legacy-mcp2 {C['old']}")
    long_s = 45
    req("legacy-mcp2", "t2d-reopen",
        {"v": "reopen", "long_s": long_s, "canary": False, "envcheck": False, "nonce": "t2d"})
    host.wait_until_succeeds("test -s /var/log/switchover/req.t2d-reopen.rid", timeout=60)
    rid = host.succeed("cat /var/log/switchover/req.t2d-reopen.rid").strip()
    # Its first session closed: the old shim is running, and the run sleeps.
    scraper.wait_until_succeeds(f"test $({CLOSES}) -gt {closes0}", timeout=300)
    t_close = now()
    host.succeed("runuser -u jonathan -- lane-git reapply && runuser -u jonathan -- lane-git pull")
    host.succeed(f"test -e {CO}/broker/server.py")
    n0 = int(scraper.succeed("systemctl show -P NRestarts scraper-http.service").strip())
    # A crash, not a stop: the unit's own Restart=always brings it back.
    scraper.succeed("systemctl kill -s KILL scraper-http.service")
    host.wait_until_succeeds("curl -fsS -m 5 http://127.0.0.1:8123/health | grep -q '\"stale\": false'",
                             timeout=60)
    t_new = now()
    n1 = int(scraper.succeed("systemctl show -P NRestarts scraper-http.service").strip())
    say(f"T2d: scraper-http restarted by Restart= (NRestarts {n0} -> {n1}), on the pulled code "
        f"{t_new - t_close:.1f}s after the run's first session closed (it sleeps {long_s}s)")
    assert n1 == n0 + 1, f"T2d: scraper-http must come back through its own Restart= ({n0} -> {n1})"
    assert t_new - t_close < long_s - 5, \
        f"T2d: the new scraper was up only {t_new - t_close:.1f}s in; the run's second open may predate it"
    host.succeed("test \"$(cat /var/log/switchover/legacy-mcp2.inflight)\" = 1")
    r = wait_req("t2d-reopen")
    # The run used the OLD guest code: only the new run-agent.sh logs a
    # protocol line, and new code would also have sent a run_id.
    agent.fail(f"journalctl -t research-agent -o cat | grep -q 'run-agent: protocol=.* run={rid}$'")
    assert r.get("mode") == "legacy", f"T2d: {r}"
    assert r["ok"], f"T2d: the old shim's new session on the restarted scraper failed: {r}"
    # The failure that would otherwise read as success: a 200 on the open
    # with the artifact lost. It must be pullable via /artifacts/<run id>.
    assert r.get("artifacts", 0) >= 1, f"T2d: the run's screenshot artifact did not reach the host: {r}"
    host.succeed("systemctl stop lane-legacy-mcp2.service")

# ---------------------------------------------------------------- End
with subtest("End: aggregate"):
    rs = records()
    steps = []
    for r in rs:
        if r["step"] not in steps:
            steps.append(r["step"])
    for s in steps:
        mine = [r for r in rs if r["step"] == s]
        lat = sorted(r["t1"] - r["t0"] for r in mine)
        waits = [r["t_lock"] - r["t0"] for r in mine if "t_lock" in r]
        say(f"{s:5} calls={len(mine):3} failed={sum(1 for r in mine if not r['ok'] and not xfail(r))}"
            f" xfail={sum(1 for r in mine if xfail(r))}"
            f" latency p50={lat[len(lat) // 2]:.1f}s max={lat[-1]:.1f}s"
            f" lock-wait max={max(waits, default=0):.1f}s")
        assert max(waits, default=0) < 1800, f"{s}: a call waited past the 1800 s lock bound"
    failed = [r for r in rs if not r["ok"] and not xfail(r)]
    say(f"total calls={len(rs)} failed={len(failed)}")
    assert not failed, json.dumps(failed[:5])
