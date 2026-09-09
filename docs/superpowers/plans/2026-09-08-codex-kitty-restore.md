# Codex-aware Kitty Restore Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (default) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore Claude Code and Codex panes to their recorded sessions while leaving a short, unsent pickup draft backed by a private state-directory note.

**Architecture:** Tasks 1–4 record the landed typed pane registry, canonical resume planning, and private recovery-note baseline. The remaining work stages each cold restore as a private generation, routes every restored Codex pane through an in-pane identity bootstrap, persists the exact `(window ID, kind, UUID)` mapping through one shared locked writer, and keeps the parent restore transaction serialized against autosave until every pane reaches a terminal settlement and every eligible draft attempt has a durable marker state.

**Tech Stack:** Nix/Home Manager, embedded Python 3, embedded Bash, Kitty remote control, NixOS VM tests, shell runtime harness.

---

## File map

- `home/kitty.nix`: generated pane recorder, snapshot enricher, session converter, pane launcher, restore planner, note writer, and unsent-draft delivery.
- `tests/claude-pane.nix`: VM assertions for agent-kind registry rows, enrichment, collision protection, and exact Codex resume planning.
- `tests/kitty-scripts.nix`: fast runtime harness for generation manifests, in-pane bootstrap, restore/save races, finite deadlines, settlement, delivery-marker transitions, cleanup, permissions, and exact draft bytes.
- `tests/kitty.nix`: real-X topology restore regression, including transaction cleanup and a subsequent save after restore.
- `docs/superpowers/specs/2026-09-08-codex-kitty-restore-design.md`: approved behavior contract; no further edits unless implementation exposes a contradiction.

Tasks 1–4 are completed history. Commits `cf07b08`, `da26766`, `de1db92`,
`069cfa0`, and `b6889b6` contain the RED checkpoints, implementation, focused
GREEN runs, and follow-up hardening described below. Tasks 5 onward are the
remaining correction prompted by the no-SessionStart Codex smoke.

### Task 1: Add failing agent-identity and Codex resume VM tests

**Files:**
- Modify: `tests/claude-pane.nix`
- Test: `tests/claude-pane.nix`

- [x] **Step 1: Add a Codex hook-row fixture**

Create a third UUID and invoke the deployed recorder with Codex identity:

```python
sid_codex = "cccc3333-cccc-4333-8333-cccccccccccc"
sid_codex_2 = "dddd4444-dddd-4444-8444-dddddddddddd"
wid_codex, wid_codex_2 = 103, 104
stage_input(
    "/tmp/hook-codex.json",
    f'{{"session_id":"{sid_codex}","cwd":"/tmp/fake",'
    '"transcript_path":"/home/jonathan/.codex/sessions/main.jsonl"}',
)
run_codex_hook(wid_codex, "/tmp/hook-codex.json")
dellan.succeed(
    f"grep -qP '^{wid_codex}\\tcodex\\t{sid_codex}\\t' {tsv}"
)
```

Keep the existing Claude assertions, changing their expected row shape to
`window_id<TAB>claude<TAB>session_id`.

- [x] **Step 2: Add enrichment and negative-control fixtures**

Feed `kitty-session-enrich` two Codex panes in the same cwd, each with a distinct registry row, and assert each gets its own `codex_session_id` and no `claude_session_id`. Then remove one row and assert the command exits `2`, proving same-cwd Codex collision protection fails closed. Add a shell control carrying a stale Codex row and assert it receives neither session field.

Use these window shapes:

```python
{"id": 103, "cwd": "/tmp/codex", "cmdline": ["/bin/zsh"],
 "foreground_processes": [{"cmdline": ["/usr/bin/codex"]}]}
{"id": 104, "cwd": "/tmp/codex", "cmdline": ["/bin/zsh"],
 "foreground_processes": [{"cmdline": ["/usr/bin/codex", "--yolo"]}]}
```

- [x] **Step 3: Add restore-planner assertions**

Write a snapshot containing the enriched Codex windows, run
`kitty-restore-session --dump-panes`, and assert:

```python
assert resolved[0]["cmd"] == ["/usr/bin/codex", "resume", sid_codex]
assert resolved[1]["cmd"] == ["/usr/bin/codex", "resume", sid_codex_2]
assert all("--yolo" not in pane["cmd"] for pane in resolved)
```

