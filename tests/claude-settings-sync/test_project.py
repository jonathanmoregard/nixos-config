"""Unit tests for scripts/claude-settings-project.py.

The checked-in settings.json is authoritative: after a run the live file is
the served file, byte for byte. A live-only edit does not survive, which is
the point -- every live-only entry measured on tuxedo was drift nobody
wanted: a store-pinned hook group dcg wrote into the file itself, an allow
rule a merged PR had deleted, and a `model` value `/model` wrote over the
checked-in one.

The fixtures model that measured divergence. `live_of` is what the harness
and dcg did to the file at runtime; `served_of` is what merged PRs did to
the repository copy. Both must end as `served_of`.

Run: python3 -m unittest tests/claude-settings-sync/test_project.py
"""
import copy
import glob
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.environ.get(
    "CLAUDE_SETTINGS_PROJECT_SRC",
    os.path.join(HERE, "..", "..", "scripts", "claude-settings-project.py"),
)

PUSH = {"matcher": "Bash", "hooks": [{"type": "command", "command": "push-check.sh"}]}
GUARD = {"matcher": "Bash", "hooks": [{"type": "command", "command": "python3 bash-guard.py"}]}
DCG = {
    "matcher": "Bash|PowerShell",
    "hooks": [{"type": "command", "command": "/nix/store/xxx-dcg-0.12.5/bin/dcg"}],
}
DISPLAY = [{"hooks": [{"type": "command", "command": "python3 code-span-punct.py", "timeout": 5}]}]
SKILLS_EDIT = "Edit(//home/jonathan/.claude/skills/**)"

BASE = {
    "model": "opus[1m]",
    "hooks": {"PreToolUse": [PUSH, GUARD]},
    # Fixture data for a unittest module, not a permissions table anything
    # loads. The gate's JSON-path exemption cannot reach it because this file
    # is Python, so it is waived here instead.
    # arftl-allow: permission-widened
    "permissions": {
        "allow": ["Read(//a/**)", SKILLS_EDIT],
        # A deny rule names a command in order to forbid it.
        # arftl-allow: destructive-rm
        "deny": ["Bash(rm -rf *)"],
    },
    "sandbox": {"enabled": False},
}


def live_of(base):
    """What the harness and dcg did to the file at runtime."""
    live = copy.deepcopy(base)
    live["model"] = "claude-opus-5"
    live["hooks"]["PreToolUse"].insert(0, DCG)
    live["permissions"]["allow"].append("Bash(ls:*)")
    return live


def served_of(base):
    """What merged PRs did to the repository copy."""
    served = copy.deepcopy(base)
    served["hooks"]["MessageDisplay"] = DISPLAY
    served["permissions"]["allow"].append("Read(//b/**)")
    served["permissions"]["allow"].remove(SKILLS_EDIT)
    served["sandbox"]["failIfUnavailable"] = True
    return served


def render(doc):
    return json.dumps(doc, indent=2, ensure_ascii=False) + "\n"


class ProjectionCase(unittest.TestCase):
    """A temp directory holding a served file, a live file and a marker."""

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="settings-project-test.")
        self.addCleanup(self._cleanup)
        self.served = os.path.join(self.dir, "served.json")
        self.live = os.path.join(self.dir, "live.json")
        self.marker = os.path.join(self.dir, ".projection-enabled")
        self.write(self.served, render(served_of(BASE)))
        self.write(self.live, render(live_of(BASE)))
        self.write(self.marker, "")

    def _cleanup(self):
        for path in glob.glob(os.path.join(self.dir, "*")) + glob.glob(
                os.path.join(self.dir, ".*")):
            os.unlink(path)
        os.rmdir(self.dir)

    def write(self, path, text):
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)

    def read(self, path):
        with open(path, "rb") as f:
            return f.read()

    def run_script(self, *extra, expect=0):
        argv = [sys.executable, SRC, "--served", self.served,
                "--live", self.live, "--marker", self.marker, *extra]
        done = subprocess.run(argv, capture_output=True, text=True, check=False)
        self.assertEqual(done.returncode, expect,
                         f"exit {done.returncode}\nstdout: {done.stdout}\nstderr: {done.stderr}")
        return done

    def strays(self):
        """Temporary files the script failed to clean up."""
        return [p for p in glob.glob(os.path.join(self.dir, ".*"))
                if os.path.basename(p) != ".projection-enabled"]


