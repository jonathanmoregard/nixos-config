# vm-claude-pane: Claude-Code-aware kitty pane disambiguation.
#
# Two `claude` panes in the same cwd must each get their own
# claude_session_id attached to the corresponding window in
# snapshot.json. Without per-pane id, the latest-by-mtime fallback
# in maybe_resume_claude collapses both onto whichever .jsonl is
# newest, yielding a duplicate session on restore instead of the
# user's two distinct ones.
#
# Mechanism: a Claude Code SessionStart hook
# (`claude-kitty-pane-record`) writes (window_id, session_id, cwd,
# ts) rows into ~/.cache/kitty-session/pane-sessions.tsv keyed by
# $KITTY_WINDOW_ID — the same integer kitty puts in `kitty @ ls`'s
# window `id` field. The enricher joins the TSV into snapshot JSON.
#
# This replaces an earlier /proc/<pid>/fd scan, which assumed
# `claude` keeps its session jsonl fd open. Empirically claude
# opens/appends/closes per write, so the scan returned None and
# the snapshot fell through to latest-by-mtime — exactly the bug.
#
# Sub-phases:
#   6a  hook writes TSV rows from JSON-on-stdin + KITTY_WINDOW_ID env
#   6b  enricher reads TSV and attaches id keyed by kitty window id
#   6c  pruning — stale TSV entries removed on each enrich pass
#   6d  production safety — KITTY_ENRICH_TSV ignored without test flag
#   6e  malformed TSV lines ignored, valid row still wins
#
# Uses mkFeatureTest with home/_test-claude-pane.nix — only kitty.nix
# (which contains claude-kitty-pane-record + kitty-session-enrich) is
# in the HM closure. Edits to home/cinnamon.nix, home/desktop-apps.nix,
# home/jonathan.nix, home/claude-services.nix etc. leave this lane's
# drvPath unchanged → cachix serves across PRs that don't touch the
# kitty-side claude integration.
#
# Run: nix build .#checks.x86_64-linux.vm-claude-pane -L
{ pkgs, inputs }:
(import ./lib/common.nix { inherit pkgs inputs; }).mkFeatureTest {
  name = "vm-claude-pane";
  hm = ../home/_test-claude-pane.nix;
  # `jq` on the test driver's PATH (testScript runs commands as root,
  # not jonathan). The full-host node got jq transitively via
  # modules/common.nix; the minimal feature node doesn't import it.
  extraModules = [
    ({ pkgs, ... }: { environment.systemPackages = [ pkgs.jq ]; })
  ];
  testScript = ''
    import json

    dellan.wait_for_unit("multi-user.target")
    dellan.wait_for_unit("home-manager-jonathan.service")
    dellan.wait_for_unit("default.target", "jonathan")

    # Stop the periodic snapshotter — its enricher would race the
    # synthetic phases below by pruning our planted window ids (101,
    # 102) because they aren't in the real kitty's live-window set,
    # and the resulting TSV would be missing rows by the time we
    # assert on them.
    # Production timer is OnBootSec=30s + OnUnitActiveSec=60s, well
    # inside this test's ~100s wall time. `--machine=jonathan@.host`
    # is what `wait_for_unit("...", "jonathan")` uses under the hood;
    # `su -` alone doesn't set XDG_RUNTIME_DIR in this test VM.
    dellan.succeed(
        "systemctl --machine=jonathan@.host --user "
        "stop kitty-session-save.timer"
    )

    tsv = "/home/jonathan/.cache/kitty-session/pane-sessions.tsv"
    sid_a = "aaaa1111-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    sid_b = "bbbb2222-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    wid_a, wid_b = 101, 102

    def stage_input(path, payload):
        dellan.succeed(
            f"cat > {path} <<'EOF'\n" + payload + "\nEOF"
        )
        dellan.succeed(f"chown jonathan {path}")

    # --- 6a: hook writes TSV rows from JSON-on-stdin + KITTY_WINDOW_ID env.
    dellan.succeed(f"su - jonathan -c 'mkdir -p $(dirname {tsv}) && rm -f {tsv}'")
    stage_input(
        "/tmp/hook-a.json",
        f'{{"session_id":"{sid_a}","cwd":"/tmp/fake"}}',
    )
    stage_input(
        "/tmp/hook-b.json",
        f'{{"session_id":"{sid_b}","cwd":"/tmp/fake"}}',
    )
    dellan.succeed(
        f"su - jonathan -c 'KITTY_WINDOW_ID={wid_a} "
        "claude-kitty-pane-record < /tmp/hook-a.json'"
    )
    dellan.succeed(
        f"su - jonathan -c 'KITTY_WINDOW_ID={wid_b} "
        "claude-kitty-pane-record < /tmp/hook-b.json'"
    )
    print("[diag phase6] TSV after hooks:\n" + dellan.succeed(f"cat {tsv}"))
    dellan.succeed(f"grep -qP '^{wid_a}\\t{sid_a}\\t' {tsv}")
    dellan.succeed(f"grep -qP '^{wid_b}\\t{sid_b}\\t' {tsv}")

    # Re-invoking the hook for an existing window_id REPLACES the row,
    # doesn't append a duplicate — guards against unbounded TSV growth
    # when claude sessions are resumed multiple times in the same pane.
    sid_a2 = "cccc3333-cccc-cccc-cccc-cccccccccccc"
    stage_input(
        "/tmp/hook-a2.json",
        f'{{"session_id":"{sid_a2}","cwd":"/tmp/fake"}}',
    )
    dellan.succeed(
        f"su - jonathan -c 'KITTY_WINDOW_ID={wid_a} "
        "claude-kitty-pane-record < /tmp/hook-a2.json'"
    )
    row_count_a = int(dellan.succeed(
        f"grep -cP '^{wid_a}\\t' {tsv} || true"
    ).strip())
    assert row_count_a == 1, (
        f"expected exactly 1 row for window {wid_a} after re-invocation, "
        f"got {row_count_a}"
    )
    dellan.succeed(f"grep -qP '^{wid_a}\\t{sid_a2}\\t' {tsv}")
    # Reset to original sid for downstream assertions.
    dellan.succeed(
        f"su - jonathan -c 'KITTY_WINDOW_ID={wid_a} "
        "claude-kitty-pane-record < /tmp/hook-a.json'"
    )

    # No KITTY_WINDOW_ID env → silent no-op. Hook must be safe to wire
    # globally even for claude invocations outside kitty.
    dellan.succeed(
        "su - jonathan -c 'env -u KITTY_WINDOW_ID "
        "claude-kitty-pane-record < /tmp/hook-a.json'"
    )

    # Malformed session_id rejected (not a canonical UUID) → no row.
    stage_input(
        "/tmp/hook-bad.json",
        '{"session_id":"not-a-uuid","cwd":"/tmp/fake"}',
    )
    dellan.succeed(
        "su - jonathan -c 'KITTY_WINDOW_ID=998 "
        "claude-kitty-pane-record < /tmp/hook-bad.json'"
    )
    row_count_bad = int(dellan.succeed(
        f"grep -cP '^998\\t' {tsv} || true"
    ).strip())
    assert row_count_bad == 0, (
        f"malformed session_id should be rejected; got {row_count_bad} row(s)"
    )

    # CLAUDE_CODE_ENTRYPOINT != "cli" silent no-op. Nested
    # `claude -p` invocations inherit KITTY_WINDOW_ID from parent and
    # would otherwise overwrite the row with the subprocess's session
    # id, causing kitty restore to resume the subprocess on next
    # restart (the watcher-prompt-on-resume bug). Verify the gate
    # holds for sdk-cli AND any other non-cli entrypoint name.
    sid_evil = "eeee5555-eeee-eeee-eeee-eeeeeeeeeeee"
    stage_input(
        "/tmp/hook-evil.json",
        f'{{"session_id":"{sid_evil}","cwd":"/tmp/fake"}}',
    )
    for evil_entrypoint in ["sdk-cli", "claude_code_action", "unknown"]:
        dellan.succeed(
            f"su - jonathan -c 'KITTY_WINDOW_ID={wid_a} "
            f"CLAUDE_CODE_ENTRYPOINT={evil_entrypoint} "
            "claude-kitty-pane-record < /tmp/hook-evil.json'"
        )
        row_count_evil = int(dellan.succeed(
            f"grep -cP '\\t{sid_evil}\\t' {tsv} || true"
        ).strip())
        assert row_count_evil == 0, (
            f"entrypoint={evil_entrypoint}: row written despite "
            f"non-cli gate; got {row_count_evil} matching rows"
        )
        # Existing main row for wid_a must remain untouched.
        dellan.succeed(f"grep -qP '^{wid_a}\\t{sid_a}\\t' {tsv}")

    # Non-numeric KITTY_WINDOW_ID rejected — defends against TSV
    # corruption if some upstream sets the env var to a non-integer.
    dellan.succeed(
        "su - jonathan -c 'KITTY_WINDOW_ID=abc "
        "claude-kitty-pane-record < /tmp/hook-a.json'"
    )
    row_count_abc = int(dellan.succeed(
        f"grep -cP '^abc\\t' {tsv} || true"
    ).strip())
    assert row_count_abc == 0, (
        f"non-numeric KITTY_WINDOW_ID should be rejected; got {row_count_abc} row(s)"
    )

    # --- 6b: enricher reads TSV and attaches id keyed by kitty window id.
    print("[diag phase6b] TSV right before enricher call:\n"
          + dellan.succeed(f"cat {tsv}"))
    fake_ls = json.dumps([{
        "tabs": [{
            "windows": [
                {"id": wid_a, "cwd": "/tmp/fake", "title": "pane-a",
                 "foreground_processes": [
                     {"pid": 11111, "cmdline": ["/usr/bin/claude"]}
                 ]},
                {"id": wid_b, "cwd": "/tmp/fake", "title": "pane-b",
                 "foreground_processes": [
                     {"pid": 22222, "cmdline": ["/usr/bin/claude"]}
                 ]},
            ],
        }],
    }])
    stage_input("/tmp/fake-ls.json", fake_ls)
    dellan.succeed(
        "su - jonathan -c 'kitty-session-enrich "
        "< /tmp/fake-ls.json > /tmp/enriched.json'"
    )
    print("[diag phase6] enriched.json:\n" + dellan.succeed("cat /tmp/enriched.json"))

    id_a = dellan.succeed(
        "jq -r '.[0].tabs[0].windows[0].claude_session_id // empty' "
        "/tmp/enriched.json"
    ).strip()
    id_b = dellan.succeed(
        "jq -r '.[0].tabs[0].windows[1].claude_session_id // empty' "
        "/tmp/enriched.json"
    ).strip()
    assert id_a == sid_a, (
        f"window {wid_a}: expected sid {sid_a!r}, got {id_a!r}"
    )
    assert id_b == sid_b, (
        f"window {wid_b}: expected sid {sid_b!r}, got {id_b!r}"
    )
    assert id_a != id_b, (
        "same-cwd panes collapsed to a single claude_session_id"
    )

    # Negative path: a non-claude foreground process must NOT get a
    # claude_session_id attached even with a matching TSV row.
    fake_ls_noclaude = json.dumps([{
        "tabs": [{
            "windows": [
                {"id": wid_a, "cwd": "/tmp/fake", "title": "shell",
                 "foreground_processes": [
                     {"pid": 11111, "cmdline": ["/usr/bin/zsh"]}
                 ]},
            ],
        }],
    }])
    stage_input("/tmp/fake-ls-noclaude.json", fake_ls_noclaude)
    dellan.succeed(
        "su - jonathan -c 'kitty-session-enrich "
        "< /tmp/fake-ls-noclaude.json > /tmp/enriched-noclaude.json'"
    )
    has_field = dellan.succeed(
        "jq -r '.[0].tabs[0].windows[0] | has(\"claude_session_id\")' "
        "/tmp/enriched-noclaude.json"
    ).strip()
    assert has_field == "false", (
        f"non-claude window got claude_session_id (has_field={has_field!r})"
    )

    # --- 6c: pruning — stale TSV entries for windows not in `ls` are
    # removed on each enrich pass, keeping the TSV bounded.
    sid_stale = "dddd4444-dddd-dddd-dddd-dddddddddddd"
    dellan.succeed(
        f"su - jonathan -c \"printf '999\\t{sid_stale}\\t/tmp/dead\\t0\\n' "
        f">> {tsv}\""
    )
    dellan.succeed(f"grep -qP '^999\\t' {tsv}")
    dellan.succeed(
        "su - jonathan -c 'kitty-session-enrich "
        "< /tmp/fake-ls.json > /dev/null'"
    )
    dellan.fail(f"grep -qP '^999\\t' {tsv}")

    # --- 6d: production safety — KITTY_ENRICH_TSV must be ignored
    # without KITTY_ENRICH_TEST=1, or a stray export in a user's shell
    # rc could silently re-route lookups to an attacker-controllable TSV.
    dellan.succeed(
        f"su - jonathan -c \"printf '1234\\t{sid_a}\\t/tmp/fake\\t0\\n' "
        f"> /tmp/evil-tsv\""
    )
    fake_ls_evil = json.dumps([{
        "tabs": [{
            "windows": [
                {"id": 1234, "cwd": "/tmp/fake", "title": "evil",
                 "foreground_processes": [
                     {"pid": 99, "cmdline": ["/usr/bin/claude"]}
                 ]},
            ],
        }],
    }])
    stage_input("/tmp/fake-ls-evil.json", fake_ls_evil)
    dellan.succeed(
        "su - jonathan -c 'KITTY_ENRICH_TSV=/tmp/evil-tsv "
        "kitty-session-enrich < /tmp/fake-ls-evil.json "
        "> /tmp/enriched-evil.json'"
    )
    has_field_evil = dellan.succeed(
        "jq -r '.[0].tabs[0].windows[0] | has(\"claude_session_id\")' "
        "/tmp/enriched-evil.json"
    ).strip()
    assert has_field_evil == "false", (
        f"KITTY_ENRICH_TSV honored without KITTY_ENRICH_TEST=1 — "
        f"production env-var leak risk (has_field={has_field_evil!r})"
    )
    # With the test flag set, the redirect IS honored.
    dellan.succeed(
        "su - jonathan -c 'KITTY_ENRICH_TEST=1 "
        "KITTY_ENRICH_TSV=/tmp/evil-tsv kitty-session-enrich "
        "< /tmp/fake-ls-evil.json > /tmp/enriched-evil-on.json'"
    )
    has_field_evil_on = dellan.succeed(
        "jq -r '.[0].tabs[0].windows[0] | has(\"claude_session_id\")' "
        "/tmp/enriched-evil-on.json"
    ).strip()
    assert has_field_evil_on == "true", (
        "test flag should enable TSV redirect"
    )

    # --- 6e: malformed TSV lines (non-uuid sid, non-numeric wid, too
    # few fields) are ignored by enricher rather than crashing or
    # mis-attributing. Mix junk around a valid row and assert only the
    # valid one wins.
    dellan.succeed(
        f"su - jonathan -c \"printf '"
        f"not-a-number\\tnot-a-uuid\\n"
        f"\\n"
        f"{wid_a}\\t{sid_a}\\t/tmp/fake\\t0\\n"
        f"truncated\\n"
        f"' > /tmp/junk-tsv\""
    )
    dellan.succeed(
        "su - jonathan -c 'KITTY_ENRICH_TEST=1 "
        "KITTY_ENRICH_TSV=/tmp/junk-tsv kitty-session-enrich "
        "< /tmp/fake-ls.json > /tmp/enriched-junk.json'"
    )
    id_a_junk = dellan.succeed(
        "jq -r '.[0].tabs[0].windows[0].claude_session_id // empty' "
        "/tmp/enriched-junk.json"
    ).strip()
    assert id_a_junk == sid_a, (
        f"junk TSV: expected {sid_a!r} for window {wid_a}, got {id_a_junk!r}"
    )
  '';
}
