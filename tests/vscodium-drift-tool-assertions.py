"""Behavioural checks for the VSCodium settings drift recorder/reporter.

Prints PASS/FAIL per case and exits non-zero on any failure. The last line
is `all green`, which tests/vscodium-drift-tool.nix asserts: a runner that
reports per-case instead of failing fast must be shown to have finished.

Two ways to invoke it, on purpose:

    nix build .#checks.x86_64-linux.vscodium-drift-tool -L
        The gate. Drives ${driftTool}/bin/vscodium-drift-tool, the same
        derivation home/vscodium.nix and home/drift-analyzer.nix import, so
        the `python3 -I` wrapper and the json5 in its closure are under test
        too -- the first draft shipped without json5 and quarantined a valid
        settings.json for it.

    <python-with-json5> tests/vscodium-drift-tool-assertions.py \\
        home/vscodium-drift-tool.py
        The fast loop while editing, no nix build in the way.

A `.py` argument is run through this interpreter, which must therefore have
json5; anything else is executed directly and brings its own.
"""
import json
import os
import subprocess
import sys
import tempfile

TOOL = sys.argv[1]
# The wrapper is a shell script that execs `python3 -I <script>`; handing it
# to an interpreter would make it a syntax error rather than a test.
ARGV0 = [sys.executable, TOOL] if TOOL.endswith(".py") else [TOOL]
failures = []


def run(sub, root, extra=()):
    return subprocess.run(
        [*ARGV0, sub,
         "--live", os.path.join(root, "settings.json"),
         "--declared", os.path.join(root, "declared.json"),
         "--state-dir", os.path.join(root, "state"), *extra],
        capture_output=True, text=True)


def setup(live, declared):
    root = tempfile.mkdtemp()
    if live is not None:
        with open(os.path.join(root, "settings.json"), "w") as fh:
            fh.write(live)
    with open(os.path.join(root, "declared.json"), "w") as fh:
        json.dump(declared, fh)
    return root


def state(root, name):
    return os.path.join(root, "state", name)


def report_text(root):
    out = os.path.join(root, "out.md")
    res = run("report", root, ("--out", out))
    assert res.returncode == 0, res.stderr
    with open(out) as fh:
        return int(res.stdout.strip()), fh.read()


def live_text(root):
    with open(os.path.join(root, "settings.json")) as fh:
        return fh.read()


def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + (f"  {detail!r}" if not cond else ""))
    if not cond:
        failures.append(name)


# 1. an undeclared key survives and is reported as the promotion queue
root = setup('{"editor.fontSize": 14}', {"editor.formatOnSave": True})
g = run("record", root)
check("1 record exits 0", g.returncode == 0, g.stderr)
check("1 live file untouched", live_text(root) == '{"editor.fontSize": 14}')
n, text = report_text(root)
check("1 reports undeclared", "editor.fontSize" in text and "not declared" in text, text)
check("1 no override recorded for a sparse live file",
      not os.path.exists(state(root, "overridden.json"))
      or json.load(open(state(root, "overridden.json"))) == {},
      open(state(root, "overridden.json")).read()
      if os.path.exists(state(root, "overridden.json")) else "")

# 2. a divergent declared key is recorded as a pending override
root = setup('{"editor.formatOnSave": false}', {"editor.formatOnSave": True})
run("record", root)
rec = json.load(open(state(root, "overridden.json")))
check("2 override recorded", "editor.formatOnSave" in rec, rec)
check("2 discarded value kept",
      rec.get("editor.formatOnSave", {}).get("discarded") is False, rec)
check("2 kind is overridden", rec["editor.formatOnSave"]["kind"] == "overridden", rec)
n, text = report_text(root)
check("2 reports override", "overwritten by the declared config" in text, text)

# 3. promotion retires the record and clears the finding
with open(os.path.join(root, "declared.json"), "w") as fh:
    json.dump({"editor.formatOnSave": False}, fh)
run("record", root)
check("3 record retired after promotion",
      json.load(open(state(root, "overridden.json"))) == {})
n, text = report_text(root)
check("3 no findings after promotion", n == 0, text)

# 4. a malformed live file is recorded and LEFT ALONE — never moved
root = setup('{{{ not json', {"a": 1})
g = run("record", root)
check("4 record still exits 0", g.returncode == 0, g.stderr)
check("4 live file still in place", live_text(root) == '{{{ not json')
check("4 no quarantine dir", not os.path.exists(state(root, "quarantine")))
check("4 unparseable marker written", os.path.exists(state(root, "unparseable.json")))
n, text = report_text(root)
check("4 reports unparseable", "does not parse" in text, text)
check("4 says left in place", "left in place" in text, text)

# 4b. a later parseable file clears the marker
with open(os.path.join(root, "settings.json"), "w") as fh:
    fh.write('{"a": 1}')