Also write a Codex window with no `codex_session_id` and assert it resolves to
the original shell, not `codex resume --last` or another cwd-local thread.

- [x] **Step 4: Run the focused lane and observe RED**

Run:

```bash
nix build .#checks.x86_64-linux.vm-claude-pane -L
```

Expected: failure at the first new five-column TSV or `codex_session_id`
assertion because production still emits four-column Claude-only semantics.

- [x] **Step 5: Commit the failing test checkpoint**

Stage `tests/claude-pane.nix` and commit with a risky pre-push checklist that
records the expected failing lane as behavioral evidence. Do not push this
red checkpoint.

### Task 2: Add failing manual-pickup runtime tests

**Files:**
- Modify: `tests/kitty-scripts.nix`
- Test: `tests/kitty-scripts.nix`

- [x] **Step 1: Replace automatic-prompt expectations**

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

- [x] **Step 2: Assert private state-note creation**

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

- [x] **Step 3: Assert environment transport and unsent bytes**

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

- [x] **Step 4: Run the focused check and observe RED**

Run:

```bash
nix build .#checks.x86_64-linux.kitty-scripts -L
```

Expected: failure because the current resume argv still contains the automatic
notice and no state note or draft marker exists.

- [x] **Step 5: Commit the failing test checkpoint**

Stage `tests/kitty-scripts.nix` and commit locally. Keep the branch unpushed
until implementation turns both targeted checks green.

### Task 3: Generalize pane identity and Codex resume planning

**Files:**
- Modify: `home/kitty.nix`
- Test: `tests/claude-pane.nix`
- Test: `tests/kitty-scripts.nix`

- [x] **Step 1: Add shared agent classifiers**

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

- [x] **Step 2: Write and parse agent-kind registry rows**

In `claudeKittyPaneRecord`, derive kind without trusting arbitrary input.
Walk `/proc/$PPID` ancestry to the owning Codex executable, parse its argv,
and accept interactive root/positional-prompt/`resume`/`fork` invocations only
when the hook input also carries a Codex session transcript path. Explicitly
reject `codex exec`, `review`, `exec-server`, and the other one-shot/service
subcommands. Do not use `CODEX_THREAD_ID`: it is absent from real SessionStart
hook processes.

```bash
kind=claude
if codex_ancestor_is_interactive && codex_transcript_path_is_valid; then
  kind=codex
fi
printf '%s\t%s\t%s\t%s\t%s\n' \
  "$KITTY_WINDOW_ID" "$kind" "$session_id" "$cwd" "$(date +%s)"
```

Update the awk replacement to remain keyed only by field one. Make
`load_tsv()` return `(kind_or_none, sid)` and accept both five-column new rows
and four-column legacy rows.

- [x] **Step 3: Enrich both agent kinds**

For each live window, classify the foreground and stable launch command. For
Claude, retain the current zombie recovery arm. For Codex, require a live Codex
foreground process because Codex is normally launched from zsh and a stale row
must not resurrect it after the user returns to a shell.

Attach `claude_session_id` or `codex_session_id` only when the row kind agrees,
or when a legacy row is disambiguated by the detected process. Track collision
groups under `(kind, cwd)` and return exit `2` if a same-kind, same-cwd group
has a missing UUID.

- [x] **Step 4: Produce canonical Codex resume commands**

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

- [x] **Step 5: Run the fast targeted checks**

Run `nix build .#checks.x86_64-linux.kitty-scripts -L`, then the VM lane
`nix build .#checks.x86_64-linux.vm-claude-pane -L`. At this checkpoint, Codex
identity tests should pass; pickup tests may remain red until Task 4.

### Task 4: Move recovery text to state and type an unsent draft

**Files:**
- Modify: `home/kitty.nix`
- Test: `tests/kitty-scripts.nix`

- [x] **Step 1: Materialize private notes atomically**

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

- [x] **Step 2: Remove all automatic prompt arguments**

Change `_resume_cmd` to return exactly `[claude, "--resume", sid]`. Codex
already returns exactly `[codex, "resume", sid]`. Confirm neither pane-zero
JSON nor a `kitty-pane-add -- ...` argv contains the note text.

