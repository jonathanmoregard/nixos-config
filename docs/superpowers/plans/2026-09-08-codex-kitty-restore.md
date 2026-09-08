# Codex-aware Kitty Restore Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (default) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore Claude Code and Codex panes to their recorded sessions while leaving a short, unsent pickup draft backed by a private state-directory note.

**Architecture:** Extend the existing Kitty pane registry with an agent-kind column, enrich each live agent pane with a kind-specific session field, and make restore planning produce canonical Claude or Codex resume commands. Move the recovery text out of argv into private files under `~/.local/state/claude/kitty-restore`; pass each note through the pane environment and let the existing SessionStart hook type a constant draft without a newline after atomically claiming a one-shot marker.

**Tech Stack:** Nix/Home Manager, embedded Python 3, embedded Bash, Kitty remote control, NixOS VM tests, shell runtime harness.

---

## File map

- `home/kitty.nix`: generated pane recorder, snapshot enricher, session converter, pane launcher, restore planner, note writer, and unsent-draft delivery.
- `tests/claude-pane.nix`: VM assertions for agent-kind registry rows, enrichment, collision protection, and exact Codex resume planning.
- `tests/kitty-scripts.nix`: fast runtime assertions for note files, permissions, environment transport, marker consumption, no automatic prompt, and no newline in the draft.
- `tests/kitty.nix`: real-X topology restore regression; extend only where the existing black-box flow needs a Codex pane assertion.
- `docs/superpowers/specs/2026-09-08-codex-kitty-restore-design.md`: approved behavior contract; no further edits unless implementation exposes a contradiction.

### Task 1: Add failing agent-identity and Codex resume VM tests

**Files:**
- Modify: `tests/claude-pane.nix`
- Test: `tests/claude-pane.nix`

- [ ] **Step 1: Add a Codex hook-row fixture**

Create a third UUID and invoke the deployed recorder with Codex identity:

```python
sid_codex = "cccc3333-cccc-4333-8333-cccccccccccc"
sid_codex_2 = "dddd4444-dddd-4444-8444-dddddddddddd"
wid_codex, wid_codex_2 = 103, 104
stage_input(
    "/tmp/hook-codex.json",
    f'{{"session_id":"{sid_codex}","cwd":"/tmp/fake"}}',
)
dellan.succeed(
    f"su - jonathan -c 'KITTY_WINDOW_ID={wid_codex} "
    f"CODEX_THREAD_ID={sid_codex} "
    "claude-kitty-pane-record < /tmp/hook-codex.json'"
)
dellan.succeed(
    f"grep -qP '^{wid_codex}\\tcodex\\t{sid_codex}\\t' {tsv}"
)
```

Keep the existing Claude assertions, changing their expected row shape to
`window_id<TAB>claude<TAB>session_id`.

- [ ] **Step 2: Add enrichment and negative-control fixtures**

Feed `kitty-session-enrich` two Codex panes in the same cwd, each with a distinct registry row, and assert each gets its own `codex_session_id` and no `claude_session_id`. Then remove one row and assert the command exits `2`, proving same-cwd Codex collision protection fails closed. Add a shell control carrying a stale Codex row and assert it receives neither session field.

Use these window shapes:

```python
{"id": 103, "cwd": "/tmp/codex", "cmdline": ["/bin/zsh"],
 "foreground_processes": [{"cmdline": ["/usr/bin/codex"]}]}
{"id": 104, "cwd": "/tmp/codex", "cmdline": ["/bin/zsh"],
 "foreground_processes": [{"cmdline": ["/usr/bin/codex", "--yolo"]}]}
```

- [ ] **Step 3: Add restore-planner assertions**

Write a snapshot containing the enriched Codex windows, run
`kitty-restore-session --dump-panes`, and assert:

```python
assert resolved[0]["cmd"] == ["/usr/bin/codex", "resume", sid_codex]
assert resolved[1]["cmd"] == ["/usr/bin/codex", "resume", sid_codex_2]
assert all("--yolo" not in pane["cmd"] for pane in resolved)
```

