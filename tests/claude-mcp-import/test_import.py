"""Unit tests for scripts/claude-mcp-import.py.

Run: python3 -m unittest tests/claude-mcp-import/test_import.py
"""
import copy
import json
import os
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.environ.get(
    "CLAUDE_MCP_IMPORT_SRC",
    os.path.join(HERE, "..", "..", "scripts", "claude-mcp-import.py"),
)

GITHUB = {"type": "stdio", "command": "github-mcp", "args": ["stdio"], "env": {}}
RESEARCH = {
    "type": "stdio",
    "command": "research-agent-mcp",
    "args": [],
    "env": {"RESEARCH_AGENT_TIMEOUT": "900"},
}
BROKER = {"type": "stdio", "command": "agent-e2e-broker", "args": ["--stdio"], "env": {}}
HAND_ADDED = {"type": "stdio", "command": "scratch-mcp", "args": [], "env": {"TOKEN": "live-secret"}}

LIVE = {
    "numStartups": 412,
    "oauthAccount": {"emailAddress": "x@example.invalid"},
    "projects": {"/home/jonathan": {"allowedTools": []}},
    "mcpServers": {"github": GITHUB, "research-agent": RESEARCH, "scratch": HAND_ADDED},
}
SERVED = {"github": GITHUB, "research-agent": RESEARCH, "agent_e2e_broker": BROKER}


def render(doc):
    return json.dumps(doc, indent=2) + "\n"


class ImportCase(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="mcp-import-test.")
        self.addCleanup(subprocess.run, ["rm", "-rf", self.dir], check=True)
        self.served = os.path.join(self.dir, "mcp-servers.json")
        self.live = os.path.join(self.dir, ".claude.json")
        self.lock = self.live + ".lock"
        self.marker = os.path.join(self.dir, ".projection-enabled")
        self.write(self.served, render(SERVED))
        self.write(self.live, render(LIVE))
        self.write(self.marker, "")

    def write(self, path, text):
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)

    def raw(self, path):
        with open(path, "rb") as f:
            return f.read()

    def read_live(self):
        with open(self.live, encoding="utf-8") as f:
            return json.load(f)

    def run_import(self, *extra):
        return subprocess.run(
            [sys.executable, SRC, "--served", self.served, "--live", self.live,
             "--marker", self.marker, *extra],
            capture_output=True, text=True, timeout=60,
        )

    def assert_unchanged_after(self, code, *extra):
        before = self.raw(self.live)
        proc = self.run_import(*extra)
        self.assertEqual(proc.returncode, code, proc.stderr)
        self.assertEqual(self.raw(self.live), before)
        return proc