- [x] **Step 3: Pass `KITTY_RESTORE_NOTE` through Kitty**

For the pane-zero session line, add:

```text
--env KITTY_RESTORE_NOTE=<quoted-note-path>
```

Extend `kitty-pane-add` with repeatable `--env NAME=VALUE` arguments and pass
them through to `kitty @ launch`. For panes one and later, invoke it with the
same `KITTY_RESTORE_NOTE=<path>` assignment. Reject names outside
`[A-Z_][A-Z0-9_]*` before building a remote-control argv.

- [x] **Step 4: Deliver the one-shot draft from SessionStart**

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

- [x] **Step 5: Run all targeted checks GREEN**

Run, in order:

```bash
nix build .#checks.x86_64-linux.kitty-scripts -L
nix build .#checks.x86_64-linux.vm-claude-pane -L
nix build .#checks.x86_64-linux.vm-kitty -L
```

Expected: all derivations build successfully; runtime harness reports exact
draft bytes with no newline; VM lanes retain topology and distinct IDs.

- [x] **Step 6: Commit the green implementation**

Stage `home/kitty.nix` and both test files, run `git diff --cached --check`, and
commit with the full risky pre-push checklist populated from the measured
commands rather than generic “tests pass” wording.

### Task 5: Specify no-hook Codex bootstrap and exact registry binding

**Files:**
- Modify: `tests/kitty-scripts.nix`
- Test: `tests/kitty-scripts.nix`

- [ ] **Step 1: Add a no-SessionStart restore fixture**

Extend the existing fake-Kitty harness with two Codex panes and deliberately do
not invoke `claude-kitty-pane-record` after either `codex resume` launch. Give
each pane a distinct recorded UUID, safe-shell argv, ordinal, and fake
Kitty-injected window ID. The parent-side launch log must contain the bootstrap
wrapper, never direct Codex:

```bash
if jq -e '.argv | index("codex") and index("resume")' \
    state/parent-launches.jsonl >/dev/null; then
  echo "FAIL(bootstrap): parent launched codex resume directly"
  exit 1
fi
```

- [ ] **Step 2: Assert private generation identity**

After `kitty-restore-session --emit-stub`, assert the active generation has a
128-bit token, mode-`0600` `manifest.json`, and one entry per pane binding
`ordinal`, `kind`, `session_id`, `cwd`, `note_path`, `resume_argv`, and
`safe_shell_argv`. Assert root and generation directory modes are `0700`.
Pane-zero's mode-`0600` `pane0-launch.json` must carry the same binding.

```python
entry = manifest["panes"]["2"]
assert entry["kind"] == "codex"
assert entry["session_id"] == sid_codex
assert entry["resume_argv"] == [codex, "resume", sid_codex]
assert entry["safe_shell_argv"] == [shell]
```

- [ ] **Step 3: Assert in-pane binding precedes exec**

Drive pane zero through `--exec-pane0` and a later pane through the generated
bootstrap entrypoint. Supply `KITTY_RESTORE_BOOTSTRAP`,
`KITTY_RESTORE_ORDINAL`, `KITTY_RESTORE_NOTE`,
`KITTY_RESTORE_DEADLINE_MONOTONIC`, and numeric `KITTY_WINDOW_ID`. For the later
pane, publish the matching decimal launch return in `pane-2.expected-window`.
Pause at the test seam immediately after `pane-2.bootstrap-bound` and assert:

```bash
grep -qP "^202\\tcodex\\t${sid_codex}\\t" \
  "$XDG_CACHE_HOME/kitty-session/pane-sessions.tsv"
test ! -e state/codex-exec-called
```

Release the seam and assert the executed argv is exactly
`codex resume <UUID>`, with no prompt or replayed flags.

- [ ] **Step 4: Assert every identity failure degrades to safe shell**

Run independent cases for missing/malformed window ID, stale generation token,
wrong ordinal, altered note path, altered resume argv, missing/mismatched
`expected-window`, and registry-writer failure. Each case must create
`bootstrap-failed`, leave the note `.pending`, omit `codex` from the exec log,
and execute the recorded safe shell.