run("record", root)
check("4b marker cleared", not os.path.exists(state(root, "unparseable.json")))
n, text = report_text(root)
check("4b finding cleared", "does not parse" not in text, text)

# 5. JSONC comments parse rather than being called malformed
root = setup('{\n  // a comment the UI preserved\n  "editor.fontSize": 14,\n}',
             {"editor.formatOnSave": True})
g = run("record", root)
check("5 comments parse", not os.path.exists(state(root, "unparseable.json")), g.stderr)
n, text = report_text(root)
check("5 still sees the key", "editor.fontSize" in text, text)

# 6. store-path churn is ignored on both sides
root = setup('{"rust-analyzer.server.path": "/nix/store/OLD/bin/x",'
             ' "claudeCode.claudeProcessWrapper": "/nix/store/OLD/bin/y"}',
             {"rust-analyzer.server.path": "/nix/store/NEW/bin/x",
              "claudeCode.claudeProcessWrapper": "/nix/store/NEW/bin/y"})
run("record", root)
n, text = report_text(root)
check("6 store paths produce no findings", n == 0, text)

# 7. nested divergence is reported at the leaf, not the whole block
root = setup('{"[html]": {"editor.formatOnSave": true, "editor.tabSize": 4}}',
             {"[html]": {"editor.formatOnSave": False}})
run("record", root)
n, text = report_text(root)
check("7 nested leaf path rendered", "[html] -> editor.formatOnSave" in text, text)
check("7 nested undeclared sibling reported", "[html] -> editor.tabSize" in text, text)

# 7b. a nested promotion retires its record (flatten_leaves, not diff-vs-{})
with open(os.path.join(root, "declared.json"), "w") as fh:
    json.dump({"[html]": {"editor.formatOnSave": True}}, fh)
run("record", root)
check("7b nested record retired",
      json.load(open(state(root, "overridden.json"))) == {},
      json.load(open(state(root, "overridden.json"))))

# 8. arrays are leaves: jq '*' replaces them wholesale, so a changed array
#    is an override, not a merge
root = setup('{"rules": [1, 2]}', {"rules": [1]})
run("record", root)
rec = json.load(open(state(root, "overridden.json")))
check("8 array change recorded", rec.get("rules", {}).get("discarded") == [1, 2], rec)

# 9. documented limitation: a declared key missing from live is NOT a
#    finding. Absent and never-written are the same state on disk, so
#    reporting it would flood on every sparse file (post-reset VSCodium).
root = setup('{}', {"git.autofetch": True})
run("record", root)
check("9 missing declared key is not a finding",
      json.load(open(state(root, "overridden.json"))) == {},
      json.load(open(state(root, "overridden.json"))))
n, text = report_text(root)
check("9 and reports nothing", n == 0, text)

# 10. absent live file is a no-op, not a crash
root = setup(None, {"a": 1})
g = run("record", root)
check("10 absent live file ok", g.returncode == 0, g.stderr)

# 11. an INTERNAL failure must leave the file alone AND not masquerade as
#     the user's file being broken. Unreadable declared.json stands in for
#     any of our own faults.
root = setup('{"editor.fontSize": 14}', {"a": 1})
os.chmod(os.path.join(root, "declared.json"), 0o000)
g = run("record", root)
check("11 record still exits 0", g.returncode == 0, g.stderr)
check("11 live file untouched", live_text(root) == '{"editor.fontSize": 14}')
check("11 not called unparseable", not os.path.exists(state(root, "unparseable.json")))
check("11 internal error recorded", os.path.exists(state(root, "internal-error.json")))
os.chmod(os.path.join(root, "declared.json"), 0o644)
n, text = report_text(root)
check("11 reports recorder failure", "recorder failed" in text, text)
run("record", root)
check("11 marker cleared on recovery",
      not os.path.exists(state(root, "internal-error.json")))

# 12. the merge-failed marker (written by the activation entry, not here)
#     is surfaced by the report
root = setup('{"a": 1}', {"a": 1})
os.makedirs(os.path.join(root, "state"), exist_ok=True)
with open(state(root, "merge-failed.json"), "w") as fh:
    json.dump({"failed_at": "2026-11-06T12:00:00+00:00", "status": 1}, fh)
n, text = report_text(root)
check("12 reports merge failure", "merge failed at activation" in text, text)
check("12 says not applied", "NOT applied" in text, text)

# 13. a live-only key under a sensitive prefix is its own finding, not
#     filed with the cosmetic promotion queue. "Undeclared colour theme"
#     and "undeclared workspace-trust switch" are the same shape on disk.
root = setup('{"security.workspace.trust.enabled": false, "editor.fontSize": 14}',
             {"editor.formatOnSave": True})
n, text = report_text(root)
check("13 security finding raised",
      "VSCodium security settings live but not declared" in text, text)