class Merge(ImportCase):
    def test_tracked_server_missing_live_is_added(self):
        proc = self.run_import()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(self.read_live()["mcpServers"]["agent_e2e_broker"], BROKER)

    def test_live_only_server_survives(self):
        self.run_import()
        self.assertEqual(self.read_live()["mcpServers"]["scratch"], HAND_ADDED)

    def test_live_env_key_absent_from_tracked_survives(self):
        live = copy.deepcopy(LIVE)
        live["mcpServers"]["github"]["env"] = {"GITHUB_TOKEN": "live-secret"}
        self.write(self.live, render(live))
        self.run_import()
        self.assertEqual(self.read_live()["mcpServers"]["github"]["env"],
                         {"GITHUB_TOKEN": "live-secret"})

    def test_live_env_survives_tracked_entry_without_env_key(self):
        served = copy.deepcopy(SERVED)
        del served["research-agent"]["env"]
        self.write(self.served, render(served))
        self.run_import()
        self.assertEqual(self.read_live()["mcpServers"]["research-agent"]["env"],
                         RESEARCH["env"])

    def test_tracked_values_win_on_conflict(self):
        served = copy.deepcopy(SERVED)
        served["github"]["args"] = ["stdio", "--read-only"]
        served["research-agent"]["env"]["RESEARCH_AGENT_TIMEOUT"] = "1200"
        self.write(self.served, render(served))
        self.run_import()
        servers = self.read_live()["mcpServers"]
        self.assertEqual(servers["github"]["args"], ["stdio", "--read-only"])
        self.assertEqual(servers["research-agent"]["env"]["RESEARCH_AGENT_TIMEOUT"], "1200")

    def test_rest_of_live_file_untouched(self):
        self.run_import()
        got = self.read_live()
        for key in ("numStartups", "oauthAccount", "projects"):
            self.assertEqual(got[key], LIVE[key])
        self.assertEqual(list(got), list(LIVE))

    def test_live_without_mcp_servers_gains_them(self):
        live = copy.deepcopy(LIVE)
        del live["mcpServers"]
        self.write(self.live, render(live))
        self.run_import()
        self.assertEqual(self.read_live()["mcpServers"], SERVED)

    def test_mode_preserved(self):
        os.chmod(self.live, 0o600)
        self.run_import()
        self.assertEqual(stat.S_IMODE(os.stat(self.live).st_mode), 0o600)

    def test_lone_surrogate_in_live_file_survives(self):
        # JSON.stringify writes a lone surrogate as an escape; JSON.parse reads it back.
        live = copy.deepcopy(LIVE)
        live["projects"]["/home/jonathan"]["lastPrompt"] = "cut emoji \ud83d"
        self.write(self.live, render(live))
        proc = self.run_import()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.raw(self.live).decode("utf-8")
        self.assertEqual(self.read_live()["projects"], live["projects"])

    def test_second_run_is_a_no_op(self):
        self.run_import()
        ino = os.stat(self.live).st_ino
        proc = self.assert_unchanged_after(0)
        self.assertEqual(os.stat(self.live).st_ino, ino)
        self.assertIn("nothing to change", proc.stdout)


class NothingToDo(ImportCase):
    def test_no_marker(self):
        os.unlink(self.marker)
        self.assert_unchanged_after(0)

    def test_no_live_file(self):
        os.unlink(self.live)
        proc = self.run_import()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertFalse(os.path.exists(self.live))


class Refusals(ImportCase):
    def test_served_missing(self):
        os.unlink(self.served)
        self.assert_unchanged_after(75)

    def test_served_unparseable(self):
        self.write(self.served, "{ truncated")
        proc = self.assert_unchanged_after(75)
        self.assertIn("is not valid JSON", proc.stderr)

    def test_served_not_an_object(self):
        self.write(self.served, "[]\n")
        self.assert_unchanged_after(75)

    def test_served_entry_not_an_object(self):
        self.write(self.served, render({"github": "github-mcp"}))
        self.assert_unchanged_after(75)

    def test_served_nan(self):
        self.write(self.served, '{"github": {"timeout": NaN}}\n')
        self.assert_unchanged_after(75)

    def test_served_number_out_of_range(self):
        # JSON.parse reads 1e400 as Infinity; Python would write it back as `Infinity`.
        self.write(self.served, '{"github": {"timeout": 1e400}}\n')
        self.assert_unchanged_after(75)

    def test_live_unparseable(self):
        self.write(self.live, "{ half-written")
        self.assert_unchanged_after(75)


class Locking(ImportCase):
    def test_lock_released_after_write(self):
        proc = self.run_import()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertFalse(os.path.exists(self.lock))

    def test_lock_held_past_timeout_refuses(self):
        os.mkdir(self.lock)
        self.assert_unchanged_after(75, "--lock-timeout", "1")
        self.assertTrue(os.path.isdir(self.lock), "a lock it does not own was removed")

    def test_waits_for_lock_then_merges_the_file_written_under_it(self):
        os.mkdir(self.lock)
        concurrent = copy.deepcopy(LIVE)
        concurrent["numStartups"] = 413

        def holder():
            time.sleep(1)
            self.write(self.live, render(concurrent))
            os.rmdir(self.lock)

        t = threading.Thread(target=holder)
        t.start()
        proc = self.run_import("--lock-timeout", "20")
        t.join()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        got = self.read_live()
        self.assertEqual(got["numStartups"], 413)
        self.assertEqual(got["mcpServers"]["agent_e2e_broker"], BROKER)


if __name__ == "__main__":
    unittest.main()