Also write a Codex window with no `codex_session_id` and assert it resolves to
the original shell, not `codex resume --last` or another cwd-local thread.

- [ ] **Step 4: Run the focused lane and observe RED**

Run:

```bash
nix build .#checks.x86_64-linux.vm-claude-pane -L
```

Expected: failure at the first new five-column TSV or `codex_session_id`
assertion because production still emits four-column Claude-only semantics.

- [ ] **Step 5: Commit the failing test checkpoint**

Stage `tests/claude-pane.nix` and commit with a risky pre-push checklist that
records the expected failing lane as behavioral evidence. Do not push this
red checkpoint.

### Task 2: Add failing manual-pickup runtime tests

**Files:**
- Modify: `tests/kitty-scripts.nix`
- Test: `tests/kitty-scripts.nix`

- [ ] **Step 1: Replace automatic-prompt expectations**

Change the fixture's phase A/B contract so `--dump-panes` contains no argv
element matching `restored by kitty`, and pane zero's executed argv contains
only `--resume` plus its UUID. The negative assertion must be:

```bash
if jq -e '.[].cmd[]? | select(test("restored by kitty"))' \
    state/panes.json >/dev/null; then
  echo "FAIL: restore still submits its recovery notice as argv"
  exit 1
fi
```

- [ ] **Step 2: Assert private state-note creation**

Set `XDG_STATE_HOME="$PWD/fx/state-home"`, invoke `--emit-stub`, and assert one
note exists at `state-home/claude/kitty-restore/pane-1.md`, its directory mode
is `700`, its file mode is `600`, and the note contains both the restore
boundary and the fixture's six edited paths.

```bash
note="$XDG_STATE_HOME/claude/kitty-restore/pane-1.md"
[ "$(stat -c %a "$(dirname "$note")")" = 700 ]
[ "$(stat -c %a "$note")" = 600 ]
grep -qF "edited 6 file(s):" "$note"
```

- [ ] **Step 3: Assert environment transport and unsent bytes**

Assert the pane-zero stub contains a Kitty launch environment assignment for
`KITTY_RESTORE_NOTE` and no recovery text. Extend the fake Kitty command used
by later panes so its command log proves `kitty-pane-add` receives the same
environment assignment.

Drive the pane recorder with `KITTY_RESTORE_NOTE` and fake `kitten`/`kitty`
remote-control binaries that copy stdin to `state/draft-bytes`. Assert exact
bytes with Python so a hidden carriage return cannot pass:

```python
from pathlib import Path
assert Path("state/draft-bytes").read_bytes() == b"Read $KITTY_RESTORE_NOTE."
```

Run the hook a second time and assert the byte file is unchanged, proving the
marker is one-shot. Make the fake `kitty @ ls` omit the current window once and
assert the pending marker remains, no bytes are sent, and no newline-bearing
fallback prompt appears anywhere.

- [ ] **Step 4: Run the focused check and observe RED**

Run:

```bash
nix build .#checks.x86_64-linux.kitty-scripts -L
```

Expected: failure because the current resume argv still contains the automatic
notice and no state note or draft marker exists.

- [ ] **Step 5: Commit the failing test checkpoint**

Stage `tests/kitty-scripts.nix` and commit locally. Keep the branch unpushed
until implementation turns both targeted checks green.

### Task 3: Generalize pane identity and Codex resume planning

**Files:**
- Modify: `home/kitty.nix`
- Test: `tests/claude-pane.nix`
- Test: `tests/kitty-scripts.nix`

- [ ] **Step 1: Add shared agent classifiers**

In the existing shared Python helper beside `_is_claude`, add basename-based
classification after launcher unwrapping:

```python
def _is_codex_exe(cmdline):
    return bool(cmdline) and os.path.basename(cmdline[0]) == "codex"

def _agent_kind(cmdline):
    inner = unwrap_launchers(cmdline)
    if _is_claude_exe(inner):
        return "claude"
    if _is_codex_exe(inner):
        return "codex"
    return None
```

