"""The importer, fed the host's generated list, leaves ~/.claude.json with
exactly the configured servers, each one an argv the managed policy allows."""
import json
import os
import subprocess
import sys
import tempfile

importer, served, policy_path, names_path = sys.argv[1:5]
names = set(json.load(open(names_path)))
policy = json.load(open(policy_path))
allowed = [e["serverCommand"] for e in policy["allowedMcpServers"] if "serverCommand" in e]

with tempfile.TemporaryDirectory() as d:
    live, marker = os.path.join(d, "claude.json"), os.path.join(d, "marker")
    open(marker, "w").close()
    with open(live, "w") as f:
        json.dump({"numStartups": 3, "mcpServers": {"stale": {"command": "/tmp/x"}}}, f)
    subprocess.run([sys.executable, importer, "--served", served, "--live", live, "--marker", marker], check=True)
    doc = json.load(open(live))

got = doc["mcpServers"]
assert set(got) == names, f"live servers {sorted(got)} != configured {sorted(names)}"
for name, entry in got.items():
    argv = [entry["command"]] + entry.get("args", [])
    assert argv in allowed, f"{name}: {argv} is not in the managed allowlist"
assert doc["numStartups"] == 3, doc
print(f"ok: importer contract, {len(got)} servers")