class TestProjection(ProjectionCase):
    def test_live_becomes_the_served_file_byte_for_byte(self):
        """The whole contract in one assertion."""
        self.run_script()
        self.assertEqual(self.read(self.live), self.read(self.served))

    def test_checked_in_value_wins_over_the_live_one(self):
        self.run_script()
        self.assertEqual(json.loads(self.read(self.live))["model"], "opus[1m]")

    def test_live_only_entries_are_dropped(self):
        self.run_script()
        doc = json.loads(self.read(self.live))
        self.assertNotIn(DCG, doc["hooks"]["PreToolUse"])
        self.assertNotIn("Bash(ls:*)", doc["permissions"]["allow"])

    def test_checked_in_additions_and_removals_both_land(self):
        self.run_script()
        doc = json.loads(self.read(self.live))
        self.assertEqual(doc["hooks"]["MessageDisplay"], DISPLAY)
        self.assertIn("Read(//b/**)", doc["permissions"]["allow"])
        self.assertNotIn(SKILLS_EDIT, doc["permissions"]["allow"])
        self.assertIs(doc["sandbox"]["failIfUnavailable"], True)

    def test_entries_the_repository_never_changed_survive(self):
        """Projection is not a reset: untouched keys are still there."""
        self.run_script()
        doc = json.loads(self.read(self.live))
        self.assertIn(GUARD, doc["hooks"]["PreToolUse"])
        # Asserts a deny rule SURVIVES the projection; the string is the
        # protection, not a hazard.
        # arftl-allow: destructive-rm
        self.assertIn("Bash(rm -rf *)", doc["permissions"]["deny"])

    def test_a_missing_live_file_is_created(self):
        os.unlink(self.live)
        self.run_script()
        self.assertEqual(self.read(self.live), self.read(self.served))
        self.assertEqual(stat.S_IMODE(os.stat(self.live).st_mode), 0o644)

    def test_an_unparseable_live_file_is_replaced(self):
        """Nothing is read out of the live file, so corruption cannot wedge it."""
        self.write(self.live, "{ this is not json")
        self.run_script()
        self.assertEqual(self.read(self.live), self.read(self.served))


class TestRefusals(ProjectionCase):
    """An unusable input must never leave the live file worse than it was."""

    def assert_live_untouched(self, before, inode):
        self.assertEqual(self.read(self.live), before)
        self.assertEqual(os.stat(self.live).st_ino, inode)
        self.assertEqual(self.strays(), [])

    def test_unparseable_served_refuses_and_leaves_live_alone(self):
        before, inode = self.read(self.live), os.stat(self.live).st_ino
        self.write(self.served, "{ truncated")
        self.run_script(expect=75)
        self.assert_live_untouched(before, inode)

    def test_served_that_is_not_an_object_refuses(self):
        before, inode = self.read(self.live), os.stat(self.live).st_ino
        self.write(self.served, "[]\n")
        self.run_script(expect=75)
        self.assert_live_untouched(before, inode)

    def test_missing_served_refuses(self):
        before, inode = self.read(self.live), os.stat(self.live).st_ino
        os.unlink(self.served)
        self.run_script(expect=75)
        self.assert_live_untouched(before, inode)

    def test_an_absent_marker_is_a_no_op(self):
        before, inode = self.read(self.live), os.stat(self.live).st_ino
        os.unlink(self.marker)
        self.run_script()
        self.assert_live_untouched(before, inode)

    def test_dry_run_writes_nothing_and_reports_the_change(self):
        before, inode = self.read(self.live), os.stat(self.live).st_ino
        done = self.run_script("--dry-run")
        self.assert_live_untouched(before, inode)
        self.assertIn("model", done.stdout)


class TestJsonParseParity(ProjectionCase):
    """Claude Code reads this file with JSON.parse, which is stricter than
    json.loads. A served file the harness cannot load must not be projected.
    Each payload below was confirmed to project with rc=0 before the fix."""

    def assert_refused(self, payload):
        before, inode = self.read(self.live), os.stat(self.live).st_ino
        with open(self.served, "wb") as f:
            f.write(payload)
        self.run_script(expect=75)
        self.assertEqual(self.read(self.live), before)
        self.assertEqual(os.stat(self.live).st_ino, inode)

    def test_nan_is_refused(self):
        self.assert_refused(b'{"a": NaN}\n')

    def test_infinity_is_refused(self):
        self.assert_refused(b'{"a": Infinity}\n')

    def test_negative_infinity_is_refused(self):
        self.assert_refused(b'{"a": -Infinity}\n')

    def test_a_utf8_bom_is_refused(self):
        self.assert_refused(b'\xef\xbb\xbf{"a": 1}\n')

    def test_utf16_is_refused(self):
        """json.loads sniffs this from bytes; JSON.parse cannot read it."""
        self.assert_refused('{"a": 1}\n'.encode("utf-16-le"))


class TestLiveModeLookup(unittest.TestCase):
    """The mode is the one thing still read from the live file, so its lookup
    must survive the file being unlinked between the read and the stat."""

    def test_a_vanished_live_file_falls_back_to_0644(self):
        import importlib.machinery
        import importlib.util
        spec = importlib.util.spec_from_loader(
            "project", importlib.machinery.SourceFileLoader("project", SRC))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        self.assertEqual(mod._live_mode("/nonexistent/settings.json"), 0o644)

    def test_an_existing_live_file_reports_its_own_mode(self):
        import importlib.machinery
        import importlib.util
        spec = importlib.util.spec_from_loader(
            "project", importlib.machinery.SourceFileLoader("project", SRC))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        with tempfile.NamedTemporaryFile(suffix=".json") as f:
            os.chmod(f.name, 0o600)
            self.assertEqual(mod._live_mode(f.name), 0o600)


class TestWriteDiscipline(ProjectionCase):
    def test_a_second_run_does_not_rewrite_the_file(self):
        self.run_script()
        inode = os.stat(self.live).st_ino
        done = self.run_script()
        self.assertEqual(os.stat(self.live).st_ino, inode,
                         "an unchanged file was replaced anyway")
        self.assertIn("nothing to change", done.stdout)

    def test_the_live_file_mode_is_preserved(self):
        os.chmod(self.live, 0o600)
        self.run_script()
        self.assertEqual(stat.S_IMODE(os.stat(self.live).st_mode), 0o600)

    def test_no_temporary_file_is_left_behind(self):
        self.run_script()
        self.assertEqual(self.strays(), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