Keep `slice_launch` restricted to Claude.

- [ ] **Step 2: Write and parse agent-kind registry rows**

In `claudeKittyPaneRecord`, derive kind without trusting arbitrary input:

```bash
kind=claude
if [ -n "${CODEX_THREAD_ID:-}" ] && [ "$CODEX_THREAD_ID" = "$session_id" ]; then
  kind=codex
fi
printf '%s\t%s\t%s\t%s\t%s\n' \
  "$KITTY_WINDOW_ID" "$kind" "$session_id" "$cwd" "$(date +%s)"
```

Update the awk replacement to remain keyed only by field one. Make
`load_tsv()` return `(kind_or_none, sid)` and accept both five-column new rows
and four-column legacy rows.

- [ ] **Step 3: Enrich both agent kinds**

For each live window, classify the foreground and stable launch command. For
Claude, retain the current zombie recovery arm. For Codex, require a live Codex
foreground process because Codex is normally launched from zsh and a stale row
must not resurrect it after the user returns to a shell.

Attach `claude_session_id` or `codex_session_id` only when the row kind agrees,
or when a legacy row is disambiguated by the detected process. Track collision
groups under `(kind, cwd)` and return exit `2` if a same-kind, same-cwd group
has a missing UUID.

- [ ] **Step 4: Produce canonical Codex resume commands**

Make both session-converter and restore `pane_cmd` loops prefer a live Claude
or Codex TUI found anywhere in `foreground_processes`. In restore, resolve:

```python
if kind == "claude":
    cmd = maybe_resume_claude(cmd, cwd, claude_sid, claimed["claude"])
elif kind == "codex" and codex_sid:
    cmd = [cmd[0], "resume", codex_sid]
elif kind == "codex":
    cmd = window_shell_command(win)
```

Do not add a Codex latest-by-mtime fallback and do not replay prior CLI flags.

- [ ] **Step 5: Run the fast targeted checks**

Run `nix build .#checks.x86_64-linux.kitty-scripts -L`, then the VM lane
`nix build .#checks.x86_64-linux.vm-claude-pane -L`. At this checkpoint, Codex
identity tests should pass; pickup tests may remain red until Task 4.

### Task 4: Move recovery text to state and type an unsent draft

**Files:**
- Modify: `home/kitty.nix`
- Test: `tests/kitty-scripts.nix`

- [ ] **Step 1: Materialize private notes atomically**

Add a state-root helper using `XDG_STATE_HOME` with the default
`~/.local/state`. Create `claude/kitty-restore` as `0700`. Write each
`pane-<ordinal>.md` through a same-directory `O_NOFOLLOW` temporary file,
`fchmod(0600)`, and `os.replace`. Write an empty `<note>.pending` marker with
the same protections.

Reuse the current recovery analysis to produce Markdown for Claude. Produce a
bounded Codex variant containing the restore boundary, cwd Git summary, and
the instruction to verify current state. `load_panes()` returns note text as
data; `emit_stub()` and the normal restore path materialize it only when they
are about to launch a real agent pane, so `--dump-panes` stays read-only.

- [ ] **Step 2: Remove all automatic prompt arguments**

Change `_resume_cmd` to return exactly `[claude, "--resume", sid]`. Codex
already returns exactly `[codex, "resume", sid]`. Confirm neither pane-zero
JSON nor a `kitty-pane-add -- ...` argv contains the note text.

- [ ] **Step 3: Pass `KITTY_RESTORE_NOTE` through Kitty**

For the pane-zero session line, add:

```text
--env KITTY_RESTORE_NOTE=<quoted-note-path>
```

Extend `kitty-pane-add` with repeatable `--env NAME=VALUE` arguments and pass
them through to `kitty @ launch`. For panes one and later, invoke it with the
same `KITTY_RESTORE_NOTE=<path>` assignment. Reject names outside
`[A-Z_][A-Z0-9_]*` before building a remote-control argv.