check("13 names the sensitive key",
      "security.workspace.trust.enabled" in text, text)
check("13 says the merge preserves it", "PRESERVES" in text, text)
check("13 cosmetic key filed separately",
      "## VSCodium settings live but not declared" in text, text)
check("13 two separate findings", n == 2, n)
# The cosmetic key must not be listed under the security heading.
sec_block = text.split("## VSCodium security settings live but not declared")[1] \
                .split("## ")[0]
check("13 security block excludes the cosmetic key",
      "editor.fontSize" not in sec_block, sec_block)

# 14. with only cosmetic drift there is no security finding at all -- the
#     escalation must not fire on everything, or it escalates nothing.
root = setup('{"editor.fontSize": 14}', {"editor.formatOnSave": True})
n, text = report_text(root)
check("14 no security finding for cosmetic drift",
      "security settings live but not declared" not in text, text)
check("14 one finding", n == 1, n)

# 15. a DECLARED sensitive key that was edited live is not a "live but not
#     declared" finding: the merge reverted it, so it is an override, and
#     the guard held. Reporting it as undeclared would invert the meaning.
root = setup('{"security.workspace.trust.enabled": false}',
             {"security.workspace.trust.enabled": True})
n, text = report_text(root)
check("15 declared sensitive key is not an undeclared finding",
      "security settings live but not declared" not in text, text)

# 16. prefix matching, so a key that does not exist yet still escalates.
#     The auto-approve keys are spelled chat.tools.<area>.autoApprove by the
#     editor, so the prefix is the subtree -- an earlier draft listed
#     "chat.tools.autoApprove", which matches none of the real keys.
root = setup('{"security.someFutureSwitch": false, "telemetry.telemetryLevel": "all",'
             ' "chat.tools.global.autoApprove": true,'
             ' "chat.tools.terminal.autoApprove": {"rm": true}}',
             {"editor.formatOnSave": True})
n, text = report_text(root)
for key in ("security.someFutureSwitch", "telemetry.telemetryLevel",
            "chat.tools.global.autoApprove", "chat.tools.terminal.autoApprove"):
    check(f"16 escalates {key}", key in text, text)
check("16 only the security finding", n == 1, n)

# 17. the one claudeCode key whose declared value is a store path stays
#     ignored -- it changes on every rebuild and would cry wolf forever.
root = setup('{"claudeCode.claudeProcessWrapper": "/tmp/evil"}',
             {"editor.formatOnSave": True})
n, text = report_text(root)
check("17 store-path key stays ignored", n == 0, text)

# 18. ...but the rest of the subtree does NOT. `claudeCode.` was ignored
#     wholesale once, which hid exactly this: bypassPermissions is an enum
#     value of initialPermissionMode, and an undeclared key is PRESERVED by
#     the merge, so it would have outlived every deploy unreported.
root = setup('{"claudeCode.initialPermissionMode": "bypassPermissions",'
             ' "claudeCode.allowDangerouslySkipPermissions": true,'
             ' "claudeCode.environmentVariables": [{"name": "X", "value": "y"}],'
             ' "claudeCode.preferredLocation": "editor"}',
             {"editor.formatOnSave": True})
n, text = report_text(root)
sec = text.split("## VSCodium security settings live but not declared")[1] \
          .split("## ")[0]
for key in ("claudeCode.initialPermissionMode",
            "claudeCode.allowDangerouslySkipPermissions",
            "claudeCode.environmentVariables"):
    check(f"18 escalates {key}", key in sec, sec)
# A cosmetic sibling is still cosmetic.
check("18 cosmetic claudeCode key not escalated",
      "claudeCode.preferredLocation" not in sec, sec)
check("18 cosmetic sibling still reported",
      "claudeCode.preferredLocation" in text, text)

# 19. the nested spelling must not dodge the prefix match. VS Code's config
#     parser honours it, and "security" does not start with "security." --
#     so an undeclared subtree has to be expanded to leaves before anything
#     classifies it, or this lands in the cosmetic promotion queue.
root = setup('{"security": {"workspace.trust.enabled": false}}',
             {"editor.formatOnSave": True})
n, text = report_text(root)
check("19 nested sensitive key escalated",
      "VSCodium security settings live but not declared" in text, text)
check("19 reported as a leaf, not the bare parent",
      "security -> workspace.trust.enabled" in text, text)

# 20. the same expansion must not swallow an ignored leaf.
root = setup('{"claudeCode": {"claudeProcessWrapper": "/tmp/evil"}}',
             {"editor.formatOnSave": True})
n, text = report_text(root)
check("20 ignored leaf stays ignored when nested", n == 0, text)

print()
if failures:
    print(f"{len(failures)} FAILED: {failures}")
    sys.exit(1)
print("all green")