- [ ] **Step 5: Run RED and commit**

```bash
XDG_CACHE_HOME=/tmp/codex-kitty-nix-cache \
  nix build .#checks.x86_64-linux.kitty-scripts -L
```

Expected: failure containing
`FAIL(bootstrap): parent launched codex resume directly` or the first missing
generation/bootstrap assertion. Commit only `tests/kitty-scripts.nix` with a
risky checklist recording this expected RED result; do not push.

### Task 6: Implement shared registry writer and in-pane bootstrap

**Files:**
- Modify: `home/kitty.nix`
- Test: `tests/kitty-scripts.nix`
- Test: `tests/claude-pane.nix`

- [ ] **Step 1: Extract one atomic registry writer**

Generate `kitty-pane-registry-write` and make both SessionStart recording and
restore bootstrap call it. Its interface is:

```text
kitty-pane-registry-write \
  --window-id <decimal> --kind <claude|codex> \
  --session-id <uuid> --cwd <absolute-path>
```

It validates every field, takes the existing `.pane-sessions.lock`, replaces
only the matching window-ID row through a same-directory mode-`0600` temporary
file, and atomically renames it. Keep five-column output and legacy read support
unchanged.

- [ ] **Step 2: Publish the generation atomically**

In `kittyRestoreSession`, create `generation-<32 hex chars>.tmp-*`, write the
manifest, notes, `.pending` markers, and pane-zero launch record with
`O_NOFOLLOW`/`0600`, then rename the complete directory and atomically replace
the mode-`0600` `current` pointer. Put these exact environment names on every
bootstrap launch:

```text
KITTY_RESTORE_BOOTSTRAP
KITTY_RESTORE_ORDINAL
KITTY_RESTORE_NOTE
KITTY_RESTORE_DEADLINE_MONOTONIC
```

- [ ] **Step 3: Add one bootstrap path for every Codex pane**

Route pane zero from `--exec-pane0` and later panes from `kitty-pane-add`
through the same bootstrap function. Validate active token, manifest binding,
exact independently carried resume/safe-shell argv, note path, ordinal, and
Kitty's own numeric `KITTY_WINDOW_ID`. Later panes also wait for and match the
atomic `expected-window` result. On success, call the shared registry writer,
write `bootstrap-bound`, then `execvp` exact Codex argv. On identity or writer
failure, write `bootstrap-failed` and `execvp` the recorded safe shell.

- [ ] **Step 4: Run focused GREEN checks**

```bash
XDG_CACHE_HOME=/tmp/codex-kitty-nix-cache \
  nix build .#checks.x86_64-linux.kitty-scripts -L
XDG_CACHE_HOME=/tmp/codex-kitty-nix-cache \
  nix build .#checks.x86_64-linux.vm-claude-pane -L
```

Expected: both derivations build; no-hook cases persist exact typed rows before
Codex exec, and all SessionStart classifier regressions remain green.

- [ ] **Step 5: Commit bootstrap implementation**

Stage `home/kitty.nix`, `tests/kitty-scripts.nix`, and
`tests/claude-pane.nix`; run `git diff --cached --check`; commit with measured
GREEN commands in the full risky checklist.

### Task 7: Specify restore/save serialization and bounded failure

**Files:**
- Modify: `tests/kitty-scripts.nix`
- Modify: `tests/kitty.nix`

- [ ] **Step 1: Add restore-lock saver race tests**

Pause one bootstrap before its registry write, start `kitty-session-save`, and
assert it exits zero without creating a candidate or changing
`snapshot.json`/`last.session`. Repeat after `bootstrap-bound` but before
`execvp`: the saver must still skip, because the parent has not observed exact
Codex foreground settlement.

```bash
before=$(sha256sum "$snapshot" "$last_session")
kitty-session-save
after=$(sha256sum "$snapshot" "$last_session")
test "$before" = "$after"
```

- [ ] **Step 2: Add bounded failure cases**

Use `KITTY_RESTORE_TIMEOUT_SECONDS=1` to exercise missing launch return,
wrapper death before receipt, vanished window, and foreground-settlement
timeout. Assert every case completes within the shared monotonic deadline,
logs generation/ordinal/stage, leaves `.pending`, preserves prior snapshot and
`last.session`, retains `restore-incomplete`, and releases `restore.lock` so a
later process can acquire it.