- [ ] **Step 4: Deliver the one-shot draft from SessionStart**

After the registry write, validate that `KITTY_RESTORE_NOTE` resolves beneath
the fixed state root and has a sibling `.pending` marker. Query the current
Kitty socket and confirm its JSON contains the numeric `KITTY_WINDOW_ID`, then
atomically rename the marker to `.sending` and send the constant bytes through
that socket/window without newline:

```bash
printf %s 'Read $KITTY_RESTORE_NOTE.' |
  kitten @ --to "$KITTY_LISTEN_ON" send-text \
    --match "id:$KITTY_WINDOW_ID" --stdin
```

Kitty documents that `send-text` always exits zero even when no window matched,
so do not treat its status as delivery acknowledgement. The `kitty @ ls`
preflight is the fail-closed target check; consume `.sending` after a successful
preflight and send. If preflight fails, leave `.pending`, write a concise stderr
diagnostic, and return success so pickup failure cannot prevent the agent
session from starting. Add `pkgs.kitty` to the recorder's runtime inputs.

- [ ] **Step 5: Run all targeted checks GREEN**

Run, in order:

```bash
nix build .#checks.x86_64-linux.kitty-scripts -L
nix build .#checks.x86_64-linux.vm-claude-pane -L
nix build .#checks.x86_64-linux.vm-kitty -L
```

Expected: all derivations build successfully; runtime harness reports exact
draft bytes with no newline; VM lanes retain topology and distinct IDs.

- [ ] **Step 6: Commit the green implementation**

Stage `home/kitty.nix` and both test files, run `git diff --cached --check`, and
commit with the full risky pre-push checklist populated from the measured
commands rather than generic “tests pass” wording.

### Task 5: Interactive smoke and integrated review

**Files:**
- Modify only if the smoke exposes a confirmed defect.

- [ ] **Step 1: Invoke `nixos-agent-testing`**

Start the feature VM with `nix run .#feature-vm`, launch real Kitty, and create
one Claude and one Codex pane whose hook registry rows contain distinct UUIDs.
Capture the real `kitty @ ls` snapshot and restart Kitty through the wrapper.

- [ ] **Step 2: Exercise the user decision point**

Verify both clients resume the intended UUID, each input buffer visibly holds
exactly `Read $KITTY_RESTORE_NOTE.` without an automatic turn, Backspace/Ctrl+U
can erase one draft without agent activity, and Enter submits the other. Read
the submitted note and confirm it is under `~/.local/state/claude`, not either
working directory.

- [ ] **Step 3: Re-run integrated checks**

Run the three targeted builds again from the settled tree plus:

```bash
nix flake check --no-build --all-systems
git diff --check origin/main...HEAD
```

Expected: zero evaluation errors, zero whitespace errors, and all targeted
check derivations green.

- [ ] **Step 4: Run close-out review**

Invoke `advice-refine-test-loop once` over `origin/main...HEAD`. Reproduce every
material finding, fix confirmed defects test-first, and rerun the affected lane
plus the full three-lane gate.

### Task 6: Deliver through the NixOS PR pipeline

**Files:**
- Create outside repository: `/tmp/codex-kitty-restore-pr.md`

- [ ] **Step 1: Synchronize without rewriting history**

Fetch `origin/main`. If it advanced, merge `origin/main` into the feature
branch, resolve conflicts, and rerun the three targeted gates. Do not rebase.

- [ ] **Step 2: Run delivery verification**

Invoke `finishing-up`, run `~/.claude/scripts/dod-check.py`, and address every
measured blocker. Confirm the HEAD commit has a complete risky pre-push
checklist matching the final diff.

- [ ] **Step 3: Push and open the PR**

Push `feat/codex-kitty-restore`, create a PR targeting the repository default
branch, and include root cause, behavior, exact automated checks, and the
interactive evidence in the body.

- [ ] **Step 4: Monitor CI**

Watch all required checks through completion. Fix failures at the root and
push normal follow-up commits. Stop only when the PR is green and ready for the
user's deliberate merge click.
