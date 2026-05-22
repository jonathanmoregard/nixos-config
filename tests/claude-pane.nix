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

    # The fake_ls_noclaude run above had `live_window_ids = {wid_a}`,
    # so the enricher's prune-pass DROPPED wid_b's row as a side effect.
    # Re-add it before downstream phases that rely on both wids present.
    dellan.succeed(
        f"su - jonathan -c 'KITTY_WINDOW_ID={wid_b} "
        "claude-kitty-pane-record < /tmp/hook-b.json'"
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
    # valid one wins. Uses a single-window fake_ls so the assertion is
    # purely about row parsing (the multi-window race-window guard in
    # 6f-1 is exercised separately and would mask this signal).
    dellan.succeed(
        f"su - jonathan -c \"printf '"
        f"not-a-number\\tnot-a-uuid\\n"
        f"\\n"
        f"{wid_a}\\t{sid_a}\\t/tmp/fake\\t0\\n"
        f"truncated\\n"
        f"' > /tmp/junk-tsv\""
    )
    fake_ls_one = json.dumps([{
        "tabs": [{
            "windows": [
                {"id": wid_a, "cwd": "/tmp/fake", "title": "pane-a",
                 "foreground_processes": [
                     {"pid": 11111, "cmdline": ["/usr/bin/claude"]}
                 ]},
            ],
        }],
    }])
    stage_input("/tmp/fake-ls-one.json", fake_ls_one)
    dellan.succeed(
        "su - jonathan -c 'KITTY_ENRICH_TEST=1 "
        "KITTY_ENRICH_TSV=/tmp/junk-tsv kitty-session-enrich "
        "< /tmp/fake-ls-one.json > /tmp/enriched-junk.json'"
    )
    id_a_junk = dellan.succeed(
        "jq -r '.[0].tabs[0].windows[0].claude_session_id // empty' "
        "/tmp/enriched-junk.json"
    ).strip()
    assert id_a_junk == sid_a, (
        f"junk TSV: expected {sid_a!r} for window {wid_a}, got {id_a_junk!r}"
    )

    # --- 6f: race-window guards. The SessionStart hook can fire after
    # the periodic kitty-session-save tick that captured the pane, so a
    # snapshot can land with one same-cwd claude pane enriched and a
    # sibling un-enriched. Without the guards, that snapshot would
    # collapse both panes onto the enriched sibling's sid on next
    # restore (un-enriched pane falls back to latest-by-mtime → finds
    # sibling's freshly-touched jsonl).
    #
    # 6f-1: enricher exits 2 on collision-risk (multiple same-cwd
    # claude panes with at least one un-enriched). The save wrapper
    # treats exit 2 as "preserve prior good snapshot, don't commit
    # this partial".
    dellan.succeed(f"rm -f {tsv}")
    dellan.succeed(
        f"su - jonathan -c 'KITTY_WINDOW_ID={wid_a} "
        "claude-kitty-pane-record < /tmp/hook-a.json'"
    )
    # wid_b has NO TSV row — race window: hook hasn't fired yet.
    fake_ls_partial = json.dumps([{
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
    stage_input("/tmp/fake-ls-partial.json", fake_ls_partial)
    rc_partial = int(dellan.succeed(
        "su - jonathan -c 'kitty-session-enrich "
        "< /tmp/fake-ls-partial.json > /tmp/enriched-partial.json; "
        "echo $?'"
    ).strip().splitlines()[-1])
    assert rc_partial == 2, (
        f"enricher should exit 2 on partial same-cwd; got rc={rc_partial}"
    )

    # 6f-2: solo claude pane lacking a TSV row is NOT collision risk
    # (no sibling to collide with). Exit 0; snapshot may commit.
    fake_ls_solo_unenriched = json.dumps([{
        "tabs": [{
            "windows": [
                {"id": 555, "cwd": "/tmp/solo", "title": "lone",
                 "foreground_processes": [
                     {"pid": 33333, "cmdline": ["/usr/bin/claude"]}
                 ]},
            ],
        }],
    }])
    stage_input("/tmp/fake-ls-solo.json", fake_ls_solo_unenriched)
    rc_solo = int(dellan.succeed(
        "su - jonathan -c 'kitty-session-enrich "
        "< /tmp/fake-ls-solo.json > /dev/null; echo $?'"
    ).strip().splitlines()[-1])
    assert rc_solo == 0, (
        f"solo un-enriched claude pane should exit 0; got rc={rc_solo}"
    )

    # 6f-3: two same-cwd panes BOTH enriched — exit 0 (normal commit).
    # 6f-2's enrich pruned the TSV to live_set={555}, so wipe and
    # re-seed both rows for a clean precondition here.
    dellan.succeed(f"rm -f {tsv}")
    dellan.succeed(
        f"su - jonathan -c 'KITTY_WINDOW_ID={wid_a} "
        "claude-kitty-pane-record < /tmp/hook-a.json'"
    )
    dellan.succeed(
        f"su - jonathan -c 'KITTY_WINDOW_ID={wid_b} "
        "claude-kitty-pane-record < /tmp/hook-b.json'"
    )
    rc_full = int(dellan.succeed(
        "su - jonathan -c 'kitty-session-enrich "
        "< /tmp/fake-ls-partial.json > /dev/null; echo $?'"
    ).strip().splitlines()[-1])
    assert rc_full == 0, (
        f"both panes enriched: exit 0 expected, got rc={rc_full}"
    )

    # 6f-4: empty CLAUDE_CODE_ENTRYPOINT fails the gate. Before this
    # fix the bash ''${VAR:-cli} default treated empty-string the same
    # as unset, so a misconfigured shell launcher injecting an empty
    # env var would silently write to TSV as if it were the main
    # interactive session. The bare ''${VAR-cli} default flips that.
    dellan.succeed(f"rm -f {tsv}")
    dellan.succeed(
        f"su - jonathan -c 'KITTY_WINDOW_ID={wid_a} "
        "CLAUDE_CODE_ENTRYPOINT= "
        "claude-kitty-pane-record < /tmp/hook-a.json'"
    )
    empty_entrypoint_wrote = dellan.succeed(
        f"test -f {tsv} && wc -l < {tsv} || echo 0"
    ).strip()
    assert empty_entrypoint_wrote == "0", (
        f"empty CLAUDE_CODE_ENTRYPOINT wrote TSV "
        f"({empty_entrypoint_wrote} lines); gate must reject"
    )
    # Sanity: explicit `cli` still writes.
    dellan.succeed(
        f"su - jonathan -c 'KITTY_WINDOW_ID={wid_a} "
        "CLAUDE_CODE_ENTRYPOINT=cli "
        "claude-kitty-pane-record < /tmp/hook-a.json'"
    )
    dellan.succeed(f"grep -qP '^{wid_a}\\t{sid_a}\\t' {tsv}")

    # 6f-5: restore-side load_panes refuses to collide. Stage a
    # snapshot.json where two same-cwd claude panes share a cwd but
    # only one has claude_session_id attached; pre-create both panes'
    # .jsonl files in the encoded cwd dir, with the enriched pane's
    # being the FRESHEST. The un-enriched pane's latest-by-mtime
    # fallback would, without the guard, pick the sibling's sid and
    # collide. With the guard, it must EITHER pick a different jsonl
    # OR drop --resume entirely.
    restore_cwd = "/tmp/restore-test"
    encoded = restore_cwd.replace("/", "-")
    proj = f"/home/jonathan/.claude/projects/{encoded}"
    dellan.succeed(f"su - jonathan -c 'mkdir -p {proj}'")
    sid_p1 = "11111111-1111-1111-1111-111111111111"
    sid_p2 = "22222222-2222-2222-2222-222222222222"
    # p1 is the enriched one (also the freshest jsonl on disk).
    dellan.succeed(
        f"su - jonathan -c 'touch -d \"2020-01-01\" {proj}/{sid_p2}.jsonl'"
    )
    dellan.succeed(
        f"su - jonathan -c 'touch -d \"2030-01-01\" {proj}/{sid_p1}.jsonl'"
    )
    cache_dir = "/home/jonathan/.cache/kitty-session"
    dellan.succeed(f"su - jonathan -c 'mkdir -p {cache_dir}'")
    snap = json.dumps([{
        "tabs": [{
            "windows": [
                {"id": 201, "cwd": restore_cwd, "title": "enriched",
                 "claude_session_id": sid_p1,
                 "foreground_processes": [
                     {"pid": 71, "cmdline": ["/usr/bin/claude"]}
                 ]},
                {"id": 202, "cwd": restore_cwd, "title": "unenriched",
                 "foreground_processes": [
                     {"pid": 72, "cmdline": ["/usr/bin/claude"]}
                 ]},
            ],
        }],
    }])
    stage_input("/tmp/race-snap.json", snap)
    dellan.succeed(
        f"su - jonathan -c 'cp /tmp/race-snap.json {cache_dir}/snapshot.json'"
    )
    dump = dellan.succeed(
        "su - jonathan -c 'kitty-restore-session --dump-panes'"
    )
    print("[diag phase6f-5] resolved panes:\n" + dump)
    resolved = json.loads(dump)
    assert len(resolved) == 2, f"expected 2 panes, got {len(resolved)}"
    # Pane 1: enriched, must resume sid_p1.
    cmd1 = resolved[0]["cmd"]
    assert cmd1[:3] == ["/usr/bin/claude", "--resume", sid_p1], (
        f"enriched pane: expected --resume {sid_p1!r}, got {cmd1!r}"
    )
    # Pane 2: un-enriched, latest-by-mtime would pick sid_p1
    # (touch'd to 2030); the collision guard must NOT let it.
    cmd2 = resolved[1]["cmd"]
    if cmd2[1:2] == ["--resume"]:
        resumed_sid = cmd2[2]
        assert resumed_sid != sid_p1, (
            f"COLLISION: un-enriched pane resumed sibling's sid "
            f"{sid_p1!r}; cmd={cmd2!r}"
        )
        # Acceptable fallback: the OTHER jsonl in proj_dir (sid_p2).
        assert resumed_sid == sid_p2, (
            f"unexpected fallback target {resumed_sid!r}; expected "
            f"{sid_p2!r} (only non-claimed jsonl) or no --resume"
        )
    else:
        # Also acceptable: no --resume at all (claude launches fresh).
        assert cmd2 == ["/usr/bin/claude"], (
            f"un-enriched pane has unexpected cmd: {cmd2!r}"
        )

    # 6f-6: when EVERY jsonl in proj_dir is claimed by enriched
    # siblings, un-enriched fallback must drop --resume rather than
    # wrong-collide. Remove the spare sid_p2 jsonl so the only option
    # collides; load_panes must return cmd unchanged for pane 2.
    dellan.succeed(f"su - jonathan -c 'rm -f {proj}/{sid_p2}.jsonl'")
    dump_no_spare = dellan.succeed(
        "su - jonathan -c 'kitty-restore-session --dump-panes'"
    )
    resolved_no_spare = json.loads(dump_no_spare)
    cmd2_no_spare = resolved_no_spare[1]["cmd"]
    assert cmd2_no_spare == ["/usr/bin/claude"], (
        f"all-claimed fallback should drop --resume; got {cmd2_no_spare!r}"
    )
  '';
}
