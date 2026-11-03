"""Unit tests for scripts/claude-settings-merge.py.

The merge brings the claude-config served copy of settings.json into the
live ~/.claude/settings.json without losing what the harness (or anything
else) wrote there at runtime. The fixtures model the divergence measured on
tuxedo: a live-only dcg hook group, a /model pin and an "always allow" rule
on one side; a new hook event, a new allow rule, a removed allow rule and a
new sandbox key on the other.

Run: python3 -m unittest tests/claude-settings-sync/test_merge.py
"""
import copy
import importlib.machinery
import importlib.util
import json
import os
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.environ.get(
    "CLAUDE_SETTINGS_MERGE_SRC",
    os.path.join(HERE, "..", "..", "scripts", "claude-settings-merge.py"),
)
# An explicit loader: the installed script has no .py suffix.
spec = importlib.util.spec_from_loader("merge", importlib.machinery.SourceFileLoader("merge", SRC))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

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
    "permissions": {
        "allow": ["Read(//a/**)", SKILLS_EDIT],
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


LIVE = live_of(BASE)
SERVED = served_of(BASE)


def canon(value):
    return json.dumps(value, sort_keys=True)


class Merge3(unittest.TestCase):
    def setUp(self):
        self.result, self.conflicts = m.merge3(BASE, LIVE, SERVED)

    # What merged PRs changed has to arrive.

    def test_upstream_scalar_addition_arrives(self):
        self.assertIs(self.result["sandbox"]["failIfUnavailable"], True)

    def test_upstream_list_addition_arrives(self):
        self.assertIn("Read(//b/**)", self.result["permissions"]["allow"])

    def test_upstream_list_removal_arrives(self):
        self.assertNotIn(SKILLS_EDIT, self.result["permissions"]["allow"])

    def test_upstream_new_hook_event_arrives(self):
        self.assertEqual(self.result["hooks"]["MessageDisplay"], DISPLAY)

    def test_upstream_change_to_untouched_scalar_arrives(self):
        served = copy.deepcopy(SERVED)
        served["model"] = "sonnet"
        live = copy.deepcopy(LIVE)
        live["model"] = BASE["model"]
        result, _ = m.merge3(BASE, live, served)
        self.assertEqual(result["model"], "sonnet")

    # What was written live has to survive.

    def test_live_only_hook_group_survives(self):
        self.assertIn(canon(DCG), [canon(g) for g in self.result["hooks"]["PreToolUse"]])

    def test_live_only_hook_group_survives_upstream_edit_of_same_list(self):
        served = copy.deepcopy(SERVED)
        new_group = {"matcher": "Bash", "hooks": [{"type": "command", "command": "new.sh"}]}
        served["hooks"]["PreToolUse"].append(new_group)
        result, _ = m.merge3(BASE, LIVE, served)
        groups = [canon(g) for g in result["hooks"]["PreToolUse"]]
        self.assertIn(canon(DCG), groups)
        self.assertIn(canon(new_group), groups)

    def test_live_only_allow_rule_survives(self):
        self.assertIn("Bash(ls:*)", self.result["permissions"]["allow"])

    def test_local_model_pin_survives_when_upstream_unchanged(self):
        self.assertEqual(self.result["model"], "claude-opus-5")

    def test_untouched_entries_survive_once(self):
        groups = [canon(g) for g in self.result["hooks"]["PreToolUse"]]
        self.assertEqual(sorted(groups), sorted({canon(PUSH), canon(GUARD), canon(DCG)}))
        allow = self.result["permissions"]["allow"]
        self.assertEqual(len(allow), len(set(allow)))
        self.assertEqual(self.result["permissions"]["deny"], ["Bash(rm -rf *)"])

    def test_no_conflicts_in_the_measured_divergence(self):
        self.assertEqual(self.conflicts, [])

    # Both sides changed the same scalar.

    def test_scalar_conflict_takes_served_and_is_reported(self):
        served = copy.deepcopy(SERVED)
        served["model"] = "sonnet"
        result, conflicts = m.merge3(BASE, LIVE, served)
        self.assertEqual(result["model"], "sonnet")
        self.assertEqual(len(conflicts), 1)
        self.assertIn("model", conflicts[0])


class LostAdditions(unittest.TestCase):
    """The check that refuses a merge which would drop a live-only entry.

    It must flag the two ways this has gone wrong or nearly gone wrong here
    — jq's `*` operator, which replaces arrays, and a blind copy — and must
    pass a correct merge, or it is a check that cannot fail or cannot pass.
    """

    def test_flags_jq_star_merge_dropping_live_hook(self):
        jq = shutil.which("jq")
        if jq is None:
            self.fail("jq is required: this test runs the real operator")
        with tempfile.TemporaryDirectory() as d:
            live, served = os.path.join(d, "live.json"), os.path.join(d, "served.json")
            with open(live, "w") as f:
                json.dump(LIVE, f)
            with open(served, "w") as f:
                json.dump(SERVED, f)
            out = subprocess.run(
                [jq, "-s", ".[0] * .[1]", live, served],
                check=True, capture_output=True, text=True,
            ).stdout
        lost = m.lost_additions(BASE, LIVE, SERVED, json.loads(out))
        self.assertTrue(any("dcg" in entry for entry in lost), lost)

    def test_flags_blind_copy_of_served(self):
        lost = m.lost_additions(BASE, LIVE, SERVED, copy.deepcopy(SERVED))
        self.assertTrue(any("dcg" in entry for entry in lost), lost)
        self.assertTrue(any("Bash(ls:*)" in entry for entry in lost), lost)

    def test_flags_merge_that_never_delivers(self):
        lost = m.lost_additions(BASE, LIVE, SERVED, copy.deepcopy(LIVE))
        self.assertTrue(any("Read(//b/**)" in entry for entry in lost), lost)

    def test_passes_merge3_output(self):
        result, _ = m.merge3(BASE, LIVE, SERVED)
        self.assertEqual(m.lost_additions(BASE, LIVE, SERVED, result), [])

    def test_flags_live_addition_under_key_upstream_deleted(self):
        served = copy.deepcopy(SERVED)
        del served["hooks"]["PreToolUse"]
        result, _ = m.merge3(BASE, LIVE, served)
        lost = m.lost_additions(BASE, LIVE, served, result)
        self.assertTrue(any("dcg" in entry for entry in lost), lost)


class Cli(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir)
        self.served = os.path.join(self.dir, "served.json")
        self.live = os.path.join(self.dir, "live", "settings.json")
        self.base = os.path.join(self.dir, "state", "base.json")
        self.marker = os.path.join(self.dir, "live", ".projection-enabled")
        os.makedirs(os.path.dirname(self.live))
        self.write(self.served, SERVED)
        self.write(self.live, LIVE)
        self.write(self.base, BASE)
        open(self.marker, "w").close()

    def write(self, path, value, text=None):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(text if text is not None else json.dumps(value, indent=2) + "\n")

    def read(self, path):
        with open(path) as f:
            return json.load(f)

    def raw(self, path):
        with open(path, "rb") as f:
            return f.read()

    def run_main(self, *extra):
        return m.main([
            "--served", self.served, "--live", self.live,
            "--base", self.base, "--marker", self.marker, *extra,
        ])

    def test_merges_and_records_served_as_next_base(self):
        self.assertEqual(self.run_main(), 0)
        live = self.read(self.live)
        self.assertIs(live["sandbox"]["failIfUnavailable"], True)
        self.assertIn(canon(DCG), [canon(g) for g in live["hooks"]["PreToolUse"]])
        self.assertEqual(self.read(self.base), SERVED)

    def test_second_run_is_a_noop(self):
        self.assertEqual(self.run_main(), 0)
        before = os.stat(self.live)
        self.assertEqual(self.run_main(), 0)
        after = os.stat(self.live)
        self.assertEqual((before.st_ino, before.st_mtime_ns), (after.st_ino, after.st_mtime_ns))

    def test_output_is_two_space_json_with_trailing_newline(self):
        self.run_main()
        text = self.raw(self.live).decode()
        self.assertTrue(text.endswith("}\n"))
        self.assertEqual(text, json.dumps(json.loads(text), indent=2, ensure_ascii=False) + "\n")

    def test_keeps_file_mode(self):
        os.chmod(self.live, 0o600)
        self.run_main()
        self.assertEqual(os.stat(self.live).st_mode & 0o777, 0o600)

    def test_installs_served_when_live_absent(self):
        os.remove(self.live)
        os.remove(self.base)
        self.assertEqual(self.run_main(), 0)
        self.assertEqual(self.read(self.live), SERVED)
        self.assertEqual(self.read(self.base), SERVED)

    def test_refuses_without_base_and_leaves_live_untouched(self):
        os.remove(self.base)
        before = self.raw(self.live)
        self.assertEqual(self.run_main(), 75)
        self.assertEqual(self.raw(self.live), before)
        self.assertFalse(os.path.exists(self.base))

    def test_records_base_without_writing_when_live_already_matches(self):
        os.remove(self.base)
        self.write(self.live, SERVED)
        before = os.stat(self.live)
        self.assertEqual(self.run_main(), 0)
        self.assertEqual(os.stat(self.live).st_mtime_ns, before.st_mtime_ns)
        self.assertEqual(self.read(self.base), SERVED)

    def test_refuses_unparseable_live(self):
        self.write(self.live, None, text="{ not json")
        self.assertEqual(self.run_main(), 75)
        self.assertEqual(self.raw(self.live), b"{ not json")

    def test_refuses_unparseable_served(self):
        self.write(self.served, None, text="[]")
        before = self.raw(self.live)
        self.assertEqual(self.run_main(), 75)
        self.assertEqual(self.raw(self.live), before)

    def test_refuses_lossy_merge_and_writes_nothing(self):
        served = copy.deepcopy(SERVED)
        del served["hooks"]["PreToolUse"]
        self.write(self.served, served)
        live_before, base_before = self.raw(self.live), self.raw(self.base)
        self.assertEqual(self.run_main(), 1)
        self.assertEqual(self.raw(self.live), live_before)
        self.assertEqual(self.raw(self.base), base_before)

    def test_does_nothing_before_cutover(self):
        os.remove(self.marker)
        before = self.raw(self.live)
        self.assertEqual(self.run_main(), 0)
        self.assertEqual(self.raw(self.live), before)

    def test_dry_run_writes_nothing(self):
        live_before, base_before = self.raw(self.live), self.raw(self.base)
        self.assertEqual(self.run_main("--dry-run"), 0)
        self.assertEqual(self.raw(self.live), live_before)
        self.assertEqual(self.raw(self.base), base_before)

    def test_unchanged_live_keeps_its_bytes(self):
        # dcg re-serialises without a trailing newline; a merge with nothing
        # to deliver must not rewrite the file just to reformat it.
        self.write(self.served, BASE)
        self.write(self.live, None, text=json.dumps(LIVE, indent=2))
        before = self.raw(self.live)
        self.assertEqual(self.run_main(), 0)
        self.assertEqual(self.raw(self.live), before)

    def test_concurrent_live_edit_is_not_lost(self):
        real_merge3 = m.merge3
        calls = []

        def racing_merge3(base, ours, theirs):
            if not calls:
                # The harness writes an "always allow" rule while we merge.
                edited = self.read(self.live)
                edited["permissions"]["allow"].append("Bash(git log:*)")
                self.write(self.live, edited)
            calls.append(1)
            return real_merge3(base, ours, theirs)

        m.merge3 = racing_merge3
        self.addCleanup(setattr, m, "merge3", real_merge3)
        self.assertEqual(self.run_main(), 0)
        live = self.read(self.live)
        self.assertIn("Bash(git log:*)", live["permissions"]["allow"])
        self.assertIs(live["sandbox"]["failIfUnavailable"], True)


if __name__ == "__main__":
    unittest.main()