- [ ] **Step 3: Separate terminal failure from successful completion**

Make one pane write `bootstrap-failed` and settle in its safe shell. Assert the
parent stops waiting and releases the lock, but keeps `restore-incomplete` and
the prior exact snapshot. A saver after lock release must still skip
publication while the guard exists.

- [ ] **Step 4: Extend real-X topology coverage**

In `tests/kitty.nix`, assert a successful restore removes
`restore-incomplete` only after every planned Codex pane appears with exact
foreground resume argv. Trigger a subsequent save and assert the exact
`codex_session_id` remains in the published snapshot.

- [ ] **Step 5: Run RED and commit**

```bash
XDG_CACHE_HOME=/tmp/codex-kitty-nix-cache \
  nix build .#checks.x86_64-linux.kitty-scripts -L
```

Expected: first saver-race or finite-deadline assertion fails because saver and
restore do not yet share the full transaction. Commit failing tests only with
measured RED evidence; do not push.

### Task 8: Implement transaction, marker states, and bounded cleanup

**Files:**
- Modify: `home/kitty.nix`
- Test: `tests/kitty-scripts.nix`
- Test: `tests/kitty.nix`

- [ ] **Step 1: Serialize cold restore against autosave**

Write `restore-incomplete` immediately after taking `restore.lock`. Hold that
lock across reconciliation, generation publication, all launches, bootstrap
receipts, final `kitty @ ls` settlement, and eligible delivery attempts.
Change `kitty-session-save` to non-blockingly acquire the same lock before
socket discovery; if busy or `restore-incomplete` exists, exit zero before any
candidate or output replacement.

- [ ] **Step 2: Enforce one finite deadline and terminal settlement**

Compute one `time.monotonic() + timeout` deadline, using production 30 seconds
and only honoring `KITTY_RESTORE_TIMEOUT_SECONDS` in the generated test path.
Every socket, launch-return, expected-window, receipt, foreground, and preflight
wait consumes the remaining budget. Observe exact `codex resume <UUID>` as
successful settlement; observe `bootstrap-failed` plus safe shell as terminal
failure. Release the lock from a `finally` path on every exit.

- [ ] **Step 3: Preserve prior snapshots on incomplete restore**

Remove `restore-incomplete` only when every Codex pane settles on exact intended
argv and every other required pane launch succeeds. Timeout, vanished windows,
safe-shell settlement, cleanup failure, or guard-removal failure keeps the
guard and prior `snapshot.json`/`last.session` authoritative. Close partial
windows only when returned/self-reported ID and bootstrap argv prove ownership.

- [ ] **Step 4: Implement honest draft marker transitions**

Persist registry mapping before preflight. For eligible settled panes, validate
one exact window on the configured socket, then rename `.pending` to `.sending`.
A handled failure before spawning `send-text` may restore `.pending`; after any
send invocation, rename `.sending` to `.uncertain` regardless of return code.
Cold-start reconciliation also changes stale `.sending` to `.uncertain`.
Never automatically resend `.uncertain`.

Test seams immediately before and after `send-text` must prove:

```python
assert draft_bytes == b"Read $KITTY_RESTORE_NOTE."
assert b"\n" not in draft_bytes and b"\r" not in draft_bytes
```

If the window disappears after preflight, assert `.uncertain`, exact mapping
retained, no delivered claim, and no second send.

- [ ] **Step 5: Bound generations and topology shrink**

While holding `restore.lock`, reconcile markers and retain only active plus
immediately previous `generation-*`. Remove older generations, abandoned hidden
temporary directories, and legacy loose `pane-*.md*`. A smaller next topology
must activate only its current ordinals while keeping directory/file modes
`0700`/`0600`.

- [ ] **Step 6: Run all targeted GREEN gates and commit**

```bash
XDG_CACHE_HOME=/tmp/codex-kitty-nix-cache \
  nix build .#checks.x86_64-linux.kitty-scripts -L
XDG_CACHE_HOME=/tmp/codex-kitty-nix-cache \
  nix build .#checks.x86_64-linux.vm-claude-pane -L
XDG_CACHE_HOME=/tmp/codex-kitty-nix-cache \
  nix build .#checks.x86_64-linux.vm-kitty -L
```

Expected: all build successfully; fast harness proves races/deadlines/markers,
and VM lanes preserve exact identity plus real-X topology. Run
`git diff --cached --check`, then commit with exact durations and evidence in
the full risky checklist.

### Task 9: Repeat interactive dual-client smoke

**Files:**
- Modify only if smoke exposes a new confirmed defect; fix test-first under a
  new task before continuing.

- [ ] **Step 1: Prepare one clean feature VM**

Invoke `nixos-agent-testing`, run `nix run .#feature-vm`, and record its control
directory. The guest currently fails to decrypt host Anthropic/OpenAI agenix
recipients, so copy only those two host secret files directly into snapshot-VM
temporary files, mode `0600`, without printing contents or placing them in
argv. Create minimal guest-only Claude/Codex onboarding and SessionStart hook
config. One earlier boot hit a non-reproduced async-`#PF` kernel panic; treat a
recurrence as harness evidence, never as an acceptance skip.

- [ ] **Step 2: Create and capture exact real sessions**

Launch real Kitty under Cinnamon X11, seed one Claude and one Codex interactive
session, and record both UUIDs plus typed registry rows. Save, capture real
`kitty @ ls`, close the original process tree, and restore through the deployed
wrapper using its configured `/tmp/kitty.sock-*` socket convention.

- [ ] **Step 3: Verify manual decision point and identity retention**

Assert both foreground argv resume the recorded UUIDs. Before any new Codex
hook/transcript event, assert its bootstrap row exists. Verify both input
buffers contain exact unsent `Read $KITTY_RESTORE_NOTE.` and transcript counts
remain unchanged. Erase one draft with Ctrl+U/Backspace and prove no activity;
submit the other with Enter, then read its private note beneath
`~/.local/state/claude/kitty-restore/` and outside project cwd.

Trigger periodic save, close Kitty, restore a second time, and prove Codex again
uses the same UUID. This second restart is the regression that failed during
the first smoke.

- [ ] **Step 4: Clean test credentials and stop VM**

Delete the two explicit guest temporary key files, verify absence, stop the VM
gracefully, and confirm its snapshot control directory is removed. Capture
commands, decisive outputs, and screencaps for the PR body.

### Task 10: Integrated review and delivery

**Files:**
- Create outside repository: `/tmp/codex-kitty-restore-pr.md`

- [ ] **Step 1: Re-run integrated checks**

```bash
XDG_CACHE_HOME=/tmp/codex-kitty-nix-cache \
  nix build .#checks.x86_64-linux.kitty-scripts -L
XDG_CACHE_HOME=/tmp/codex-kitty-nix-cache \
  nix build .#checks.x86_64-linux.vm-claude-pane -L
XDG_CACHE_HOME=/tmp/codex-kitty-nix-cache \
  nix build .#checks.x86_64-linux.vm-kitty -L
nix flake check --no-build --all-systems
git diff --check origin/main...HEAD
```

Expected: all three derivations succeed, flake evaluation exits zero, and diff
check prints nothing.

- [ ] **Step 2: Run close-out review**

Invoke `advice-refine-test-loop once` over `origin/main...HEAD`. Reproduce each
material finding, fix confirmed defects test-first, and rerun the affected lane
plus all three targeted gates. Repeat until reviewer verdict is clean.

- [ ] **Step 3: Synchronize and verify delivery state**

Fetch `origin/main`. If advanced, merge it into `feat/codex-kitty-restore`
without rewriting history and rerun the full gate. Invoke `finishing-up`, run
`~/.claude/scripts/dod-check.py`, and ensure final HEAD has a complete risky
pre-push checklist matching the final diff and interactive evidence.

- [ ] **Step 4: Push, open PR, and monitor CI**

Push `feat/codex-kitty-restore`, create a PR targeting default branch, and
include root cause, behavior, exact automated commands, both smoke attempts,
and final successful screencaps. Watch every required check through completion;
fix failures at root and push normal follow-up commits. Stop when PR is green
and ready for the user's deliberate GitHub merge click.
